#!/usr/bin/env python3
"""Builds the website's images from app snapshots.

    swift build
    .build/debug/Keel --snapshots /tmp/keel-shots --tweak dock-autohide-instant
    scripts/site-images.py /tmp/keel-shots

Writes WebP files at 1x, 1.5x and 2x widths plus the Open Graph image to docs/site/assets/img/.
Needs Pillow (pip install pillow).
"""
import os, sys
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

if len(sys.argv) != 2:
    sys.exit(__doc__)
shots = sys.argv[1]
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, "docs", "site", "assets", "img")
os.makedirs(out, exist_ok=True)


def shot(name):
    return Image.open(os.path.join(shots, f"{name}.png")).convert("RGB")


def save(im, name, widths, quality=84):
    for w in widths:
        r = im if w == im.width else im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)
        path = os.path.join(out, f"{name}-{w}.webp")
        r.save(path, "WEBP", quality=quality, method=6)
        print(f"{os.path.relpath(path, root)}  {r.width}x{r.height}  {os.path.getsize(path) // 1024} KB")


# Window snapshots are 2560x1640 (a 1280x820 window at 2x).
save(shot("tweaks-1280-dark"), "tweaks", [1280, 1920, 2560])
save(shot("tweaks-drawer-1280-dark"), "detail", [1280, 1920, 2560])
save(shot("cleanup-1280-dark"), "cleanup", [1280, 1920, 2560])
save(shot("tweaks-drawer-1280-dark").crop((1840, 56, 2560, 1588)), "drawer", [480, 720])
save(shot("confirm-dark").crop((681, 425, 1880, 1273)), "confirm", [800, 1199])
save(shot("menubar-dark"), "menubar", [320, 640])


def sf(size, weight):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    f.set_variation_by_axes([100, 96, 400, weight])  # width, optical size, grade, weight
    return f


# Open Graph image, drawn at 2x and downsampled.
W, H = 2400, 1260
glow = Image.new("RGB", (W, H))
g = ImageDraw.Draw(glow)
cx, cy = 1900, 1300
for r in range(1300, 0, -8):
    a = (1 - r / 1300) ** 1.8
    g.ellipse((cx - r * 1.5, cy - r, cx + r * 1.5, cy + r), fill=(int(255 * a), int(105 * a), int(25 * a)))
img = ImageChops.add(Image.new("RGB", (W, H), (18, 18, 18)), glow.filter(ImageFilter.GaussianBlur(80)))

ui = shot("tweaks-drawer-1280-dark").resize((1400, 897), Image.LANCZOS)
x, y = 1260, 440
shadow = Image.new("L", (W, H))
ImageDraw.Draw(shadow).rounded_rectangle((x, y + 40, x + 1400, y + 937), radius=30, fill=230)
img.paste((0, 0, 0), (0, 0), shadow.filter(ImageFilter.GaussianBlur(60)))
mask = Image.new("L", ui.size)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, *ui.size), radius=30, fill=255)
img.paste(ui, (x, y), mask)
ImageDraw.Draw(img).rounded_rectangle((x, y, x + 1400, y + 897), radius=30, outline=(78, 78, 78), width=3)

icon = Image.open(os.path.join(root, "docs", "site", "assets", "icon-256.png")).convert("RGBA").resize((168, 168), Image.LANCZOS)
img.paste(icon, (140, 150), icon)
d = ImageDraw.Draw(img)
# Two-line headline, sized to fit beside the screenshot.
size = 118
while sf(size, 640).getlength("Put it back exactly.") > x - 136 - 56:
    size -= 2
head = sf(size, 640)
d.text((136, 400), "Tune your Mac.", font=head, fill=(242, 242, 242))
d.text((136, 400 + size * 1.2), "Put it back ", font=head, fill=(242, 242, 242))
d.text((136 + head.getlength("Put it back "), 400 + size * 1.2), "exactly.", font=head, fill=(255, 146, 64))
d.text((140, 760), "Free and open source", font=sf(48, 460), fill=(170, 170, 170))
d.text((140, 826), "for Apple silicon Macs.", font=sf(48, 460), fill=(170, 170, 170))
d.text((140, 1110), "keel.mohdmahmodi.com", font=sf(40, 500), fill=(120, 120, 120))
path = os.path.join(out, "og-2.jpg")
img.resize((1200, 630), Image.LANCZOS).save(path, quality=88, optimize=True, progressive=True)
print(f"{os.path.relpath(path, root)}  1200x630  {os.path.getsize(path) // 1024} KB")
