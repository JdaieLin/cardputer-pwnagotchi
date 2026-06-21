#!/usr/bin/env python3
import json
import os
import select
import struct
import sys

from PIL import Image, ImageDraw, ImageFont

FB_DEV = os.environ.get("PWNAGOTCHI_FBDEV", os.environ.get("APPLAUNCH_LINUX_FBDEV_DEVICE", "/dev/fb0"))
WIDTH = int(os.environ.get("PWNAGOTCHI_FB_WIDTH", "320"))
HEIGHT = int(os.environ.get("PWNAGOTCHI_FB_HEIGHT", "170"))

TEXT_FONT_CANDIDATES = [
    "/usr/share/APPLaunch/share/pwnagotchi/fonts/NotoSansSC-Bold.ttf",
    "/usr/share/APPLaunch/share/pwnagotchi/fonts/NotoSansSC-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/pwnagotchi/NotoSansSC-Bold.ttf",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]


def find_font(candidates):
    for path in candidates:
        if os.path.exists(path):
            return path
    raise RuntimeError("font not found")


FONT_PATH = find_font(TEXT_FONT_CANDIDATES)
FACE_FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf" if os.path.exists("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf") else FONT_PATH
TOP_FONT = ImageFont.truetype(FONT_PATH, 13)
BODY_FONT = ImageFont.truetype(FONT_PATH, 14)
FACE_FONT = ImageFont.truetype(FACE_FONT_PATH, 26)
BOTTOM_FONT = ImageFont.truetype(FONT_PATH, 13)
LAST_FRAME_KEY = None

def img_to_rgb565(img):
    data = bytearray()
    pixels = img.load()
    for y in range(img.height):
        for x in range(img.width):
            r, g, b, a = pixels[x, y]
            if a < 128:
                r, g, b = 0, 0, 0
            rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            data.extend(struct.pack("<H", rgb565))
    return bytes(data)


def face_for_mood(mood):
    return {
        "awake": "(◕‿‿◕)",
        "idle": "(◕‿‿◕)",
        "looking_r": "( ⚆_⚆)",
        "looking_l": "(☉_☉ )",
        "looking_r_happy": "( ◕‿◕)",
        "looking_l_happy": "(◕‿◕ )",
        "sleep": "(⇀‿‿↼)",
        "sleep2": "(≖‿‿≖)",
        "bored": "(-__-)",
        "bored2": "(—__—)",
        "intense": "(°▃▃°)",
        "intense2": "(°ロ°)",
        "busy": "(°▃▃°)",
        "cool": "(⌐■_■)",
        "cool2": "(단__단)",
        "listening-scanning": "(⌐■_■)",
        "happy": "(•‿‿•)",
        "happy-handshake": "(•‿‿•)",
        "happy2": "(^‿‿^)",
        "happy3": "(^◡◡^)",
        "grateful": "(^‿‿^)",
        "excited": "(ᵔ◡◡ᵔ)",
        "motivated": "(☼‿‿☼)",
        "motivated2": "(★‿★)",
        "motivated3": "(•̀ᴗ•́)",
        "demotivated": "(≖__≖)",
        "demotivated2": "(￣ヘ￣)",
        "demotivated3": "(¬､¬)",
        "smart": "(✜‿‿✜)",
        "friend": "(♥‿‿♥)",
        "friend2": "(♡‿‿♡)",
        "friend3": "(♥‿♥ )",
        "friend4": "(♥ω♥ )",
        "lonely": "(ب__ب)",
        "lonely2": "(｡•́︿•̀｡)",
        "lonely3": "(︶︹︺)",
        "sad": "(╥☁╥ )",
        "sad2": "(╥﹏╥)",
        "sad3": "(ಥ﹏ಥ)",
        "angry": "(-_-')",
        "angry2": "(⇀__⇀)",
        "angry3": "(`___´)",
        "broken": "(☓‿‿☓)",
        "error": "(☓‿‿☓)",
        "debug": "(#__#)",
        "upload": "(1__0)",
        "upload1": "(1__1)",
        "upload2": "(0__1)",
    }.get(mood, "(◕‿‿◕)")


def mode_label(mode):
    return "MANU" if mode == "manual" else "AUTO"


