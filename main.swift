import Cocoa

let appVersion = "2.3.0"
let kBundleIDs = ["com.apple.pixelmator", "com.pixelmatorteam.pixelmator.x"]

// MARK: - Talking to Pixelmator Pro

func pixelmatorApp() -> NSRunningApplication? {
    for id in kBundleIDs { if let a = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return a } }
    return nil
}

func runningPixelmatorID() -> String? {
    for id in kBundleIDs where !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty { return id }
    return nil
}

/// Rotates every selected layer by `delta` degrees (negative allowed) and returns the first layer's new angle.
/// Compass convention: 0 at the top, angles grow clockwise. Pixelmator Pro counts counterclockwise, so the
/// number shown is 360 minus Pixelmator's, and every change is negated on the way in.
func toCompass(_ pm: Double) -> Double { let a = (360 - pm).truncatingRemainder(dividingBy: 360); return a < 0 ? a + 360 : a }

/// The angles the selected layers had when they were first selected, so Cancel can put them back.
/// Touched only on the AppleScript queue.
var baseline: [String: Double] = [:]

/// Records the selection's current angles as the baseline when the selection is new (different layers than before).
func noteBaseline() {
    guard let id = runningPixelmatorID() else { return }
    let src = """
    tell application id "\(id)"
        if (count of documents) is 0 then return ""
        tell front document
            set out to ""
            set sel to selected layers
            repeat with i from 1 to count of sel
                set l to item i of sel
                set out to out & (id of l) & "|" & (rotation of l as text) & ";"
            end repeat
            return out
        end tell
    end tell
    """
    var err: NSDictionary?
    guard let r = NSAppleScript(source: src)?.executeAndReturnError(&err), err == nil, let t = r.stringValue, !t.isEmpty else { return }
    var now: [String: Double] = [:]
    for part in t.split(separator: ";") {
        let kv = part.components(separatedBy: "|")
        if kv.count == 2, let v = Double(kv[1]) { now[kv[0]] = v }
    }
    if Set(now.keys) != Set(baseline.keys) { baseline = now; log("baseline \(now.count) layer(s)") }
}

