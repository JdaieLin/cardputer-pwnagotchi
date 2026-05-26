#!/usr/bin/env python3
import argparse
import base64
import struct
import json
import os
import pathlib
import select
import subprocess
import sys
import time
import urllib.error
import urllib.request

try:
    import tomllib
except ImportError:  # pragma: no cover
    tomllib = None


MODE_ENV_FILE = "/etc/default/pwnagotchi-cardputer"


def print_event(event, payload):
    body = {"event": event}
    body.update(payload)
    print(json.dumps(body, ensure_ascii=False), flush=True)


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def service_state(name):
    result = sh(["systemctl", "is-active", name])
    if result.returncode == 0:
        return result.stdout.strip() or "active"
    text = (result.stdout + result.stderr).strip()
    return text or "inactive"


def load_config(path):
    config = {}
    if not path or not os.path.exists(path) or tomllib is None:
        return config
    with open(path, "rb") as f:
        config = tomllib.load(f)
    return config


def nested_get(data, keys, default=None):
    cur = data
    for key in keys:
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur


def count_handshakes(path):
    root = pathlib.Path(path)
    try:
        if not root.exists():
            return 0, ""
    except PermissionError:
        return 0, ""
    count = 0
    latest = ""
    latest_ts = 0.0
    try:
        entries = list(root.rglob("*"))
    except PermissionError:
        return 0, ""
    for entry in entries:
        if not entry.is_file():
            continue
        if entry.suffix.lower() not in (".pcap", ".pcapng", ".22000", ".hccapx"):
            continue
        try:
            size = entry.stat().st_size
        except OSError:
            continue
        # A 24-byte pcap is just the global header, not a captured handshake.
        if entry.suffix.lower() in (".pcap", ".pcapng") and size <= 24:
            continue
        count += 1
        try:
            mtime = entry.stat().st_mtime
        except OSError:
            continue
        if mtime > latest_ts:
            latest_ts = mtime
            latest = extract_pcap_ssid(entry) or handshake_label_from_filename(entry) or time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime))
    return count, latest


def mac_addr(raw):
    if len(raw) != 6:
        return ""
    return ":".join(f"{b:02x}" for b in raw)


def bssid_for_data_frame(frame, fc):
    to_ds = bool(fc & 0x0100)
    from_ds = bool(fc & 0x0200)
    if len(frame) < 24:
        return ""
    if not to_ds and not from_ds:
        return mac_addr(frame[16:22])
    if to_ds and not from_ds:
        return mac_addr(frame[4:10])
    if from_ds and not to_ds:
        return mac_addr(frame[10:16])
    if len(frame) >= 30:
        return mac_addr(frame[24:30])
    return ""


def ssid_from_tags(tags):
    idx = 0
    while idx + 2 <= len(tags):
        tag_id = tags[idx]
        length = tags[idx + 1]
        value = tags[idx + 2:idx + 2 + length]
        if idx + 2 + length > len(tags):
            break
        if tag_id == 0:
            try:
                return value.decode("utf-8", "ignore").strip()
            except UnicodeDecodeError:
                return ""
        idx += 2 + length
    return ""


def extract_pcap_ssid(entry):
    if entry.suffix.lower() not in (".pcap", ".pcapng"):
        return ""
    try:
        data = entry.read_bytes()
    except (OSError, PermissionError):
        return ""
    if len(data) <= 24:
        return ""
    magic = data[:4]
    if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        endian = "<"
    elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        endian = ">"
    else:
        return ""

    offset = 24
    bssid_to_ssid = {}
    eapol_bssid = ""
    while offset + 16 <= len(data):
        try:
            incl_len = struct.unpack(endian + "I", data[offset + 8:offset + 12])[0]
        except struct.error:
            break
        offset += 16
        packet = data[offset:offset + incl_len]
        offset += incl_len
        if len(packet) < 8:
            continue
        radiotap_len = struct.unpack_from("<H", packet, 2)[0]
        if radiotap_len >= len(packet):
            continue
        frame = packet[radiotap_len:]
        if len(frame) < 24:
            continue
        fc = struct.unpack_from("<H", frame, 0)[0]
        frame_type = (fc >> 2) & 0x3
        subtype = (fc >> 4) & 0xF
        if frame_type == 0 and subtype in (5, 8):
            ssid = ssid_from_tags(frame[36:])
            if ssid:
                bssid_to_ssid[mac_addr(frame[16:22])] = ssid
        elif frame_type == 2 and b"\xaa\xaa\x03\x00\x00\x00\x88\x8e" in frame:
            candidate = bssid_for_data_frame(frame, fc)
            if candidate:
                eapol_bssid = candidate

    if eapol_bssid and eapol_bssid in bssid_to_ssid:
        return bssid_to_ssid[eapol_bssid][:24]
    return ""


def handshake_label_from_filename(entry):
    stem = entry.stem
    if stem in ("bettercap-wifi-handshakes", "handshakes"):
        return ""
    for suffix in ("_handshake", "-handshake", ".handshake"):
        stem = stem.replace(suffix, "")
    stem = stem.replace("_", " ").replace("-", " ").strip()
    if not stem or stem.lower().startswith("closed loop"):
        return ""
    return stem[:24]


