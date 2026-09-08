import AppKit

enum MenuBarStyle: String, CaseIterable, Identifiable {
    /// Monochrome until the number needs attention, then a coloured pill.
    case adaptive
    /// Always a coloured pill.
    case pill
    /// Never coloured.
    case mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .adaptive: return "Adaptive"
        case .pill: return "Always colour"
        case .mono: return "Monochrome"
        }
    }
}

/// Draws the menu bar label — a cup glyph plus the running total.
///
/// The hard constraint here is that `NSImage.isTemplate` is all-or-nothing: a template
/// image is flattened to an alpha mask, so you cannot mix system-adapted text with a
/// custom-coloured accent in one image. Each label is therefore *either* fully
/// template *or* fully self-coloured.
///
/// That matters because the menu bar background is arbitrary — your wallpaper shows
/// through it, and macOS decides menu bar contrast from the wallpaper's luminance,
/// which an app can't reliably read. Only the template path gets that right. A
/// hand-picked "dark green for light mode" is illegible the moment there's a mid-tone
/// wallpaper behind the menu bar.
///
/// So colour is only used where it's safe: inside a filled pill, where we control the
/// background as well as the text and contrast is guaranteed regardless of wallpaper.
enum StatusBarIcon {

    private static let height: CGFloat = 18
    private static let gap: CGFloat = 3

    static func render(
        text: String,
        level: SpendLevel,
        holdingAwake: Bool,
        style: MenuBarStyle,
        lidArmed: Bool
    ) -> NSImage {
        let useColour: Bool
        switch style {
        case .mono: useColour = false
        case .pill: useColour = true
        // Quiet while you're fine, loud once you're not.
        case .adaptive: useColour = (level == .warning || level == .over)
        }

        return useColour
            ? pillImage(text: text, level: level, holdingAwake: holdingAwake, lidArmed: lidArmed)
            : templateImage(text: text, holdingAwake: holdingAwake, lidArmed: lidArmed)
    }

    // MARK: - Monochrome

    /// Drawn in solid black and marked as a template, so macOS recolours it to whatever
    /// actually contrasts with the menu bar.
    private static func templateImage(text: String, holdingAwake: Bool, lidArmed: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
        ])
        let warning = lidArmed ? warningImage(tint: .black, pointSize: 12) : nil
        let glyph = cupImage(filled: holdingAwake, tint: .black, pointSize: 14)

        let textSize = attributed.size()
        let glyphs = [warning, glyph].compactMap { $0 }
        let glyphWidth = glyphs.reduce(0) { $0 + $1.size.width + gap }
        let width = glyphWidth + ceil(textSize.width)

        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for glyph in glyphs {
                glyph.draw(in: NSRect(
                    x: x,
                    y: (height - glyph.size.height) / 2,
                    width: glyph.size.width,
                    height: glyph.size.height
                ))
                x += glyph.size.width + gap
            }
            attributed.draw(at: NSPoint(x: x, y: (height - ceil(textSize.height)) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Coloured pill

    /// White on a saturated fill. Self-contained, so it stays readable on any wallpaper.
    private static func pillImage(
        text: String,
        level: SpendLevel,
        holdingAwake: Bool,
        lidArmed: Bool
    ) -> NSImage {
        let pillHeight: CGFloat = 15
        let insetX: CGFloat = 6
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
        ])
        let warning = lidArmed ? warningImage(tint: .white, pointSize: 10.5) : nil
        let glyph = cupImage(filled: holdingAwake, tint: .white, pointSize: 11.5)

        let textSize = attributed.size()
        let glyphs = [warning, glyph].compactMap { $0 }
        let glyphWidth = glyphs.reduce(0) { $0 + $1.size.width + gap }
        let width = glyphWidth + ceil(textSize.width) + insetX * 2

        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { _ in
            let pill = NSRect(x: 0, y: (height - pillHeight) / 2, width: width, height: pillHeight)
            NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2).setClip()
            fillColor(for: level).setFill()
            pill.fill()

            var x = insetX
            for glyph in glyphs {
                glyph.draw(in: NSRect(
                    x: x,
                    y: (height - glyph.size.height) / 2,
                    width: glyph.size.width,
                    height: glyph.size.height
                ))
                x += glyph.size.width + gap
            }
            attributed.draw(at: NSPoint(x: x, y: (height - ceil(textSize.height)) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Shown whenever lid sleep is disabled — global system state should never change
    /// without something visible saying so.
    private static func warningImage(tint: NSColor, pointSize: CGFloat) -> NSImage? {
        symbol("exclamationmark.triangle.fill", tint: tint, pointSize: pointSize)
    }

    private static func cupImage(filled: Bool, tint: NSColor, pointSize: CGFloat) -> NSImage? {
        symbol(filled ? "cup.and.saucer.fill" : "cup.and.saucer", tint: tint, pointSize: pointSize)
    }

    private static func symbol(_ name: String, tint: NSColor, pointSize: CGFloat) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: "DoubleShot") else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let configured = image.withSymbolConfiguration(configuration) ?? image
        configured.isTemplate = false
        return configured
    }

    /// Pill fills. Dark enough that white text clears WCAG AA at this size, and fixed
    /// rather than appearance-dependent — the pill supplies its own background.
    static func fillColor(for level: SpendLevel) -> NSColor {
        switch level {
        case .ok:      return NSColor(srgbRed: 0.16, green: 0.55, blue: 0.27, alpha: 1)
        case .caution: return NSColor(srgbRed: 0.68, green: 0.48, blue: 0.03, alpha: 1)
        case .warning: return NSColor(srgbRed: 0.83, green: 0.40, blue: 0.04, alpha: 1)
        case .over:    return NSColor(srgbRed: 0.78, green: 0.14, blue: 0.11, alpha: 1)
        }
    }

    /// For in-app text and bars. Inside a window the effective appearance *is* known,
    /// so these can adapt to light/dark properly.
    static func color(for level: SpendLevel) -> NSColor {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        switch level {
        case .ok:
            return dark ? NSColor(srgbRed: 0.42, green: 0.85, blue: 0.47, alpha: 1)
                        : NSColor(srgbRed: 0.13, green: 0.52, blue: 0.24, alpha: 1)
        case .caution:
            return dark ? NSColor(srgbRed: 0.98, green: 0.82, blue: 0.30, alpha: 1)
                        : NSColor(srgbRed: 0.66, green: 0.48, blue: 0.02, alpha: 1)
        case .warning:
            return dark ? NSColor(srgbRed: 1.00, green: 0.62, blue: 0.24, alpha: 1)
                        : NSColor(srgbRed: 0.78, green: 0.38, blue: 0.02, alpha: 1)
        case .over:
            return dark ? NSColor(srgbRed: 1.00, green: 0.45, blue: 0.41, alpha: 1)
                        : NSColor(srgbRed: 0.75, green: 0.12, blue: 0.10, alpha: 1)
        }
    }
}
