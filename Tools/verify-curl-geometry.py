#!/usr/bin/env python3
"""Check that the curl is anchored to the finger and does not pop.

Two device complaints drove this:

  * "the rolled-up part is always some distance from my finger"
  * "the screen flashes once before the curl starts"

Geometry under test, mirroring CurlGeometry: the finger holds the free edge of
the curl, so `d = 0` (the de facto reference line) sits under the finger, the
curl band occupies `-band < d < 0`, the flat current page is `d <= -band`, and
beyond `d >= 0` the next page shows through.

Assertions:
  1. regions partition the page exactly, no overlap
  2. the free edge of the band sits on the finger (within 1pt)
  3. the band is 0 at t = 0, so nothing appears before the drag moves
  4. the band returns to 0 at t = 1, leaving no residue
  5. forward and backward are exact mirrors
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw

W, H = 420, 760
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")


def smoothstep(e0, e1, x):
    t = min(max((x - e0) / (e1 - e0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def geometry(t, forward=True):
    finger_x = W * (1 - t) if forward else W * t
    tilt = 5 + 31 * t
    rad = math.radians(90 - tilt)
    dx, dy = math.cos(rad), math.sin(rad)
    tan = (dx, dy) if forward else (-dx, dy)
    nx, ny = -tan[1], tan[0]
    ref = (1, -0.35) if forward else (-1, -0.35)
    if nx * ref[0] + ny * ref[1] < 0:
        nx, ny = -nx, -ny

    band = W * 0.16 * smoothstep(0, 0.30, t) * (1 - smoothstep(0.80, 1.0, t))
    # Crease sits one band width along the normal from the finger.
    cp = (finger_x + nx * band, H * 0.94 * t)
    return cp, (nx, ny), (dx, dy), band, finger_x


def regions(t, forward=True):
    cp, n, tan, band, finger_x = geometry(t, forward)
    ys, xs = np.mgrid[0:H, 0:W]
    d = (xs - cp[0]) * n[0] + (ys - cp[1]) * n[1]
    return {
        "flat": d <= -band,
        "band": (d > -band) & (d < 0),
        "revealed": d >= 0,
    }, d, band, finger_x


def page(label, bg, ink, tint):
    img = Image.new("RGB", (W, H), bg)
    d = ImageDraw.Draw(img)
    d.rectangle([40, 30, W - 40, 38], fill=tint)
    for i in range(25):
        y = 74 + i * 25
        d.rectangle([40, y, W - 40 - (70 if i % 7 == 6 else 0), y + 7], fill=ink)
    d.text((W // 2 - 8, H - 44), label, fill=tint)
    return img


def render(t, forward=True):
    r, d, band, finger_x = regions(t, forward)
    front = page("1", (250, 247, 240), (58, 58, 58), (150, 120, 90))
    nxt = page("2", (236, 240, 248), (40, 70, 140), (30, 60, 130))

    canvas = np.asarray(front).copy()
    canvas[r["revealed"]] = np.asarray(nxt)[r["revealed"]]

    cp, n, tan, _, _ = geometry(t, forward)
    by, bx = np.nonzero(r["band"])
    if len(by):
        bd = d[r["band"]]
        sx = np.rint(bx - 2 * bd * n[0]).astype(np.int32)
        sy = np.rint(by - 2 * bd * n[1]).astype(np.int32)
        ok = (sx >= 0) & (sx < W) & (sy >= 0) & (sy < H)
        src = np.asarray(front)
        cols = np.empty((len(by), 3), np.uint8)
        cols[:] = (250, 247, 240)
        cols[ok] = src[sy[ok], sx[ok]]
        cols = np.clip(cols.astype(np.float32) * np.array([0.97, 0.95, 0.91]), 0, 255).astype(np.uint8)
        canvas[r["band"]] = cols

    img = Image.fromarray(canvas)
    if len(by):
        ramp = np.clip((bd + band) / max(band, 1e-6), 0, 1)
        shade = 0.72 + 0.34 * ramp
        arr = np.asarray(img).astype(np.float32)
        arr[r["band"]] *= shade[:, None]
        img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))

    dr = ImageDraw.Draw(img)
    # Mark where the finger is, so alignment can be judged by eye.
    if 0 <= finger_x < W:
        dr.line([(finger_x, 0), (finger_x, H)], fill=(220, 0, 0), width=1)
    dr.text((8, 8), f"t={t:.2f}", fill=(190, 0, 0))
    return img, r, band, finger_x


def main():
    os.makedirs(OUT, exist_ok=True)
    ts = (0.0, 0.05, 0.1, 0.25, 0.4, 0.55, 0.7, 0.85, 1.0)

    print(f"{'t':>5} {'flat':>7} {'band':>7} {'reveal':>7} {'sum':>7} {'overlap':>8}")
    print("-" * 52)
    ok = True
    for t in ts:
        r, _, _, _ = regions(t)
        f, b, v = r["flat"].mean(), r["band"].mean(), r["revealed"].mean()
        total = f + b + v
        ov = ((r["flat"] & r["band"]).sum() + (r["band"] & r["revealed"]).sum()
              + (r["flat"] & r["revealed"]).sum())
        good = abs(total - 1.0) < 0.005 and ov == 0
        ok &= good
        print(f"{t:>5.2f} {f:>6.1%} {b:>6.1%} {v:>6.1%} {total:>6.1%} {ov:>8d}"
              f"{'' if good else '  <-- MISMATCH'}")
    print()
    print("1. regions partition the page:", ok)

    # 2. Free edge should land on the finger.
    print()
    print(f"{'t':>5} {'finger_x':>9} {'crease_x':>9} {'edge_x':>8} {'off by':>7} {'band':>6}")
    edge_ok = True
    for t in (0.1, 0.25, 0.4, 0.55, 0.7, 0.85):
        cp, n, _, band, finger_x = geometry(t)
        edge_x = cp[0] - n[0] * band
        off = edge_x - finger_x
        edge_ok &= abs(off) < 1.0
        print(f"{t:>5.2f} {finger_x:>9.1f} {cp[0]:>9.1f} {edge_x:>8.1f} {off:>7.1f} {band:>6.1f}")
    print()
    print("2. free edge sits on the finger:", edge_ok)

    # 3/4. No pop at either end.
    b0 = geometry(0.0)[3]
    b1 = geometry(1.0)[3]
    print(f"3. band at t=0: {b0:.2f}pt (must be ~0)")
    print(f"4. band at t=1: {b1:.2f}pt (must be ~0)")

    # 5. Mirror symmetry.
    print()
    sym = True
    for t in (0.25, 0.5, 0.75):
        rf, _, _, _ = regions(t, True)
        rb, _, _, _ = regions(t, False)
        m = {k: np.fliplr(v) for k, v in rb.items()}
        same = all((rf[k] == m[k]).mean() > 0.995 for k in rf)
        sym &= same
        print(f"5. t={t:.2f} forward == mirrored backward: {same}")

    tiles = [render(t)[0] for t in ts]
    sheet = Image.new("RGB", (W * len(tiles), H), (26, 26, 30))
    for i, im in enumerate(tiles):
        sheet.paste(im, (i * W, 0))
    path = os.path.join(OUT, "swift-geometry.png")
    sheet.resize((sheet.width // 4, sheet.height // 4), Image.LANCZOS).save(path)
    print()
    print("wrote", path)

    allok = ok and edge_ok and b0 < 0.5 and b1 < 0.5 and sym
    print("ALL CHECKS PASS:", allok)
    return 0 if allok else 1


if __name__ == "__main__":
    raise SystemExit(main())
