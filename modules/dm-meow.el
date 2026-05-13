;;; dm-meow.el --- Daymacs Meow setup  -*- lexical-binding: t; -*-

;;; Commentary:

;; Kakoune-style modal editing via meow. The canonical qwerty layout is
;; installed verbatim from the meow README; per-mode initial state lives in
;; `meow-mode-state-list'. Leader paths are defined here (replacing
;; general.el's leader! definer in the old evil setup).

;;; Code:

(defun dm-meow--setup-qwerty ()
  "Install the canonical meow qwerty bindings."
  (meow-motion-overwrite-define-key
   '("j" . meow-next)
   '("k" . meow-prev)
   '("<escape>" . ignore))
  (meow-leader-define-key
   ;; SPC <digit> as digit argument.
   '("1" . meow-digit-argument)
   '("2" . meow-digit-argument)
   '("3" . meow-digit-argument)
   '("4" . meow-digit-argument)
   '("5" . meow-digit-argument)
   '("6" . meow-digit-argument)
   '("7" . meow-digit-argument)
   '("8" . meow-digit-argument)
   '("9" . meow-digit-argument)
   '("0" . meow-digit-argument)
   '("/" . meow-keypad-describe-key)
   '("?" . meow-cheatsheet))
  (meow-normal-define-key
   '("0" . meow-expand-0)
   '("1" . meow-expand-1)
   '("2" . meow-expand-2)
   '("3" . meow-expand-3)
   '("4" . meow-expand-4)
   '("5" . meow-expand-5)
   '("6" . meow-expand-6)
   '("7" . meow-expand-7)
   '("8" . meow-expand-8)
   '("9" . meow-expand-9)
   ;; `-' is overridden below; keep negative-argument default available via
   ;; meow's prefix-argument forms when wanted.
   '("-" . dired-jump)
   '(";" . meow-reverse)
   '("," . meow-inner-of-thing)
   '("." . meow-bounds-of-thing)
   '("[" . meow-beginning-of-thing)
   '("]" . meow-end-of-thing)
   '("a" . meow-append)
   '("A" . meow-open-below)
   '("b" . meow-back-word)
   '("B" . meow-back-symbol)
   '("c" . meow-change)
   '("d" . meow-delete)
   '("D" . meow-backward-delete)
   '("e" . meow-next-word)
   '("E" . meow-next-symbol)
   '("f" . meow-find)
   '("g" . meow-cancel-selection)
   '("G" . meow-grab)
   '("h" . meow-left)
   '("H" . meow-left-expand)
   '("i" . meow-insert)
   '("I" . meow-open-above)
   '("j" . meow-next)
   '("J" . meow-next-expand)
   '("k" . meow-prev)
   '("K" . meow-prev-expand)
   '("l" . meow-right)
   '("L" . meow-right-expand)
   '("m" . meow-join)
   '("n" . meow-search)
   '("o" . meow-block)
   '("O" . meow-to-block)
   '("p" . meow-yank)
   '("q" . meow-quit)
   '("Q" . meow-goto-line)
   '("r" . meow-replace)
   '("R" . meow-swap-grab)
   '("s" . meow-kill)
   '("t" . meow-till)
   '("u" . meow-undo)
   '("U" . meow-undo-in-selection)
   '("v" . meow-visit)
   '("w" . meow-mark-word)
   '("W" . meow-mark-symbol)
   '("x" . meow-line)
   '("X" . meow-goto-line)
   '("y" . meow-save)
   '("Y" . meow-sync-grab)
   '("z" . meow-pop-selection)
   '("'" . repeat)
   '("<escape>" . ignore)))

(use-package meow
  :demand t
  :init
  (setq meow-use-clipboard t)
  (setq meow-keypad-leader-dispatch nil)
  ;; Free up `g' as a leader prefix; the default routes it to C-M-, which
  ;; intercepts `SPC g g' (magit) and similar paths before leader lookup.
  (setq meow-keypad-ctrl-meta-prefix nil)
  ;; Pop the keypad describer faster (default is 0.5s); matches the previous
  ;; which-key feel.
  (setq meow-keypad-describe-delay 0.15)
  :config
  (setq meow-cheatsheet-layout meow-cheatsheet-layout-qwerty)
  (dm-meow--setup-qwerty)
  (meow-global-mode 1))

;; Per-mode initial state. Modes not listed default to meow-normal-mode.
;; Modes whose own keymap owns the buffer (magit, dired, help) go to motion
;; state so meow doesn't shadow their single-key bindings. Modes that need
;; to accept typed input (terminals, commit messages) go to insert state.
(with-eval-after-load 'meow
  (dolist (entry '((magit-status-mode      . motion)
                   (magit-log-mode         . motion)
                   (magit-diff-mode        . motion)
                   (magit-revision-mode    . motion)
                   (magit-stash-mode       . motion)
                   (git-commit-mode        . insert)
                   (dired-mode             . motion)
                   (ibuffer-mode           . motion)
                   (help-mode              . motion)
                   (helpful-mode           . motion)
                   (Info-mode              . motion)
                   (compilation-mode       . motion)
                   (git-timemachine-mode   . motion)
                   (xref--xref-buffer-mode . motion)
                   (Custom-mode            . motion)
                   (eat-mode               . insert)
                   (eshell-mode            . insert)
                   (vterm-mode             . insert)))
    (add-to-list 'meow-mode-state-list entry)))

(provide 'dm-meow)
;;; dm-meow.el ends here
