#!/usr/bin/env python3
"""Draws the disk image window background: Resources/dmg-background.tiff (1x and 2x).

    scripts/make-dmg-background.py

The layout matches scripts/make-dmg.sh: a 600x380 window, Keel at (150, 190) and Applications at
(450, 190). The background is light so Finder's icon labels stay readable in light and dark mode.
Needs Pillow (pip install pillow).
"""
import os, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageFont

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W, H = 600, 380


def sf(size, weight):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    f.set_variation_by_axes([100, min(96, max(17, size)), 400, weight])
    return f


def draw(scale):
    w, h = W * scale, H * scale
    img = Image.new("RGB", (w, h), (246, 245, 244))
    glow = Image.new("L", (w, h))
    ImageDraw.Draw(glow).ellipse((w * 0.15, h * 0.55, w * 0.85, h * 1.35), fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(70 * scale))
    img.paste(Image.new("RGB", (w, h), (255, 226, 205)), (0, 0), glow.point(lambda v: int(v * 0.55)))

    d = ImageDraw.Draw(img)
    s = lambda v: int(v * scale)
    title = "Drag Keel into Applications"
    f = sf(s(20), 620)
    d.text(((w - d.textlength(title, font=f)) / 2, s(36)), title, font=f, fill=(29, 29, 31))
    sub = "Then open it from Applications or Spotlight."
    f2 = sf(s(13), 440)
    d.text(((w - d.textlength(sub, font=f2)) / 2, s(66)), sub, font=f2, fill=(110, 110, 115))

    # Arrow between the two icons.
    y = s(190)
    x0, x1 = s(238), s(362)
    d.line((x0, y, x1 - s(4), y), fill=(255, 122, 47), width=s(3))
    d.polygon([(x1, y), (x1 - s(12), y - s(8)), (x1 - s(12), y + s(8))], fill=(255, 122, 47))
    return img


tmp = tempfile.mkdtemp()
one, two = os.path.join(tmp, "bg.png"), os.path.join(tmp, "bg@2x.png")
draw(1).save(one)
draw(2).save(two)
out = os.path.join(root, "Resources", "dmg-background.tiff")
subprocess.run(["tiffutil", "-cathidpicheck", one, two, "-out", out], check=True, capture_output=True)
print(f"{os.path.relpath(out, root)}  {os.path.getsize(out) // 1024} KB")
