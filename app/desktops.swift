// Desktop panel — a small label at the top centre of each screen with the
// name of the macOS desktop (Space) it shows and the Claude sessions on it.
//
// macOS has no public API for Spaces, so this uses the private CGS calls
// that yabai and Hammerspoon rely on. They have been stable for years, but a
// macOS update could break them. Which session is on which desktop: the
// Accessibility API lists Ghostty's windows on the visible desktops with
// their window numbers and titles, CGS says which desktop each window is on,
// and the title is the selected tab's, which Ghostty's AppleScript also
// reports as the window name.

import AppKit
import ApplicationServices

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray
@_silgen_name("CGSCopySpacesForWindows") private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> CFArray
@_silgen_name("_AXUIElementGetWindow") private func _AXUIElementGetWindow(_ el: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}

struct Desktop {
    let screen: NSScreen
    let spaceID: UInt64
    let key: String // what its custom name is stored under
    let number: Int // 1-based position on its display, for "Desktop N"
    let fullscreen: Bool
}

// Where a window was, saved so it can go back there after a restart. The
// uuid usually survives a reboot; if it does not, the position on the
// display is the next best guess.
struct DesktopRef: Codable, Equatable, Hashable {
    let uuid: String
    let display: String // "Main" when all displays share one set of desktops
    let number: Int // 1-based position on its display
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

enum Spaces {
    static let cid = CGSMainConnectionID()

    // The desktop each screen shows right now.
    static func current() -> [Desktop] {
        guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
        return displays.compactMap { d in
            guard let cur = d["Current Space"] as? [String: Any],
                  let id = (cur["ManagedSpaceID"] as? NSNumber)?.uint64Value,
                  let screen = screen(for: d["Display Identifier"] as? String ?? "") else { return nil }
            // type 0 is a normal desktop, 4 a full-screen app.
            let desktops = (d["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 0 }
            let number = (desktops.firstIndex { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value == id } ?? -1) + 1
            let uuid = cur["uuid"] as? String ?? ""
            return Desktop(screen: screen, spaceID: id, key: uuid.isEmpty ? "id-\(id)" : uuid,
                           number: number, fullscreen: (cur["type"] as? Int) != 0)
        }
    }

    // "Main" when all displays share one set of Spaces.
    static func screen(for identifier: String) -> NSScreen? {
        if identifier == "Main" { return NSScreen.screens.first }
        return NSScreen.screens.first { s in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(s.displayID)?.takeRetainedValue() else { return false }
            return CFUUIDCreateString(nil, uuid) as String == identifier
        }
    }

    // Every normal desktop, by id, as a DesktopRef that can find it again.
    static func all() -> [UInt64: DesktopRef] {
        var out: [UInt64: DesktopRef] = [:]
        for d in displays() {
            for (i, s) in d.desktops.enumerated() {
                out[s.id] = DesktopRef(uuid: s.uuid, display: d.identifier, number: i + 1)
            }
        }
        return out
    }

    // The live id of a saved desktop: the same uuid, else the same position
    // on the same display, else that position on the first display. Nil if
    // there are not that many desktops now.
    static func find(_ ref: DesktopRef) -> UInt64? {
        let ds = displays()
        if !ref.uuid.isEmpty, let s = ds.flatMap(\.desktops).first(where: { $0.uuid == ref.uuid }) { return s.id }
        let d = ds.first { $0.identifier == ref.display } ?? ds.first
        guard let d, d.desktops.indices.contains(ref.number - 1) else { return nil }
        return d.desktops[ref.number - 1].id
    }

    // Shows desktop `id` by pressing the "Move left/right a space" shortcuts
    // (⌃← and ⌃→, on by default) once per step, waiting for each to land.
    // There is no public call for this. Needs Accessibility to post keys.
    static func switchTo(_ id: UInt64) -> Bool {
        guard AXIsProcessTrusted(),
              let d = displays().first(where: { $0.desktops.contains { $0.id == id } }),
              let target = d.desktops.firstIndex(where: { $0.id == id }) else { return false }
        // The shortcuts act on the display with the pointer.
        if NSScreen.screens.count > 1, let screen = screen(for: d.identifier) {
            let f = screen.frame, main = NSScreen.screens[0].frame
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: main.maxY - f.midY))
        }
        for _ in 0..<20 {
            guard let now = displays().first(where: { $0.identifier == d.identifier }),
                  let at = now.desktops.firstIndex(where: { $0.id == now.current }) else { return false }
            if at == target { return true }
            guard press(hotKey: at < target ? 81 : 79) else { return false }
            // Wait for the desktop to change, then for the slide to finish.
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, displays().first(where: { $0.identifier == d.identifier })?.current == now.current {
                usleep(50_000)
            }
            usleep(400_000)
        }
        return false
    }

