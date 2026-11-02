// Gestures, actions and the user's bindings, persisted in UserDefaults.

import Cocoa

enum Gesture: String, CaseIterable, Codable, CodingKeyRepresentable, Identifiable {
    case oneFingerDoubleTap
    case threeFingerTap
    case threeFingerClick
    case fourFingerTap
    case fourFingerClick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneFingerDoubleTap: "Double tap with one finger"
        case .threeFingerTap: "Tap with three fingers"
        case .threeFingerClick: "Click with three fingers"
        case .fourFingerTap: "Tap with four fingers"
        case .fourFingerClick: "Click with four fingers"
        }
    }

    /// A conflict with a macOS gesture the user may need to switch off.
    var hint: String? {
        switch self {
        case .oneFingerDoubleTap: "Works best with Tap to click turned off"
        case .threeFingerTap: "Turn off Look up & data detectors with three fingers"
        case .threeFingerClick: "Turn off three-finger drag"
        case .fourFingerTap, .fourFingerClick: nil
        }
    }

    /// The multi-finger tap for a finger count, or nil when there is none.
    static func tap(fingers: Int) -> Gesture? {
        switch fingers {
        case 3: .threeFingerTap
        case 4: .fourFingerTap
        default: nil
        }
    }

    /// The multi-finger click for a finger count, or nil when there is none.
    static func click(fingers: Int) -> Gesture? {
        switch fingers {
        case 3: .threeFingerClick
        case 4: .fourFingerClick
        default: nil
        }
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64   // CGEventFlags bits; NSEvent.ModifierFlags uses the same bits
    var key: String         // label captured when recording

    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }

    static func command(_ key: String, _ keyCode: UInt16, shift: Bool = false) -> Shortcut {
        var flags: NSEvent.ModifierFlags = .command
        if shift { flags.insert(.shift) }
        return Shortcut(keyCode: keyCode, modifiers: UInt64(flags.rawValue), key: key)
    }

    static let copy = command("c", 8)
    static let paste = command("v", 9)
    static let cut = command("x", 7)
    static let undo = command("z", 6)
    static let redo = command("z", 6, shift: true)
    static let selectAll = command("a", 0)
}

/// What a gesture does. A gesture without an action has no entry in `Settings.bindings`.
enum GestureAction: Codable, Equatable {
    case shortcut(Shortcut)
    case middleClick
}

/// Menu entries in the settings window. `custom` means a recorded shortcut.
enum ActionPreset: String, CaseIterable, Identifiable {
    case nothing, copy, paste, cut, undo, redo, selectAll, middleClick, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nothing: "Nothing"
        case .copy: "Copy  ⌘C"
        case .paste: "Paste  ⌘V"
        case .cut: "Cut  ⌘X"
        case .undo: "Undo  ⌘Z"
        case .redo: "Redo  ⇧⌘Z"
        case .selectAll: "Select all  ⌘A"
        case .middleClick: "Middle click"
        case .custom: "Custom shortcut…"
        }
    }

    /// The action this preset binds; nil for `nothing`. `custom` has no fixed action,
    /// so callers check for it first.
    var action: GestureAction? {
        switch self {
        case .nothing, .custom: nil
        case .copy: .shortcut(.copy)
        case .paste: .shortcut(.paste)
        case .cut: .shortcut(.cut)
        case .undo: .shortcut(.undo)
        case .redo: .shortcut(.redo)
        case .selectAll: .shortcut(.selectAll)
        case .middleClick: .middleClick
        }
    }

    /// The fixed preset for an action, or `custom` for a recorded shortcut.
    init(_ action: GestureAction?) {
        self = Self.allCases.first { $0 != .custom && $0.action == action } ?? .custom
    }
}

/// Everything the user can change, stored as one JSON value.
struct Settings: Codable, Equatable {
    var bindings: [Gesture: GestureAction] = [
        .oneFingerDoubleTap: .shortcut(.copy),
        .threeFingerClick: .shortcut(.paste),
    ]
    var enabled = true
    var tapMaxDuration = 0.25   // s
    var doubleTapGap = 0.35     // s
    var tapTravel = 0.03        // fraction of trackpad width
}

final class Preferences: ObservableObject {
    static let shared = Preferences()

    private static let key = "settings"
    /// Keys of the earlier unreleased format, removed on the first save.
    private static let legacyKeys = ["bindings", "enabled", "tapMaxDuration", "doubleTapGap", "tapTravel"]

    /// Every change is saved and handed to the engine in one step.
    @Published var settings: Settings {
        didSet {
            defaults.set(try? JSONEncoder().encode(settings), forKey: Self.key)
            Self.legacyKeys.forEach(defaults.removeObject(forKey:))
            Engine.shared.apply(settings)
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        // Unreadable or missing data falls back to the defaults.
        settings = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        Engine.shared.apply(settings)
    }

    /// Restores the bindings and timing; the Enabled switch stays as it is.
    func resetToDefaults() {
        var fresh = Settings()
        fresh.enabled = settings.enabled
        settings = fresh
    }
}
