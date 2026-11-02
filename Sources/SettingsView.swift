// Settings window: gesture bindings, timing and about.

import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable {
    case gestures, general, about
}

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @State var tab: SettingsTab = .gestures

    var body: some View {
        TabView(selection: $tab) {
            GesturesTab(prefs: prefs)
                .tabItem { Label("Gestures", systemImage: "hand.tap") }
                .tag(SettingsTab.gestures)
            GeneralTab(prefs: prefs)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .padding(20)
        .frame(width: 600, height: 560)
    }
}

// MARK: - Gestures

struct GesturesTab: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            ForEach(Gesture.allCases) { gesture in
                GestureRow(gesture: gesture, prefs: prefs)
            }
        }
        .formStyle(.grouped)
    }
}

struct GestureRow: View {
    let gesture: Gesture
    @ObservedObject var prefs: Preferences
    @State private var showsRecorder = false

    private var action: GestureAction? { prefs.settings.bindings[gesture] }

    private var preset: Binding<ActionPreset> {
        Binding(
            get: { showsRecorder ? .custom : ActionPreset(action) },
            set: { newValue in
                showsRecorder = newValue == .custom
                if !showsRecorder {
                    prefs.settings.bindings[gesture] = newValue.action  // nil removes the binding
                }
            }
        )
    }

    /// The current shortcut, shown on the recorder button.
    private var shortcut: Shortcut? {
        if case .shortcut(let shortcut) = action { shortcut } else { nil }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(gesture.title)
                if let hint = gesture.hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if preset.wrappedValue == .custom {
                ShortcutRecorder(shortcut: shortcut) { shortcut in
                    prefs.settings.bindings[gesture] = .shortcut(shortcut)
                    showsRecorder = false
                }
            }
            Picker("", selection: preset) {
                ForEach(ActionPreset.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170)
        }
    }
}

/// Click, then press a key combination. Esc cancels.
struct ShortcutRecorder: View {
    let shortcut: Shortcut?
    let onRecord: (Shortcut) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : (shortcut?.display ?? "Record")) {
            recording ? stop() : start()
        }
        .frame(minWidth: 90)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let key = event.charactersIgnoringModifiers ?? "?"
            onRecord(Shortcut(keyCode: event.keyCode, modifiers: UInt64(flags.rawValue), key: key))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var access = AccessibilityWatch.shared
    @State private var loginItem = SMAppService.mainApp.status

    var body: some View {
        Form {
            Section {
                Toggle("Enable gestures", isOn: $prefs.settings.enabled)
                // requiresApproval: registered, but switched off by the user in Login Items.
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem == .enabled || loginItem == .requiresApproval },
                    set: setLaunchAtLogin))
                if loginItem == .requiresApproval {
                    LabeledContent("Turned off in System Settings") {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                LabeledContent("Accessibility access") {
                    if access.trusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Settings") { openPane("com.apple.preference.security?Privacy_Accessibility") }
                    }
                }
            }
            Section("Timing") {
                slider("Tap length", value: $prefs.settings.tapMaxDuration, range: 0.15...0.45, unit: "s")
                slider("Double tap gap", value: $prefs.settings.doubleTapGap, range: 0.2...0.6, unit: "s")
                slider("Allowed movement", value: $prefs.settings.tapTravel, range: 0.01...0.08, unit: "%", scale: 100)
            }
            Section {
                HStack {
                    Button("Open Trackpad Settings") { openPane("com.apple.Trackpad-Settings.extension") }
                    Spacer()
                    Button("Reset to Defaults") { prefs.resetToDefaults() }
                }
            }
            Section("Menu bar icon") {
                Text("Can't see the TapKeys icon? Menu bar managers like Ice or Bartender move new icons "
                     + "to their hidden section, and on a MacBook with a notch icons can sit behind it. "
                     + "Open TapKeys again from Finder, Spotlight or Launchpad to get back to this window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // The status changes in System Settings too; read it again when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem = SMAppService.mainApp.status
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        unit: String, scale: Double = 1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(String(format: scale == 1 ? "%.2f %@" : "%.0f %@", value.wrappedValue * scale, unit))
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
            }
            .frame(width: 260)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("TapKeys: launch at login failed: %@", String(describing: error))
        }
        loginItem = SMAppService.mainApp.status
    }

    private func openPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - About

struct AboutTab: View {
    @Environment(\.openURL) private var openURL
    @State private var showsAcknowledgements = false

    private static let repo = URL(string: "https://github.com/scharfff/tapkeys")!
    private static let newIssue = URL(string: "https://github.com/scharfff/tapkeys/issues/new")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 170, height: 170)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TapKeys")
                        .font(.system(size: 44, weight: .medium))
                    Text("Version \(version)")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Copyright © 2026 Scharf L.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Button("Quit TapKeys") { NSApp.terminate(nil) }
                Spacer()
                Button("Acknowledgements") { showsAcknowledgements = true }
                Button("Contribute") { openURL(Self.repo) }
                Button("Report a Bug") { openURL(Self.newIssue) }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
        }
        .sheet(isPresented: $showsAcknowledgements) { Acknowledgements() }
    }
}

struct Acknowledgements: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Acknowledgements").font(.title2.bold())
            item("MultitouchSupport",
                 "Apple's private framework that reports trackpad touches. It ships with macOS "
                 + "and is loaded from the system at run time; TapKeys bundles none of its code.")
            item("Ice",
                 "The menu bar manager by Jordan Baird. Its About page inspired the layout of this one.")
            item("App icon",
                 "An original drawing by Scharf L.")
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func item(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
