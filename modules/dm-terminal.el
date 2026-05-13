;;; dm-terminal.el --- Daymacs terminal setup  -*- lexical-binding: t; -*-

;;; Commentary:

;; Eat terminal setup. Paste flows through eat's own `eat-yank' commands;
;; `eat-mode' starts in meow insert state (see `dm-meow.el') so the buffer
;; receives keystrokes immediately.

;;; Code:

(use-package eat
  :hook ((eshell-load . eat-eshell-mode)
         (eat-mode    . dm-disable-line-numbers-h))
  :custom
  (eat-kill-buffer-on-exit t)
  (eat-term-name "xterm-256color")
  :config
  (defun dm-eat-setup-paste-bindings ()
    "Route paste commands through Eat instead of inserting into the buffer."
    (define-key eat-mode-map (kbd "s-v") #'eat-yank)
    (define-key eat-mode-map [remap yank] #'eat-yank)
    (define-key eat-mode-map [remap clipboard-yank] #'eat-yank)
    (define-key eat-semi-char-mode-map (kbd "s-v") #'eat-yank)
    (define-key eat-semi-char-mode-map (kbd "C-y") #'eat-yank)
    (define-key eat-semi-char-mode-map (kbd "S-<insert>") #'eat-yank)
    (define-key eat-semi-char-mode-map [remap yank] #'eat-yank)
    (define-key eat-semi-char-mode-map [remap clipboard-yank] #'eat-yank)
    (define-key eat-char-mode-map (kbd "s-v") #'eat-yank)
    (define-key eat-char-mode-map [remap yank] #'eat-yank)
    (define-key eat-char-mode-map [remap clipboard-yank] #'eat-yank))

  (dm-eat-setup-paste-bindings))

(provide 'dm-terminal)
;;; dm-terminal.el ends here
