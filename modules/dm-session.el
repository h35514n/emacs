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
  (setq desktop-load-locked-desktop t)
  (setq desktop-restore-frames t)
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

  (defun dm-desktop-bury-scratch-frame ()
    "Close any leftover frame that shows only `*scratch*'.
`desktop-restore-reuses-frames' is nil, so restoring the desktop is
meant to replace the startup frame rather than leave it alongside the
restored one; when it lingers anyway, fold it away here and bury
`*scratch*' instead of leaving it visible in its own frame."
    (let ((scratch (get-buffer "*scratch*")))
      (dolist (frame (frame-list))
        (when (and (frame-live-p frame)
                   (> (length (frame-list)) 1)
                   (null (cdr (window-list frame)))
                   (eq (window-buffer (frame-first-window frame)) scratch))
          (delete-frame frame)))
      (when scratch
        (bury-buffer scratch))))
  (add-hook 'desktop-after-read-hook #'dm-desktop-bury-scratch-frame)

  (desktop-save-mode 1))

(provide 'dm-session)
;;; dm-session.el ends here
