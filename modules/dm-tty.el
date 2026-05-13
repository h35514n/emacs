;;; dm-tty.el --- Daymacs TTY config  -*- lexical-binding: t; -*-

;;; Commentary:

;; Customizations for TTY Emacs, mainly meta keybindings.
;; Assumptions:
;;   - TTY Emacs is run daemonized with a socket name that includes `tty`.
;;

;;; Code:

;; git commit daemon: load magit eagerly
(require 'magit)

(defun dm-pbcut (beg end)
  "Cut region from BEG to END to the system clipboard."
  (interactive "r")
  (unless (use-region-p)
    (user-error "No active region"))
  (call-process-region beg end "pbcopy")
  (delete-region beg end))

(defun dm-pbcopy (beg end)
  "Copy region from BEG to END to the system clipboard."
  (interactive "r")
  (let ((text (buffer-substring-no-properties beg end)))
    (with-temp-buffer
      (insert text)
      (call-process-region (point-min) (point-max) "pbcopy"))))

(defun dm-pbpaste ()
  "Insert the contents of the system clipboard."
  (interactive)
  (insert (shell-command-to-string "pbpaste")))

(defun dm-bind-tty-keys (&optional frame)
  "Set up keybindings specific to TTY Emacs."
  (with-selected-frame (or frame (selected-frame))
    (keymap-global-set "M-["   #'previous-buffer)
    (keymap-global-set "M-]"   #'next-buffer)
    (keymap-global-set "M-{"   #'tab-bar-switch-to-prev-tab)
    (keymap-global-set "M-}"   #'tab-bar-switch-to-next-tab)
    (keymap-global-set "C-M-p" #'execute-extended-command-for-buffer)
    (keymap-global-set "M-f"   #'avy-goto-char-2)
    (keymap-global-set "M-g"   #'magit-status)
    (keymap-global-set "M-k"   #'bury-buffer)
    (keymap-global-set "M-K"   #'kill-current-buffer)
    (keymap-global-set "M-n"   #'dm-new-buffer)
    (keymap-global-set "M-t"   #'tab-new)
    (keymap-global-set "M-W"   #'tab-close)
    (keymap-global-set "M-w"   #'dm-delete-window-dwim)
    (keymap-global-set "C-c y" #'dm-pbcopy)
    (keymap-global-set "C-c d" #'dm-pbcut)
    (keymap-global-set "C-c p" #'dm-pbpaste)))
;; Run on new frames, and for the initial frame in non-daemonized Emacs
(add-hook 'after-make-frame-functions #'dm-bind-tty-keys)

;; TODO: idle delay may need tweaking in tty
(use-package which-key
  :defer 0.6
  :config
  (setq which-key-idle-delay 0.15)
  (setq which-key-idle-secondary-delay 0.1))

(provide 'dm-tty)
;;; dm-tty.el ends here
