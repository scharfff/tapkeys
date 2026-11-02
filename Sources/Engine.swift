// Gesture recognition and actions.
//
// Touches come from the private MultitouchSupport framework (loaded with
// dlsym). Physical clicks come from a CGEvent tap, so a multi-finger click
// can be swallowed and replaced with the bound action.

import Carbon.HIToolbox
import Cocoa
import IOKit

final class Engine {
    static let shared = Engine()

    private let lock = NSLock()
    private var settings = Settings()

    // Touch state, written by the multitouch thread and read by the event tap.
    private var fingerCount = 0
    private var touching = false
    private var touchStart = 0.0
    private var maxFingers = 0
    private var lastCount = 0
    private var baseline = MTPoint(x: 0, y: 0)
    private var moved = false
    private var clicked = false
    private var lastTapEnd = 0.0

    func apply(_ settings: Settings) {
        lock.lock(); defer { lock.unlock() }
        self.settings = settings
    }

    /// The action to perform for a gesture now: nil when the gesture is unbound or TapKeys is paused.
    func action(for gesture: Gesture) -> GestureAction? {
        lock.lock(); defer { lock.unlock() }
        return settings.enabled ? settings.bindings[gesture] : nil
    }

    var currentFingerCount: Int {
        lock.lock(); defer { lock.unlock() }
        return fingerCount
    }

    func markClicked() {
        lock.lock(); clicked = true; lock.unlock()
    }

    /// Forgets the touch in progress when the trackpads are listed again: a device that
    /// went away never reports its fingers lifting, and a stale finger count would turn
    /// the next ordinary click into a multi-finger click.
    func resetTouches() {
        lock.lock(); defer { lock.unlock() }
        fingerCount = 0
        touching = false
        lastCount = 0
        maxFingers = 0
        lastTapEnd = 0
    }

    /// Feeds one multitouch frame. Returns a tap gesture when one just completed.
    func handleFrame(touches: UnsafeMutablePointer<MTTouch>?, count: Int, timestamp: Double) -> Gesture? {
        lock.lock(); defer { lock.unlock() }
        fingerCount = count

        if count > 0, let touches {
            let center = centroid(touches, count)
            if !touching {
                touching = true
                touchStart = timestamp
                maxFingers = count
                moved = false
                clicked = false
                baseline = center
            } else if count != lastCount {
                // Fingers land and lift a few frames apart; restart the
                // movement baseline so the centroid jump is not a swipe.
                baseline = center
            }
            lastCount = count
            maxFingers = max(maxFingers, count)
            if hypotf(center.x - baseline.x, center.y - baseline.y) > Float(settings.tapTravel) {
                moved = true
            }
            return nil
        }

        guard touching else { return nil }
        touching = false
        lastCount = 0

        let isTap = timestamp - touchStart < settings.tapMaxDuration && !moved && !clicked
        guard isTap else {
            lastTapEnd = 0
            return nil
        }
        if maxFingers == 1 {
            if lastTapEnd > 0 && timestamp - lastTapEnd < settings.doubleTapGap {
                lastTapEnd = 0
                return .oneFingerDoubleTap
            }
            lastTapEnd = timestamp
            return nil
        }
        lastTapEnd = 0
        return Gesture.tap(fingers: maxFingers)
    }

    private func centroid(_ touches: UnsafeMutablePointer<MTTouch>, _ count: Int) -> MTPoint {
        var x: Float = 0, y: Float = 0
        for i in 0..<count {
            x += touches[i].normalized.position.x
            y += touches[i].normalized.position.y
        }
        return MTPoint(x: x / Float(count), y: y / Float(count))
    }
}

// MARK: - Actions

/// Posts the action's events. Main thread only: it reads the layout cache, and the
/// event tap callback must never wait for it.
func perform(_ action: GestureAction) {
    dispatchPrecondition(condition: .onQueue(.main))
    switch action {
    case .shortcut(let shortcut):
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode = layoutKeyCode(for: shortcut)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = CGEventFlags(rawValue: shortcut.modifiers)
            event?.post(tap: .cghidEventTap)
        }
    case .middleClick:
        let location = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .center)?
                .post(tap: .cghidEventTap)
        }
    }
}

/// The key that types the shortcut's letter in the current keyboard layout.
/// Presets store US key codes: on AZERTY key code 6 is W and 0 is Q, so
/// Undo would send ⌘W and Select all ⌘Q. Letters are looked up in the
/// ASCII capable layout (the one macOS uses for ⌘ shortcuts, also under a
/// Russian layout); anything else keeps its recorded key code.
func layoutKeyCode(for shortcut: Shortcut) -> CGKeyCode {
    LayoutCache.shared.keyCodes[shortcut.key.lowercased()] ?? shortcut.keyCode
}

