;;; dm-latex-tests.el --- Save command tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with: bin/test dm-latex
;; Exercise the real process launcher and sentinels using children that wait
;; for input, so queue ordering does not depend on sleep durations.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'tex-mode)
(cl-letf (((symbol-function 'use-package)
           (cons 'macro (lambda (&rest _) nil))))
  (require 'dm-latex))

(defconst dm-latex-tests--command
  '("/bin/sh" "-c"
    "read -r go; printf 'RESULT:%s|%s|%s|%s\\n' \"$PWD\" \"$DM_LATEX_SAVED_FILE\" \"$DM_LATEX_TEST_VALUE\" \"$1\"; exit \"${DM_LATEX_TEST_STATUS:-0}\""
    "save-test" "original"))

(defmacro dm-latex-tests--with-project (&rest body)
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "latex project " t))))
          (default-directory root)
          (dm-latex--compile-processes nil)
          (dm-latex--compile-queues nil)
          (process-connection-type nil)
          (process-environment (copy-sequence process-environment))
          (enable-local-variables nil)
          (create-lockfiles nil)
          (auto-save-default nil))
     (unwind-protect
         (progn
           (write-region "" nil (expand-file-name "Makefile" root) nil 'silent)
           (with-current-buffer (get-buffer-create "*latex-make*") (erase-buffer))
           ,@body)
       (dolist (entry dm-latex--compile-processes)
         (when (processp (cdr entry))
           (set-process-sentinel (cdr entry) #'ignore)
           (when (process-live-p (cdr entry)) (delete-process (cdr entry)))))
       (delete-directory root t))))

(defun dm-latex-tests--save (root file &optional command value status)
  "Submit a save from a short-lived buffer under ROOT."
  (with-temp-buffer
    (setq buffer-file-name (expand-file-name file root)
          default-directory (file-name-directory buffer-file-name))
    (let ((dm-latex-compile-command (or command dm-latex-tests--command))
          (process-environment (copy-sequence process-environment)))
      (setenv "DM_LATEX_TEST_VALUE" (or value "value"))
      (setenv "DM_LATEX_TEST_STATUS" (number-to-string (or status 0)))
      (dm-latex-compile-after-save))))

(defun dm-latex-tests--process (root)
  (alist-get root dm-latex--compile-processes nil nil #'equal))

(defun dm-latex-tests--wait (predicate)
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (should (funcall predicate))))

(defun dm-latex-tests--finish (root)
  (let ((proc (dm-latex-tests--process root)))
    (should (process-live-p proc))
    (process-send-string proc "go\n")
    (dm-latex-tests--wait (lambda () (process-get proc 'dm-latex-finished)))
    proc))

(defun dm-latex-tests--output ()
  (with-current-buffer "*latex-make*" (buffer-string)))

(ert-deftest dm-latex-save/passes-context-without-changing-the-command ()
  (dm-latex-tests--with-project
    (let ((file "chapter 'quoted' $(literal).tex")
          (original-environment (copy-sequence process-environment)))
      (setenv "DM_LATEX_SAVED_FILE" "outside")
      (setq original-environment (copy-sequence process-environment))
      (dm-latex-tests--save root file)
      (should (equal (process-command (dm-latex-tests--process root)) dm-latex-tests--command))
      (should (equal process-environment original-environment))
      (dm-latex-tests--finish root)
      (should (string-match-p
               (regexp-quote (format "RESULT:%s|%s|value|original" (directory-file-name root) file))
               (dm-latex-tests--output)))
      (should (string-match-p "Command:" (dm-latex-tests--output)))
      (should-not dm-latex--compile-processes)
      (should-not dm-latex--compile-queues))))

(ert-deftest dm-latex-save/serializes-files-and-keeps-the-latest-pending-request ()
  (dm-latex-tests--with-project
    (dm-latex-tests--save root "a.tex")
    (let ((first (dm-latex-tests--process root))
          (latest (append (butlast dm-latex-tests--command) '("latest"))))
      (dm-latex-tests--save root "b.tex" nil "old")
      (dm-latex-tests--save root "c.tex")
      (dm-latex-tests--save root "b.tex" latest "new")
      (should (eq first (dm-latex-tests--process root)))
      (should (equal (mapcar #'dm-latex--build-file (cdr (assoc root dm-latex--compile-queues)))
                     '("b.tex" "c.tex")))
      (dm-latex-tests--finish root)
      (should (equal (process-command (dm-latex-tests--process root)) latest))
      ;; Repeated terminal notifications cannot advance the new process.
      (dm-latex--compile-sentinel first "finished\n")
      (should (equal (process-get (dm-latex-tests--process root) 'dm-latex-file) "b.tex"))
      (dm-latex-tests--finish root)
      (should (equal (process-get (dm-latex-tests--process root) 'dm-latex-file) "c.tex"))
      (dm-latex-tests--finish root)
      (should (string-match-p "|b.tex|new|latest" (dm-latex-tests--output)))
      (should-not (string-match-p "|b.tex|old|" (dm-latex-tests--output)))
      (should-not dm-latex--compile-queues))))

(ert-deftest dm-latex-save/resaving-the-active-file-schedules-one-followup ()
  (dm-latex-tests--with-project
    (dm-latex-tests--save root "a.tex")
    (dm-latex-tests--save root "a.tex")
    (dm-latex-tests--save root "a.tex")
    (should (= 1 (length (cdr (assoc root dm-latex--compile-queues)))))
    (dm-latex-tests--finish root)
    (should (equal (process-get (dm-latex-tests--process root) 'dm-latex-file) "a.tex"))
    (dm-latex-tests--finish root)
    (should-not dm-latex--compile-processes)))

(ert-deftest dm-latex-save/queued-command-keeps-its-executable-search-path ()
  (dm-latex-tests--with-project
    (let ((bin (expand-file-name "bin" root)))
      (make-directory bin)
      (make-symbolic-link "/bin/sh" (expand-file-name "save-test-shell" bin))
      (dm-latex-tests--save root "a.tex")
      (let ((exec-path (list bin)))
        (dm-latex-tests--save root "b.tex"
                             (cons "save-test-shell" (cdr dm-latex-tests--command))))
      (dm-latex-tests--finish root)
      (should (process-live-p (dm-latex-tests--process root)))
      (dm-latex-tests--finish root)
      (should (string-match-p "|b.tex|value|original" (dm-latex-tests--output))))))

(ert-deftest dm-latex-save/failure-and-launch-error-do-not-block-later-files ()
  (dm-latex-tests--with-project
    (dm-latex-tests--save root "fails.tex" nil nil 7)
    (dm-latex-tests--save root "missing.tex" '("/no/such/latex-save-command"))
    (dm-latex-tests--save root "next.tex")
    (let ((failed (dm-latex-tests--finish root)))
      (should (= (process-exit-status failed) 7)))
    (should (equal (process-get (dm-latex-tests--process root) 'dm-latex-file) "next.tex"))
    (dm-latex-tests--finish root)
    (should (string-match-p "Could not start missing.tex" (dm-latex-tests--output)))
    (should (string-match-p "exited abnormally with code 7" (dm-latex-tests--output)))
    (should-not dm-latex--compile-processes)))

(ert-deftest dm-latex-save/independent-roots-can-run-together ()
  (dm-latex-tests--with-project
    (let ((other (expand-file-name "other/" root)))
      (make-directory other)
      (write-region "" nil (expand-file-name "GNUmakefile" other) nil 'silent)
      (dm-latex-tests--save root "a.tex")
      (dm-latex-tests--save other "b.tex")
      (should (process-live-p (dm-latex-tests--process root)))
      (should (process-live-p (dm-latex-tests--process other)))
      (dm-latex-tests--finish other)
      (should (process-live-p (dm-latex-tests--process root)))
      (dm-latex-tests--finish root))))

(ert-deftest dm-latex-save/default-command-and-no-makefile-behavior ()
  (should (equal (default-value 'dm-latex-compile-command) '("make" "-k")))
  (dm-latex-tests--with-project
    (delete-file (expand-file-name "Makefile" root))
    (dm-latex-tests--save root "a.tex")
    (should-not dm-latex--compile-processes)
    (should-not dm-latex--compile-queues)
    (with-temp-buffer
      (dm-latex-compile-after-save)
      (should-not dm-latex--compile-processes))))

(ert-deftest dm-latex-save/mode-toggle-controls-real-saves ()
  (dm-latex-tests--with-project
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "a.tex" root))
      (let ((dm-latex-compile-command dm-latex-tests--command))
        (dm-latex-auto-compile-mode 1)
        (dm-latex-auto-compile-mode 1)
        (insert "A\n")
        (save-buffer)
        (should (process-live-p (dm-latex-tests--process root)))
        (should-not dm-latex--compile-queues)
        (dm-latex-tests--finish root)
        (dm-latex-auto-compile-mode -1)
        (insert "B\n")
        (save-buffer)
        (should-not dm-latex--compile-processes)))))

(ert-deftest dm-latex-save/eglot-rereads-the-single-trusted-command-without-prompting ()
  (require 'eglot)
  (dm-latex-tests--with-project
    (write-region
     "((nil . ((dm-latex-compile-command . (\"make\" \"-k\" \"on-save\")))))"
     nil (expand-file-name ".dir-locals.el" root) nil 'silent)
    (let ((enable-local-variables t)
          (dir-locals-class-alist nil)
          (dir-locals-directory-cache nil))
      (cl-letf (((symbol-function 'eglot--major-modes) (lambda (_) '(LaTeX-mode)))
                ((symbol-function 'hack-local-variables-confirm)
                 (lambda (&rest _) (ert-fail "Unexpected local-variable prompt"))))
        (dotimes (_ 3)
          (eglot--workspace-configuration-plist 'stub-server (expand-file-name "a.tex" root))))
      (with-temp-buffer
        (setq buffer-file-name (expand-file-name "a.tex" root))
        (hack-local-variables)
        (should (local-variable-p 'dm-latex-compile-command))
        (should (equal dm-latex-compile-command '("make" "-k" "on-save")))))))

(provide 'dm-latex-tests)
;;; dm-latex-tests.el ends here
