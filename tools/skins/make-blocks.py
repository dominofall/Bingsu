#!/usr/bin/env python3
"""그림 스킨 'blocks'(납작한 색 블록) 만들기.

빙수 앱에 든 그림 스킨 예시다. 그림 경로(버튼 공통 그림·알약 9-slice·십자키+눌린 팔·스틱 바닥/손잡이·일시정지 버튼)를
전부 쓰므로, 이 스킨이 그려지면 그림 스킨 처리가 다 맞는 것이다. 그림은 모두 이 스크립트가 직접 그린다(외부 그림 없음, CC0).

    python3 tools/skins/make-blocks.py

결과:
    BingsuApp/Bingsu/Resources/Skins/blocks/skin.json + *.png
    docs/skins/examples/blocks.bingsuskin   (같은 파일을 zip 으로 묶은 것, 가져오기 시험용)

외부 패키지 없이 표준 라이브러리만 쓴다(부호 거리 함수로 모양을 그리고 zlib 으로 PNG 를 쓴다).
"""
import json
import math
import os
import struct
import sys
import zipfile
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "BingsuApp", "Bingsu", "Resources", "Skins", "blocks")
EXAMPLE = os.path.join(ROOT, "docs", "skins", "examples", "blocks.bingsuskin")

# 앱 아이콘 팔레트 (PLAN 7.6)
BLUE = (0x2F, 0x62, 0xC8)
NAVY = (0x1F, 0x3F, 0x94)
SKY = (0x6E, 0xC2, 0xE8)
CORAL = (0xEE, 0x6A, 0x55)
CORAL_DARK = (0xB8, 0x45, 0x36)
ICE = (0xF6, 0xFA, 0xFC)
SLATE = (0x3B, 0x3F, 0x4A)
SLATE_DARK = (0x23, 0x26, 0x2E)
GREY = (0x5A, 0x61, 0x70)
GREY_DARK = (0x3A, 0x3F, 0x4A)


# ---- 모양 (부호 거리: 안쪽 음수, 픽셀 단위) ----

def sd_round_rect(x, y, cx, cy, hw, hh, r):
    qx = abs(x - cx) - (hw - r)
    qy = abs(y - cy) - (hh - r)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r


def sd_circle(x, y, cx, cy, r):
    return math.hypot(x - cx, y - cy) - r


