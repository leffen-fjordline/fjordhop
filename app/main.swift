// Fjordhop — menu bar app listing the Ghostty terminals that run
// Claude Code, and focusing one when clicked. Same detection as bin/cs:
// Ghostty's AppleScript exposes each terminal's id, working directory and
// title; Claude titles start with a status glyph (✳ idle, spinner busy).
//
// Also: ⌃⌥C opens the menu from anywhere, a notification fires when a
// session finishes (busy → idle), and "New Claude Session" opens a tab in
// a project folder and starts `claude` there. The open sessions are saved
// as they change, and reopened with "Restore Sessions" after a restart
// (snapshot.swift).

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

let ghosttyBundleID = "com.mitchellh.ghostty"

struct Session {
    let id: String
    let cwd: String
    let title: String
    let windowTitle: String // its Ghostty window's title, i.e. the selected tab's
    let windowID: String

    var busy: Bool { title.first != "✳" }
    var task: String { String(title.drop(while: { $0 != " " }).dropFirst()) }
    var project: String { (cwd as NSString).lastPathComponent }
    // Parent/project, used when two sessions share a project name.
    var longProject: String {
        let parent = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return "\(parent)/\(project)"
    }

    // "✳ Task" or "◐ Task": one non-alphanumeric glyph, then a space.
    // Plain shells show a path ("…/p/x", "~/x") or a command ("m run").
    static func isClaudeTitle(_ t: String) -> Bool {
        guard let g = t.first, t.dropFirst().first == " " else { return false }
        return !g.isLetter && !g.isNumber && !"…/~".contains(g)
    }

    // A title without its status glyph. The spinner changes several times a
    // second, so titles read a moment apart only match without it.
    static func titleKey(_ t: String) -> String {
        isClaudeTitle(t) ? String(t.dropFirst(2)) : t
    }
}

enum Ghostty {
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID).isEmpty
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ghosttyBundleID
    }

    @discardableResult
    static func run(_ src: String) -> String? {
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue
        if let err { NSLog("Fjordhop: AppleScript failed: \(err)") }
        return out
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // Claude sessions, plus the id of the terminal that has focus in
    // Ghostty's front window ("" if none).
    static func sessions() -> (sessions: [Session], focusedID: String) {
        // Never script Ghostty when it is closed: that would launch it.
        guard isRunning else { return ([], "") }
        // Fetch each property for all terminals in one Apple event (a list per
        // window), then join locally. Asking terminal by terminal costs an
        // event per property: ~2 s with 30 terminals, against ~0.1 s.
        let src = """
        set sep to character id 9 -- not `tab`: inside the tell block that is Ghostty's tab class
        tell application "Ghostty"
          set focusedID to ""
          try
            set focusedID to id of focused terminal of selected tab of front window
          end try
          set wns to name of every window
          set wis to id of every window
          set ids to id of every terminal of every window
          set wds to working directory of every terminal of every window
          set tts to name of every terminal of every window
        end tell
        set out to focusedID & linefeed
        repeat with i from 1 to count of ids
          -- A window opened or closed between the queries: skip what no longer lines up.
          try
            repeat with j from 1 to count of item i of ids
              set out to out & (item j of item i of ids) & sep & (item j of item i of wds) & sep & (item i of wns) & sep & (item i of wis) & sep & (item j of item i of tts) & linefeed
            end repeat
          end try
        end repeat
        return out
        """
        guard let out = run(src) else { return ([], "") }
        var lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        let focusedID = lines.isEmpty ? "" : String(lines.removeFirst())
        let sessions: [Session] = lines.compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5, Session.isClaudeTitle(f[4]) else { return nil }
            return Session(id: f[0], cwd: f[1], title: f[4], windowTitle: f[2], windowID: f[3])
        }
        return (sessions, focusedID)
    }

    static func focus(_ id: String) {
        run("""
        tell application "Ghostty"
          activate
          focus (first terminal whose id is \(quote(id)))
        end tell
        """)
    }

    // New tab in the front window (or a new window if there is none) in
    // `dir`, typing `claude` into the shell so the shell survives an exit.
    static func newSession(in dir: String) {
        run("""
        tell application "Ghostty"
          activate
          set cfg to {initial working directory:\(quote(dir)), initial input:"claude" & linefeed}
          if (count of windows) is 0 then
            new window with configuration cfg
          else
            new tab in front window with configuration cfg
          end if
        end tell
        """)
    }
}

// Carbon hot key: works without Accessibility permission. The C callback
// cannot capture context, so it calls through this global.
var hotKeyAction: (() -> Void)?