def recent_pwned_network():
    result = sh(["journalctl", "-u", "bettercap.service", "-n", "240", "--no-pager"])
    text = result.stdout + result.stderr
    latest = ""
    for line in text.splitlines():
        if "handshake" in line.lower() and " for " in line:
            candidate = line.rsplit(" for ", 1)[-1].split(" (", 1)[0].strip(" .")
            if candidate:
                latest = candidate
    return latest[:24]


def current_wifi_ssid():
    result = sh(["nmcli", "-t", "-f", "ACTIVE,SSID", "dev", "wifi"])
    for line in result.stdout.splitlines():
        if line.startswith("yes:"):
            ssid = line.split(":", 1)[1].replace("\\:", ":").strip()
            if ssid:
                return ssid[:24]
    return ""


def bettercap_state(url, username, password):
    req = urllib.request.Request(url.rstrip("/") + "/session")
    token = base64.b64encode(f"{username}:{password}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    try:
        with urllib.request.urlopen(req, timeout=1.2) as resp:
            raw = json.loads(resp.read().decode("utf-8", "ignore"))
    except Exception as exc:
        return "offline", 0, 0, 0, f"bettercap unavailable: {exc}"

    ap_count = 0
    client_count = 0
    channel = 0
    wifi = raw.get("wifi") if isinstance(raw, dict) else None
    if isinstance(wifi, dict):
        aps = wifi.get("aps") or wifi.get("access_points") or []
        clients = wifi.get("clients") or []
        channel = wifi.get("channel") or wifi.get("current_channel") or 0
        if isinstance(aps, list):
            ap_count = len(aps)
            for ap in aps:
                if isinstance(ap, dict):
                    if not channel:
                        channel = ap.get("channel") or 0
                    stations = ap.get("clients") or ap.get("stations") or []
                    if isinstance(stations, list):
                        client_count += len(stations)
        if isinstance(clients, list):
            client_count = max(client_count, len(clients))
    return "online", ap_count, client_count, int(channel or 0), ""


def bettercap_monitor_error(service_name):
    result = sh(["journalctl", "-u", f"{service_name}.service", "-n", "80", "--no-pager"])
    text = (result.stdout + result.stderr).lower()
    if "operation not supported" in text and "initializing" in text:
        return "monitor channel unsupported"
    if "cannot create monitor interface" in text:
        return "monitor interface unavailable"
    if "executable file not found" in text and "iw" in text:
        return "iw command unavailable"
    return ""


def read_battery_pct():
    ps_dir = "/sys/class/power_supply"
    voltage_uv = 0
    if os.path.isdir(ps_dir):
        for name in os.listdir(ps_dir):
            if name.startswith("."):
                continue
            base = os.path.join(ps_dir, name)
            cap_path = os.path.join(base, "capacity")
            if os.path.exists(cap_path):
                try:
                    value = int(pathlib.Path(cap_path).read_text().strip())
                    if 0 <= value <= 100:
                        return value
                    if 100 < value <= 10000:
                        return max(0, min(100, round(value / 65.0)))
                except Exception:
                    pass
            volt_path = os.path.join(base, "voltage_now")
            if os.path.exists(volt_path):
                try:
                    voltage_uv = max(voltage_uv, int(pathlib.Path(volt_path).read_text().strip()))
                except Exception:
                    pass

    try:
        import smbus2
        bus = smbus2.SMBus(1)
        try:
            raw = bus.read_word_data(0x55, 0x2C)
            soc = raw & 0xFF
            if soc > 100:
                soc = (raw >> 8) & 0xFF
            if 0 <= soc <= 100:
                return soc
        except Exception:
            pass
        finally:
            bus.close()
    except Exception:
        pass

    if voltage_uv > 0:
        voltage_v = voltage_uv / 1_000_000.0
        if voltage_v >= 4.20:
            return 100
        if voltage_v >= 4.10:
            return 90
        if voltage_v >= 4.00:
            return 80
        if voltage_v >= 3.92:
            return 70
        if voltage_v >= 3.86:
            return 60
        if voltage_v >= 3.80:
            return 50
        if voltage_v >= 3.74:
            return 40
        if voltage_v >= 3.68:
            return 30
        if voltage_v >= 3.62:
            return 20
        if voltage_v >= 3.56:
            return 10
        return 5

    return 0


def read_uptime_s():
    try:
        raw = pathlib.Path("/proc/uptime").read_text().split()[0]
        return int(float(raw))
    except Exception:
        return int(time.monotonic())


def read_mode_override():
    if not os.path.exists(MODE_ENV_FILE):
        return ""
    for line in pathlib.Path(MODE_ENV_FILE).read_text().splitlines():
        if line.startswith("PWNAGOTCHI_MODE="):
            return line.split("=", 1)[1].strip().strip('"')
    return ""


def rotating_choice(options, period_s=20):
    if not options:
        return ""
    index = int(time.monotonic() // period_s) % len(options)
    return options[index]


def personality_state(service, cap_state, ap_count, client_count, handshake_count, channel, monitor_error, cap_error):
    if service not in ("active", "running") and cap_state != "online":
        return "sleep", "ZzzzZZzzzzZzzz"
    if monitor_error:
        return "broken", monitor_error
    if cap_state != "online":
        return "sad", cap_error or "Where's everybody?!"
    if handshake_count > 0:
        return "happy-handshake", f"Cool, we got {handshake_count} handshake{'s' if handshake_count != 1 else ''}!"
    if ap_count >= 40 and client_count >= 8:
        return "excited", rotating_choice([
            "So many networks!!!",
            "I'm having so much fun!",
            "I pwn therefore I am.",
        ])
    if client_count > 0:
        return "intense", rotating_choice([
            f"Watching {client_count} stations",
            "My crime is curiosity ...",
            f"CH {channel}: making friends",
        ])
    if ap_count >= 20:
        return "motivated", rotating_choice([
            f"Looking at {ap_count} APs",
            "This is the best day of my life!",
            "New day, new hunt!",
        ])
    if ap_count > 0:
        return "awake", rotating_choice([
            f"Looking around ({ap_count} APs)",
            "...",
            "Waiting for clients ...",
        ])
    return "bored", rotating_choice([
        "I'm bored ...",
        "Let's go for a walk!",
        "Where's everybody?!",
    ])


def write_mode_override(mode):
    content = f'PWNAGOTCHI_MODE="{mode}"\n'
    pathlib.Path(MODE_ENV_FILE).write_text(content)


def action_service(service_name, action):
    result = sh(["systemctl", action, service_name])
    ok = result.returncode == 0
    msg = (result.stdout + result.stderr).strip() or f"{action} {service_name}"
    return ok, msg


def action_set_mode(service_name, mode):
    try:
        write_mode_override(mode)
    except Exception as exc:
        return False, f"mode write failed: {exc}"
    restart = sh(["systemctl", "restart", service_name])
    ok = restart.returncode == 0
    msg = (restart.stdout + restart.stderr).strip() or f"mode set to {mode}"
    return ok, msg


def aggregate_state(args):
    cfg = load_config(args.config)
    name = nested_get(cfg, ["main", "name"], "Pwnagotchi") or "Pwnagotchi"
    mode = read_mode_override() or nested_get(cfg, ["main", "mode"], "auto") or "auto"
    service = service_state(args.service_name)
    cap_state, ap_count, client_count, channel, cap_error = bettercap_state(
        args.bettercap_api_url, args.bettercap_username, args.bettercap_password
    )
    monitor_error = ""
    if cap_state == "online" and not (ap_count or client_count):
        monitor_error = bettercap_monitor_error("bettercap")
    handshake_count, last_session = count_handshakes(args.handshakes_dir)
    recent_network = recent_pwned_network()
    if recent_network:
        last_session = recent_network
    elif handshake_count > 0 and not last_session:
        last_session = current_wifi_ssid()
    battery_pct = read_battery_pct()

    last_error = ""
    if service not in ("active", "running") and cap_state != "online":
        last_error = f"service {service}"
    elif monitor_error:
        last_error = monitor_error
    elif cap_error:
        last_error = cap_error

    mood, status = personality_state(
        service,
        cap_state,
        ap_count,
        client_count,
        handshake_count,
        channel,
        monitor_error,
        cap_error,
    )

    return {
        "name": name,
        "mood": mood,
        "mode": mode,
        "service_state": service,
        "bettercap_state": cap_state,
        "channel": channel,
        "handshake_count": handshake_count,
        "ap_count": ap_count,
        "client_count": client_count,
        "battery_pct": battery_pct,
        "uptime_s": read_uptime_s(),
        "last_session": last_session,
        "status_text": status,
        "last_error": last_error,
    }


def handle_action(args, name):
    if name == "start_service":
        return action_service(args.service_name, "start")
    if name == "stop_service":
        return action_service(args.service_name, "stop")
    if name == "restart_service":
        return action_service(args.service_name, "restart")
    if name == "set_manual":
        return action_set_mode(args.service_name, "manual")
    if name == "set_auto":
        return action_set_mode(args.service_name, "auto")
    return False, f"unknown action: {name}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--handshakes-dir", required=True)
    parser.add_argument("--service-name", required=True)
    parser.add_argument("--bettercap-api-url", required=True)
    parser.add_argument("--bettercap-username", required=True)
    parser.add_argument("--bettercap-password", required=True)
    args = parser.parse_args()

    print_event("connected", {})
    while True:
        readable, _, _ = select.select([sys.stdin], [], [], 0.2)
        if not readable:
            continue
        line = sys.stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except json.JSONDecodeError:
            continue
        if cmd.get("cmd") == "poll":
            print_event("state", aggregate_state(args))
        elif cmd.get("cmd") == "action":
            ok, message = handle_action(args, cmd.get("name", ""))
            print_event("action_result", {"ok": ok, "message": message})
            print_event("state", aggregate_state(args))


if __name__ == "__main__":
    main()
