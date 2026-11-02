// TapKeys: free trackpad gestures for macOS.
// Menu bar app: the engine lives in Engine.swift, bindings in Preferences.swift,
// the settings window in SettingsView.swift.

import Cocoa
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private var settingsWindow: NSWindow?
    private var subscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let prefs = Preferences.shared

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: "TapKeys")

        let menu = NSMenu()
        enabledItem.target = self
        menu.addItem(enabledItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TapKeys", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        subscription = prefs.$settings.map(\.enabled).removeDuplicates().sink { [weak self] enabled in
            self?.enabledItem.state = enabled ? .on : .off
            self?.statusItem.button?.appearsDisabled = !enabled
        }

        // A menu bar app shows no window by default, and menu bar managers (Ice, Bartender)
        // hide new icons, so on the first launch the settings window is the visible sign of life.
        // It has to be on screen before the Accessibility prompt: a window ordered in while
        // the prompt appears stays hidden.
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            openSettings()
        }

        LayoutCache.shared.start()
        Multitouch.shared.start()
        Multitouch.shared.watch()
        // The click tap needs Accessibility access: ask once here; AccessibilityWatch then
        // creates the tap when access is granted and removes it when access goes away.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        AccessibilityWatch.shared.start()
    }

    // Launching the app again from Finder, Spotlight or Launchpad opens the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    @objc private func toggleEnabled() {
        Preferences.shared.settings.enabled.toggle()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "TapKeys Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Open on the current Space, including over a full screen app.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            // SwiftUI sizes the window lazily; size it first, otherwise center() works on
            // an empty frame and the window ends up off to the right.
            window.setContentSize(window.contentViewController?.view.fittingSize ?? .zero)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Since macOS 14 activation is cooperative and can be refused, for example when the
        // app is launched at login or from a background process; show the window anyway.
        settingsWindow?.orderFrontRegardless()
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--selftest") {
    // Loads the framework and counts trackpads without touching any events.
    print("trackpads found: \(Multitouch.shared.start())")
    // Rebuilds the device list twice in a row, as a wake does: the old devices are
    // unregistered, stopped and released, then the trackpads are listed and started again.
    for round in 1...2 {
        print("restart \(round): trackpads found: \(Multitouch.shared.start())")
    }
    // The wake path end to end: the observer schedules a restart, the timer fires it.
    Multitouch.shared.watch()
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 3))
    Multitouch.shared.stop()
    print("accessibility granted: \(AXIsProcessTrusted())")
    // Fills the layout cache the same way the app does at launch; no event tap is created.
    LayoutCache.shared.start()
    let presets: [Shortcut] = [.copy, .paste, .cut, .undo, .selectAll]
    print("layout key codes: \(presets.map { "\($0.key)=\(layoutKeyCode(for: $0))" })")
    let bindings = Preferences.shared.settings.bindings.map { gesture, action in
        switch action {
        case .shortcut(let shortcut): "\(gesture.rawValue)=\(shortcut.display)"
        case .middleClick: "\(gesture.rawValue)=middleClick"
        }
    }
    print("bindings: \(bindings.sorted())")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
