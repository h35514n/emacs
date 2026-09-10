;;; dm-session --- Summary: Daymacs session configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;; Save and restore the desktop only for explicit restarts.

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
  (setq desktop-save nil)
  (setq desktop-restore-eager 4)
  (setq desktop-lazy-verbose nil)
  :config
  ;; The mode also reads the desktop from `after-init-hook'.  Both saving
  ;; and loading are explicit below, so ordinary launches and exits leave
  ;; the saved session alone.
  (desktop-save-mode -1)
  ;; Remember the existing file without loading it.  A later restart can
  ;; replace it without an overwrite prompt unless another process changed it.
  (setq desktop-file-modtime
        (file-attribute-modification-time
         (file-attributes (desktop-full-file-name))))

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

  (defun dm-desktop-restart-marker-file ()
    "Return this process's one-use desktop restart marker file."
    (expand-file-name (format "restart-%d" (emacs-pid)) dm-dir-desktop))

  (defun dm-desktop-restart-identity ()
    "Identify this OS process across a restart, or return nil if unavailable.
The built-in restart re-executes the same process.  Its OS start time
guards against stale markers when a later process reuses the PID."
    ;; `process-attributes' consults the remote host in a Tramp buffer.
    (let* ((default-directory (expand-file-name dm-dir-desktop))
           (start (cdr (assq 'start (process-attributes (emacs-pid))))))
      (when start
        (list (system-name) (emacs-pid) start))))

  (defun dm-desktop-restart-matches-p (identity saved)
    "Return non-nil when SAVED identifies the same process as IDENTITY."
    (pcase saved
      (`(,host ,pid ,start)
       (and identity start
            (equal host (car identity))
            (equal pid (nth 1 identity))
            ;; On Linux the start time is derived from separate wall-clock
            ;; and uptime readings, so it can differ slightly across calls.
            (condition-case nil
                (< (abs (float-time (time-subtract start (nth 2 identity)))) 1)
              (error nil))))))

  (defun dm-desktop-save-on-restart (orig-fun &optional arg restart)
    "Save the desktop before ORIG-FUN only when RESTART is non-nil.
Advising `kill-emacs' places the save after shutdown confirmations.
Pass ARG and RESTART through, and remove the marker if shutdown fails."
    (if (not restart)
        (funcall orig-fun arg restart)
      (let ((marker (dm-desktop-restart-marker-file))
            (identity (dm-desktop-restart-identity)))
        (unless identity
          (user-error "Cannot identify this process for desktop restart"))
        (unwind-protect
            (progn
              ;; Do not release here: `desktop-save' must signal if the
              ;; user declines a conflict prompt, aborting the restart.
              ;; The normal `kill-emacs-hook' releases the desktop lock.
              (desktop-save dm-dir-desktop)
              (let ((print-length nil)
                    (print-level nil))
                (with-temp-file marker
                  (prin1 identity (current-buffer))))
              (funcall orig-fun arg restart))
          ;; Successful re-exec never returns to this cleanup.
          (when (file-exists-p marker)
            (delete-file marker))))))
  (advice-add 'kill-emacs :around #'dm-desktop-save-on-restart)

  (defun dm-desktop-restore-after-restart ()
    "Consume a matching restart marker and restore the saved desktop."
    (unless noninteractive
      (let* ((marker (dm-desktop-restart-marker-file))
             (identity (dm-desktop-restart-identity))
             (saved-identity
              (condition-case nil
                  (with-temp-buffer
                    (insert-file-contents marker)
                    (read (current-buffer)))
                ((file-error end-of-file invalid-read-syntax) nil))))
        (when (dm-desktop-restart-matches-p identity saved-identity)
          ;; Consume before loading, so a failed restore cannot be retried
          ;; accidentally.  An explicit --no-desktop still takes precedence.
          (delete-file marker)
          (when (and (not (member "--no-desktop" command-line-args))
                     (file-exists-p (desktop-full-file-name dm-dir-desktop)))
            (desktop-read dm-dir-desktop))))))
  (add-hook 'after-init-hook #'dm-desktop-restore-after-restart))

(provide 'dm-session)
;;; dm-session.el ends here
