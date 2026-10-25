// Session snapshot — remembers which Claude sessions were open, window by
// window, so they can all be reopened after a restart with `claude --resume`.
//
// The app saves the open sessions to current.json once they have been the
// same for two polls in a row, so a Ghostty that is half way through quitting
// is not saved. When the sessions go away (Ghostty quit, a reboot, or the app
// starting with none open) current.json becomes last.json, and the menu offers
// to restore what is in it that is not open already.
//
// Ghostty does not say which Claude conversation runs in a terminal. Claude
// Code itself writes ~/.claude/sessions/<pid>.json with the session id and
// folder of each running `claude`, so sessions are matched to tabs by folder.
// Two tabs in one folder get that folder's two session ids, maybe swapped.
// That file is not a documented format: without it, a tab falls back to
// `claude --continue`, the most recent conversation in its folder.
// Sessions running outside Ghostty are left out, as far as the counts allow.
//
// Each window also keeps the desktop it was last seen on (see trackDesktops
// in main.swift), and a restore opens it there again.

import Foundation

struct SavedTab: Codable, Equatable {
    let cwd: String
    let sessionID: String?

    var command: String {
        sessionID.map { "claude --resume \($0)" } ?? "claude --continue"
    }
}

struct Snapshot: Codable, Equatable {
    var savedAt: Date
    var windows: [[SavedTab]]
    // One per window, nil where it is not known. Missing in snapshots saved
    // before desktops were.
    var desktops: [DesktopRef?]?

    var tabs: [SavedTab] { windows.flatMap { $0 } }

    // Groups sessions by Ghostty window, keeping Ghostty's order.
    init(_ sessions: [Session], ids: [String: [String]], desktops: [String: DesktopRef] = [:]) {
        var free = ids
        var tabs: [SavedTab?] = sessions.map { s in
            guard let id = free[s.cwd]?.first else { return nil }
            free[s.cwd]!.removeFirst()
            return SavedTab(cwd: s.cwd, sessionID: id)
        }
        // Ghostty's folder for a tab can be stale (a `cd` the shell never
        // reported), so a tab left over takes a session left over, with that
        // session's folder. Failing that it continues in its own folder,
        // unless another tab already covers it: `--continue` there would
        // open the same conversation twice.
        var spare = free.sorted { $0.key < $1.key }.flatMap { cwd, ids in ids.map { SavedTab(cwd: cwd, sessionID: $0) } }
        var used = Set(tabs.compactMap { $0?.cwd })
        for i in tabs.indices where tabs[i] == nil {
            if !spare.isEmpty {
                tabs[i] = spare.removeFirst()
            } else if !used.contains(sessions[i].cwd) {
                tabs[i] = SavedTab(cwd: sessions[i].cwd, sessionID: nil)
                used.insert(sessions[i].cwd)
            }
        }
        var order: [String] = []
        var byWindow: [String: [SavedTab]] = [:]
        for (s, t) in zip(sessions, tabs) {
            guard let t else { continue }
            if byWindow[s.windowID] == nil { order.append(s.windowID) }
            byWindow[s.windowID, default: []].append(t)
        }
        savedAt = Date()
        windows = order.map { byWindow[$0]! }
        self.desktops = order.map { desktops[$0] }
    }

    // Same sessions in the same places, whenever they were saved.
    func sameLayout(_ other: Snapshot?) -> Bool {
        windows == other?.windows && desktops == other?.desktops
    }

    func desktop(ofWindow i: Int) -> DesktopRef? {
        desktops?[safe: i] ?? nil
    }

    // What is not open now. A tab with a session id is open if that session
    // runs; one without is open if any Claude session runs in its folder.
    func missing(running ids: [String: [String]]) -> Snapshot {
        let live = Set(ids.values.flatMap { $0 })
        var s = self
        let kept = windows.indices
            .map { (tabs: windows[$0].filter { t in t.sessionID.map { !live.contains($0) } ?? (ids[t.cwd] == nil) }, desktop: desktop(ofWindow: $0)) }
            .filter { !$0.tabs.isEmpty }
        s.windows = kept.map(\.tabs)
        s.desktops = kept.map(\.desktop)
        return s
    }
}

enum Snapshots {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Fjordhop")
    static let current = dir.appendingPathComponent("current.json")
    static let last = dir.appendingPathComponent("last.json")

    static func save(_ s: Snapshot) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try enc.encode(s).write(to: current, options: .atomic)
        } catch {
            NSLog("Fjordhop: could not save snapshot: \(error)")
        }
    }

    static func load(_ url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Snapshot.self, from: data)
    }

    // current.json becomes last.json. Nothing happens if there is no
    // current.json, so a second call keeps the last.json from the first.
    static func rotate() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: current.path) else { return }
        try? fm.removeItem(at: last)
        do { try fm.moveItem(at: current, to: last) } catch {
            NSLog("Fjordhop: could not keep snapshot: \(error)")
        }
    }

    // Session ids of the running interactive `claude` processes, by folder,
    // read from Claude Code's ~/.claude/sessions/<pid>.json.
    static func runningClaudeSessions() -> [String: [String]] {
        let sessionsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [String: [(started: Double, id: String)]] = [:]
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  d["kind"] as? String == "interactive",
                  let pid = d["pid"] as? Int32, kill(pid, 0) == 0,
                  let id = d["sessionId"] as? String, let cwd = d["cwd"] as? String else { continue }
            out[cwd, default: []].append((d["startedAt"] as? Double ?? 0, id))
        }
        // Oldest first: the order is the best guess at the order of the tabs.
        return out.mapValues { $0.sorted { $0.started < $1.started }.map(\.id) }
    }
}

extension Ghostty {
    // One window per saved window, one tab per session, each window on the
    // desktop it was on. Windows whose desktop is unknown or gone open on
    // the desktop you are on, first. Then it goes back there.
    static func restore(_ s: Snapshot) {
        let start = Spaces.current().first?.spaceID
        var groups: [(desktop: UInt64?, windows: [[SavedTab]])] = []
        for (i, tabs) in s.windows.enumerated() {
            let d = s.desktop(ofWindow: i).flatMap(Spaces.find)
            if let g = groups.firstIndex(where: { $0.desktop == d }) {
                groups[g].windows.append(tabs)
            } else {
                groups.append((d, [tabs]))
            }
        }
        for g in groups.filter({ $0.desktop == nil }) + groups.filter({ $0.desktop != nil }) {
            if let d = g.desktop, !Spaces.switchTo(d) {
                NSLog("Fjordhop: could not switch to desktop \(d); restoring here")
            }
            open(g.windows)
        }
        if let start, groups.contains(where: { $0.desktop != nil }) { _ = Spaces.switchTo(start) }
    }

    // Each tab types its command into the shell, like newSession, so the
    // shell survives an exit. No `activate`: that can jump to a desktop
    // where Ghostty already has a window, and these must open here.
    private static func open(_ windows: [[SavedTab]]) {
        var lines: [String] = []
        for tabs in windows {
            for (i, t) in tabs.enumerated() {
                let cfg = "{initial working directory:\(quote(t.cwd)), initial input:\(quote(t.command)) & linefeed}"
                lines.append(i == 0 ? "set w to new window with configuration \(cfg)" : "new tab in w with configuration \(cfg)")
            }
        }
        guard !lines.isEmpty else { return }
        run("""
        tell application "Ghostty"
          \(lines.joined(separator: "\n  "))
        end tell
        """)
    }
}
