#!/usr/bin/env python3
"""Check the Swift CurlGeometry's region maths against the validated prototype.

Renders with the exact same formulas as CurlGeometry in CurledPage.swift, so the
region split (flat / band / revealed) can be verified on Linux before the app is
installed. Region coverage is the thing that broke repeatedly: a band that
overlaps the flat page draws the same glyphs twice, and one that never reaches
the page edge leaves a strip of the old page behind.
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw

W, H = 420, 760
# Output goes next to this script so the render can be committed and compared.
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")


def smoothstep(e0, e1, x):
    t = min(max((x - e0) / (e1 - e0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def geometry(t, forward=True):
    """Mirror of CurlGeometry.

    The lifted corner is a top one: top-right going forward, top-left going
    back. The crease starts on the top edge and sweeps down.
    """
    x = W * (1 - 0.92 * t)
    y = H * 0.94 * t
    cp = (x, y) if forward else (W - x, y)

    deg = 80 - 62 * t
    rad = math.radians(deg)
    dx, dy = math.cos(rad), math.sin(rad)
    tan = (dx, dy) if forward else (-dx, dy)

    nx, ny = -tan[1], tan[0]
    ref = (1, -0.35) if forward else (-1, -0.35)
    if nx * ref[0] + ny * ref[1] < 0:
        nx, ny = -nx, -ny

    grow = 0.18 + 0.82 * min(t / 0.62, 1.0)
    shrink = 1 - smoothstep(0.78, 1.0, t)
    band = W * 0.42 * grow * shrink
    return cp, (nx, ny), (dx, dy), band


def regions(t, forward=True):
    cp, n, tan, band = geometry(t, forward)
    ys, xs = np.mgrid[0:H, 0:W]
    d = (xs - cp[0]) * n[0] + (ys - cp[1]) * n[1]
    return {
        "flat": d <= 0,
        "band": (d > 0) & (d < band),
        "revealed": d >= band,
    }, d, band


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
    r, d, band = regions(t, forward)
    front = page("1", (250, 247, 240), (58, 58, 58), (150, 120, 90))
    nxt = page("2", (236, 240, 248), (40, 70, 140), (30, 60, 130))

    canvas = np.asarray(front).copy()
    canvas[r["revealed"]] = np.asarray(nxt)[r["revealed"]]

    cp, n, tan, _ = geometry(t, forward)
    by, bx = np.nonzero(r["band"])
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
    ramp = np.clip(bd / max(band, 1e-6), 0, 1)
    shade = 1.06 - 0.46 * ramp ** 1.3
    arr = np.asarray(img).astype(np.float32)
    arr[r["band"]] *= shade[:, None]
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))

    dr = ImageDraw.Draw(img)
    reach = 2000
    dr.line([(cp[0] - tan[0] * reach, cp[1] - tan[1] * reach),
             (cp[0] + tan[0] * reach, cp[1] + tan[1] * reach)],
            fill=(168, 160, 148), width=1)
    return img, r


def main():
    os.makedirs(OUT, exist_ok=True)
    ts = (0.0, 0.1, 0.25, 0.4, 0.55, 0.7, 0.85, 1.0)

    print(f"{'t':>5} {'flat':>7} {'band':>7} {'reveal':>7} {'sum':>7} {'overlap':>8}")
    print("-" * 50)
    ok_all = True
    for t in ts:
        r, _, _ = regions(t)
        f, b, v = r["flat"].mean(), r["band"].mean(), r["revealed"].mean()
        total = f + b + v
        overlap = (r["flat"] & r["band"]).sum() + (r["band"] & r["revealed"]).sum() + (r["flat"] & r["revealed"]).sum()
        ok = abs(total - 1.0) < 0.005 and overlap == 0
        ok_all &= ok
        print(f"{t:>5.2f} {f:>6.1%} {b:>6.1%} {v:>6.1%} {total:>6.1%} {overlap:>8d}"
              f"{'' if ok else '  <-- MISMATCH'}")
    print()
    print("regions partition the page with no overlap:", ok_all)

    tiles = []
    for t in ts:
        img, _ = render(t)
        tiles.append(img)
    sheet = Image.new("RGB", (W * len(tiles), H), (26, 26, 30))
    for i, im in enumerate(tiles):
        sheet.paste(im, (i * W, 0))
    path = os.path.join(OUT, "swift-geometry.png")
    sheet.resize((sheet.width // 4, sheet.height // 4), Image.LANCZOS).save(path)
    print("wrote", path)

    # Forward and backward must be mirror images of each other.
    print()
    print("forward vs mirrored backward (should match):")
    for t in (0.25, 0.5, 0.75):
        rf, _, _ = regions(t, True)
        rb, _, _ = regions(t, False)
        mirrored = {k: np.fliplr(v) for k, v in rb.items()}
        same = all((rf[k] == mirrored[k]).mean() > 0.995 for k in rf)
        print(f"  t={t}: {same}")


if __name__ == "__main__":
    main()
