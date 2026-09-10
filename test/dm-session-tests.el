;;; dm-session-tests.el --- Restart-only desktop tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with: bin/test dm-session
;; Load the real configuration and desktop library with isolated state files.
;; Only the final process exit is substituted; saves and reads use real files.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'use-package)
(require 'desktop)

(defvar dm-dir-desktop)
(defvar dm-session-tests--restored nil)

(defmacro dm-session-tests--with-desktop (contents &rest body)
  "Create an isolated desktop with CONTENTS, configure it, then run BODY."
  (declare (indent 1) (debug t))
  `(let* ((root (make-temp-file "dm-session-" t))
          (dm-dir-desktop (file-name-as-directory root))
          (default-directory dm-dir-desktop)
          (desktop-file (expand-file-name "emacs.desktop" root))
          (desktop-path nil)
          (desktop-dirname nil)
          (desktop-base-file-name "emacs.desktop")
          (desktop-base-lock-name "emacs.desktop.lock")
          (desktop-save-mode nil)
          (desktop-save nil)
          (desktop-file-modtime nil)
          (desktop-file-checksum nil)
          (desktop-io-file-version nil)
          (desktop-saved-frameset nil)
          (desktop-globals-to-save '(dm-session-tests--restored))
          (desktop-save-hook nil)
          (desktop-delay-hook nil)
          (desktop-buffer-args-list nil)
          (desktop-lazy-timer nil)
          (desktop-after-read-hook nil)
          (after-init-hook (copy-sequence after-init-hook))
          (kill-emacs-query-functions (list #'desktop-kill))
          (kill-emacs-hook (list #'desktop--on-kill))
          (window-configuration-change-hook nil)
          (command-line-args '("emacs"))
          (dm-session-tests--restored nil)
          (noninteractive nil))
     (unwind-protect
         (save-window-excursion
           (when ,contents
             (with-temp-file desktop-file (insert ,contents)))
           (let ((use-package-expand-minimally t))
             (load "dm-session" nil t))
           ;; Frame replacement is exercised in the graphical smoke test.
           (setq desktop-restore-frames nil)
           (switch-to-buffer (get-buffer-create "*scratch*"))
           ,@body)
       (desktop-lazy-abort)
       (delete-directory root t))))

(defun dm-session-tests--write-marker (identity)
  "Write IDENTITY to this process's restart marker."
  (with-temp-file (dm-desktop-restart-marker-file)
    (prin1 identity (current-buffer))))

(defun dm-session-tests--contents (file)
  "Return FILE's contents."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(ert-deftest dm-session/fresh-start-and-ordinary-exit-leave-desktop-alone ()
  (let ((contents "(setq dm-session-tests--restored t)\n"))
    (dm-session-tests--with-desktop contents
      (run-hooks 'after-init-hook)
      (should-not dm-session-tests--restored)
      (should (equal (buffer-name (window-buffer)) "*scratch*"))
      (should-not desktop-save-mode)
      (should-not (memq #'desktop-auto-save-set-timer
                        window-configuration-change-hook))
      (should (run-hook-with-args-until-failure 'kill-emacs-query-functions))
      (should (equal (dm-desktop-save-on-restart #'list 7 nil) '(7 nil)))
      (run-hooks 'kill-emacs-hook)
      (should (equal contents (dm-session-tests--contents desktop-file)))
      (should-not (file-exists-p (dm-desktop-restart-marker-file))))))

(ert-deftest dm-session/restart-saves-and-restores-once ()
  (dm-session-tests--with-desktop ";; Previous session\n"
    (setq dm-session-tests--restored 'saved)
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (ert-fail "Unexpected overwrite prompt"))))
      (dm-desktop-save-on-restart
       (lambda (arg restart)
         (should (equal arg 7))
         (should restart)
         (should (string-match-p "dm-session-tests--restored"
                                 (dm-session-tests--contents desktop-file)))
         (should (file-exists-p (dm-desktop-restart-marker-file)))
         ;; Simulate shutdown and startup in the same OS process, as re-exec
         ;; does, while retaining the real save/read and startup hook paths.
         (run-hooks 'kill-emacs-hook)
         (setq dm-session-tests--restored nil)
         (run-hooks 'after-init-hook)
         (should (eq dm-session-tests--restored 'saved))
         (should-not (file-exists-p (dm-desktop-restart-marker-file)))
         (setq dm-session-tests--restored nil)
         (run-hooks 'after-init-hook)
         (should-not dm-session-tests--restored))
       7 t))
    ;; Restoring does not turn automatic saving back on.
    (should-not desktop-save-mode)
    (let ((contents (dm-session-tests--contents desktop-file)))
      (desktop-kill)
      (should (equal contents (dm-session-tests--contents desktop-file))))))

(ert-deftest dm-session/ignores-stale-foreign-and-malformed-markers ()
  (dm-session-tests--with-desktop "(setq dm-session-tests--restored t)\n"
    (let ((identity (dm-desktop-restart-identity)))
      (dolist (other (list (cons "another-host" (cdr identity))
                          (list (car identity) (1+ (emacs-pid)) (nth 2 identity))
                          (list (car identity) (emacs-pid) '(0 0 0 0))))
        (dm-session-tests--write-marker other)
        (run-hooks 'after-init-hook)
        (should-not dm-session-tests--restored)))
    (with-temp-file (dm-desktop-restart-marker-file) (insert "("))
    (run-hooks 'after-init-hook)
    (should-not dm-session-tests--restored)
    (should (equal (buffer-name (window-buffer)) "*scratch*"))))

(ert-deftest dm-session/missing-desktop-consumes-marker-and-keeps-scratch ()
  (dm-session-tests--with-desktop nil
    (dm-session-tests--write-marker (dm-desktop-restart-identity))
    (run-hooks 'after-init-hook)
    (should-not (file-exists-p (dm-desktop-restart-marker-file)))
    (should (equal (buffer-name (window-buffer)) "*scratch*"))))

(ert-deftest dm-session/process-start-time-tolerates-clock-sampling-skew ()
  (dm-session-tests--with-desktop "(setq dm-session-tests--restored t)\n"
    (let ((identity (dm-desktop-restart-identity)))
      (dm-session-tests--write-marker
       (list (car identity) (nth 1 identity) (time-add (nth 2 identity) 0.02))))
    (run-hooks 'after-init-hook)
    (should dm-session-tests--restored)
    (should-not (file-exists-p (dm-desktop-restart-marker-file)))))

(ert-deftest dm-session/explicit-no-desktop-consumes-marker-without-restoring ()
  (dm-session-tests--with-desktop "(setq dm-session-tests--restored t)\n"
    (dm-session-tests--write-marker (dm-desktop-restart-identity))
    (push "--no-desktop" command-line-args)
    (run-hooks 'after-init-hook)
    (should-not dm-session-tests--restored)
    (should-not (file-exists-p (dm-desktop-restart-marker-file)))))

(ert-deftest dm-session/cancelled-restart-does-not-save-or-mark ()
  (dm-session-tests--with-desktop ";; Previous session\n"
    (let ((kill-emacs-query-functions (list (lambda () nil)))
          (confirm-kill-processes nil))
      (cl-letf (((symbol-function 'kill-emacs)
                 (lambda (&rest _) (ert-fail "Cancelled restart tried to exit"))))
        (restart-emacs)))
    (should (equal ";; Previous session\n"
                   (dm-session-tests--contents desktop-file)))
    (should-not (file-exists-p (dm-desktop-restart-marker-file)))))

(ert-deftest dm-session/save-failure-aborts-restart-without-marker ()
  (dm-session-tests--with-desktop nil
    (cl-letf (((symbol-function 'desktop-save)
               (lambda (&rest _) (signal 'file-error '("Cannot save desktop")))))
      (should-error
       (dm-desktop-save-on-restart
        (lambda (&rest _) (ert-fail "Restart continued after save failure")) nil t)
       :type 'file-error))
    (should-not (file-exists-p (dm-desktop-restart-marker-file)))))

(ert-deftest dm-session/changed-desktop-retains-conflict-protection ()
  (dm-session-tests--with-desktop ";; Previous session\n"
    (with-temp-file desktop-file (insert ";; Another process's session\n"))
    (set-file-times desktop-file (time-add desktop-file-modtime 10))
    (let (asked)
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (setq asked t) nil)))
        (should-error
         (dm-desktop-save-on-restart
          (lambda (&rest _) (ert-fail "Restart continued after declined overwrite"))
          nil t)))
      (should asked))
    (should (equal ";; Another process's session\n"
                   (dm-session-tests--contents desktop-file)))
    (should-not (file-exists-p (dm-desktop-restart-marker-file)))))

(ert-deftest dm-session/failed-or-returning-shutdown-removes-marker ()
  (dm-session-tests--with-desktop nil
    (should (eq 'returned (dm-desktop-save-on-restart
                          (lambda (&rest _) 'returned) nil t)))
    (should-not (file-exists-p (dm-desktop-restart-marker-file)))
    (should-error (dm-desktop-save-on-restart
                   (lambda (&rest _) (error "Shutdown failed")) nil t))
    (should-not (file-exists-p (dm-desktop-restart-marker-file)))))

(ert-deftest dm-session/restore-error-still-consumes-marker ()
  (dm-session-tests--with-desktop "(error \"Cannot restore desktop\")\n"
    (dm-session-tests--write-marker (dm-desktop-restart-identity))
    (should-error (run-hooks 'after-init-hook))
    (should-not (file-exists-p (dm-desktop-restart-marker-file)))))

(ert-deftest dm-session/process-identity-is-local-even-in-tramp-buffer ()
  (dm-session-tests--with-desktop nil
    (let ((identity (dm-desktop-restart-identity))
          (default-directory "/ssh:example.invalid:/"))
      (should identity)
      (should (dm-desktop-restart-matches-p
               identity (dm-desktop-restart-identity))))))

(provide 'dm-session-tests)
;;; dm-session-tests.el ends here
