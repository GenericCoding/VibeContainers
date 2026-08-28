import SwiftUI

/// The theme: PS3-era homebrew.
///
/// Deep blue-black glass, ice-cyan light, and type that glows slightly rather
/// than sitting flat — the palette the XMB and every custom dashboard built on
/// top of it shared. No pure black and no pure white: the darkest surface still
/// has blue in it, and the brightest text is tinted the same way, which is what
/// keeps a screen of translucent panels reading as one material.
///
/// Everything routes through here, so re-tinting the whole simulator is a
/// matter of changing values in this file. `SysColor` maps these onto the iOS
/// names the app code uses.
enum Palette {
    // Surfaces, darkest to lightest.
    static let ink = Color(hex: "05080F")            // behind everything
    static let surface = Color(hex: "0F1725")        // grouped rows
    static let surfaceRaised = Color(hex: "1A2537")  // pressed / tertiary fill
    static let hairline = Color(hex: "A8DBFF").opacity(0.16)

    /// The sheen along the top edge of a glass panel.
    static let specular = Color(hex: "CFEEFF")
    /// The glow a lit control throws.
    static let bloom = Color(hex: "5FD0FF")

    // Type
    static let paper = Color(hex: "E9F2FF")          // primary label
    static let paperDim = Color(hex: "92A6C4")       // secondary label

    // Accents. Ice leads: it is the XMB's own colour.
    static let ice = Color(hex: "6ED8FF")
    static let denim = Color(hex: "4C9BFF")
    static let sage = Color(hex: "5FE0A8")
    static let clay = Color(hex: "FF6B72")
    static let amber = Color(hex: "FFB454")
    static let wheat = Color(hex: "FFD98A")
    static let mauve = Color(hex: "B18CFF")
    static let rose = Color(hex: "FF8FC5")
    static let seafoam = Color(hex: "55E3D8")
    static let dusk = Color(hex: "7C8CFF")
    static let stone = Color(hex: "6C7E99")

    // The background wave, from the horizon up.
    static let wavePeak = Color(hex: "7FE9FF")
    static let waveMid = Color(hex: "2E7FE0")
    static let waveDeep = Color(hex: "10214A")

    /// Vertical wash behind the wave: night at the top, a cold dawn below.
    static let skyTop = Color(hex: "04060D")
    static let skyUpper = Color(hex: "071228")
    static let skyMid = Color(hex: "0B2145")
    static let skyGlow = Color(hex: "17457F")
    static let skyLow = Color(hex: "071426")
    static let ground = Color(hex: "04070E")

    static let grain = Color(hex: "CFE8FF")
    static let vignette = Color(hex: "01030A")

    /// Dust drifting through the light.
    static let moteTints: [Color] = [
        Color(hex: "9FE6FF"),
        Color(hex: "6FC7FF"),
        Color(hex: "CFF3FF"),
        Color(hex: "7FA8FF"),
        Color(hex: "B9E9FF")
    ]
}
