#!/usr/bin/env python3
"""Build the handwritten wordmarks from Sacramento

For each word the script lays out the glyphs, finds the centre line of the
letters, walks it the way a hand writes and records when the pen reaches every
pixel. The app reveals pixels whose time has passed, so the animation costs one
masked draw per frame

Writes lib/assets/wordmark/<word>.png, red holding the antialiased lettering
and green the pen arrival time, and lib/ui/widgets/wordmark_glyphs.g.dart with
each texture's size

    pip install numpy scipy scikit-image pillow uharfbuzz
    python3 tools/build_wordmark.py
"""
from __future__ import annotations

import math
import os
from collections import defaultdict

import numpy as np
import uharfbuzz as hb
from PIL import Image
from scipy import ndimage
from scipy.spatial import cKDTree
from skimage.morphology import skeletonize

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT = os.path.join(ROOT, "tools", "fonts", "Sacramento-Regular.ttf")
ASSET_DIR = os.path.join(ROOT, "client", "lib", "assets", "wordmark")
DART_OUT = os.path.join(ROOT, "client", "lib", "ui", "widgets", "wordmark_glyphs.g.dart")

# Sacramento is a hairline; this thickens it into an even pen line, in font units
STROKE_UNITS = 48
# Coverage is rasterised this many times larger, then averaged down
SUPERSAMPLE = 4


# outlines via harfbuzz
class Pen:
    def __init__(self):
        self.contours = []
        self.cur = None

    def move_to(self, x, y, _):
        self.cur = [(x, y)]
        self.contours.append(self.cur)

    def line_to(self, x, y, _):
        self.cur.append((x, y))

    def quadratic_to(self, cx, cy, x, y, _):
        x0, y0 = self.cur[-1]
        for i in range(1, 9):
            t = i / 8
            a = (1 - t) ** 2
            b = 2 * (1 - t) * t
            c = t * t
            self.cur.append((a * x0 + b * cx + c * x, a * y0 + b * cy + c * y))

    def cubic_to(self, c1x, c1y, c2x, c2y, x, y, _):
        x0, y0 = self.cur[-1]
        for i in range(1, 11):
            t = i / 10
            mt = 1 - t
            self.cur.append((
                mt**3 * x0 + 3 * mt * mt * t * c1x + 3 * mt * t * t * c2x + t**3 * x,
                mt**3 * y0 + 3 * mt * mt * t * c1y + 3 * mt * t * t * c2y + t**3 * y,
            ))

    def close_path(self, _):
        pass


def shape(path, word):
    blob = hb.Blob.from_file_path(path)
    face = hb.Face(blob)
    font = hb.Font(face)
    buf = hb.Buffer()
    buf.add_str(word)
    buf.guess_segment_properties()
    hb.shape(font, buf, {"kern": True, "liga": True, "calt": True})
    funcs = hb.DrawFuncs()
    funcs.set_move_to_func(lambda x, y, p: p.move_to(x, y, None))
    funcs.set_line_to_func(lambda x, y, p: p.line_to(x, y, None))
    funcs.set_quadratic_to_func(lambda a, b, x, y, p: p.quadratic_to(a, b, x, y, None))
    funcs.set_cubic_to_func(lambda a, b, c, d, x, y, p: p.cubic_to(a, b, c, d, x, y, None))
    funcs.set_close_path_func(lambda p: p.close_path(None))
    glyphs = []
    x = 0
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        pen = Pen()
        font.draw_glyph(info.codepoint, funcs, pen)
        glyphs.append((x + pos.x_offset, pos.y_offset, pen))
        x += pos.x_advance
    return glyphs, face.upem