    // Presses a system shortcut by its id in com.apple.symbolichotkeys,
    // using the keys it is set to. 79 is "Move left a space", 81 right.
    private static func press(hotKey id: Int) -> Bool {
        let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        let entry = all?[String(id)] as? [String: Any]
        if let on = entry?["enabled"] as? Bool, !on { return false }
        let params = (entry?["value"] as? [String: Any])?["parameters"] as? [Int]
        let key = params?[safe: 1] ?? (id == 79 ? 123 : 124) // ← or →
        let mods = params?[safe: 2] ?? 0x840000 // ⌃ + fn, as macOS sets arrow keys
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: down)
            e?.flags = CGEventFlags(rawValue: UInt64(mods))
            e?.post(tap: .cghidEventTap)
        }
        return true
    }

    private struct Display {
        let identifier: String
        let current: UInt64
        let desktops: [(id: UInt64, uuid: String)]
    }

    // Normal desktops only: type 0 is a desktop, 4 a full-screen app.
    private static func displays() -> [Display] {
        guard let ds = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
        return ds.map { d in
            let cur = d["Current Space"] as? [String: Any]
            let desktops = (d["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 0 }.compactMap { s in
                (s["ManagedSpaceID"] as? NSNumber).map { (id: $0.uint64Value, uuid: s["uuid"] as? String ?? "") }
            }
            return Display(identifier: d["Display Identifier"] as? String ?? "",
                           current: (cur?["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0, desktops: desktops)
        }
    }

    // Title keys (see Session.titleKey) of Ghostty's windows on the visible
    // desktops, by desktop id. Empty without Accessibility permission.
    static func ghosttyWindows() -> [UInt64: Set<String>] {
        guard AXIsProcessTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID).first?.processIdentifier
        else { return [:] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [:] }
        var out: [UInt64: Set<String>] = [:]
        for w in windows {
            var title: CFTypeRef?
            var wid: CGWindowID = 0
            guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title) == .success,
                  let title = title as? String, _AXUIElementGetWindow(w, &wid) == .success else { continue }
            for s in CGSCopySpacesForWindows(cid, 0x7, [wid] as CFArray) as? [NSNumber] ?? [] {
                out[s.uint64Value, default: []].insert(Session.titleKey(title))
            }
        }
        return out
    }
}

// One borderless, non-activating panel per screen. It shows on every
// desktop and is redrawn when the desktop changes, so one panel per screen
// is enough.
final class DesktopPanels: NSObject {
    let defaults = UserDefaults.standard
    var onPick: (String) -> Void = { _ in }
    var onRename: () -> Void = {}
    private var panels: [CGDirectDisplayID: NSPanel] = [:]

    var names: [String: String] {
        get { defaults.dictionary(forKey: "desktopNames") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "desktopNames") }
    }

    func name(of d: Desktop) -> String {
        names[d.key] ?? (d.number > 0 ? "Desktop \(d.number)" : "Desktop")
    }

    func hide() {
        panels.values.forEach { $0.orderOut(nil) }
    }

    func update(_ shown: [(Desktop, [Session])]) {
        let live = Set(shown.map { $0.0.screen.displayID })
        for (screen, p) in panels where !live.contains(screen) {
            p.orderOut(nil)
            panels[screen] = nil
        }
        for (d, sessions) in shown {
            let p = panels[d.screen.displayID] ?? makePanel()
            panels[d.screen.displayID] = p
            guard !d.fullscreen else { p.orderOut(nil); continue }
            let view = content(d, sessions)
            p.contentView = view
            let size = view.fittingSize
            let top = d.screen.visibleFrame.maxY - 4
            p.setFrame(NSRect(x: d.screen.frame.midX - size.width / 2, y: top - size.height,
                              width: size.width, height: size.height), display: true)
            p.orderFrontRegardless()
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        return p
    }

    private func content(_ d: Desktop, _ sessions: [Session]) -> NSView {
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        bg.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = button(name(of: d), font: .boldSystemFont(ofSize: 12), action: #selector(rename(_:)))
        title.identifier = NSUserInterfaceItemIdentifier(d.key)
        title.toolTip = "Click to rename this desktop"
        stack.addArrangedSubview(title)

        // Waiting first: those are the ones that need you.
        for s in sessions.sorted(by: { !$0.busy && $1.busy }) {
            let b = button("\(s.busy ? "◐" : "✳") \(s.project)", font: .systemFont(ofSize: 12), action: #selector(pick(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(s.id)
            b.contentTintColor = s.busy ? .secondaryLabelColor : .labelColor
            b.toolTip = s.task
            stack.addArrangedSubview(b)
        }

        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        return bg
    }

    private func button(_ title: String, font: NSFont, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.font = font
        return b
    }

    @objc private func pick(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onPick(id) }
    }

    @objc private func rename(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        rename(key: key, current: sender.title)
    }

    // An empty name goes back to "Desktop N".
    func rename(key: String, current: String) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = names[key] ?? ""
        field.placeholderString = current
        let alert = NSAlert()
        alert.messageText = "Rename Desktop"
        alert.informativeText = "Leave empty to use the default name."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        names[key] = name.isEmpty ? nil : name
        onRename()
    }
}
