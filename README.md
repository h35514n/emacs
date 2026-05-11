Emacs Config
============

A bare-metal Emacs configuration using straight.el for package
management, Evil for modal editing, Vertico/Consult/Embark for
completion, Magit for VCS, Eglot for LSP, and tree-sitter for major
modes. Designed to work on a fresh remote machine with a small
dependency set, while becoming richer when local language servers and
formatters are installed.

Requirements
------------

- Emacs 29 or newer is recommended (tree-sitter and Eglot are expected
  to be built in). Emacs 30+ additionally honors `trusted-content`; on
  older builds that variable is unbound and the relevant `add-to-list`
  is skipped.
- Required CLI tools: `git`, `ripgrep`.
- Recommended local tools:
  - Search/navigation: `fd` (Debian/Ubuntu ships `fdfind`; symlink it to
    `fd`), `universal-ctags`
  - Compilation: a working C toolchain (`build-essential` / `gcc`,
    `make`) for native-compiled packages and tree-sitter grammars
  - Language tools (optional, picked up via `executable-find`):
    - Shell: `shellcheck`, `shfmt`
    - Python: `python3`, `pip`, `ruff`
    - Web/YAML/JSON: `node`, `eslint`, `prettier`, `jq`, `yamllint`
    - Elixir: `expert` or `elixir-ls`
    - LaTeX: `texlab` or `digestif`

Fresh Setup
-----------

This config expects to live at `~/.dotfiles/config/emacs` --- path
constants in `early-init.el` reference
`~/.dotfiles/{cache,config,share,state}/emacs/` directly. The setup
script links the checkout into place and symlinks `~/.config/emacs` to
it so Emacs auto-discovers the config via XDG.

On a remote Linux VM, run the setup script from this directory:

``` sh
bin/setup
```

For optional language linters and formatters, use:

``` sh
bin/setup --with-language-tools
```

The script supports Debian/Ubuntu via `apt-get` and Red
Hat/Amazon/Fedora style hosts via `yum` or `dnf`. It installs required
CLI dependencies, creates the `~/.dotfiles/{cache,share,state}/emacs/`
directories, links this checkout to `~/.dotfiles/config/emacs` and
`~/.config/emacs`, and bootstraps straight.el and all packages by
running Emacs in batch mode.

If the distro-default Emacs is older than 29, the script attempts to
upgrade. On Debian it configures `<codename>-backports` (e.g.
`bookworm-backports`) and reinstalls `emacs-nox` from there. On other
distros it warns and continues with the older Emacs — the bootstrap
will still run, falling back to plain `emacs --batch` via the
`~/.config/emacs` symlink on Emacs 27/28.

Manual setup is:

``` sh
mkdir -p "$HOME/.dotfiles/config" \
  "$HOME/.dotfiles/cache/emacs" \
  "$HOME/.dotfiles/share/emacs" \
  "$HOME/.dotfiles/state/emacs"

ln -s "$PWD" "$HOME/.dotfiles/config/emacs"
mkdir -p "$HOME/.config"
ln -s "$HOME/.dotfiles/config/emacs" "$HOME/.config/emacs"

# Emacs 29+:
emacs --init-directory="$HOME/.dotfiles/config/emacs" --batch \
  --eval '(kill-emacs 0)'

# Emacs 27/28 (relies on the XDG symlink above):
emacs --batch --eval '(kill-emacs 0)'
```

The first batch run clones straight.el into
`~/.dotfiles/share/emacs/straight/` and installs every package declared
by `use-package`. Expect it to take several minutes on a fresh host.

Notes
-----

- The XDG paths are hardcoded as constants in `early-init.el`. If you
  want the config elsewhere, edit those constants rather than fighting
  the symlinks.
- `~/.emacs.d` shadows `~/.config/emacs`. If `~/.emacs.d` exists on the
  target host, move or remove it before launching Emacs.
- Language tools are optional. Eglot servers and Apheleia formatters are
  guarded by `executable-find`, so missing tools should not block
  editing.
- Tree-sitter grammars install on demand via `treesit-auto` into
  `~/.dotfiles/share/emacs/tree-sitter/`. A C toolchain is required to
  compile them; install `--with-language-tools` to get one.
