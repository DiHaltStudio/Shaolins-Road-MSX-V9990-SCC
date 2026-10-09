#!/usr/bin/env python3
"""Pictures of a V9990 game manual from manual.json: cover, montage, annotated HUD crops, label.

usage: manual_images.py MANUAL_DIR [PROJECT_ROOT]
  MANUAL_DIR    the folder with manual.tex and manual.json (img/ is written next to them)
  PROJECT_ROOT  paths in manual.json are relative to it (default: two levels above MANUAL_DIR)

manual.json (all paths relative to PROJECT_ROOT, sizes in pixels of those pictures):
{
  "cover":   "assets/intro/opening.png",           # cover art; scaled and cropped to fill an A4 page
  "cover_shot": "docs/img/cover.png",              # optional: screenshot of the cover shown by the game
  "title":   "docs/img/title.png",                 # screenshot of the title screen (copied as img/title.png)
  "montage": ["docs/img/a.png", ...],              # 3 to 6 screenshots, laid out as one wide picture
  "huds": [ {"name": "hud", "src": "docs/img/play.png", "box": [x0,y0,x1,y1],
             "labels": [[1, x, y], [2, x, y, "b"], ...]} ],   # numbered callouts (above, or "b" below); x,y in src pixels
                                                           # keep callouts at least 22 px apart (in src pixels) on a side
  "label": {"lines": ["MSX1 \u00b7 64 KB RAM", "Konami SCC MegaROM \u00b7 1 MiB"],
            "credit": "KONAMI 1985 \u00b7 V9990 PORT: DIHALT STUDIO 2026",
            "crop": [x0,y0,x1,y1], "fit": false, "accent": [235,170,30], "bg": [8,8,20]}
}
"""
import json, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

SANS = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
SANS_REG = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'


def font(size, bold=True):
    return ImageFont.truetype(SANS if bold else SANS_REG, size)


def fill_crop(image, ratio):
    """Crop image (centre) to width/height = ratio."""
    w, h = image.size
    if w / h > ratio:
        nw = int(h * ratio)
        return image.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
    nh = int(w / ratio)
    return image.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))


def cover(cfg, root, out):
    image = Image.open(root / cfg['cover']).convert('RGB')
    image = fill_crop(image, 210 / 297)                 # A4 portrait
    image.save(out / 'cover.jpg', quality=90)


