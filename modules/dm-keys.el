;;; dm-keys.el --- Daymacs global keymaps  -*- lexical-binding: t; -*-

;;; Commentary:

;; Global and leader keybindings. This module intentionally stays declarative:
;; command implementations live in their domain modules, while this file owns
;; discoverability and the top-level command vocabulary.

;;; Code:

(defun dm-new-buffer ()
  "Create and switch to a fresh, unnamed buffer in fundamental mode."
  (interactive)
  (switch-to-buffer (generate-new-buffer "*new*")))

(defun dm-split-window-right ()
  "Split the current window vertically and focus the new pane."
  (interactive)
  (split-window-right)
  (other-window 1))

(defun dm-split-window-below ()
  "Split the current window horizontally and focus the new pane."
  (interactive)
  (split-window-below)
  (other-window 1))

(with-eval-after-load 'meow
  (meow-leader-define-key
   ;; Top-level
   '("SPC" . consult-buffer)
   '("*"   . dm-search-for-this-dwim)

   ;; Agent (claude-code-ide / codex-ide, toggled at runtime via SPC a A)
   '("a a" . dm-agent-open)
   '("a A" . dm-toggle-agent)
   '("a t" . dm-agent-toggle)
   '("a c" . claude-code-ide-continue)
   '("a r" . claude-code-ide-resume)
   '("a l" . claude-code-ide-list-sessions)
   '("a m" . claude-code-ide-menu)

   ;; Buffers
   '("b b" . consult-buffer)
   '("b d" . bury-buffer)
   '("b D" . kill-current-buffer)
   '("b f" . apheleia-format-buffer)
   '("b i" . ibuffer)
   '("b n" . dm-new-buffer)
   '("b u" . dm-unfill-region)

   ;; Directory
   '("d o" . dm-directory-open)
   '("d p" . dm-directory-open-project)

   ;; Files
   '("f d"   . dm-delete-this-file)
   '("f f"   . consult-fd)
   '("f h"   . dm-find-in-home)
   '("f p"   . dm-open-config-new-tab)
   '("f r"   . consult-recent-file)
   '("f o"   . dm-file-open)
   '("f t"   . dm-toggle-test-implementation)
   '("f y RET" . dm-copy-file-path-dwim)
   '("f y p" . dm-copy-file-project-path)
   '("f y a" . dm-copy-file-abspath)
   '("f y h" . dm-copy-file-path)

   ;; Help
   '("h K" . helpful-at-point)

   ;; Search
   '("s e" . iedit-mode)
   '("s i" . consult-imenu-multi)
   '("s p" . consult-ripgrep)
   '("s s" . consult-line)

   ;; Jump (avy)
   '("j j" . avy-goto-char-2)

   ;; Git
   '("g g" . magit-status)
   '("g b" . magit-blame)
   '("g t" . git-timemachine)
   '("g n" . diff-hl-show-hunk-next)
   '("g p" . diff-hl-show-hunk-previous)

   ;; Org
   '("o a" . org-agenda)
   '("o c" . org-capture)

   ;; Toggle
   '("t c" . copilot-mode)
   '("t w" . dm-wrapping-toggle)

   ;; Tabs
   '("T RET" . tab-new)
   '("T W"   . tab-close)
   '("T n"   . tab-bar-switch-to-next-tab)
   '("T p"   . tab-bar-switch-to-prev-tab)

   ;; Workspaces (tabspaces)
   '("TAB TAB" . tabspaces-switch-or-create-workspace)
   '("TAB n"   . tabspaces-open-or-create-project-and-workspace)
   '("TAB d"   . tabspaces-close-workspace)
   '("TAB r"   . tabspaces-rename-workspace)
   '("TAB b"   . tabspaces-switch-to-buffer)
   '("TAB B"   . tabspaces-move-buffer-to-tab)

   ;; Project (project.el, built-in)
   '("p d" . project-dired)
   '("p p" . project-switch-project)
   '("p f" . project-find-file)
   '("p b" . project-switch-to-buffer)
   '("p k" . project-kill-buffers)
   '("p s" . consult-ripgrep)

   ;; LSP (eglot)
   '("l r" . eglot-rename)
   '("l a" . eglot-code-actions)
   '("l e" . consult-flymake)
   '("l d" . flymake-show-project-diagnostics)
   '("l k" . eldoc-print-current-symbol-info)

   ;; REPL / tight loop
   '("r r" . dm-repl-start-or-pop)
   '("r e" . dm-repl-eval-dwim)
   '("r l" . dm-repl-eval-line)
   '("r b" . dm-repl-eval-buffer)
   '("r c" . dm-repl-eval-cell)
   '("r n" . dm-repl-next-cell)
   '("r p" . dm-repl-previous-cell)
   '("r k" . dm-repl-check-dwim)
   '("r t" . dm-repl-test-dwim)
   '("r a" . dm-repl-test-all)

   ;; Windows
   '("w v" . dm-split-window-right)
   '("w s" . dm-split-window-below)
   '("w d" . dm-delete-window-dwim)
   '("w m" . delete-other-windows)
   '("w r" . dm-window-resize-hydra/body)
   '("w h" . windmove-left)
   '("w l" . windmove-right)
   '("w j" . windmove-down)
   '("w k" . windmove-up)

   ;; quit
   '("q q" . save-buffers-kill-terminal)
   '("q Q" . save-buffers-kill-emacs)
   '("q r" . dm-restart-emacs-and-restore)
   '("q R" . dm-restart-emacs-no-restore)))

(keymap-global-set "C-," #'embark-dwim)
(keymap-global-set "C-g" #'dm-quit-or-close-popup)

(defun dm-bind-gui-keys (&optional frame)
  "Set up keybindings specific to GUI Emacs.
Set up in frame hooks to correctly distinguish between non/daemonized and
GUI Emacs. Should be kept minimal to militate against drift."
  (with-selected-frame (or frame (selected-frame))
    (when (display-graphic-p)
      (keymap-global-set "s-<backspace>" #'dm-text-kill-line-bti)
      (keymap-global-set "s-["   #'previous-buffer)
      (keymap-global-set "s-]"   #'next-buffer)
      (keymap-global-set "s-{"   #'tab-bar-switch-to-prev-tab)
      (keymap-global-set "s-}"   #'tab-bar-switch-to-next-tab)
      (keymap-global-set "s-p"   #'dm-find-in-home)
      (keymap-global-unset "s-r")
      (keymap-global-set "s-R"   #'dm-restart-emacs-and-restore)
      (keymap-global-set "s-P"   #'execute-extended-command)
      (keymap-global-set "C-s-p" #'execute-extended-command-for-buffer)
      (keymap-global-set "s-f"   #'avy-goto-char-2)
      (keymap-global-set "s-g"   #'magit-status)
      (keymap-global-set "s-k"   #'bury-buffer)
      (keymap-global-set "s-K"   #'kill-current-buffer)
      (keymap-global-set "s-n"   #'dm-new-buffer)
      (keymap-global-set "s-N"   #'make-frame)
      (keymap-global-set "s-t"   #'tab-new)
      (keymap-global-set "s-W"   #'tab-close)
      (keymap-global-set "s-w"   #'dm-delete-window-dwim)
      (keymap-global-set "s-'"   #'eat-other-window)
      (keymap-global-set "s-\""  #'eat-project-other-window))))

;; Run on new frames, and for the initial frame in non-daemonized Emacs
(add-hook 'after-make-frame-functions #'dm-bind-gui-keys)
(add-hook 'window-setup-hook #'dm-bind-gui-keys)

(use-package which-key
  ;; Displays available key completions after a short delay. Deferred because
  ;; nothing needs it before the first partial key sequence.
  :defer 0.5
  :config
  (which-key-mode 1)
  (setq which-key-idle-delay 0.15)
  (setq which-key-idle-secondary-delay 0.1)

  ;; Prefix labels for the meow leader keymap. Meow uses `mode-specific-map'
  ;; (i.e. C-c) as its leader, so SPC <key> and C-c <key> share these names.
  (with-eval-after-load 'meow
    (dolist (entry '(("a"   . "agent")
                     ("b"   . "buffer")
                     ("d"   . "directory")
                     ("f"   . "file")
                     ("f y" . "yank")
                     ("g"   . "git")
                     ("h"   . "help")
                     ("j"   . "jump")
                     ("l"   . "lsp")
                     ("o"   . "org")
                     ("p"   . "project")
                     ("q"   . "quit")
                     ("r"   . "repl")
                     ("s"   . "search")
                     ("t"   . "toggle")
                     ("T"   . "tab")
                     ("TAB" . "workspace")
                     ("w"   . "window")))
      (which-key-add-keymap-based-replacements mode-specific-map
        (car entry) (cdr entry))))
  ;; review these: disable and see which if any are still needed.
  (defvar dm-which-key-replacement-rules
    '(
      ;; prefix names
      (("\\`C-x w\\'"     . nil) .  (nil . "window"))
      (("\\`C-x RET\\'"   . nil) .  (nil . "coding system"))
      (("\\`C-h 4\\'"     . nil) .  (nil . "help/info"))
      (("\\`C-x 4\\'"     . nil) .  (nil . "window/buffer"))
      (("\\`C-x 5\\'"     . nil) .  (nil . "frames"))
      (("\\`C-x 8\\'"     . nil) .  (nil . "special chars/emoji"))
      (("\\`C-x 8 e\\'"   . nil) .  (nil . "emoji"))
      (("\\`C-x a\\'"     . nil) .  (nil . "abbrev"))
      (("\\`C-x a i\\'"   . nil) .  (nil . "inverse"))
      (("\\`C-x n\\'"     . nil) .  (nil . "[deprecated]"))
      (("\\`C-x p\\'"     . nil) .  (nil . "project"))
      (("\\`C-x p C-x\\'" . nil) .  (nil . "save"))
      (("\\`C-x r\\'"     . nil) .  (nil . "registers"))
      (("\\`C-x X\\'"     . nil) .  (nil . "edebug"))
      (("\\`C-x C-a\\'"   . nil) .  (nil . "edebug"))
      (("\\`C-x t\\'"     . nil) .  (nil . "tab"))
      (("\\`C-x t ^\\'"   . nil) .  (nil . "detach"))
      (("\\`C-x x\\'"     . nil) .  (nil . "revert/rename"))
      (("\\`C-c @\\'"     . nil) .  (nil . "hideshow"))
      ;; name substitutions (roughly in descending order of width savings)
      ((nil . "find-file-at-point")             . (nil . "ffap"))
      ((nil . "\\`diff-hl-\\(.*\\)previous\\(.*\\)\\'") . (nil . "\\1prev\\2"))

      ((nil . "\\`diff-hl-") . (nil . ""))
      ((nil . "\\`dm-")      . (nil . ""))
      ((nil . "\\`edebug-")  . (nil . ""))
      ((nil . "\\`flymake-") . (nil . ""))
      ((nil . "\\`project-") . (nil . ""))
      ((nil . "\\`tab-")     . (nil . ""))
      ((nil . "\\`tab-bar-") . (nil . ""))

      ((nil . "previous")           . (nil . "prev"))
      ((nil . "forward")            . (nil . "fwd"))
      ((nil . "backward")           . (nil . "bwd"))
      ((nil . "-")                  . (nil . " "))
      ))
  ;; append to the list: these must come after :which_key customizations
  ;; (only the first match applies)
  (dolist (rule dm-which-key-replacement-rules)
    (add-to-list 'which-key-replacement-alist rule t)))

(provide 'dm-keys)
;;; dm-keys.el ends here
