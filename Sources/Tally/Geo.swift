import SwiftUI

/// A drawable, hit-testable outline in map grid coordinates (shared by municipalities, wards and
/// voting districts so every level lines up and zooms smoothly).
struct GeoShape: Identifiable, @unchecked Sendable {
    let id: Int
    let parent: Int          // province (municipalities), ward id (voting districts), municipality (wards)
    let number: Int          // ward number for wards, 0 otherwise
    let path: Path
    let bounds: CGRect
}

/// The Albers projection and grid transform used by scripts/build-map.py, read from sa-map.json,
/// so on-demand GeoJSON lands exactly on the bundled national outlines.
struct AlbersGrid: Decodable, Sendable {
    let lat1: Double, lat2: Double, lon0: Double, lat0: Double
    let minx: Double, maxy: Double, scale: Double

    func project(lon: Double, lat: Double) -> CGPoint {
        let r = Double.pi / 180
        let n = (sin(lat1 * r) + sin(lat2 * r)) / 2
        let c = cos(lat1 * r) * cos(lat1 * r) + 2 * n * sin(lat1 * r)
        let rho0 = (c - 2 * n * sin(lat0 * r)).squareRoot() / n
        let rho = (c - 2 * n * sin(lat * r)).squareRoot() / n
        let theta = n * (lon - lon0) * r
        let x = rho * sin(theta), y = rho0 - rho * cos(theta)
        return CGPoint(x: (x - minx) * scale, y: (maxy - y) * scale)
    }
}

enum GeoBuilder {
    /// Projects and simplifies GeoJSON features into shapes. Runs off the main thread.
    /// `tolerance` is in grid units (1 unit ≈ 0.8 km); `id`/`parent`/`number` pick the identifiers.
    static func shapes(from collection: GeoFeatureCollection, grid: AlbersGrid, tolerance: Double,
                       id: (GeoFeature.Properties) -> Int?,
                       parent: (GeoFeature.Properties) -> Int,
                       number: (GeoFeature.Properties) -> Int) -> [GeoShape] {
        var out: [GeoShape] = []
        out.reserveCapacity(collection.features.count)
        for feature in collection.features {
            guard let fid = id(feature.properties), let rings = feature.geometry?.rings, !rings.isEmpty else { continue }
            var path = Path()
            for ring in rings {
                let projected = ring.compactMap { pair -> CGPoint? in
                    pair.count >= 2 ? grid.project(lon: pair[0], lat: pair[1]) : nil
                }
                let simple = simplify(projected, tolerance: tolerance)
                guard simple.count >= 3 else { continue }
                path.move(to: simple[0])
                for p in simple.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
            }
            guard !path.isEmpty else { continue }
            out.append(GeoShape(id: fid, parent: parent(feature.properties), number: number(feature.properties),
                                path: path, bounds: path.boundingRect))
        }
        // Largest first so enclosed shapes draw on top and hit-test first in reverse.
        return out.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
    }

    /// Iterative Douglas–Peucker.
    static func simplify(_ points: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard points.count > 4, tolerance > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        let tol2 = tolerance * tolerance
        while let (a, b) = stack.popLast() {
            let pa = points[a], pb = points[b]
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let seg2 = dx * dx + dy * dy
            var best = -1
            var bestDistance = tol2
            if b > a + 1 {
                for i in (a + 1)..<b {
                    let p = points[i]
                    let d: Double
                    if seg2 == 0 {
                        d = (p.x - pa.x) * (p.x - pa.x) + (p.y - pa.y) * (p.y - pa.y)
                    } else {
                        let t = max(0, min(1, ((p.x - pa.x) * dx + (p.y - pa.y) * dy) / seg2))
                        let ex = p.x - pa.x - t * dx, ey = p.y - pa.y - t * dy
                        d = ex * ex + ey * ey
                    }
                    if d > bestDistance { best = i; bestDistance = d }
                }
            }
            if best >= 0 {
                keep[best] = true
                stack.append((a, best))
                stack.append((best, b))
            }
        }
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }
}

extension String {
    /// "TRINITY COMMUNITY CHURCH" → "Trinity Community Church" (keeps short acronyms like NG, AFM, VGK).
    var stationTitleCase: String {
        let keep: Set<String> = ["NG", "AFM", "VGK", "URCSA", "ZCC", "AME", "UCC", "NGK", "RC", "SDA", "LP", "JP", "II", "III", "IV", "CPA", "RDP", "SAPS"]
        let lower: Set<String> = ["of", "the", "and", "in", "at", "van", "der", "de", "la"]
        return split(separator: " ", omittingEmptySubsequences: true).enumerated().map { i, w in
            let word = String(w)
            if keep.contains(word.uppercased()) { return word.uppercased() }
            let l = word.lowercased()
            if i > 0 && lower.contains(l) { return l }
            // Capitalise the first letter even after punctuation: "(bassonia)" → "(Bassonia)".
            guard let first = l.firstIndex(where: \.isLetter) else { return l }
            return l[..<first] + l[first...first].uppercased() + l[l.index(after: first)...]
        }.joined(separator: " ")
    }
}