def rasterize(contours, w, h, ss=1):
    """Nonzero winding scanline fill at pixel centers"""
    edges = []
    for c in contours:
        for i in range(len(c)):
            x0, y0 = c[i]
            x1, y1 = c[(i + 1) % len(c)]
            if y0 != y1:
                edges.append((x0, y0, x1, y1))
    e = np.array(edges)
    out = np.zeros((h, w), np.uint8)
    xs = np.arange(w) + 0.5
    for row in range(h):
        y = row + 0.5
        y0, y1 = e[:, 1], e[:, 3]
        m = ((y0 <= y) & (y1 > y)) | ((y1 <= y) & (y0 > y))
        if not m.any():
            continue
        ee = e[m]
        t = (y - ee[:, 1]) / (ee[:, 3] - ee[:, 1])
        xc = ee[:, 0] + t * (ee[:, 2] - ee[:, 0])
        dirn = np.where(ee[:, 3] > ee[:, 1], 1, -1)
        order = np.argsort(xc)
        xc, dirn = xc[order], dirn[order]
        wind = np.cumsum(dirn)
        idx = np.searchsorted(xc, xs)
        windx = np.where(idx > 0, wind[np.clip(idx - 1, 0, None)], 0)
        out[row] = windx != 0
    return out


# skeleton graph
NB = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]


def build_graph(sk):
    pts = set(zip(*np.nonzero(sk)))

    def nbrs(p):
        return [(p[0] + dy, p[1] + dx) for dy, dx in NB if (p[0] + dy, p[1] + dx) in pts]

    deg = {p: len(nbrs(p)) for p in pts}
    nodes = {p for p in pts if deg[p] != 2}
    # cluster adjacent node pixels into one junction
    cid = {}
    clusters = []
    for p in nodes:
        if p in cid:
            continue
        stack = [p]
        cid[p] = len(clusters)
        members = []
        while stack:
            q = stack.pop()
            members.append(q)
            for r in nbrs(q):
                if r in nodes and r not in cid:
                    cid[r] = cid[p]
                    stack.append(r)
        clusters.append(members)
    centers = [tuple(np.mean(m, axis=0)) for m in clusters]

    edges = []
    seen = set()
    for p in nodes:
        for r in nbrs(p):
            if r in nodes:
                continue
            if (p, r) in seen:
                continue
            path = [p, r]
            prev, cur = p, r
            while cur not in nodes:
                nxt = [q for q in nbrs(cur) if q != prev and q not in path[-3:]]
                if not nxt:
                    break
                prev, cur = cur, nxt[0]
                path.append(cur)
            if cur not in nodes:
                continue
            seen.add((path[-1], path[-2]))
            seen.add((p, r))
            edges.append([cid[p], cid[cur], path])
    # pure loops with no node (like an isolated o)
    covered = set()
    for _, _, pth in edges:
        covered.update(pth)
    for p in nodes:
        covered.add(p)
    rest = pts - covered
    while rest:
        start = rest.pop()
        path = [start]
        prev, cur = None, start
        while True:
            nxt = [q for q in nbrs(cur) if q != prev and q in rest]
            if not nxt:
                break
            prev, cur = cur, nxt[0]
            rest.discard(cur)
            path.append(cur)
        cid_new = len(centers)
        centers.append(tuple(path[0]))
        path.append(path[0])
        edges.append([cid_new, cid_new, path])
    return centers, edges


def plen(path):
    a = np.array(path, float)
    return float(np.sum(np.hypot(*np.diff(a, axis=0).T))) if len(a) > 1 else 0.0


def prune(centers, edges, radius):
    """Drop short spurs that end in a free end, a few rounds"""
    for _ in range(4):
        deg = defaultdict(int)
        for a, b, _ in edges:
            deg[a] += 1
            deg[b] += 1
        keep = []
        changed = False
        for a, b, pth in edges:
            spur = (deg[a] == 1) != (deg[b] == 1)
            if spur and plen(pth) < radius * 1.6:
                changed = True
                continue
            keep.append([a, b, pth])
        edges = keep
        if not changed:
            break
    return edges


def direction(path, at_start, k=8):
    a = np.array(path, float)
    if at_start:
        v = a[min(k, len(a) - 1)] - a[0]
    else:
        v = a[max(-k - 1, -len(a))] - a[-1]
    n = np.hypot(*v)
    return v / n if n else v


