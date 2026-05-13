;;; dm-session --- Summary: Daymacs session configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;; Session persistence and restore.

;;; Code:

(use-package desktop
  :ensure nil
  :demand t
  :init
  (make-directory dm-dir-desktop t)
  (setq desktop-path (list dm-dir-desktop))
  (setq desktop-dirname dm-dir-desktop)
  (setq desktop-base-file-name "emacs.desktop")
  (setq desktop-base-lock-name "emacs.desktop.lock")
  (setq desktop-load-locked-desktop 'check-pid)
  (setq desktop-restore-frames nil)
  (setq desktop-restore-reuses-frames nil) ;; t can restore with the window size broken
  (setq desktop-save t)
  (setq desktop-restore-eager 4)
  (setq desktop-lazy-verbose nil)
  :config
  (dolist (mode '(compilation-mode
                  eat-mode
                  eshell-mode
                  help-mode
                  helpful-mode
                  shell-mode
                  term-mode
                  term-mode
                  vterm-mode))
    (add-to-list 'desktop-modes-not-to-save mode))

  (defun dm-desktop-read-silently (orig-fun &rest args)
    "Run `desktop-read' without echo-area messages."
    (let ((inhibit-message t))
      (apply orig-fun args)))
  (advice-add 'desktop-read :around #'dm-desktop-read-silently)
  (desktop-save-mode 1))

(provide 'dm-session)
;;; dm-session.el ends here
