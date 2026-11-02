// Gesture recognition and actions.
//
// Touches come from the private MultitouchSupport framework (loaded with
// dlsym). Physical clicks come from a CGEvent tap, so a multi-finger click
// can be swallowed and replaced with the bound action.

import Carbon.HIToolbox
import Cocoa

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
typealias MTRegisterContactFrameCallbackFn = @convention(c) (MTDeviceRef?, MTFrameCallbackFunction?) -> Void
typealias MTDeviceStartFn = @convention(c) (MTDeviceRef?, Int32) -> Void

let frameCallback: MTFrameCallbackFunction = { _, touches, numTouches, timestamp, _ in
    if let gesture = Engine.shared.handleFrame(touches: touches, count: Int(numTouches), timestamp: timestamp),
       let action = Engine.shared.action(for: gesture) {
        DispatchQueue.main.async { perform(action) }
    }
    return 0
}

var multitouchDevices: CFMutableArray?  // kept alive for the lifetime of the app

/// Starts listening on every trackpad. Returns the number of devices found.
@discardableResult
func startMultitouch() -> Int {
    let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    guard let handle = dlopen(path, RTLD_NOW),
          let createList = dlsym(handle, "MTDeviceCreateList"),
          let register = dlsym(handle, "MTRegisterContactFrameCallback"),
          let start = dlsym(handle, "MTDeviceStart") else {
        NSLog("TapKeys: MultitouchSupport is unavailable")
        return 0
    }
    let createListFn = unsafeBitCast(createList, to: MTDeviceCreateListFn.self)
    let registerFn = unsafeBitCast(register, to: MTRegisterContactFrameCallbackFn.self)
    let startFn = unsafeBitCast(start, to: MTDeviceStartFn.self)

    guard let devices = createListFn()?.takeRetainedValue() else { return 0 }
    multitouchDevices = devices
    let count = CFArrayGetCount(devices)
    for i in 0..<count {
        let device = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(devices, i))
        registerFn(device, frameCallback)
        startFn(device, 0)
    }
    return count
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
            startClickTap()
        } else if eventTap != nil {
            stopClickTap()
            NSLog("TapKeys: Accessibility access is gone, click tap removed")
        }
    }
}
