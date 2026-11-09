#!/usr/bin/env python3
"""Builds Resources/sa-map.json from the IEC's 2026 boundary files.

Source (the files the IEC results map uses, published by the IEC / Municipal Demarcation Board):
  https://results.elections.org.za/ElectionMap/MapData/2026/nationalMunic.js     (~10 MB GeoJSON)
  https://results.elections.org.za/ElectionMap/MapData/2026/nationalProvince.js  (~3 MB GeoJSON)

Output: an Albers-projected, Douglas-Peucker-simplified, integer-quantised outline set (~150 KB), bundled
with the app so the map needs no network at all. Only needed again if the IEC re-demarcates boundaries.

Usage: python3 scripts/build-map.py <nationalMunic.js> <nationalProvince.js> Resources/sa-map.json
"""
import json
import math
import sys

WIDTH = 2000          # output grid width (integer units)
TOLERANCE = 1.1       # simplification tolerance in grid units (~0.2 px at popover size)
MIN_RING_AREA = 6.0   # drop slivers/islets smaller than this (grid units squared)

# Albers equal-area conic tuned for South Africa
LAT1, LAT2, LON0, LAT0 = math.radians(-24), math.radians(-33), math.radians(25), math.radians(-29)
N = (math.sin(LAT1) + math.sin(LAT2)) / 2
C = math.cos(LAT1) ** 2 + 2 * N * math.sin(LAT1)
RHO0 = math.sqrt(C - 2 * N * math.sin(LAT0)) / N


def project(lon, lat):
    lam, phi = math.radians(lon), math.radians(lat)
    rho = math.sqrt(C - 2 * N * math.sin(phi)) / N
    theta = N * (lam - LON0)
    return rho * math.sin(theta), RHO0 - rho * math.cos(theta)


def rings_of(geometry):
    if geometry["type"] == "Polygon":
        return [geometry["coordinates"][0]]                 # outer ring only; holes are filled by neighbours
    return [poly[0] for poly in geometry["coordinates"]]


def simplify(points, tol):
    """Iterative Douglas-Peucker."""
    if len(points) < 4:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    tol2 = tol * tol
    while stack:
        a, b = stack.pop()
        ax, ay = points[a]
        bx, by = points[b]
        dx, dy = bx - ax, by - ay
        seg2 = dx * dx + dy * dy
        best, best_d = -1, tol2
        for i in range(a + 1, b):
            px, py = points[i]
            if seg2 == 0:
                d = (px - ax) ** 2 + (py - ay) ** 2
            else:
                t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / seg2))
                d = (px - ax - t * dx) ** 2 + (py - ay - t * dy) ** 2
            if d > best_d:
                best, best_d = i, d
        if best >= 0:
            keep[best] = True
            stack += [(a, best), (best, b)]
    return [p for p, k in zip(points, keep) if k]


def area(points):
    return abs(sum(x1 * y2 - x2 * y1 for (x1, y1), (x2, y2) in zip(points, points[1:] + points[:1]))) / 2


def main(munic_path, province_path, out_path):
    munics = json.load(open(munic_path))["features"]
    provinces = json.load(open(province_path))["features"]

    projected = []
    for kind, features in (("m", munics), ("p", provinces)):
        for f in features:
            props = f["properties"]
            fid = props.get("MunicId") if kind == "m" else props.get("ProvinceId")
            rings = [[project(lon, lat) for lon, lat, *_ in ring] for ring in rings_of(f["geometry"])]
            projected.append((kind, fid, props, rings))

    xs = [x for *_, rings in projected for r in rings for x, _ in r]
    ys = [y for *_, rings in projected for r in rings for _, y in r]
    minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
    scale = WIDTH / (maxx - minx)
    height = math.ceil((maxy - miny) * scale)

    # Projection parameters, so the app can project on-demand ward / voting-district GeoJSON into
    # exactly the same coordinate space as this bundled outline set.
    out = {"w": WIDTH, "h": height, "m": [], "p": [],
           "proj": {"lat1": -24, "lat2": -33, "lon0": 25, "lat0": -29, "minx": minx, "maxy": maxy, "scale": scale}}
    points = 0
    for kind, fid, props, rings in projected:
        encoded = []
        for ring in rings:
            grid = [((x - minx) * scale, (maxy - y) * scale) for x, y in ring]   # flip y for screen coordinates
            grid = simplify(grid, TOLERANCE)
            if len(grid) < 4 or area(grid) < MIN_RING_AREA:
                continue
            flat, px, py = [], 0, 0
            for x, y in grid:                                   # delta-encoded integers
                ix, iy = round(x), round(y)
                flat += [ix - px, iy - py]
                px, py = ix, iy
            encoded.append(flat)
            points += len(grid)
        if not encoded:
            continue
        if kind == "m":
            out["m"].append({"i": fid, "p": props.get("ProvinceId"), "c": props.get("MunicCode"), "r": encoded})
        else:
            out["p"].append({"i": fid, "r": encoded})

    with open(out_path, "w") as fh:
        json.dump(out, fh, separators=(",", ":"))
    print(f"{len(out['m'])} municipalities, {len(out['p'])} provinces, {points} points, {WIDTH}x{height}")


if __name__ == "__main__":
    main(*sys.argv[1:4])