/// Key codes of the letters a to z in the ASCII capable layout. Read once at launch and
/// again when the input source changes, on the main thread (Text Input Sources wants it),
/// so a gesture never waits for the input source server.
final class LayoutCache: NSObject {
    static let shared = LayoutCache()
    private(set) var keyCodes: [String: CGKeyCode] = [:]

    func start() {
        reload()
        // A menu bar app is almost never active, and NSApplication holds back distributed
        // notifications for inactive apps unless the observer asks for immediate delivery.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(reload),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func reload() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            keyCodes = [:]
            return
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var codes: [String: CGKeyCode] = [:]
        data.withUnsafeBytes { bytes in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for code in CGKeyCode(0)..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, chars.count, &length, &chars)
                let letter = String(utf16CodeUnits: chars, count: length)
                if status == noErr, letter.unicodeScalars.count == 1,
                   let scalar = letter.unicodeScalars.first, ("a"..."z").contains(scalar), codes[letter] == nil {
                    codes[letter] = code
                }
            }
        }
        keyCodes = codes
    }
}

// MARK: - Multitouch

typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
typealias MTContactFrameCallbackFn = @convention(c) (MTDeviceRef?, MTFrameCallbackFunction?) -> Void
typealias MTDeviceStartFn = @convention(c) (MTDeviceRef?, Int32) -> Void
typealias MTDeviceStopFn = @convention(c) (MTDeviceRef?) -> Void

let frameCallback: MTFrameCallbackFunction = { _, touches, numTouches, timestamp, _ in
    if let gesture = Engine.shared.handleFrame(touches: touches, count: Int(numTouches), timestamp: timestamp),
       let action = Engine.shared.action(for: gesture) {
        DispatchQueue.main.async { perform(action) }
    }
    return 0
}

/// Listens on every trackpad and lists them again when the set may have changed.
///
/// A device from MTDeviceCreateList is bound to one kernel object. On an Intel MacBook the
/// built in trackpad is a USB device that the kernel tears down and creates again on every
/// wake (log: "AppleMultitouchDevice::willTerminate", then "::start" with a new registry
/// ID), and a Magic Trackpad comes and goes with Bluetooth. A device bound to a removed
/// object never calls back, so gestures stop until the list is rebuilt: after wake, after
/// the screens wake, and whenever IOKit reports a trackpad added or removed. Main thread only.
final class Multitouch {
    static let shared = Multitouch()

    private struct API {
        let createList: MTDeviceCreateListFn
        let register: MTContactFrameCallbackFn
        let unregister: MTContactFrameCallbackFn
        let start: MTDeviceStartFn
        let stop: MTDeviceStopFn
    }

    private lazy var api: API? = {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW),
              let createList = dlsym(handle, "MTDeviceCreateList"),
              let register = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let start = dlsym(handle, "MTDeviceStart"),
              let stop = dlsym(handle, "MTDeviceStop") else {
            NSLog("TapKeys: MultitouchSupport is unavailable")
            return nil
        }
        return API(createList: unsafeBitCast(createList, to: MTDeviceCreateListFn.self),
                   register: unsafeBitCast(register, to: MTContactFrameCallbackFn.self),
                   unregister: unsafeBitCast(unregister, to: MTContactFrameCallbackFn.self),
                   start: unsafeBitCast(start, to: MTDeviceStartFn.self),
                   stop: unsafeBitCast(stop, to: MTDeviceStopFn.self))
    }()

    /// The current devices. The list holds the only reference to each one (retain count 1
    /// right after MTDeviceCreateList), so dropping the list frees them.
    private var devices: CFMutableArray?
    private var restartTimer: Timer?
    private var notificationPort: IONotificationPortRef?

    /// Stops the current devices, lists the trackpads again and starts them.
    /// Returns the number of devices found.
    @discardableResult
    func start() -> Int {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        guard let api, let list = api.createList()?.takeRetainedValue() else { return 0 }
        devices = list
        let count = CFArrayGetCount(list)
        for i in 0..<count {
            let device = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, i))
            api.register(device, frameCallback)
            api.start(device, 0)
        }
        return count
    }

    /// Unregisters and stops every device, then releases them with the list. No
    /// MTDeviceRelease on top: the list owns the devices, a second release would free them twice.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let api, let list = devices else { return }
        for i in 0..<CFArrayGetCount(list) {
            let device = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, i))
            api.unregister(device, frameCallback)
            api.stop(device)
        }
        devices = nil
        Engine.shared.resetTouches()
    }

    /// Rebuilds the device list once `delay` seconds pass without another request, so a
    /// wake that removes and adds the trackpad and wakes the screens restarts it once.
    func scheduleRestart(after delay: TimeInterval, reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        restartTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.restartTimer = nil
            NSLog("TapKeys: %@, trackpads found again: %d", reason, self.start())
        }
        // Common modes: restart even while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        restartTimer = timer
    }

    /// Subscribes to wake and to trackpads being added or removed. Call once, after start().
    func watch() {
        dispatchPrecondition(condition: .onQueue(.main))
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Give the kernel a moment to finish bringing the trackpad back.
                self?.scheduleRestart(after: 2, reason: note.name.rawValue)
            }
        }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            NSLog("TapKeys: no IOKit notification port, a trackpad connected later needs a restart")
            return
        }
        notificationPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .commonModes)
        let changed: IOServiceMatchingCallback = { _, iterator in
            Multitouch.drain(iterator)
            Multitouch.shared.scheduleRestart(after: 1, reason: "trackpad added or removed")
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(port, type, IOServiceMatching("AppleMultitouchDevice"),
                                                          changed, nil, &iterator)
            if result == KERN_SUCCESS {
                // Draining arms the notification. The trackpads already present are started.
                Multitouch.drain(iterator)
            } else {
                NSLog("TapKeys: IOKit notification %@ failed (%d)", type, result)
            }
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}