def sd_segment(x, y, ax, ay, bx, by, r):
    px, py, dx, dy = x - ax, y - ay, bx - ax, by - ay
    h = max(0.0, min(1.0, (px * dx + py * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - dx * h, py - dy * h) - r


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = [[0.0, 0.0, 0.0, 0.0] for _ in range(w * h)]  # 미리 곱한 RGBA (0~1)

    def paint(self, sdf, color, alpha=1.0):
        """sdf(x, y) < 0 인 곳을 color 로 덮는다 (가장자리 1px 부드럽게)"""
        r, g, b = (c / 255 for c in color)
        for j in range(self.h):
            for i in range(self.w):
                d = sdf(i + 0.5, j + 0.5)
                if d > 1:
                    continue
                a = max(0.0, min(1.0, 0.5 - d)) * alpha
                if a <= 0:
                    continue
                p = self.px[j * self.w + i]
                p[0] = r * a + p[0] * (1 - a)
                p[1] = g * a + p[1] * (1 - a)
                p[2] = b * a + p[2] * (1 - a)
                p[3] = a + p[3] * (1 - a)

    def png(self):
        raw = bytearray()
        for j in range(self.h):
            raw.append(0)
            for i in range(self.w):
                r, g, b, a = self.px[j * self.w + i]
                if a > 0:
                    r, g, b = r / a, g / a, b / a
                raw += bytes(int(round(max(0, min(1, v)) * 255)) for v in (r, g, b, a))

        def chunk(tag, data):
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


# ---- 그림 ----

S = 256       # 정사각 그림 한 변
LIP = 16      # 블록 아래 두께


def block_button(face, lip, pressed):
    """둥근 버튼: 둥근 사각 블록. 눌리면 윗면이 내려앉아 아래 두께가 사라진다"""
    c = Canvas(S, S)
    hw, r = 112, 44
    c.paint(lambda x, y: sd_round_rect(x, y, 128, 128 + LIP / 2, hw, hw - LIP / 2, r), lip)
    dy = LIP / 2 if pressed else 0
    c.paint(lambda x, y: sd_round_rect(x, y, 128, 128 - LIP / 2 + dy, hw, hw - LIP / 2, r), face)
    # 윗면 위쪽의 옅은 빛
    c.paint(lambda x, y: sd_round_rect(x, y, 128, 60 + dy, hw - 22, 14, 14), (255, 255, 255), 0.18)
    return c


def block_pill(face, lip, pressed):
    """알약 버튼: 가로로 긴 블록 (9-slice, 가운데가 늘어난다)"""
    c = Canvas(S, 128)
    c.paint(lambda x, y: sd_round_rect(x, y, 128, 64 + LIP / 2, 120, 56 - LIP / 2, 40), lip)
    dy = LIP / 2 if pressed else 0
    c.paint(lambda x, y: sd_round_rect(x, y, 128, 64 - LIP / 2 + dy, 120, 56 - LIP / 2, 40), face)
    return c


def plus(x, y, cx, cy, arm, half, r):
    return min(sd_round_rect(x, y, cx, cy, arm, half, r), sd_round_rect(x, y, cx, cy, half, arm, r))


def dpad():
    c = Canvas(S, S)
    arm, half = 42, 124
    c.paint(lambda x, y: plus(x, y, 128, 128 + 6, arm, half - 6, 14), SLATE_DARK)
    c.paint(lambda x, y: plus(x, y, 128, 128 - 6, arm, half - 6, 14), SLATE)
    c.paint(lambda x, y: sd_circle(x, y, 128, 122, 22), SLATE_DARK, 0.5)
    return c


def dpad_up_on():
    """위쪽 팔만 눌린 그림 (빙수가 돌려서 다른 방향에도 쓴다). 나머지는 투명"""
    c = Canvas(S, S)
    arm = 42
    c.paint(lambda x, y: sd_round_rect(x, y, 128, 2 + (128 - arm - 2) / 2, arm - 4, (128 - arm - 2) / 2 - 4, 12), SKY, 0.9)
    return c


def stick_base():
    c = Canvas(S, S)
    c.paint(lambda x, y: sd_circle(x, y, 128, 128, 124), SLATE_DARK, 0.85)
    c.paint(lambda x, y: sd_circle(x, y, 128, 128, 100), SLATE, 0.9)
    c.paint(lambda x, y: abs(sd_circle(x, y, 128, 128, 62)) - 3, SLATE_DARK, 0.6)
    return c


def stick_knob(face, lip):
    c = Canvas(S, S)
    c.paint(lambda x, y: sd_circle(x, y, 128, 128 + 10, 116), lip)
    c.paint(lambda x, y: sd_circle(x, y, 128, 128 - 4, 112), face)
    c.paint(lambda x, y: sd_circle(x, y, 128, 128 - 4, 64), (255, 255, 255), 0.12)
    return c


def orb():
    """일시정지 버튼: 흰 블록 위 파란 눈송이 (선 세 개 + 끝 갈래)"""
    c = Canvas(S, S)
    c.paint(lambda x, y: sd_round_rect(x, y, 128, 128 + 8, 120, 112, 56), NAVY)
    c.paint(lambda x, y: sd_round_rect(x, y, 128, 120, 120, 112, 56), ICE)
    segs = []
    for k in range(3):
        a = math.pi / 2 + k * math.pi / 3
        dx, dy = math.cos(a) * 70, math.sin(a) * 70
        segs.append((128 - dx, 120 - dy, 128 + dx, 120 + dy))
        for sgn in (1, -1):
            tx, ty = 128 + sgn * dx * 0.62, 120 + sgn * dy * 0.62
            for t in (-1, 1):
                b = a + t * math.pi / 4
                segs.append((tx, ty, tx + sgn * math.cos(b) * 26, ty + sgn * math.sin(b) * 26))
    c.paint(lambda x, y: min(sd_segment(x, y, *s, 7) for s in segs), BLUE)
    return c


def main():
    os.makedirs(OUT, exist_ok=True)
    images = {
        "round.png": block_button(BLUE, NAVY, False),
        "round-on.png": block_button(SKY, NAVY, True),
        "pill.png": block_pill(GREY, GREY_DARK, False),
        "pill-on.png": block_pill(SKY, GREY_DARK, True),
        "dpad.png": dpad(),
        "dpad-up-on.png": dpad_up_on(),
        "stick-base.png": stick_base(),
        "stick-knob.png": stick_knob(CORAL, CORAL_DARK),
        "stick-knob-on.png": stick_knob((0xF3, 0x8A, 0x78), CORAL_DARK),
        "pause.png": orb(),
    }
    skin = {
        "format": 1,
        "id": "blocks",
        "name": "블록",
        "license": "CC0-1.0",
        "note": "납작한 색 블록 그림 스킨. 그림 스킨을 만들 때 본보기로 쓰세요.",
        "colors": {"ink": "#FFFFFF", "text": "#FFFFFF", "fill": "#2F62C8", "press": "#6EC2E8", "rim": 0.6},
        "labels": {"style": "xbox", "font": "rounded"},
        "images": {
            "button.round": {"normal": "round.png", "pressed": "round-on.png"},
            "button.pill": {"normal": "pill.png", "pressed": "pill-on.png", "capInsets": {"top": 0, "left": 48, "bottom": 0, "right": 48}},
            "dpad": {"normal": "dpad.png", "pressedArm": "dpad-up-on.png"},
            "stick.base": {"normal": "stick-base.png"},
            "stick.knob": {"normal": "stick-knob.png", "pressed": "stick-knob-on.png"},
            "orb": {"normal": "pause.png"},
        },
    }
    # 예전에 만든 PNG 중 이제 안 쓰는 것은 지운다
    for n in os.listdir(OUT):
        if n.endswith(".png") and n not in images:
            os.remove(os.path.join(OUT, n))
    for name, canvas in images.items():
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(canvas.png())
        print("  ", name, f"{canvas.w}x{canvas.h}")
    with open(os.path.join(OUT, "skin.json"), "w", encoding="utf-8") as f:
        json.dump(skin, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.makedirs(os.path.dirname(EXAMPLE), exist_ok=True)
    with zipfile.ZipFile(EXAMPLE, "w", zipfile.ZIP_DEFLATED) as z:
        for n in ["skin.json"] + sorted(images):
            z.write(os.path.join(OUT, n), n)
    print("blocks:", OUT)
    print("예시 zip:", EXAMPLE, os.path.getsize(EXAMPLE), "bytes")


if __name__ == "__main__":
    sys.exit(main())
