"""Retint the unit art into the StarCraft-micro team families
(docs/plans/2026-08-27-starcraft-look-brief.md):

  red   dir = OUR squad   -> steel-blue gunmetal hull, azure visor
  blue  dir = enemy army  -> near-black steel hull, crimson visor
  green dir = swarm       -> murky olive hull, acid visor

Every variant derives from the checked-in RED masters (the highest-quality
set), so the three families stay pixel-aligned and the rig anchors hold.
Run from the repo root:  python3 tools/art/retint_units.py <red_master_dir>

The <red_master_dir> must hold pristine copies of the ORIGINAL red art
(pre-retint), laid out as data/ is.
"""
import colorsys
import os
import sys
import numpy as np
from PIL import Image

TEAMS = {
    'red':   dict(hull_h=213/360, hull_s=0.28, hull_v=0.82,
                  vis_h=197/360,  vis_s=0.90,  vis_v=1.15),
    'blue':  dict(hull_h=222/360, hull_s=0.10, hull_v=0.55,
                  vis_h=358/360,  vis_s=0.90,  vis_v=1.10),
    'green': dict(hull_h=85/360,  hull_s=0.30, hull_v=0.62,
                  vis_h=95/360,   vis_s=0.95,  vis_v=1.10),
}

def retint(img: Image.Image, p) -> Image.Image:
    a = np.asarray(img.convert('RGBA')).astype(np.float32) / 255.0
    rgb, alpha = a[..., :3], a[..., 3:]
    mx = rgb.max(axis=-1); mn = rgb.min(axis=-1)
    v = mx
    s = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)
    # hue in [0,1)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    h = np.zeros_like(v)
    d = np.maximum(mx - mn, 1e-6)
    h = np.where(mx == r, ((g - b) / d) % 6, h)
    h = np.where(mx == g, (b - r) / d + 2, h)
    h = np.where(mx == b, (r - g) / d + 4, h)
    h = (h / 6.0) % 1.0

    # Team accent: every saturated cyan/blue pixel (visor, side pods).
    visor = (s > 0.25) & (h > 140/360) & (h < 262/360)
    # Hull: every OTHER saturated pixel (salmon shell, rainbow trims) - the
    # whole non-accent paint job collapses into the team hull family.
    warm  = (s > 0.15) & ~visor
    tan   = (s > 0.06) & (s <= 0.15) & ~visor & ~warm

    h2, s2, v2 = h.copy(), s.copy(), v.copy()
    h2[warm] = p['hull_h']; s2[warm] = p['hull_s']; v2[warm] = v[warm] * p['hull_v']
    h2[tan] = p['hull_h']; s2[tan] = s[tan] * 0.5; v2[tan] = v[tan] * (p['hull_v'] * 0.9 + 0.1)
    h2[visor] = p['vis_h']; s2[visor] = p['vis_s']
    v2[visor] = np.clip(v[visor] * p['vis_v'], 0, 1)

    # hsv -> rgb, vectorized
    i = np.floor(h2 * 6).astype(int) % 6
    f = h2 * 6 - np.floor(h2 * 6)
    pp = v2 * (1 - s2); q = v2 * (1 - f * s2); t = v2 * (1 - (1 - f) * s2)
    out = np.zeros_like(rgb)
    for idx, (rr, gg, bb) in enumerate([(v2, t, pp), (q, v2, pp), (pp, v2, t),
                                        (pp, q, v2), (t, pp, v2), (v2, pp, q)]):
        m = i == idx
        out[..., 0][m] = rr[m]; out[..., 1][m] = gg[m]; out[..., 2][m] = bb[m]
    res = np.concatenate([out, alpha], axis=-1)
    return Image.fromarray((res * 255).astype('uint8'))

def main():
    masters = sys.argv[1]
    segs = ['head', 'head_crown', 'arm_l', 'arm_r', 'leg_fl', 'leg_fr',
            'leg_rear', 'wheel_l', 'wheel_r', 'wheel_rear']
    for team, p in TEAMS.items():
        for seg in segs:
            src = Image.open(os.path.join(masters, 'rig_real/red', seg + '.png'))
            dst = f'data/rig_real/{team}/{seg}.png'
            retint(src, p).save(dst)
        for suffix in ['', '_crown', '_front', '_front_gun']:
            src_p = os.path.join(masters, f'soldier_red{suffix}.png')
            dst = f'data/soldier_{team}{suffix}.png'
            retint(Image.open(src_p), p).save(dst)
        print('retinted', team)

if __name__ == "__main__":
    main()