/// Puts every selected layer back to the angle it had when first selected.
func cancelToBaseline() -> (angle: Double?, error: String?) {
    guard let id = runningPixelmatorID() else { return (nil, "Pixelmator Pro is not running") }
    if baseline.isEmpty { return (nil, "Nothing to cancel") }
    let ids = baseline.keys.map { "\"\($0)\"" }.joined(separator: ",")
    let rots = baseline.keys.map { String(baseline[$0]!) }.joined(separator: ",")
    let src = """
    tell application id "\(id)"
        if (count of documents) is 0 then error "No document is open"
        tell front document
            set sel to selected layers
            if (count of sel) is 0 then error "No layer is selected"
            set ids to {\(ids)}
            set rots to {\(rots)}
            set firstAngle to missing value
            set hits to 0
            repeat with j from 1 to count of sel
                set l to item j of sel
                set i to id of l
                repeat with k from 1 to count of ids
                    if (item k of ids) is i then
                        set rotation of l to (item k of rots)
                        set hits to hits + 1
                        if firstAngle is missing value then set firstAngle to rotation of l
                    end if
                end repeat
            end repeat
            if hits is 0 then error "The selection changed; select the original layer again to cancel"
            return firstAngle
        end tell
    end tell
    """
    var err: NSDictionary?
    let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err = err { return (nil, (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error") }
    log("cancel -> baseline \(baseline.count) layer(s)")
    return (r.map { toCompass($0.doubleValue) }, nil)
}

func rotateSelection(by delta: Double, absolute: Bool = false) -> (angle: Double?, error: String?) {
    noteBaseline()
    guard let id = runningPixelmatorID() else { return (nil, "Pixelmator Pro is not running") }
    let src = """
    tell application id "\(id)"
        if (count of documents) is 0 then error "No document is open"
        tell front document
            set sel to selected layers
            if (count of sel) is 0 then error "No layer is selected"
            set firstAngle to 0
            repeat with i from 1 to count of sel
                set l to item i of sel
                set a to (\(absolute ? "0" : "(rotation of l)") + (\(-delta))) mod 360
                if a < 0 then set a to a + 360
                set rotation of l to a
                if i is 1 then set firstAngle to rotation of l
            end repeat
            return (firstAngle as text) & "|" & (name of it) & "|" & ((class of item 1 of sel) as text) & "|" & ((count of sel) as text)
        end tell
    end tell
    """
    var err: NSDictionary?
    let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err = err {
        let m = (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
        log("rotate \(delta) absolute=\(absolute) ERROR: \(m)")
        return (nil, m)
    }
    let parts = (r?.stringValue ?? "").components(separatedBy: "|")   // angle | document | layer class | selected count
    log("rotate \(delta) absolute=\(absolute) -> \(parts) app=\(id)")
    return (parts.first.flatMap { Double($0) }.map { toCompass($0) }, nil)
}

/// ~/Library/Logs/PixProRotate.log — launch/quit trail, so a vanishing window can be explained.
func log(_ m: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PixProRotate.log")
    let line = "\(Date()) \(m)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

/// Current angle of the first selected layer, or nil with a reason.
func readAngle() -> (angle: Double?, error: String?) {
    guard let id = runningPixelmatorID() else { return (nil, "Pixelmator Pro is not running") }
    let src = """
    tell application id "\(id)"
        if (count of documents) is 0 then error "No document is open"
        tell front document
            set sel to selected layers
            if (count of sel) is 0 then error "No layer is selected"
            return rotation of (item 1 of sel)
        end tell
    end tell
    """
    var err: NSDictionary?
    let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err = err { return (nil, (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error") }
    return (r.map { toCompass($0.doubleValue) }, nil)
}

// MARK: - Measuring the visible angle of an item

/// Pixelmator Pro only reports a layer's rotation setting. A line drawn (or imported from SVG) at an angle has
/// rotation 0, so its real direction has to be measured: the selection is copied, the clipboard image is read, and the
/// long axis of the painted pixels gives the angle. The user's clipboard is put back afterward.
struct Measure {
    var axis: Double        // direction of the long axis, compass degrees (0 = up, clockwise), 0..<180
    var tilt: Double        // how far the item sits (clockwise) from the nearest horizontal/vertical, -45...45
    var elongation: Double  // long side / short side of the pixel cloud; near 1 means no clear direction
}

func measureSelection() -> (Measure?, String?) {
    guard let id = runningPixelmatorID() else { return (nil, "Pixelmator Pro is not running") }
    let pb = NSPasteboard.general
    let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { it in
        it.types.compactMap { t in it.data(forType: t).map { (t, $0) } } }
    defer {
        pb.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let n = NSPasteboardItem(); for (t, d) in pairs { n.setData(d, forType: t) }; return n }
        if !items.isEmpty { pb.writeObjects(items) }
    }
    let before = pb.changeCount
    let src = """
    tell application id "\(id)"
        if (count of documents) is 0 then error "No document is open"
        set n to count of (selected layers of front document)
        if n is 0 then error "No layer is selected"
        if n > 1 then error "MULTIPLE"
        copy front document
    end tell
    """
    var err: NSDictionary?
    NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err = err { return (nil, (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error") }
    for _ in 0..<40 where pb.changeCount == before { Thread.sleep(forTimeInterval: 0.025) }
    guard pb.changeCount != before, let data = pb.data(forType: .tiff) ?? pb.data(forType: .png),
          let rep = NSBitmapImageRep(data: data), let px = rep.bitmapData else { return (nil, "Could not copy the layer") }
    let w = rep.pixelsWide, h = rep.pixelsHigh, spp = rep.samplesPerPixel, bpr = rep.bytesPerRow
    guard w > 1, h > 1, spp >= 3, rep.bitsPerSample == 8 else { return (nil, "Unsupported layer image") }
    // Weight = opacity; with no alpha channel, difference from the corner color.
    let hasAlpha = rep.hasAlpha && spp == 4
    let bg = (px[0], px[1], px[2])
    var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
    // A stride keeps very large layers quick; the angle does not need every pixel.
    let step = max(1, Int((Double(w) * Double(h) / 4_000_000).squareRoot()))
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            let p = px + y * bpr + x * spp
            let wt: Double = hasAlpha ? Double(p[3]) / 255
                : (abs(Int(p[0]) - Int(bg.0)) + abs(Int(p[1]) - Int(bg.1)) + abs(Int(p[2]) - Int(bg.2)) > 24 ? 1 : 0)
            if wt > 0.02 {
                let fx = Double(x), fy = Double(y)
                sw += wt; sx += wt * fx; sy += wt * fy
                sxx += wt * fx * fx; syy += wt * fy * fy; sxy += wt * fx * fy
            }
            x += step
        }
        y += step
    }
    guard sw > 0 else { return (nil, "The layer has no visible pixels") }
    let mx = sx / sw, my = sy / sw
    let cxx = sxx / sw - mx * mx, cyy = syy / sw - my * my, cxy = sxy / sw - mx * my
    let tr = cxx + cyy, det = cxx * cyy - cxy * cxy
    let disc = max(0, tr * tr / 4 - det).squareRoot()
    let l1 = tr / 2 + disc, l2 = max(1e-9, tr / 2 - disc)
    // Principal axis in image coordinates (y points down, so this angle runs clockwise from east).
    let phi = 0.5 * atan2(2 * cxy, cxx - cyy) * 180 / .pi
    var axis = (phi + 90).truncatingRemainder(dividingBy: 180); if axis < 0 { axis += 180 }
    var tilt = axis.truncatingRemainder(dividingBy: 90); if tilt > 45 { tilt -= 90 }
    return (Measure(axis: axis, tilt: tilt, elongation: (l1 / l2).squareRoot()), nil)
}

func angleText(_ a: Double) -> String {
    a == a.rounded() ? String(format: "%.0f", a) : String(format: "%.1f", a)
}

// MARK: - UI

/// Turns arrow-key presses into rotation: one step on press, then ~30 steps a second while held.
final class KeyRotator {
    static let shared = KeyRotator()
    var onRotate: ((Double) -> Void)?
    private struct Hold { var step: Double; var since: Date; var fine: Bool; var carry = 0.0 }
    private var held: [Int64: Hold] = [:]   // keyCode -> signed step per tick, press time, fractional carry
    private var timer: Timer?

    /// Arrow key codes: left 123, right 124, down 125, up 126. Returns the sign, or nil for other keys.
    static func sign(for code: Int64) -> Double? {
        switch code { case 124, 126: return 1; case 123, 125: return -1; default: return nil }   // right/up add, left/down subtract
    }

    func key(_ code: Int64, down: Bool, isRepeat: Bool, shift: Bool, option: Bool) {
        guard let sign = KeyRotator.sign(for: code) else { return }
        if down {
            if isRepeat { return }
            let step: Double = shift ? 3 : option ? 0.1 : 1
            held[code] = Hold(step: sign * step, since: Date(), fine: option)
            onRotate?(sign * step)   // a tap is exactly one step
            if timer == nil {
                let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    // Nothing for the first 0.4 s, so a tap stays one step. Then it turns steadily and speeds
                    // up the longer the key is held (1x to 3x over about 1.5 s).
                    // Whole degrees only, except with Option (fine), which moves in tenths: the fraction
                    // left over from the speed-up is carried to the next tick instead of being applied.
                    let now = Date()
                    var total = 0.0
                    for (k, var h) in self.held {
                        let t = now.timeIntervalSince(h.since) - 0.4
                        guard t > 0 else { continue }
                        h.carry += h.step * min(3, 1 + t * 1.5)
                        let unit = h.fine ? 0.1 : 1.0
                        let whole = (h.carry / unit).rounded(.towardZero) * unit
                        h.carry -= whole
                        total += whole
                        self.held[k] = h
                    }
                    if total != 0 { self.onRotate?(total) }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            held[code] = nil
            if held.isEmpty { timer?.invalidate(); timer = nil }
        }
    }

    func releaseAll() { held.removeAll(); timer?.invalidate(); timer = nil }
}

/// Number keys typed anywhere go into the angle box. Set by the app delegate; returns true when it used the key.
final class NumericEntry {
    static let shared = NumericEntry()
    var handle: ((_ code: Int64, _ down: Bool) -> Bool)?
    /// Characters for the number row and keypad (digits, decimal point, minus).
    static let chars: [Int64: String] = [
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
        47: ".", 65: ".", 27: "-", 78: "-"]
    static let editKeys: Set<Int64> = [36, 76, 51, 53]   // Return, keypad Enter, Delete, Escape
    private var consumed = Set<Int64>()
    func route(code: Int64, down: Bool, plainFlags: Bool) -> Bool {
        guard NumericEntry.chars[code] != nil || NumericEntry.editKeys.contains(code) else { return false }
        if !down { return consumed.remove(code) != nil }
        guard plainFlags, handle?(code, true) == true else { return false }
        consumed.insert(code); return true
    }
}

/// Lets the arrow keys rotate even while Pixelmator Pro is the active app, where they would otherwise
/// nudge the selected object. Needs Accessibility permission (System Settings > Privacy & Security).
final class ArrowTap {
    static let shared = ArrowTap()
    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "arrowsRotateInPixelmator") } }
    private var tap: CFMachPort?
    private(set) var active = false

    init() {
        let d = UserDefaults.standard
        d.register(defaults: ["arrowsRotateInPixelmator": true])
        enabled = d.bool(forKey: "arrowsRotateInPixelmator")
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    func requestTrust() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// True while the user is typing text in some Pixelmator field, so arrows keep moving the cursor.
    private static func typingInTextField() -> Bool {
        let sys = AXUIElementCreateSystemWide()
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let el = f else { return false }
        // The panel is non-activating, so Pixelmator can still be the front app while the cursor sits in OUR box.
        // That box is not "typing in Pixelmator": arrows must still rotate.
        var pid: pid_t = 0
        if AXUIElementGetPid(el as! AXUIElement, &pid) == .success, pid == getpid() { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &role)
        let r = role as? String ?? ""
        return r == kAXTextFieldRole || r == kAXTextAreaRole || r == kAXComboBoxRole
    }

    func start() {
        guard tap == nil, ArrowTap.trusted else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, _ in
            let me = ArrowTap.shared
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard me.enabled, type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let front0 = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            if KeyRotator.sign(for: code) == nil {
                // Number keys, decimal point, minus, Return, Delete and Escape feed the angle box.
                guard kBundleIDs.contains(front0) || front0 == Bundle.main.bundleIdentifier else { return Unmanaged.passUnretained(event) }
                let plain = !(flags.contains(.maskCommand) || flags.contains(.maskControl)
                              || flags.contains(.maskAlternate) || flags.contains(.maskShift))
                if front0 != Bundle.main.bundleIdentifier, type == .keyDown, ArrowTap.typingInTextField() { return Unmanaged.passUnretained(event) }
                return NumericEntry.shared.route(code: code, down: type == .keyDown, plainFlags: plain) ? nil : Unmanaged.passUnretained(event)
            }
            if flags.contains(.maskCommand) || flags.contains(.maskControl) { return Unmanaged.passUnretained(event) }
            // Only when Pixelmator Pro (or this panel) is the active app.
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            guard kBundleIDs.contains(front) || front == Bundle.main.bundleIdentifier else { return Unmanaged.passUnretained(event) }
            if front != Bundle.main.bundleIdentifier, type == .keyDown, ArrowTap.typingInTextField() {
                return Unmanaged.passUnretained(event)
            }
            KeyRotator.shared.key(code, down: type == .keyDown,
                                  isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                  shift: flags.contains(.maskShift), option: flags.contains(.maskAlternate))
            return nil   // swallowed: the object no longer nudges
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: cb, userInfo: nil) else { return }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        active = true
    }
}

final class RotatePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ e: NSEvent) {
        // Whenever the event tap is not consuming keys (no Accessibility permission, or the box is unchecked),
        // the arrows still work while this panel is the key window, so a click in the panel never leaves them dead.
        let tapConsuming = ArrowTap.shared.active && ArrowTap.shared.enabled
        if e.type == .keyDown || e.type == .keyUp, KeyRotator.sign(for: Int64(e.keyCode)) != nil {
            if !ArrowTap.shared.enabled {
                // Unchecked = "move": the arrows belong to Pixelmator Pro even though this panel has the focus,
                // so hand them over instead of beeping or rotating.
                if let pid = pixelmatorApp()?.processIdentifier { e.cgEvent?.copy()?.postToPid(pid) }
                return
            }
            if !tapConsuming {   // checked but no Accessibility permission: rotate from the panel
                KeyRotator.shared.key(Int64(e.keyCode), down: e.type == .keyDown, isRepeat: e.isARepeat,
                                      shift: e.modifierFlags.contains(.shift), option: e.modifierFlags.contains(.option))
                return
            }
        }
        if !tapConsuming, e.type == .keyDown || e.type == .keyUp, firstResponder?.isKind(of: NSText.self) != true {
            let plain = e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if NumericEntry.shared.route(code: Int64(e.keyCode), down: e.type == .keyDown, plainFlags: plain) { return }
        }
        super.sendEvent(e)
    }
    var onResign: (() -> Void)?
    override func resignKey() {
        KeyRotator.shared.releaseAll()
        // Clicking away (e.g. into Pixelmator Pro) ends any half-typed entry, so the box does not keep the keyboard.
        makeFirstResponder(nil)
        super.resignKey()
        onResign?()
    }
}

let launchTime = Date()

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var panel: RotatePanel!
    let field = NSTextField()
    let status = NSTextField(labelWithString: "Select a layer in Pixelmator Pro")
    lazy var toggle: NSButton = {
        let b = NSButton(checkboxWithTitle: "Arrow keys: check to rotate, uncheck to move", target: self, action: #selector(toggled(_:)))
        b.font = .systemFont(ofSize: 11); return b }()
    let queue = DispatchQueue(label: "rotate")
    var pending = 0.0
    var draining = false
    var dirty = false   // the user has typed in the angle box and not yet pressed Return

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit PixProRotate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let helpItem = NSMenuItem(); main.addItem(helpItem)
        let help = NSMenu(title: "Help")
        let r = NSMenuItem(title: "PixProRotate Read Me", action: #selector(openReadMe), keyEquivalent: "?")
        r.target = self
        help.addItem(r)
        helpItem.submenu = help
        NSApp.mainMenu = main
        NSApp.helpMenu = help
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        log("launched \(appVersion)")
        let p = RotatePanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 190),
                            styleMask: [.titled, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "PixProRotate"
        p.level = .floating
        // Follow Pixelmator into other Spaces and over its full-screen mode instead of being left behind.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        NumericEntry.shared.handle = { [weak self] code, _ in self?.numericKey(code) ?? false }
        KeyRotator.shared.onRotate = { [weak self] d in self?.dirty = false; self?.panel.makeFirstResponder(nil); self?.rotate(d) }
        panel = p
        p.onResign = { [weak self] in self?.dirty = false; self?.refreshAngle(force: true) }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: nil) { _ in log("panel willClose") }

        let label = NSTextField(labelWithString: "Angle (degrees) — type a value, press Return")
        field.placeholderString = "0"
        field.stringValue = "0"   // starts at 0 until a layer is selected
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 24, weight: .medium)
        field.delegate = self
        field.target = self
        field.action = #selector(fieldEntered)
        let hint = NSTextField(labelWithString: "→ ↑  +1°      ← ↓  −1°      hold to keep turning\n⇧ faster      ⌥ fine")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor; hint.alignment = .center
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.alignment = .center
        // A long message (an Apple event error, say) must never widen the window: it truncates instead.
        status.lineBreakMode = .byTruncatingTail; status.maximumNumberOfLines = 1
        status.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        hint.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        label.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        let presets = NSStackView(views: [0, 90, 180, 270].map { a -> NSButton in
            let b = NSButton(title: "\(a)°", target: self, action: #selector(presetPressed(_:)))
            b.tag = a; b.bezelStyle = .rounded; b.widthAnchor.constraint(equalToConstant: 64).isActive = true; return b })
        presets.orientation = .horizontal; presets.spacing = 10
        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded; quit.keyEquivalent = ""
        let readme = NSButton(title: "Read Me", target: self, action: #selector(openReadMe))
        readme.bezelStyle = .rounded
        let bottom = NSStackView(views: [readme, quit]); bottom.orientation = .horizontal; bottom.spacing = 16
        toggle.state = ArrowTap.shared.enabled ? .on : .off
        for (b, t, a) in [(detectBtn, "Detect", #selector(detectPressed)), (levelBtn, "Level", #selector(levelPressed)),
                          (restoreBtn, "Restore", #selector(restorePressed))] { b.title = t; b.target = self; b.action = a }
        let (detect, level, restore) = (detectBtn, levelBtn, restoreBtn)
        for b in [detect, level, restore] { b.bezelStyle = .rounded }
        detect.toolTip = "Measure the visible angle of the selected item (its rotation setting may say 0 for a drawn diagonal)"
        level.toolTip = "Turn the item to the nearest horizontal or vertical, remembering how far it turned"
        restore.toolTip = "Turn the item back to where it was before Level"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.toolTip = "Put the selected item back to the angle it had when you selected it"
        for b in [detect, level, restore, cancel] { b.widthAnchor.constraint(equalToConstant: 72).isActive = true }
        let tools = NSStackView(views: [detect, level, restore, cancel]); tools.orientation = .horizontal; tools.spacing = 10
        let stack = NSStackView(views: [label, field, presets, tools, hint, toggle, status, bottom])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 14
        stack.setCustomSpacing(20, after: presets)
        stack.setCustomSpacing(6, after: hint)
        stack.setCustomSpacing(20, after: status)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        p.contentView = content
        content.layoutSubtreeIfNeeded()
        p.setContentSize(stack.fittingSize)
        p.contentMinSize = stack.fittingSize          // as small as the layout needs, or any larger size
        p.setFrameAutosaveName("PixProRotatePanel")   // remembers the size you choose
        // Tiny app icon beside the title, centered in the title bar (only once AppIcon.icns is in the bundle).
        if let icon = Bundle.main.image(forResource: "AppIcon"), let bar = p.contentView?.superview {
            p.titleVisibility = .hidden
            let iv = NSImageView(image: icon)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.widthAnchor.constraint(equalToConstant: 16).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let t = NSTextField(labelWithString: "PixProRotate")
            t.font = .titleBarFont(ofSize: 0); t.textColor = .secondaryLabelColor
            let row = NSStackView(views: [iv, t]); row.orientation = .horizontal; row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(row)
            NSLayoutConstraint.activate([row.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
                                         row.centerYAnchor.constraint(equalTo: bar.topAnchor, constant: 14)])
        }
        placeOverPixelmator(p)
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshAngle() }
        refreshAngle(force: true)
        colorNext()
        if ArrowTap.shared.enabled { startArrowTap() }
        p.makeFirstResponder(nil)   // arrows work immediately; click the field to type
    }

    /// Handles a number-row/keypad key typed while PixProRotate is open; true when it consumed the key.
    func numericKey(_ code: Int64) -> Bool {
        if panel.isKeyWindow, panel.firstResponder is NSText { return false }   // the box itself is being edited: normal typing
        if let c = NumericEntry.chars[code] {
            if !dirty { field.stringValue = ""; dirty = true }
            if c == "." && field.stringValue.contains(".") { return true }
            if c == "-" && !field.stringValue.isEmpty { return true }
            if field.stringValue.count < 8 { field.stringValue += c }
            return true
        }
        guard dirty else { return false }   // Return/Delete/Escape keep their normal job unless a number is being typed
        switch code {
        case 36, 76: fieldEntered()
        case 51: field.stringValue = String(field.stringValue.dropLast()); if field.stringValue.isEmpty { dirty = false; refreshAngle(force: true) }
        case 53: dirty = false; refreshAngle(force: true)
        default: return false
        }
        return true
    }

    func controlTextDidChange(_ n: Notification) { dirty = true }
    func controlTextDidEndEditing(_ n: Notification) { dirty = false }

    @objc func fieldEntered() {
        dirty = false
        let t = field.stringValue.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "°", with: "").trimmingCharacters(in: .whitespaces)
        guard let d = Double(t) else { NSSound.beep(); refreshAngle(force: true); return }
        panel.makeFirstResponder(nil)
        setAngle(d)
    }

    /// Opens on the screen holding Pixelmator Pro's window, at that window's top-right corner.
    func placeOverPixelmator(_ p: NSPanel) {
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var best: CGRect?
        for w in info {
            guard let owner = w[kCGWindowOwnerName as String] as? String, owner.contains("Pixelmator"),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width * r.height > (best.map { $0.width * $0.height } ?? 0) { best = r }
        }
        guard let r = best, let primary = NSScreen.screens.first else { p.center(); return }
        // CG coordinates are top-left origin on the primary screen; AppKit's are bottom-left.
        let top = primary.frame.height - r.minY
        var origin = NSPoint(x: r.maxX - p.frame.width - 24, y: top - 70 - p.frame.height)
        if let scr = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: r.midX, y: top - r.height / 2)) }) {
            origin.x = max(scr.frame.minX + 8, min(origin.x, scr.frame.maxX - p.frame.width - 8))
            origin.y = max(scr.frame.minY + 8, min(origin.y, scr.frame.maxY - p.frame.height - 30))
        }
        p.setFrameOrigin(origin)
    }

    /// Shows the current angle in the text window (unless the user is typing in it) or the error below it.
    func show(_ r: (angle: Double?, error: String?), force: Bool = false) {
        if let e = r.error { status.stringValue = e; status.toolTip = e; if !dirty { field.stringValue = "0" }; return }
        if let a = r.angle, force || !dirty { field.stringValue = angleText(a) }
        if Date() < noteUntil { return }
        status.toolTip = nil
        status.stringValue = (ArrowTap.shared.enabled && !ArrowTap.shared.active)
            ? "Arrows over Pixelmator need Accessibility access (see Read Me)" : "Compass angle: 0 at top, clockwise (0–360)"
        if let a = r.angle, force || !dirty { field.stringValue = angleText(a) }
    }

    /// Re-reads the angle from Pixelmator so the window follows selection changes made there.
    func refreshAngle(force: Bool = false) {
        queue.async {
            if self.draining || self.pending != 0 { return }
            noteBaseline()
            let r = readAngle()
            DispatchQueue.main.async { self.show(r, force: force) }
        }
    }

    @objc func toggled(_ b: NSButton) {
        ArrowTap.shared.enabled = (b.state == .on)
        if b.state == .on { startArrowTap() }
        else { panel.makeFirstResponder(nil); pixelmatorApp()?.activate(options: []) }   // "move": keys go to Pixelmator Pro now
    }

    /// Starts the keyboard tap, asking for Accessibility access the first time.
    func startArrowTap() {
        if !ArrowTap.trusted { ArrowTap.shared.requestTrust() }
        ArrowTap.shared.start()
        if !ArrowTap.shared.active {
            status.stringValue = "Allow PixProRotate in Privacy & Security > Accessibility, then reopen"
        }
    }

    @objc func openReadMe() {
        if let u = Bundle.main.url(forResource: "PixProRotate-README", withExtension: "txt") { NSWorkspace.shared.open(u) }
    }

    /// Amount Level turned the item (clockwise degrees), kept so Restore can undo exactly that much.
    var levelled: Double? { didSet { colorNext() } }
    let detectBtn = NSButton(), levelBtn = NSButton(), restoreBtn = NSButton()
    var detected = false { didSet { colorNext() } }

    /// Colors the button to press next once Detect has been pressed: Level, then Restore, then plain again.
    func colorNext() {
        let next: NSButton? = levelled != nil ? restoreBtn : detected ? levelBtn : nil   // nothing is colored until Detect is pressed
        for b in [detectBtn, levelBtn, restoreBtn] {
            b.bezelColor = (b === next) ? .controlAccentColor : nil
            b.contentTintColor = (b === next) ? .white : nil
        }
    }

    /// Detect and Level measure one item. With several layers selected the measurement is meaningless, so say so.
    func reportError(_ e: String?) {
        if e == "MULTIPLE" || (e ?? "").contains("MULTIPLE") {
            note("Select a single layer to measure")
            let a = NSAlert()
            a.messageText = "More than one layer is selected"
            a.informativeText = "Detect and Level measure the angle of one item, so they cannot work on several layers at once. Select a single layer, or group the items first, and try again."
            a.addButton(withTitle: "OK")
            a.beginSheetModal(for: panel, completionHandler: nil)
        } else { note(e ?? "Could not measure") }
    }

    var noteUntil = Date.distantPast
    /// A message from Detect/Level/Restore stays up for a few seconds before the usual status returns.
    func note(_ s: String) { status.stringValue = s; status.toolTip = s; noteUntil = Date().addingTimeInterval(8) }

    @objc func detectPressed() {
        dirty = false; panel.makeFirstResponder(nil)
        note("Measuring…")
        queue.async {
            let (m, e) = measureSelection()
            DispatchQueue.main.async {
                guard let m = m else { self.reportError(e); return }
                if m.elongation < 1.25 { self.note("No clear direction (shape is nearly square or round)"); return }
                self.detected = true
                self.note("Seen at \(angleText((m.axis * 10).rounded() / 10))° (\(angleText((abs(m.tilt) * 10).rounded() / 10))° off straight). Level straightens it.")
            }
        }
    }

    @objc func levelPressed() {
        dirty = false; panel.makeFirstResponder(nil)
        queue.async {
            self.pending = 0
            let (m, e) = measureSelection()
            guard let m = m, m.elongation >= 1.25 else {
                DispatchQueue.main.async { if m == nil { self.reportError(e) } else { self.note("No clear direction to level") } }
                return
            }
            let r = rotateSelection(by: -m.tilt)
            DispatchQueue.main.async {
                if r.error == nil { self.levelled = (self.levelled ?? 0) + m.tilt; self.detected = false }
                self.show(r)
                if r.error == nil { self.note("Levelled by \(angleText((-m.tilt * 10).rounded() / 10))°. Edit, then press Restore.") }
            }
        }
    }

    @objc func cancelPressed() {
        dirty = false; panel.makeFirstResponder(nil)
        queue.async {
            self.pending = 0
            let r = cancelToBaseline()
            DispatchQueue.main.async {
                if r.error == nil { self.levelled = nil; self.detected = false }
                self.show(r)
                self.note(r.error ?? "Cancelled: back to the angle it had when selected")
            }
        }
    }

    @objc func restorePressed() {
        dirty = false; panel.makeFirstResponder(nil)
        guard let t = levelled else { note("Nothing to restore (Level first)"); return }
        queue.async {
            self.pending = 0
            let r = rotateSelection(by: t)
            DispatchQueue.main.async {
                if r.error == nil { self.levelled = nil }
                self.show(r)
                if r.error == nil { self.note("Restored to its original angle") }
            }
        }
    }

    @objc func presetPressed(_ b: NSButton) { dirty = false; panel.makeFirstResponder(nil); setAngle(Double(b.tag)) }

    /// Sets every selected layer to an absolute angle (0, 90, 180, 270 presets).
    func setAngle(_ a: Double) {
        queue.async {
            self.pending = 0
            let r = rotateSelection(by: a, absolute: true)
            DispatchQueue.main.async {
                self.show(r)
            }
        }
    }

    /// Coalesces key-repeat bursts so Pixelmator is asked once per batch.
    func rotate(_ delta: Double) {
        queue.async {
            self.pending += delta
            if self.draining { return }
            self.draining = true
            while self.pending != 0 {
                let d = self.pending; self.pending = 0
                let r = rotateSelection(by: d)
                DispatchQueue.main.async {
                    self.show(r)
                }
            }
            self.draining = false
        }
    }

    func applicationWillTerminate(_ n: Notification) { log("terminating") }
    func applicationShouldTerminate(_ a: NSApplication) -> NSApplication.TerminateReply {
        log("shouldTerminate: " + Thread.callStackSymbols.prefix(8).joined(separator: " | ")
            + " event=\(String(describing: NSApp.currentEvent)) windows=\(NSApp.windows.map { $0.isVisible })")
        // macOS delivers a spurious system quit request within a second of launch,
        // which made the window appear and vanish. Real quits come from Cmd-Q / the Dock / the red button.
        if Date().timeIntervalSince(launchTime) < 3 { log("ignored early system quit"); return .terminateCancel }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