func registerHotKey(keyCode: Int, modifiers: Int) {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        hotKeyAction?()
        return noErr
    }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x434C_5357), id: 1) // "CLSW"
    let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    if status != noErr { NSLog("Fjordhop: hot key registration failed (\(status)); already taken?") }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let defaults = UserDefaults.standard
    var sessions: [Session] = []
    var timer: Timer?
    let desktopPanels = DesktopPanels()

    // Snapshot state (see snapshot.swift): what the last poll saw, what was
    // last written to disk, and the running Claude session ids by folder.
    var lastSeen: Snapshot?
    var saved: Snapshot?
    var hadSessions = false
    var runningIDs: [String: [String]] = [:]

    // Busy → idle tracking for notifications. A session must have been seen
    // busy, then idle for two polls in a row, so a brief ✳ between tool
    // calls does not fire one.
    var sawBusy: [String: Bool] = [:]
    var idleStreak: [String: Int] = [:]

    var notifyEnabled: Bool {
        get { defaults.object(forKey: "notify") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notify") }
    }

    // Most recently seen project folders, newest first.
    var recentDirs: [String] {
        get { defaults.stringArray(forKey: "recentDirs") ?? [] }
        set { defaults.set(Array(newValue.prefix(15)), forKey: "recentDirs") }
    }

    var desktopPanelEnabled: Bool {
        get { defaults.object(forKey: "desktopPanel") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "desktopPanel") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Template image: macOS tints it for light and dark menu bars.
        let icon = Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        icon?.isTemplate = true
        icon?.accessibilityDescription = "Claude sessions"
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        hotKeyAction = { [weak self] in
            NSApp.activate(ignoringOtherApps: true) // so typing filters the menu
            self?.statusItem.button?.performClick(nil)
        }
        registerHotKey(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey)
        enableLoginItemOnFirstRun()

        desktopPanels.onPick = { Ghostty.focus($0) }
        desktopPanels.onRename = { [weak self] in self?.updateDesktopPanels() }
        // The panel needs Accessibility to see which desktop a window is on.
        if desktopPanelEnabled { askForAccessibility() }
        let ws = NSWorkspace.shared.notificationCenter
        // Redraw at once from the last known sessions (titles match without
        // the glyph, so they are still good), then refresh them.
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDesktopPanels()
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDesktopPanels() }
        }

        // What was open when the app last ran is what a restore brings back.
        Snapshots.rotate()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let (found, focusedID) = Ghostty.sessions()
        sessions = found
        trackTransitions(focusedID: focusedID)
        rememberDirs()
        snapshotSessions()

        // Menu bar shows how many sessions are waiting for you.
        let idle = sessions.filter { !$0.busy }.count
        statusItem.button?.title = idle > 0 ? " \(idle)" : ""
        statusItem.button?.toolTip = "\(idle) waiting, \(sessions.count - idle) working — ⌃⌥C"
        updateDesktopPanels()
    }

    func updateDesktopPanels() {
        guard desktopPanelEnabled else { return desktopPanels.hide() }
        let windows = Ghostty.isRunning ? Spaces.ghosttyWindows() : [:]
        desktopPanels.update(Spaces.current().map { d in
            (d, sessions.filter { windows[d.spaceID]?.contains(Session.titleKey($0.windowTitle)) ?? false })
        })
    }

    func askForAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func trackTransitions(focusedID: String) {
        let live = Set(sessions.map(\.id))
        sawBusy = sawBusy.filter { live.contains($0.key) }
        idleStreak = idleStreak.filter { live.contains($0.key) }

        for s in sessions {
            if s.busy {
                sawBusy[s.id] = true
                idleStreak[s.id] = 0
                continue
            }
            idleStreak[s.id, default: 0] += 1
            guard sawBusy[s.id] == true, idleStreak[s.id] == 2 else { continue }
            sawBusy[s.id] = false
            // Skip if you are already looking at it.
            if Ghostty.isFrontmost && s.id == focusedID { continue }
            if notifyEnabled { notify(s) }
        }
    }

    func notify(_ s: Session) {
        let content = UNMutableNotificationContent()
        content.title = "\(s.project) is waiting"
        content.body = s.task
        content.sound = .default
        content.userInfo = ["id": s.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.id, content: content, trigger: nil))
    }

    func rememberDirs() {
        var dirs = recentDirs
        for s in sessions where !dirs.contains(s.cwd) { dirs.insert(s.cwd, at: 0) }
        if dirs != recentDirs { recentDirs = dirs }
    }

    // Saves the sessions once two polls in a row agree, so a Ghostty that is
    // closing its windows one by one is not saved half way. When they are
    // gone, the saved set becomes the one "Restore Sessions" offers.
    func snapshotSessions() {
        guard !sessions.isEmpty else {
            if hadSessions { Snapshots.rotate() }
            hadSessions = false
            lastSeen = nil
            saved = nil
            runningIDs = [:]
            return
        }
        hadSessions = true
        runningIDs = Snapshots.runningClaudeSessions()
        let s = Snapshot(sessions, ids: runningIDs)
        defer { lastSeen = s }
        guard s.windows == lastSeen?.windows, s.windows != saved?.windows else { return }
        Snapshots.save(s)
        saved = s
    }

    // Open at Login is on by default: register once, on the first launch.
    // After that the menu toggle owns it, so turning it off sticks.
    func enableLoginItemOnFirstRun() {
        guard !defaults.bool(forKey: "loginItemConfigured") else { return }
        do {
            try SMAppService.mainApp.register()
            defaults.set(true, forKey: "loginItemConfigured")
        } catch {
            // Not marked as configured, so the next launch tries again.
            NSLog("Fjordhop: could not enable Open at Login: \(error)")
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        if !Ghostty.isRunning {
            menu.addItem(disabled("Ghostty is not running"))
        } else if sessions.isEmpty {
            menu.addItem(disabled("No Claude sessions"))
        }

        let counts = Dictionary(grouping: sessions, by: \.project).mapValues(\.count)
        let groups: [(String, [Session])] = [
            ("Waiting for you", sessions.filter { !$0.busy }),
            ("Working", sessions.filter { $0.busy }),
        ]
        for (header, group) in groups where !group.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(disabled(header))
            for s in group.sorted(by: { $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending }) {
                let name = counts[s.project, default: 0] > 1 ? s.longProject : s.project
                let item = NSMenuItem(title: "", action: #selector(pick(_:)), keyEquivalent: "")
                item.attributedTitle = label(glyph: s.busy ? "◐" : "✳", project: name, task: s.task)
                item.representedObject = s.id
                item.toolTip = s.cwd
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(newSessionItem())
        if let item = restoreItem() { menu.addItem(item) }

        menu.addItem(.separator())
        menu.addItem(toggle("Show Desktop Panel", on: desktopPanelEnabled, action: #selector(toggleDesktopPanel(_:))))
        let rename = NSMenuItem(title: "Rename This Desktop…", action: #selector(renameDesktop(_:)), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        menu.addItem(toggle("Notify When a Session Finishes", on: notifyEnabled, action: #selector(toggleNotify(_:))))
        menu.addItem(toggle("Open at Login", on: SMAppService.mainApp.status == .enabled, action: #selector(toggleLogin(_:))))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func newSessionItem() -> NSMenuItem {
        let item = NSMenuItem(title: "New Claude Session", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let home = NSHomeDirectory()
        let dirs = recentDirs.filter { FileManager.default.fileExists(atPath: $0) }
        for dir in dirs {
            let shown = dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
            let d = NSMenuItem(title: shown, action: #selector(newSession(_:)), keyEquivalent: "")
            d.representedObject = dir
            d.target = self
            sub.addItem(d)
        }
        if !dirs.isEmpty { sub.addItem(.separator()) }
        let choose = NSMenuItem(title: "Choose Folder…", action: #selector(chooseFolder(_:)), keyEquivalent: "")
        choose.target = self
        sub.addItem(choose)
        item.submenu = sub
        return item
    }

    // Only when the last snapshot has sessions that are not open now.
    func restoreItem() -> NSMenuItem? {
        guard let last = Snapshots.load(Snapshots.last) else { return nil }
        let missing = last.missing(running: runningIDs)
        let n = missing.tabs.count
        guard n > 0 else { return nil }
        let when = DateFormatter.localizedString(from: last.savedAt, dateStyle: .short, timeStyle: .short)
        let item = NSMenuItem(title: "Restore \(n) Session\(n == 1 ? "" : "s")", action: #selector(restore(_:)), keyEquivalent: "")
        item.toolTip = "Saved \(when):\n" + missing.tabs.map(\.cwd).joined(separator: "\n")
        item.representedObject = missing
        item.target = self
        return item
    }

    func label(glyph: String, project: String, task: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: "\(glyph)  \(project)", attributes: [.font: NSFont.menuFont(ofSize: 0)])
        s.append(NSAttributedString(string: "   \(task)", attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return s
    }

    func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func toggle(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    // MARK: Actions

    @objc func pick(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { Ghostty.focus(id) }
    }

    @objc func newSession(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String else { return }
        Ghostty.newSession(in: dir)
    }

    @objc func restore(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Snapshot else { return }
        Ghostty.restore(s)
    }

    @objc func chooseFolder(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Start Claude Here"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("p")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url?.path else { return }
        recentDirs = [dir] + recentDirs.filter { $0 != dir }
        Ghostty.newSession(in: dir)
    }

    @objc func toggleNotify(_ sender: NSMenuItem) {
        notifyEnabled.toggle()
    }

    @objc func toggleDesktopPanel(_ sender: NSMenuItem) {
        desktopPanelEnabled.toggle()
        if desktopPanelEnabled { askForAccessibility() }
        updateDesktopPanels()
    }

    // The desktop on the screen with the mouse pointer.
    @objc func renameDesktop(_ sender: NSMenuItem) {
        let mouse = NSEvent.mouseLocation
        let desktops = Spaces.current()
        guard let d = desktops.first(where: { NSMouseInRect(mouse, $0.screen.frame, false) }) ?? desktops.first else { return }
        desktopPanels.rename(key: d.key, current: desktopPanels.name(of: d))
    }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Notifications

    // Clicking a notification jumps to that session.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["id"] as? String {
            DispatchQueue.main.async { Ghostty.focus(id) }
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