def plain(cfg, root, out):
    if cfg.get('cover_shot'):
        Image.open(root / cfg['cover_shot']).convert('RGB').save(out / 'cover-shot.png')
    elif cfg.get('cover'):
        shot = Image.open(root / cfg['cover']).convert('RGB')
        canvas = Image.new('RGB', (640, 480), (0, 0, 0))
        shot.thumbnail((640, 480), Image.LANCZOS)
        canvas.paste(shot, ((640 - shot.width) // 2, 0))
        canvas.save(out / 'cover-shot.png')
    Image.open(root / cfg['title']).convert('RGB').save(out / 'title.png')


def montage(cfg, root, out):
    """A black strip with the screenshots side by side (two rows when there are more than three)."""
    shots = [Image.open(root / p).convert('RGB') for p in cfg['montage']]
    cols = 3 if len(shots) > 3 else len(shots)
    rows = (len(shots) + cols - 1) // cols
    tw = 640 if cols < 3 else 520
    th = int(tw * 3 / 4)
    pad = 12
    canvas = Image.new('RGB', (cols * tw + (cols + 1) * pad, rows * th + (rows + 1) * pad), (8, 8, 20))
    for i, s in enumerate(shots):
        s = s.resize((tw, th), Image.LANCZOS if s.width > tw else Image.NEAREST)
        canvas.paste(s, (pad + (i % cols) * (tw + pad), pad + (i // cols) * (th + pad)))
    canvas.save(out / 'montage.png')


def hud(cfg, root, out):
    """Numbered callouts above ('t', default) or below ('b') the cropped HUD: labels [n, x, y, side]."""
    for h in cfg.get('huds', []):
        shot = Image.open(root / h['src']).convert('RGB')
        x0, y0, x1, y1 = h['box']
        k = 2
        crop = shot.crop((x0, y0, x1, y1)).resize(((x1 - x0) * k, (y1 - y0) * k), Image.NEAREST)
        band = 70
        both = any(len(l) > 3 and l[3] == 'b' for l in h['labels'])
        top_band = band
        bottom_band = band if both else 0
        canvas = Image.new('RGB', (crop.width, crop.height + top_band + bottom_band), (0, 0, 0))
        canvas.paste(crop, (0, top_band))
        draw = ImageDraw.Draw(canvas)
        for lab in h['labels']:
            n, x, y = lab[:3]
            side = lab[3] if len(lab) > 3 else 't'
            cx = (x - x0) * k
            ty = (y - y0) * k + top_band
            if side == 't':
                cy, sgn = band // 2, 1
            else:
                cy, sgn = top_band + crop.height + band // 2, -1
            draw.line((cx, cy + sgn * 22, cx, ty - sgn * 6), fill=(255, 220, 40), width=3)
            draw.ellipse((cx - 22, cy - 22, cx + 22, cy + 22), fill=(255, 220, 40), outline=(0, 0, 0), width=3)
            draw.text((cx, cy), str(n), fill=(0, 0, 0), font=font(30), anchor='mm')
        canvas.save(out / (h['name'] + '.png'))


def label(cfg, root, out):
    """Cartridge label, 3:2, 1800x1200 px."""
    c = cfg['label']
    w, h = 1800, 1200
    bg = tuple(c.get('bg', (8, 8, 20)))
    accent = tuple(c.get('accent', (235, 170, 30)))
    img = Image.new('RGB', (w, h), bg)
    art = Image.open(root / cfg['cover']).convert('RGB')
    if c.get('crop'):
        art = art.crop(tuple(c['crop']))
    if c.get('fit'):                       # whole crop, centred, bars of the background colour at the sides
        art = art.resize((int(art.width * 860 / art.height), 860), Image.LANCZOS)
        img.paste(art, ((w - art.width) // 2, 0))
    else:                                  # crop to fill the 1800x860 art area
        art = fill_crop(art, w / 860)
        img.paste(art.resize((w, 860), Image.LANCZOS), (0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle((0, 852, w, 868), fill=accent)
    msx = Image.open(out / 'msx-logo.png').convert('RGBA')
    msx = msx.resize((int(msx.width * 150 / msx.height), 150), Image.LANCZOS)
    img.paste(msx, (60, 905), msx)
    lines = c.get('lines', [])
    if lines:
        d.text((60 + msx.width + 40, 930), lines[0], fill=(255, 255, 255), font=font(54))
    if len(lines) > 1:
        d.text((60 + msx.width + 40, 1000), lines[1], fill=(190, 190, 200), font=font(40, False))
    d.rounded_rectangle((1060, 890, 1740, 1070), radius=26, fill=(255, 255, 255))
    logo = Image.open(out / 'v9990-logo.png').convert('RGB')
    logo = logo.resize((600, int(600 * logo.height / logo.width)), Image.LANCZOS)
    img.paste(logo, (1100, 900))
    d.text((1400, 1040), 'REQUIRED', fill=bg, font=font(36), anchor='mm')
    d.text((900, 1120), c['credit'], fill=(230, 230, 235), font=font(40), anchor='mm')
    img.save(out / 'sticker.png')


def main():
    man = Path(sys.argv[1]).resolve()
    root = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else man.parents[1]
    cfg = json.loads((man / 'manual.json').read_text())
    out = man / 'img'
    out.mkdir(exist_ok=True)
    cover(cfg, root, out)
    plain(cfg, root, out)
    montage(cfg, root, out)
    hud(cfg, root, out)
    label(cfg, root, out)
    print('manual pictures written to', out)


if __name__ == '__main__':
    main()
