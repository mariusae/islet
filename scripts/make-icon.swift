// Generates the Islet app icon as an Icon Composer document (Islet/AppIcon.icon).
//
//   swift scripts/make-icon.swift Islet/AppIcon.icon
//
// The document has SVG layers plus an icon.json that gives light and dark appearances their own
// background and artwork. The system derives the tinted and clear variants, and Liquid Glass
// supplies the depth and highlights. Open the result in Icon Composer to preview or tweak it.
//
// The trace is an analytic curve (a baseline plus Gaussian bumps), so it has no kinks, and the
// peak's radius of curvature stays well above half the stroke width so the stroke's inner edge
// never folds over itself.

import Foundation

let S = 1024.0

// Target band, in unit coordinates (y up).
let bandLow = 0.37, bandHigh = 0.59

// Glucose trace: gentle dip, one broad meal peak above the band, settling back into range.
func trace(_ x: Double) -> Double {
    func bump(_ center: Double, _ width: Double, _ height: Double) -> Double {
        height * exp(-pow((x - center) / width, 2))
    }
    return 0.445 + bump(0.48, 0.135, 0.24) - bump(0.25, 0.10, 0.04)
}
let xStart = 0.15, xEnd = 0.80
let lineWidth = S * 0.046

/// Unit coordinates (y up) to SVG user space (y down).
func px(_ x: Double) -> String { String(format: "%.2f", x * S) }
func py(_ y: Double) -> String { String(format: "%.2f", (1 - y) * S) }

struct RGB {
    var r, g, b: Double
    var hex: String { String(format: "#%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5)) }
    func json(alpha: Double = 1) -> String { String(format: "srgb:%.5f,%.5f,%.5f,%.5f", r, g, b, alpha) }
}

struct Look {
    var name: String
    var green: RGB
    var amber: RGB
    var bandOpacity: Double
    var background: (top: RGB, bottom: RGB)
}

// Light is the default; the range colors are deepened so they hold up on the pale background.
let light = Look(name: "light",
                 green: RGB(r: 0.02, g: 0.62, b: 0.45), amber: RGB(r: 0.95, g: 0.56, b: 0.04),
                 bandOpacity: 0.13,
                 background: (RGB(r: 0.985, g: 0.995, b: 0.99), RGB(r: 0.86, g: 0.95, b: 0.92)))
// Dark matches the app's dark palette.
let dark = Look(name: "dark",
                green: RGB(r: 0.18, g: 0.83, b: 0.63), amber: RGB(r: 1.00, g: 0.70, b: 0.14),
                bandOpacity: 0.12,
                background: (RGB(r: 0.03, g: 0.11, b: 0.12), RGB(r: 0.02, g: 0.04, b: 0.07)))

func svg(_ body: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    \(body)
    </svg>

    """
}

func band(_ look: Look) -> String {
    svg("""
      <rect x="0" y="\(py(bandHigh))" width="1024" height="\(String(format: "%.2f", (bandHigh - bandLow) * S))" \
    fill="\(look.green.hex)" fill-opacity="\(look.bandOpacity)"/>
    """)
}

func traceSVG(_ look: Look) -> String {
    let steps = 240
    let points = (0...steps).map { i -> String in
        let x = xStart + (xEnd - xStart) * Double(i) / Double(steps)
        return "\(px(x)),\(py(trace(x)))"
    }
    // Green inside the band, amber above it, with a short blend at the boundary (as in the app).
    // The "now" dot is part of the same layer, a solid disc that swallows the line's end cap, so the
    // glass treats line and dot as one shape.
    return svg("""
      <defs>
        <linearGradient id="range" gradientUnits="userSpaceOnUse" x1="0" y1="1024" x2="0" y2="0">
          <stop offset="0" stop-color="\(look.green.hex)"/>
          <stop offset="\(bandHigh - 0.01)" stop-color="\(look.green.hex)"/>
          <stop offset="\(bandHigh + 0.04)" stop-color="\(look.amber.hex)"/>
          <stop offset="1" stop-color="\(look.amber.hex)"/>
        </linearGradient>
      </defs>
      <polyline points="\(points.joined(separator: " "))" fill="none" stroke="url(#range)" \
    stroke-width="\(String(format: "%.2f", lineWidth))" stroke-linecap="round" stroke-linejoin="round"/>
      <circle cx="\(px(xEnd))" cy="\(py(trace(xEnd)))" r="\(String(format: "%.2f", S * 0.050))" fill="\(look.green.hex)"/>
    """)
}

/// The dot's light core, on its own layer so it sits above the glass.
let core = svg("""
  <circle cx="\(px(xEnd))" cy="\(py(trace(xEnd)))" r="\(String(format: "%.2f", S * 0.021))" fill="#EDFFF7"/>
""")

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icon")
let assets = dir.appending(path: "Assets")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func write(_ text: String, _ name: String, in folder: URL) {
    try! text.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
}

for look in [light, dark] {
    write(band(look), "band-\(look.name).svg", in: assets)
    write(traceSVG(look), "trace-\(look.name).svg", in: assets)
}
write(core, "core.svg", in: assets)

/// A layer whose artwork differs between light (default) and dark appearance.
func layer(_ name: String, glass: Bool) -> [String: Any] {
    [
        "name": name,
        "image-name": "\(name)-light.svg",
        "image-name-specializations": [
            ["value": "\(name)-light.svg"],
            ["appearance": "dark", "value": "\(name)-dark.svg"],
        ],
        "glass": glass,
    ]
}

func gradient(_ look: Look) -> [String: Any] {
    ["linear-gradient": [look.background.top.json(), look.background.bottom.json()]]
}

// Layers are listed top first.
let icon: [String: Any] = [
    "fill-specializations": [
        ["value": gradient(light)],
        ["appearance": "dark", "value": gradient(dark)],
    ],
    "groups": [
        [
            "name": "Trace",
            "layers": [
                ["name": "core", "image-name": "core.svg", "glass": false],
                layer("trace", glass: true),
            ],
            "shadow": ["kind": "layer-color", "opacity": 0.5],
            "translucency": ["enabled": false, "value": 0.5],
            "specular": true,
        ],
        [
            "name": "Band",
            "layers": [layer("band", glass: false)],
            "shadow": ["kind": "none", "opacity": 0.5],
            "translucency": ["enabled": false, "value": 0.5],
        ],
    ],
    "supported-platforms": [
        "squares": "shared",
        "circles": ["watchOS"],
    ],
]

let json = try! JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: dir.appending(path: "icon.json"))
print("Wrote \(dir.path)")