// MARK: - Click interception

// The tap, its run loop source and the swallow flag live on the main thread only.
var swallowingClick = false
var eventTap: CFMachPort?
private var eventTapSource: CFRunLoopSource?

/// Decides pass or swallow and returns at once. The action runs later on the main
/// queue: while this callback runs, every click in the session waits for it.
let clickCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        NSLog("TapKeys: click tap disabled by the system (type %u), enabling it again", type.rawValue)
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    switch type {
    case .leftMouseDown:
        // A new press means the previous one ended. If its mouseUp never
        // reached us (tap disabled, lost event), stop swallowing now so this
        // click's mouseUp is not eaten and the button does not stick.
        swallowingClick = false
        Engine.shared.markClicked()
        if let gesture = Gesture.click(fingers: Engine.shared.currentFingerCount),
           let action = Engine.shared.action(for: gesture) {
            swallowingClick = true
            DispatchQueue.main.async { perform(action) }
            return nil
        }
    case .leftMouseDragged where swallowingClick:
        return nil
    case .leftMouseUp where swallowingClick:
        swallowingClick = false
        return nil
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

@discardableResult
func startClickTap() -> Bool {
    if eventTap != nil { return true }
    let mask = (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.leftMouseUp.rawValue)
        | (1 << CGEventType.leftMouseDragged.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                      place: .headInsertEventTap,
                                      options: .defaultTap,
                                      eventsOfInterest: CGEventMask(mask),
                                      callback: clickCallback,
                                      userInfo: nil) else {
        return false
    }
    eventTap = tap
    eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

/// Removes the tap. A filtering tap that outlives its Accessibility access freezes clicks
/// for the whole session: WindowServer drops every event the tap hands back ("Sender is
/// prohibited from synthesizing events") until the process exits.
func stopClickTap() {
    guard let tap = eventTap else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    if let source = eventTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    CFMachPortInvalidate(tap)
    eventTap = nil
    eventTapSource = nil
    swallowingClick = false
}

/// Keeps the click tap in step with Accessibility access, checked once a second: the tap is
/// created when access is granted and removed as soon as it is turned off or removed in
/// System Settings. The settings window reads `trusted` from here.
final class AccessibilityWatch: ObservableObject {
    static let shared = AccessibilityWatch()
    @Published private(set) var trusted = AXIsProcessTrusted()
    private var timer: Timer?

    func start() {
        check()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        // Common modes: keep checking while a menu is open or a slider is dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        let now = AXIsProcessTrusted()
        if now != trusted { trusted = now }
        if now {
            let hadTap = eventTap != nil
            if startClickTap(), !hadTap { NSLog("TapKeys: click tap created") }
            keepClickTapEnabled()
        } else if eventTap != nil {
            stopClickTap()
            NSLog("TapKeys: Accessibility access is gone, click tap removed")
        }
    }

    /// The system can disable the tap without telling it: the tapDisabled event reaches the
    /// callback only with the next click, and around sleep the mach port can die. Checked
    /// every second, so a disabled tap is back within a second of wake.
    private func keepClickTapEnabled() {
        guard let tap = eventTap else { return }
        if !CFMachPortIsValid(tap) {
            stopClickTap()
            NSLog("TapKeys: click tap port was invalidated, creating it again: %d", startClickTap())
        } else if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("TapKeys: click tap was disabled, enabled it again")
        }
    }
}
