# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo Purpose

"Daymacs" — a personal, bare-metal Emacs configuration. Minimal, fast, pragmatic.
Built on `straight.el` + `use-package`, with all state redirected to XDG dirs.
Lives at `$XDG_CONFIG_HOME/emacs/` (`~/.dotfiles/config/emacs`); the parent dotfiles repo
(`~/.dotfiles`) sets the XDG environment that this config depends on.

## Boot Flow

1. **`early-init.el`** — kills toolbar/menubar/scrollbars, seeds Doom One palette
   so the first frame doesn't flash, disables `package.el`, pumps GC threshold
   to `most-positive-fixnum` for startup, defines every XDG path constant
   (`dm-{cache,config,data,state}-home`, plus the `dm-dir-*` / `dm-file-*`
   set used to redirect state files), redirects the eln-cache, and adds
   `modules/` to `load-path`.
2. **`init.el`** — `require`s `dm-paths` (wires the path constants into Emacs
   vars like `backup-directory-alist`, `straight-base-dir`, etc.), then `dm-log`
   (initialized once), then `dm-straight` (bootstraps straight.el into
   `dm-data-home/straight/` and sets `straight-use-package-by-default`), then
   `dm-autoload` (regenerates `modules/loaddefs.el` if any source is newer than
   the cache), and finally `require`s the eager feature modules in dependency
   order. `dm-tty` is `require`d only when `(dm-core-daemon-is-tty-p)` returns
   non-nil. The final `(message (emacs-init-time "%.2fs"))` reports startup
   time.
3. **`init.compiled.el`** — flymake/byte-compile preamble only (load path priming
   for compile-time checks). Not loaded at runtime.

GC threshold is reset to 16 MB in `emacs-startup-hook` (see `dm-core.el`).

## Module Layout (`modules/dm-*.el`)

Module names tell you the domain. Eager-loaded modules are `require`d explicitly
from `init.el`; everything else loads through `loaddefs.el` autoload cookies or
`use-package` deferral.

| Module               | Role                                                              |
| -------------------- | ----------------------------------------------------------------- |
| `dm-paths`           | Wires the `dm-dir-*`/`dm-file-*` constants (from `early-init.el`) into Emacs state-file vars |
| `dm-straight`        | Bootstraps `straight.el`; sets `straight-use-package-by-default`  |
| `dm-autoload`        | Regenerates `loaddefs.el` from `dm-*.el` source when stale, then loads it |
| `dm-log`             | `(dm-log :level "fmt" args...)`; level from `DM_LOG_LEVEL` env    |
| `dm-session`         | `desktop.el` save/restore (one-shot — file deleted after read)    |
| `dm-core`            | Backups, auto-save, UTF-8, GC reset, popup policy, `dm-core-daemon-is-tty-p` |
| `dm-ui`              | `doom-themes`, `doom-modeline`, line numbers, fonts, frame title  |
| `dm-meow`            | Meow qwerty-layout modal editing + `meow-mode-state-list` per mode |
| `dm-window`          | `dm-delete-window-dwim`, resize hydra                             |
| `dm-completion`      | Vertico + Orderless + Consult + Marginalia + Embark + wgrep       |
| `dm-editing`         | Tabspaces, dired, apheleia formatters, corfu/cape, tempel, emmet  |
| `dm-env`             | `exec-path-from-shell` — copies env vars from login shell         |
| `dm-vcs`             | Magit (slimmed sections), diff-hl, treesit-auto perf advice       |
| `dm-magit`           | Commit message generator + display-buffer routing                 |
| `dm-ai`              | `claude-code-ide`, `codex-ide` (local), `copilot`; agent dispatch |
| `dm-terminal`        | `eat` setup                                                       |
| `dm-org`             | Org-mode config                                                   |
| `dm-langs`           | `eglot` per-language hooks, `treesit-auto`, `treesit-fold`        |
| `dm-keys`            | Global SPC leader (`meow-leader-define-key`) + which-key rules    |
| `dm-tty`             | TTY-only bindings; loaded only when daemon name contains `tty`    |
| `dm-repl`            | drepl, code-cells, inf-elixir, exunit — language REPL feedback    |
| `dm-files`           | `dm-file-open`, path copy/yank, in-home find                      |
| `dm-popup-quit`      | `dm-quit-or-close-popup` bound to global `C-g`                    |
| `dm-test-toggle`     | Toggle between source and test file                               |
| `dm-text`            | Text formatting (bold/italic/etc) for markdown/org/LaTeX          |
| `dm-lisp`            | Lisp editing helpers                                              |

`codex-ide.el` lives at the config root (not in `modules/`) because it's a
self-contained mini-package; it's loaded directly by `dm-ai.el`.

## Important Conventions

**`dm-` prefix** — every internal symbol uses it. Don't introduce a new prefix.

