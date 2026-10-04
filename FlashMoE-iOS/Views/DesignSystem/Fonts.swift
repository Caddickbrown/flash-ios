/*
 * Fonts.swift — Bundled typefaces
 *
 * Space Grotesk for text, JetBrains Mono for anything the engine produces.
 * Both are SIL OFL; the licences ship next to the files in Resources/Fonts.
 *
 * Registration is done at runtime with CTFontManager rather than the UIAppFonts
 * plist key: the project's Info.plist is generated from project.yml build
 * settings, and UIAppFonts has no INFOPLIST_KEY_ equivalent.
 */

import SwiftUI
import CoreText

enum FMFonts {

    /// PostScript names of the bundled faces, as reported by CoreText.
    private enum PS {
        static let sansRegular = "SpaceGrotesk-Regular"
        static let sansMedium = "SpaceGrotesk-Medium"
        static let sansBold = "SpaceGrotesk-Bold"
        static let monoRegular = "JetBrainsMono-Regular"
        static let monoMedium = "JetBrainsMono-Medium"
        static let monoSemiBold = "JetBrainsMono-SemiBold"
    }

    private static let files = [
        PS.sansRegular, PS.sansMedium, PS.sansBold,
        PS.monoRegular, PS.monoMedium, PS.monoSemiBold
    ]

    /// False if registration failed, in which case every helper below falls
    /// back to the system face rather than rendering in a silent substitute.
    private(set) nonisolated(unsafe) static var available = false

    /// Register the bundled faces. Call once, before the first view is built.
    static func register() {
        var urls: [URL] = []
        for name in files {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                NSLog("[fonts] missing \(name).ttf in bundle")
                continue
            }
            urls.append(url)
        }

        guard urls.count == files.count else {
            NSLog("[fonts] only \(urls.count)/\(files.count) faces found — using system font")
            return
        }

        var errors: Unmanaged<CFArray>?
        let ok = CTFontManagerRegisterFontsForURLs(urls as CFArray, .process, &errors)
        if let list = errors?.takeRetainedValue() as? [NSError], !list.isEmpty {
            NSLog("[fonts] registration errors: \(list.map(\.localizedDescription))")
        }

        // Registration reports false when a face is already registered, which
        // happens on a warm relaunch, so confirm by resolving the font itself.
        available = ok || isRegistered(PS.sansRegular)
        if !available {
            NSLog("[fonts] registration failed — falling back to the system font")
        }
    }

    /// CTFontCreateWithName always returns *a* font, so an unregistered name
    /// silently yields a substitute. Compare the resolved PostScript name.
    private static func isRegistered(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        return (CTFontCopyPostScriptName(font) as String) == name
    }

    // MARK: - Resolvers

    /// Text face. Space Grotesk ships Regular / Medium / Bold only, so
    /// semibold resolves to Bold at display sizes and Medium below them —
    /// Bold at 13px reads heavier than SF's semibold does.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard available else { return .system(size: size, weight: weight) }

        let name: String
        switch weight {
        case .bold, .heavy, .black:
            name = PS.sansBold
        case .semibold:
            name = size >= 20 ? PS.sansBold : PS.sansMedium
        case .medium:
            name = PS.sansMedium
        default:
            name = PS.sansRegular
        }
        return .custom(name, size: size)
    }

    /// Data face — readouts, units, labels, chips, file names.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard available else { return .system(size: size, weight: weight, design: .monospaced) }

        let name: String
        switch weight {
        case .semibold, .bold, .heavy, .black:
            name = PS.monoSemiBold
        case .medium:
            name = PS.monoMedium
        default:
            name = PS.monoRegular
        }
        return .custom(name, size: size)
    }
}