def plan_strokes(centers, edges, components_min_x, spur_max=0):
    """Greedy walk: continue through junctions along the straightest unused
    edge, lift the pen to the leftmost unused edge when stuck"""
    used = [False] * len(edges)
    at = defaultdict(list)
    for i, (a, b, _) in enumerate(edges):
        at[a].append(i)
        at[b].append(i)

    def oriented(i, from_node):
        a, b, pth = edges[i]
        return (pth, b) if a == from_node else (pth[::-1], a)

    strokes = []
    while not all(used):
        cand = [i for i in range(len(edges)) if not used[i]]
        start = min(cand, key=lambda i: min(p[1] for p in edges[i][2]))
        a, b, pth = edges[start]
        deg_a = sum(1 for j in at[a] if not used[j])
        deg_b = sum(1 for j in at[b] if not used[j])
        if (deg_a == 1) != (deg_b == 1):
            node = a if deg_a == 1 else b
        else:
            node = a if pth[0][1] <= pth[-1][1] else b
        stroke = []
        cur = start
        while True:
            used[cur] = True
            seg, node = oriented(cur, node)
            stroke.extend(seg if not stroke else seg[1:])
            end_dir = -direction(seg, False)
            # short dead end branches are traced out and back on the way
            for j in [j for j in at[node] if not used[j]]:
                spur, far = oriented(j, node)
                if far != node and len(at[far]) == 1 and plen(spur) < spur_max:
                    used[j] = True
                    stroke.extend(spur[1:])
                    stroke.extend(spur[::-1][1:])
            nxt = [j for j in at[node] if not used[j]]
            if not nxt:
                break
            cur = max(nxt, key=lambda j: float(np.dot(end_dir, direction(oriented(j, node)[0], True))))
        strokes.append(stroke)
    return strokes


def arrival(strokes, radius, lift_gap):
    """Pen time per skeleton point, slower in tight curves"""
    pts, times = [], []
    t = 0.0
    for si, s in enumerate(strokes):
        a = np.array(s, float)
        if len(a) < 2:
            continue
        # light smoothing for curvature
        sm = ndimage.uniform_filter1d(a, size=9, axis=0, mode="nearest")
        d = np.hypot(*np.diff(sm, axis=0).T)
        tang = np.diff(sm, axis=0)
        ang = np.arctan2(tang[:, 0], tang[:, 1])
        dang = np.abs(np.angle(np.exp(1j * np.diff(ang))))
        curv = np.concatenate([[0], dang, [0]])[:len(d)]
        curv = ndimage.uniform_filter1d(curv, size=15)
        speed = 1.0 / (1.0 + 6.0 * curv * radius / 4)
        dt = d / speed
        if si > 0:
            t += lift_gap
        local = np.concatenate([[0], np.cumsum(dt)]) + t
        pts.extend(a.tolist())
        times.extend(local.tolist())
        t = local[-1]
    return np.array(pts), np.array(times), t


def thicken(mask, stroke):
    return (ndimage.distance_transform_edt(mask == 0) <= stroke / 2).astype(np.uint8)


def lettering(contours, W, H, stroke):
    """Antialiased coverage 0..1 at map size"""
    k = SUPERSAMPLE
    big = [[(x * k, y * k) for x, y in c] for c in contours]
    mask = thicken(rasterize(big, W * k, H * k), stroke * k)
    # Thickened ring dots keep a hole, so fill holes in small pieces only
    lab, n = ndimage.label(mask, structure=np.ones((3, 3)))
    sizes = ndimage.sum(mask, lab, range(1, n + 1))
    for i, size in enumerate(sizes):
        if size < sizes.max() * 0.04:
            piece = lab == i + 1
            mask[ndimage.binary_fill_holes(piece)] = 1
    return mask.reshape(H, k, W, k).mean(axis=(1, 3))