**`#'dm-quietly` wrapper** — defined in `dm-log.el`; use it (or `:around`-advice
with it) for any function that emits stray messages during startup or async
timers (`recentf-cleanup`, `desktop-read`, etc.).

**Autoloads via `loaddefs.el`** — add `;;;###autoload` cookies to commands.
`init.el` rebuilds `modules/loaddefs.el` when any source file is newer than the
cache. Don't hand-edit `loaddefs.el`; just add the cookie and restart.

**Module load order matters** — `dm-paths` → `dm-log` → `dm-straight` →
`dm-autoload` must come first; the path constants from `early-init.el` need
to be wired before straight bootstraps (it reads `straight-base-dir`), and
autoloads need straight to resolve `;;;###autoload` package references.
Respect the order in `init.el`.

**`use-package` defaults to `:straight t`** (set via
`straight-use-package-by-default` in `dm-straight.el`). Use `:straight nil`
(or `:ensure nil`) for built-ins or for `:type built-in` declarations.

**XDG path constants** — never hardcode a state/cache/data path. Every
directory and state file used at runtime has a named constant defined in
`early-init.el`:
- Roots: `dm-cache-home`, `dm-config-home`, `dm-data-home`, `dm-state-home`
- Directories: `dm-dir-auto-save`, `dm-dir-backups`, `dm-dir-desktop`,
  `dm-dir-eln-cache`, `dm-dir-elpa`, `dm-dir-eshell`, `dm-dir-url-cache`,
  `dm-dir-tree-sitter-libs`, `dm-dir-tree-sitter-repos`
- Files: `dm-file-abbrev-defs`, `dm-file-auto-save-prefix`, `dm-file-bookmarks`,
  `dm-file-customizations`, `dm-file-project-list`, `dm-file-recentf`,
  `dm-file-savehist`, `dm-file-saveplace`, `dm-file-scratch`, `dm-file-tabspaces`,
  `dm-file-tramp`, `dm-file-transient-{history,levels,values}`

Add new constants to `early-init.el` and the corresponding `setq` to
`dm-paths.el` if you need to redirect another package's state file.

**Performance discipline** — defer aggressively:
- `:defer 0.5` for non-critical packages
- `run-with-timer 1.0 nil ...` in `emacs-startup-hook` for predictable cold loads
- `dm-eglot-ensure-deferred` runs `eglot-ensure` via 0.5s idle timer so opening a file
  doesn't block on the LSP `initialize` response
- `treesit-auto--build-major-mode-remap-alist` is memoized in `dm-vcs.el`

**Frame counting** — when filtering `(frame-list)`, exclude frames with
`(minibuffer . only)` (e.g. mini-frame's hidden minibuffer host). See
`dm-delete-window-dwim` for the pattern; this issue has bitten the config before.

## Common Tasks

**Reload a module after editing**: `M-x eval-buffer`, or restart with `SPC q r`
(saves desktop) / `SPC q R` (no restore).

**Force loaddefs regeneration**: `touch modules/dm-foo.el && restart`.

**Byte-compile check**: open a module and run `M-x flymake-mode` — `init.compiled.el`
sets up the load-path so flymake can resolve `straight/build/` packages.

**Trace startup cost**: `M-x emacs-init-time` (already printed once at boot).
For deeper analysis use `benchmark-init` (not bundled — install ad hoc).

## Daemon Modes

Two daemon flavors are supported:
- **GUI daemon** — keybindings installed via `after-make-frame-functions` hook
  (`dm-bind-gui-keys` in `dm-keys.el`). Super-key bindings like `s-g` for magit.
- **TTY daemon** — `init.el` requires `dm-tty` only when
  `(dm-core-daemon-is-tty-p)` returns non-nil (i.e. `(daemonp)` returns a name
  containing `"tty"`). Uses `M-` bindings instead of `s-` and pipes copy/paste
  through `pbcopy`/`pbpaste`.

## Leader Keymap (`SPC`)

Defined in `dm-keys.el` via `meow-leader-define-key`; SPC triggers meow's
keypad state which dispatches through `meow-keypad-leader-keymap`. Top-level
prefixes: `a` agent, `b` buffer, `d` directory, `f` file, `g` git, `h` help,
`j` jump, `l` lsp, `o` org, `p` project, `q` quit, `r` repl, `s` search,
`t` toggle, `T` tab, `TAB` workspace (tabspaces), `w` window. Command
implementations live in their domain module — `dm-keys.el` is intentionally
declarative.

## Don't

- Don't introduce `package.el` calls — straight owns package management.
- Don't add `(setq backup-directory-alist ...)` or other state-file paths
  outside `dm-paths.el` (and the constants it consumes from `early-init.el`).
- Don't add eager `(require 'foo)` for a feature module — extend `init.el` only
  for cross-cutting setup. Command-only helpers stay autoloaded.
- Don't hand-edit `loaddefs.el` or `init.compiled.el`.
