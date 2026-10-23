# Install

Fjordhop is always built from source on your own Mac. Both ways to install
below do that. The app is not signed with a Developer ID, so macOS Gatekeeper
would block a downloaded `.app`. An app you build yourself is not quarantined.

## Requirements

- macOS 14 (Sonoma) or later
- [Ghostty](https://ghostty.org) 1.3 or later, in `/Applications`
- Xcode Command Line Tools, to compile the app: `xcode-select --install`
- `fzf` for the `cs` picker. Homebrew installs it for you; with the script,
  run `brew install fzf`.

## Choose a way to install

=== "Homebrew"

    ```sh
    brew tap leffen-fjordline/fjordhop https://github.com/leffen-fjordline/fjordhop
    brew install fjordhop
    cp -R "$(brew --prefix fjordhop)/Fjordhop.app" ~/Applications/
    open ~/Applications/Fjordhop.app
    ```

    This repo is its own tap, so `brew tap` needs the full URL.
    `brew install` builds the latest release, installs `fzf`, and puts `cs` on
    your PATH.

    You have to copy the app yourself, because Homebrew cannot write to
    `~/Applications`. Run the app from the copy, not from Homebrew's folder:
    Open at Login remembers where the app is, and Homebrew's folder changes
    with every upgrade.

    To build the latest `main` instead of the last release, run
    `brew install --HEAD fjordhop`.

=== "Install script"

    ```sh
    git clone https://github.com/leffen-fjordline/fjordhop.git
    cd fjordhop
    ./install.sh
    ```

    The script checks the requirements, builds the app, installs it to
    `~/Applications/Fjordhop.app`, starts it, and links `cs` into
    `~/.local/bin`. If `~/.local/bin` is not on your PATH, the script says so.

## Permissions on first run

macOS asks for three permissions. Allow all three:

1. **Control Ghostty**, so it can read the session list and focus a tab.
   You can change this later in System Settings → Privacy & Security →
   Automation.
2. **Notifications**, so it can tell you when a session finishes.
3. **Accessibility**, so the desktop panel can see which desktop each Ghostty
   window is on. Without it the panel shows only the desktop's name.

The first launch also turns on **Open at Login** (System Settings → General →
Login Items). Untick it in the menu to stop that; the app will not turn it
back on.

!!! note "macOS asks again after an update"
    Each build gets a new local signature, and macOS ties the permissions to
    that signature. After an update, allow Ghostty control and Accessibility
    again when asked.

## Update

=== "Homebrew"

    ```sh
    brew update
    brew upgrade fjordhop
    pkill -x Fjordhop; rm -rf ~/Applications/Fjordhop.app
    cp -R "$(brew --prefix fjordhop)/Fjordhop.app" ~/Applications/
    open ~/Applications/Fjordhop.app
    ```

    If you installed with `--HEAD`, use `brew upgrade --fetch-HEAD fjordhop`.

=== "Install script"

    ```sh
    cd fjordhop
    git pull && ./install.sh
    ```

## Remove

=== "Homebrew"

    ```sh
    pkill -x Fjordhop
    brew uninstall fjordhop
    rm -rf ~/Applications/Fjordhop.app
    brew untap leffen-fjordline/fjordhop
    ```

=== "Install script"

    ```sh
    ./install.sh --uninstall
    ```

Either way, your settings (desktop names, menu choices) stay behind. Delete
them with `defaults delete local.fjordhop`.

## Troubleshooting

`Ghostty not found in /Applications`
:   The install script looks only there. Move Ghostty to `/Applications`, and
    check that it is version 1.3 or later (the first with AppleScript).

`swiftc not found`
:   Install the Command Line Tools: `xcode-select --install`.

The menu shows no sessions
:   Check System Settings → Privacy & Security → Automation and make sure
    Fjordhop may control Ghostty.

`cs` runs an old copy
:   If you used both ways to install, you have two copies of `cs`. The one in
    `~/.local/bin` usually comes first on PATH. Run `which -a cs` to see both,
    and remove the one you don't use.

⌃⌥C does nothing
:   Another app has the shortcut. Change `registerHotKey(...)` in
    `app/main.swift` and reinstall.
