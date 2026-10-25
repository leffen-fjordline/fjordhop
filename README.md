# Fjordhop

Hop to the right [Claude Code](https://claude.com/claude-code) session when
you have many of them open in [Ghostty](https://ghostty.org).

- **Menu bar app** lists every Claude session, split into *Waiting for you* and
  *Working*. Click one to jump to its tab.
- **⌃⌥C** opens that menu from any app. Type part of a project name, then ⏎.
- **Notification** when a session finishes. Click it to jump there.
- **Desktop panel** at the top centre of each screen shows the name of the
  desktop (Space) and the Claude sessions on it. Click a session to jump there,
  click the name to rename the desktop.
- **New Claude Session ▸** opens a Ghostty tab in a project folder and starts `claude`.
- **Restore Sessions** after a restart reopens every Claude session you had,
  in the same windows, each resuming its own conversation.
- **`cs`** does the same from the terminal: `cs my-api` jumps straight there,
  `cs` alone opens an fzf picker, `cs -l` lists sessions.

Guides for installing and releasing: <https://leffen-fjordline.github.io/fjordhop/>

## Requirements

- macOS 14 or later
- [Ghostty](https://ghostty.org) 1.3 or later, in `/Applications`
- Xcode Command Line Tools (`xcode-select --install`), to build the app
- `fzf` for the `cs` picker (`brew install fzf`)

## Install

```sh
git clone https://github.com/leffen-fjordline/fjordhop.git
cd fjordhop
./install.sh
```

This builds the app on your machine, installs it to
`~/Applications/Fjordhop.app`, launches it, and links `cs` into `~/.local/bin`.

On first run, macOS asks for three permissions. Allow all three:

1. **Control Ghostty**, so it can read the session list and focus a tab.
   You can change this later in System Settings → Privacy & Security → Automation.
2. **Notifications**, so it can tell you when a session finishes.
3. **Accessibility**, so the desktop panel can see which desktop each Ghostty
   window is on. Without it the panel shows only the desktop's name. Turn the
   panel off with **Show Desktop Panel** in the menu.

It starts at login from then on: the first launch turns on **Open at Login**
(System Settings → General → Login Items). Untick it in the menu to stop that;
the app will not turn it back on.

To update: `git pull && ./install.sh`. To remove: `./install.sh --uninstall`.

### With Homebrew

```sh
brew tap leffen-fjordline/fjordhop https://github.com/leffen-fjordline/fjordhop
brew install fjordhop
cp -R "$(brew --prefix fjordhop)/Fjordhop.app" ~/Applications/
open ~/Applications/Fjordhop.app
```

Homebrew also builds from source and installs `fzf`. It puts `cs` on your
PATH, but it cannot write to `~/Applications`, so you copy the app there
yourself. The app has to run from there, not from Homebrew's folder: Open at
Login remembers the app's path, and Homebrew's path changes with every
upgrade. After `brew upgrade fjordhop`, quit the app and copy it
again. To remove: `brew uninstall fjordhop`, then delete
`~/Applications/Fjordhop.app`.

> We build on your machine instead of shipping a downloaded `.app` on purpose.
> The app is not signed with a Developer ID, so macOS Gatekeeper would block a
> downloaded copy. An app you build yourself is not quarantined.

## How it works

Ghostty 1.3 has an AppleScript dictionary. For every terminal it reports an id,
the working directory and the tab title, and it can focus a terminal or open a
new tab with a given folder and startup input.

Claude Code sets the tab title to `<glyph> <task summary>`. The glyph is `✳`
when Claude is idle and waiting for you, and a spinner such as `◐` while it is
working. A plain shell shows a path or a command name instead. So the title
alone tells Claude tabs apart from shell tabs, even when both are in the same
folder.

The app checks Ghostty every 5 seconds and again each time you open the menu.
It never sends a command to Ghostty when Ghostty is closed, because doing so
would launch it.

### Restoring sessions after a restart

The app saves the open Claude sessions, window by window, to
`~/Library/Application Support/Fjordhop/current.json` each time they change.
You don't have to do anything before you restart. When the sessions go away
(a reboot, quitting Ghostty, or the app starting with none open), that file
becomes `last.json`. The menu then shows **Restore N Sessions**, which opens
the same windows and tabs and runs `claude --resume <id>` in each. Hover over
it to see the folders. Sessions that are already open are skipped, so
clicking it twice does no harm.

Ghostty doesn't say which conversation runs in a tab. The session id comes from
`~/.claude/sessions/<pid>.json`, which Claude Code writes for each running
`claude`, matched to tabs by folder.

| File | What it is |
|---|---|
| `app/main.swift` | The menu bar app |
| `app/desktops.swift` | The desktop panel, and finding which desktop a window is on |
| `app/snapshot.swift` | Saving the open sessions, and Restore Sessions |
| `app/Info.plist` | Menu bar only (no Dock icon) and the permission prompt text |
| `app/build.sh` | Compile, sign locally, install and relaunch |
| `app/AppIcon.icns`, `app/MenuBarIcon*.png` | App and menu bar icons, generated from `resources/` by `app/make-icons.py` |
| `bin/cs` | Terminal switcher (zsh + fzf) |
| `install.sh` | Installs both, or removes them with `--uninstall` |
| `Formula/fjordhop.rb` | Homebrew formula; this repo is its own tap |
| `docs/`, `mkdocs.yml` | Install and release guides ([docs/release.md](docs/release.md) for cutting a version) |

## Known limits

- Ghostty only. Other terminals (iTerm, Warp, tmux) are not detected.
- Detection depends on how Claude Code formats its tab title. If that changes,
  update `isClaudeTitle` in `app/main.swift` and the glyph check in `bin/cs`.
- A rebuild changes the app's local signature, so macOS may ask again for
  permission to control Ghostty and for Accessibility.
- macOS has no public API for desktops (Spaces). The desktop panel uses the
  private one that yabai and Hammerspoon use, which a macOS update could
  break. Desktop names are stored by the desktop's id, so they can be lost if
  macOS renumbers desktops (a display change, or rarely a reboot).
- A session is placed on a desktop by matching its Ghostty window's title. Two
  windows with the same title on different desktops can both show it.
- Restore uses `~/.claude/sessions/`, which is Claude Code's internal state
  and not a documented format. If that changes, tabs fall back to
  `claude --continue` (the latest conversation in the folder). Two tabs in
  the same folder may come back swapped. Splits come back as tabs, and
  windows are not moved back to their desktops.
- If ⌃⌥C is already taken by another app, change `registerHotKey(...)` in
  `app/main.swift` and run `./install.sh`.

## License

MIT. See [LICENSE](LICENSE).

Fjordhop is an independent project, not affiliated with or endorsed by
Anthropic. Claude and Claude Code are trademarks of Anthropic.
