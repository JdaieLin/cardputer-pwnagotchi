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
TOP_FONT = ImageFont.truetype(FONT_PATH, 14)
BODY_FONT = ImageFont.truetype(FONT_PATH, 16)
FACE_FONT = ImageFont.truetype(FACE_FONT_PATH, 25)
BOTTOM_FONT = ImageFont.truetype(FONT_PATH, 16)
LAST_FRAME_KEY = None


def img_to_rgb565(img):
    data = bytearray()
    pixels = img.load()
    for y in range(img.height):
        for x in range(img.width):
            r, g, b, a = pixels[x, y]
            if a < 128:
                r, g, b = 255, 255, 255
            rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            data.extend(struct.pack("<H", rgb565))
    return bytes(data)


def face_for_mood(mood):
    return {
        "idle": "(◕‿‿◕)",
        "listening-scanning": "(⌐■_■)",
        "happy-handshake": "(•‿‿•)",
        "busy": "(°▃▃°)",
        "error": "(☓‿‿☓)",
    }.get(mood, "(◕‿‿◕)")


def mode_label(mode):
    return "MANU" if mode == "manual" else "AUTO"


def uptime_label(uptime_s):
    hours = uptime_s // 3600
    minutes = (uptime_s % 3600) // 60
    return f"{hours:02d}:{minutes:02d}"


def pwned_label(count):
    return f"PWND {count} ({count:02d})"


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

    img = Image.new("RGBA", (WIDTH, HEIGHT), (255, 255, 255, 255))
    draw = ImageDraw.Draw(img, "RGBA")
    black = (0, 0, 0, 255)

    draw.rectangle([1, 1, WIDTH - 2, HEIGHT - 2], outline=black, width=1)
    draw.text((10, 10), f"CH {state['channel']}", font=TOP_FONT, fill=black)
    draw.text((76, 10), f"APS {state['ap_count']}", font=TOP_FONT, fill=black)
    draw.text((200, 10), f"BAT {state['battery_pct']}", font=TOP_FONT, fill=black)
    draw.text((258, 10), f"UP {uptime_label(state['uptime_s'])}", font=TOP_FONT, fill=black)

    draw.text((18, 70), face_for_mood(state["mood"]), font=FACE_FONT, fill=black)
    lines = wrap_text(state["action_message"] or state["status_text"], BODY_FONT, 128)
    for idx, line in enumerate(lines[:3]):
        draw.text((176, 60 + idx * 18), line, font=BODY_FONT, fill=black)

    draw.line((10, 142, WIDTH - 10, 142), fill=black, width=1)
    draw.text((12, 150), pwned_label(state["handshake_count"]), font=BOTTOM_FONT, fill=black)
    mode_bbox = BOTTOM_FONT.getbbox(mode_label(state["mode"]))
    mode_width = mode_bbox[2] - mode_bbox[0]
    draw.text((WIDTH - 12 - mode_width, 150), mode_label(state["mode"]), font=BOTTOM_FONT, fill=black)
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