def build(word, H=360):
    """H is the map height in pixels, sized to how large the word is drawn"""
    PAD = H // 15
    glyphs, _ = shape(FONT, word)
    all_pts = []
    for gx, gy, pen in glyphs:
        for c in pen.contours:
            for x, y in c:
                all_pts.append((x + gx, y + gy))
    P = np.array(all_pts)
    minx, miny = P.min(0)
    maxx, maxy = P.max(0)
    scale = (H - 2 * PAD) / (maxy - miny)
    W = int(math.ceil((maxx - minx) * scale + 2 * PAD))
    stroke = STROKE_UNITS * scale

    def tx(x, y, gx, gy):
        return ((x + gx - minx) * scale + PAD, (maxy - (y + gy)) * scale + PAD)

    contours = [[tx(x, y, gx, gy) for x, y in c]
                for gx, gy, pen in glyphs for c in pen.contours]
    mask = thicken(rasterize(contours, W, H), stroke)
    coverage = lettering(contours, W, H, stroke)
    dist = ndimage.distance_transform_edt(mask)
    sk = skeletonize(mask > 0)
    radius = float(np.percentile(dist[sk], 75))
    centers, edges = build_graph(sk)
    edges = prune(centers, edges, radius)

    # Small components are dots, written last
    lab, n = ndimage.label(mask, structure=np.ones((3, 3)))
    sizes = ndimage.sum(mask, lab, range(1, n + 1))
    big = sizes.max()
    small_labels = {i + 1 for i, s in enumerate(sizes) if s < big * 0.04}

    main_e = [e for e in edges if lab[e[2][0]] not in small_labels]
    dot_e = [e for e in edges if lab[e[2][0]] in small_labels]
    strokes = plan_strokes(centers, main_e, None, spur_max=radius * 12)
    dots = []
    for li in sorted(small_labels, key=lambda l: np.nonzero(lab == l)[1].mean()):
        es = [e for e in dot_e if lab[e[2][0]] == li]
        if es:
            dots.extend(plan_strokes(centers, es, None))
        else:
            ys, xs = np.nonzero(lab == li)
            cy, cx = ys.mean(), xs.mean()
            dots.append([(int(cy), int(cx) - 1), (int(cy), int(cx) + 1)])
    # Tiny leftover strokes take the time of the pen passing nearby
    major = [st for st in strokes if plen(st) >= radius * 3]
    minor = [st for st in strokes if plen(st) < radius * 3]
    pts, times, total_main = arrival(major, radius, lift_gap=radius * 2)
    if minor:
        mp = np.vstack([np.array(st, float) for st in minor])
        _, near = cKDTree(pts).query(mp)
        pts = np.vstack([pts, mp])
        times = np.concatenate([times, times[near]])
    if dots:
        dpts, dtimes, _ = arrival(dots, radius, lift_gap=radius * 4)
        pts = np.vstack([pts, dpts])
        times = np.concatenate([times, dtimes + total_main + radius * 6])
    times = times / times.max()

    # Crossings take the earlier pass
    grow = ndimage.binary_dilation(mask, iterations=4)
    ys, xs = np.nonzero(grow)
    tree = cKDTree(pts)
    dn, _ = tree.query(np.c_[ys, xs])
    tmap = np.ones((H, W))
    res = tree.query_ball_point(np.c_[ys, xs], dn + 1.5)
    for k, (y, x) in enumerate(zip(ys, xs)):
        tmap[y, x] = times[res[k]].min()
    _, (iy, ix) = ndimage.distance_transform_edt(~grow, return_indices=True)
    tmap = ndimage.gaussian_filter(tmap[iy, ix], 0.7)
    rgba = np.zeros((H, W, 4), np.uint8)
    rgba[..., 0] = np.clip(np.round(coverage * 255), 0, 255)
    rgba[..., 1] = np.clip(np.round(tmap * 255), 0, 255)
    rgba[..., 3] = 255
    Image.fromarray(rgba, "RGBA").save(os.path.join(ASSET_DIR, f"{word}.png"), optimize=True)
    print(word, W, H, "strokes", len(major), "dots", len(dots))
    return {"word": word, "width": W, "height": H}


def write_dart(marks):
    out = [
        "// Generated by tools/build_wordmark.py from Sacramento (SIL OFL 1.1), do not edit",
        "",
        "part of 'hello_wordmark.dart';",
    ]
    for m in marks:
        name = "kWordmark" + m["word"][0].upper() + m["word"][1:]
        out += [
            "",
            f"const WordmarkGlyphs {name} = WordmarkGlyphs(",
            f"  word: '{m['word']}',",
            f"  width: {m['width']},",
            f"  height: {m['height']},",
            f"  asset: 'lib/assets/wordmark/{m['word']}.png',",
            ");",
        ]
    with open(DART_OUT, "w") as f:
        f.write("\n".join(out) + "\n")


if __name__ == "__main__":
    os.makedirs(ASSET_DIR, exist_ok=True)
    write_dart([build("miuchio"), build("m", H=180)])
