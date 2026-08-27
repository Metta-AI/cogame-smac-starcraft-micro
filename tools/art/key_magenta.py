"""Chroma-key a nano-banana sprite generated on a flat magenta field: sample
the actual background color from the corners, solve alpha by color distance,
un-blend the key contribution (keeps soft glows), trim to content, save.

    python3 key_magenta.py <generated.png> <dest.png> [pad_px]
"""
import sys
import numpy as np
from PIL import Image

def main():
    src, dest = sys.argv[1], sys.argv[2]
    pad = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    a = np.asarray(Image.open(src).convert('RGB')).astype(np.float32) / 255.0
    corners = np.stack([a[2, 2], a[2, -3], a[-3, 2], a[-3, -3]])
    key = np.median(corners, axis=0)
    dist = np.linalg.norm(a - key, axis=-1)
    alpha = np.clip(dist / 0.45, 0, 1)
    alpha[alpha < 0.12] = 0
    fg = np.where(alpha[..., None] > 0,
                  (a - (1 - alpha[..., None]) * key) /
                  np.maximum(alpha[..., None], 1e-4), 0)
    fg = np.clip(fg, 0, 1)
    img = Image.fromarray(
        (np.concatenate([fg, alpha[..., None]], axis=-1) * 255).astype('uint8'))
    bbox = img.getbbox()
    if bbox:
        l, t, r, b = bbox
        w, h = img.size
        img = img.crop((max(0, l - pad), max(0, t - pad),
                        min(w, r + pad), min(h, b + pad)))
    img.save(dest)
    print(dest, img.size)

main()
