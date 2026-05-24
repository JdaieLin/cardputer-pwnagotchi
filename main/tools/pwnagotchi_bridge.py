#!/usr/bin/env python3
import argparse
import base64
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
        count += 1
        try:
            mtime = entry.stat().st_mtime
        except OSError:
            continue
        if mtime > latest_ts:
            latest_ts = mtime
            latest = time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime))
    return count, latest


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
    battery_pct = read_battery_pct()

    mood = "awake"
    if cap_state == "online":
        mood = "cool"
    if handshake_count > 0:
        mood = "happy"
    if service not in ("active", "running"):
        mood = "sleep"

    if monitor_error:
        status = monitor_error
    elif cap_state == "online" and (ap_count or client_count):
        status = f"scanning {ap_count} APs / {client_count} clients"
    elif cap_state == "online":
        status = "listening for Wi-Fi...  (•‿‿•)"
    elif service not in ("active", "running"):
        status = "paused - start service to scan"
    else:
        status = "connecting..."

    last_error = ""
    if service not in ("active", "running"):
        last_error = f"service {service}"
    elif monitor_error:
        last_error = monitor_error
    elif cap_error:
        last_error = cap_error

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