def uptime_label(uptime_s):
    hours = uptime_s // 3600
    minutes = (uptime_s % 3600) // 60
    seconds = uptime_s % 60
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def channel_label(channel):
    if isinstance(channel, int):
        return f"CH {channel:02d}"
    return f"CH {channel}"


def aps_label(ap_count, client_count):
    return f"APS {ap_count} ({client_count:02d})"


def pwned_label(count, last_session=""):
    label = f"PWND {count}"
    if last_session:
        label += f" [{last_session}]"
    return label


def wrap_text(text, font, max_width):
    if not text:
        return [""]
    lines = []
    current = ""
    for ch in text:
        test = current + ch
        bbox = font.getbbox(test)
        width = bbox[2] - bbox[0]
        if width <= max_width:
            current = test
        else:
            if current:
                lines.append(current)
            current = ch
    if current:
        lines.append(current)
    return lines or [text]


def render_frame(state):
    global LAST_FRAME_KEY
    frame_key = json.dumps(state, sort_keys=True, ensure_ascii=False)
    if frame_key == LAST_FRAME_KEY:
        return None
    LAST_FRAME_KEY = frame_key

    img = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 255))
    draw = ImageDraw.Draw(img, "RGBA")
    white = (255, 255, 255, 255)

    uptime_str = uptime_label(state['uptime_s'])
    bat_label = "BAT --" if state['battery_pct'] <= 0 else f"BAT {state['battery_pct']}"
    draw.text((10, 10), channel_label(state['channel']), font=TOP_FONT, fill=white)
    draw.text((56, 10), aps_label(state['ap_count'], state.get('client_count', 0)), font=TOP_FONT, fill=white)
    draw.text((136, 10), bat_label, font=TOP_FONT, fill=white)
    up_bbox = TOP_FONT.getbbox(f"UP {uptime_str}")
    up_width = up_bbox[2] - up_bbox[0]
    draw.text((WIDTH - 12 - up_width, 10), f"UP {uptime_str}", font=TOP_FONT, fill=white)

    draw.line((10, 29, WIDTH - 10, 29), fill=white, width=1)
    draw.text((10, 33), "pwnagotchi>", font=TOP_FONT, fill=white)

    draw.text((18, 55), face_for_mood(state["mood"]), font=FACE_FONT, fill=white)
    body_y = 50
    lines = wrap_text(state["action_message"] or state["status_text"], BODY_FONT, 128)
    for idx, line in enumerate(lines[:3]):
        draw.text((176, body_y + idx * 18), line, font=BODY_FONT, fill=white)

    draw.line((10, 142, WIDTH - 10, 142), fill=white, width=1)
    draw.text((12, 150), pwned_label(state["handshake_count"], state.get("last_session", "")), font=BOTTOM_FONT, fill=white)
    mode_bbox = BOTTOM_FONT.getbbox(mode_label(state["mode"]))
    mode_width = mode_bbox[2] - mode_bbox[0]
    draw.text((WIDTH - 12 - mode_width, 150), mode_label(state["mode"]), font=BOTTOM_FONT, fill=white)
    return img


def main():
    fb_fd = os.open(FB_DEV, os.O_RDWR)
    fb_size = WIDTH * HEIGHT * 2
    state = {
        "page": "HOME",
        "selected_action": 0,
        "bridge_connected": False,
        "action_pending": False,
        "action_message": "",
        "name": "Pwnagotchi",
        "mood": "idle",
        "mode": "auto",
        "service_state": "unknown",
        "bettercap_state": "unknown",
        "channel": 0,
        "handshake_count": 0,
        "ap_count": 0,
        "client_count": 0,
        "battery_pct": 0,
        "uptime_s": 0,
        "last_session": "",
        "status_text": "Waiting for state",
        "last_error": "",
    }

    print(json.dumps({"event": "connected"}), flush=True)
    while True:
        readable, _, _ = select.select([sys.stdin], [], [], 0.08)
        if readable:
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
            if cmd.get("cmd") == "quit":
                break
            if cmd.get("cmd") == "render":
                state.update(cmd)

        frame = render_frame(state)
        if frame is not None:
            os.lseek(fb_fd, 0, os.SEEK_SET)
            os.write(fb_fd, img_to_rgb565(frame)[:fb_size])

    os.close(fb_fd)


if __name__ == "__main__":
    main()
