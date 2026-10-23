# Fjordhop

Hop to the right [Claude Code](https://claude.com/claude-code) session when
you have many of them open in [Ghostty](https://ghostty.org).

- A **menu bar app** lists every Claude session, split into *Waiting for you*
  and *Working*. Click one to jump to its tab, or press **⌃⌥C** from any app.
- A **notification** tells you when a session finishes.
- A **desktop panel** shows the name of each desktop (Space) and the sessions
  on it.
- **`cs`** jumps to a session from the terminal: `cs my-api`, or `cs` alone
  for an fzf picker.

## Guides

| Guide | For |
|---|---|
| [Install](install.md) | Anyone who wants to use Fjordhop: install, update and remove it |
| [Release](release.md) | Maintainers: cut a new version and update the Homebrew formula |

## Building these docs

```sh
uv run --with-requirements docs/requirements.txt mkdocs serve
```

Then open <http://127.0.0.1:8000>. `mkdocs build` writes the site to `site/`.
The build is strict, so a broken link fails it.
