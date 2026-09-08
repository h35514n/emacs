;;; dm-alternate-file-tests.el --- Alternate-file tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with: bin/test dm-alternate-file
;; Suppress unrelated package configuration while loading the real navigation
;; commands and hook registrations.  Installed AUCTeX and Evil are exercised
;; separately in a fresh-session integration check.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'tex-mode)
(require 'dm-files)

(cl-letf (((symbol-function 'use-package)
           (cons 'macro (lambda (&rest _) nil))))
  (require 'dm-latex))

(defmacro dm-alternate-file-tests--with-files (files &rest body)
  "Create FILES under a temporary `root', run BODY, and clean up.
FILES is a list of (relative-name . contents) pairs."
  (declare (indent 1) (debug t))
  `(let* ((root (file-name-as-directory
                 (file-truename (make-temp-file "dm-alternate-file-" t))))
          (default-directory root)
          (auto-mode-alist nil)
          (enable-local-variables nil)
          (enable-local-eval nil)
          (create-lockfiles nil)
          (auto-save-default nil))
     (unwind-protect
         (save-window-excursion
           (dolist (entry ,files)
             (let ((file (expand-file-name (car entry) root)))
               (make-directory (file-name-directory file) t)
               (write-region (cdr entry) nil file nil 'silent)))
           ,@body)
       (dolist (buffer (buffer-list))
         (when (and (buffer-file-name buffer)
                    (string-prefix-p root (buffer-file-name buffer)))
           (with-current-buffer buffer
             (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory root t))))

(defun dm-alternate-file-tests--assert-user-error (command message-part)
  "Assert COMMAND fails with MESSAGE-PART without navigation or file changes."
  (let ((buffer (current-buffer))
        (window (selected-window))
        (displayed (window-buffer))
        (buffers (buffer-list))
        (files (directory-files-recursively default-directory "." t)))
    (let ((error (should-error (call-interactively command) :type 'user-error)))
      (should (string-match-p (regexp-quote message-part)
                              (error-message-string error))))
    (should (eq buffer (current-buffer)))
    (should (eq window (selected-window)))
    (should (eq displayed (window-buffer)))
    (should (equal buffers (buffer-list)))
    (should (equal files (directory-files-recursively default-directory "." t)))))

(ert-deftest dm-alternate-file-latex/round-trip ()
  (dolist (digits '("7" "01" "001"))
    (let ((problem (concat "problem" digits ".tex"))
          (solution (concat "solution" digits ".tex")))
      (dm-alternate-file-tests--with-files
          (list (cons problem "Problem\n") (cons solution ""))
        (find-file (expand-file-name problem root))
        (let ((origin (current-buffer))
              (window (selected-window)))
          (call-interactively #'dm-latex-toggle-problem-solution)
          (should (equal buffer-file-name (expand-file-name solution root)))
          (should (zerop (buffer-size)))
          (should (eq window (selected-window)))
          (should (eq (current-buffer) (window-buffer window)))
          (call-interactively #'dm-latex-toggle-problem-solution)
          (should (eq origin (current-buffer))))))))

(ert-deftest dm-alternate-file-latex/fragment-mode-survives-reopen ()
  (let ((configured-modes auto-mode-alist))
    (dm-alternate-file-tests--with-files
        '(("problem03.tex" . "\\problem{3}\n\\Psi(x) = A.\n")
          ("solution03.tex" . ""))
      (let ((auto-mode-alist configured-modes))
        (dotimes (_ 2)
          (find-file (expand-file-name "problem03.tex" root))
          (should (derived-mode-p 'latex-mode 'LaTeX-mode))
          (should (eq dm-alternate-file-function #'dm-latex-toggle-problem-solution))
          (dm-alternate-file)
          (should (equal buffer-file-name (expand-file-name "solution03.tex" root)))
          (should (derived-mode-p 'latex-mode 'LaTeX-mode))
          (dm-alternate-file)
          (should (equal buffer-file-name (expand-file-name "problem03.tex" root)))
          (kill-buffer (find-buffer-visiting (expand-file-name "solution03.tex" root)))
          (kill-buffer (current-buffer)))))))

(ert-deftest dm-alternate-file-latex/non-fragments-keep-tex-mode-detection ()
  (let ((configured-modes auto-mode-alist))
    (dm-alternate-file-tests--with-files
        '(("notes.tex" . "\\def\\greeting{Hello}\n\\bye\n")
          ("xproblem03.tex" . "\\def\\greeting{Hello}\n\\bye\n")
          ("problem03-notes.tex" . "\\def\\greeting{Hello}\n\\bye\n")
          ("problem١.tex" . "\\def\\greeting{Hello}\n\\bye\n"))
      (let ((auto-mode-alist configured-modes))
        (dolist (file '("notes.tex" "xproblem03.tex" "problem03-notes.tex"
                        "problem١.tex"))
          (find-file (expand-file-name file root))
          (should (derived-mode-p 'plain-tex-mode 'plain-TeX-mode))
          (should-not (local-variable-p 'dm-alternate-file-function))
          (should (eq dm-alternate-file-function #'dm-toggle-test-implementation)))))))

(ert-deftest dm-alternate-file-latex/stays-in-current-file-directory ()
  (dm-alternate-file-tests--with-files
      '(("01-pset/problem01.tex" . "First problem")
        ("01-pset/solution01.tex" . "First solution")
        ("02-pset/problem01.tex" . "Second problem")
        ("02-pset/solution01.tex" . "Second solution"))
    (dolist (assignment '("01-pset/" "02-pset/"))
      (let ((directory (expand-file-name assignment root)))
        (find-file (expand-file-name "problem01.tex" directory))
        (setq default-directory
              (expand-file-name (if (equal assignment "01-pset/")
                                    "02-pset/" "01-pset/") root))
        (dm-latex-toggle-problem-solution)
        (should (equal buffer-file-name
                       (expand-file-name "solution01.tex" directory)))))))

(ert-deftest dm-alternate-file-latex/no-project-dependency ()
  (dm-alternate-file-tests--with-files
      '(("problem01.tex" . "Problem") ("solution01.tex" . "Solution"))
    (find-file (expand-file-name "problem01.tex" root))
    (let ((unexpected (lambda (&rest _) (ert-fail "Used test/project discovery"))))
      (cl-letf (((symbol-function 'project-current) unexpected)
                ((symbol-function 'project-files) unexpected)
                ((symbol-function 'dm-test-toggle-project-root) unexpected)
                ((symbol-function 'dm-project-files) unexpected)
                ((symbol-function 'dm-related-file-candidates) unexpected)
                ((symbol-function 'dm-test-toggle-discover-candidates) unexpected))
        (dm-latex-toggle-problem-solution)
        (should (equal buffer-file-name (expand-file-name "solution01.tex" root)))
        (dm-latex-toggle-problem-solution)
        (should (equal buffer-file-name (expand-file-name "problem01.tex" root)))))))

(ert-deftest dm-alternate-file-latex/saved-untracked-counterpart ()
  (dm-alternate-file-tests--with-files '(("problem01.tex" . "Problem"))
    (should (zerop (call-process "git" nil nil nil "init" "-q" root)))
    (find-file (expand-file-name "solution01.tex" root))
    (insert "New solution")
    (save-buffer)
    (should (equal "?? solution01.tex\n"
                   (with-temp-buffer
                     (should (zerop (call-process "git" nil t nil
                                                 "status" "--porcelain" "--"
                                                 "solution01.tex")))
                     (buffer-string))))
    (find-file (expand-file-name "problem01.tex" root))
    (dm-latex-toggle-problem-solution)
    (should (equal buffer-file-name (expand-file-name "solution01.tex" root)))))

(ert-deftest dm-alternate-file-latex/reuses-unsaved-buffers-without-saving ()
  (dm-alternate-file-tests--with-files
      '(("problem01.tex" . "Problem") ("solution01.tex" . ""))
    (let ((problem (find-file-noselect (expand-file-name "problem01.tex" root)))
          (solution (find-file-noselect (expand-file-name "solution01.tex" root))))
      (with-current-buffer solution (insert "Unsaved solution"))
      (switch-to-buffer problem)
      (goto-char (point-max))
      (insert " unsaved")
      (dm-latex-toggle-problem-solution)
      (should (eq solution (current-buffer)))
      (should (equal "Unsaved solution" (buffer-string)))
      (should (buffer-modified-p))
      (dm-latex-toggle-problem-solution)
      (should (eq problem (current-buffer)))
      (should (equal "Problem unsaved" (buffer-string)))
      (should (buffer-modified-p))
      (dolist (entry '(("problem01.tex" . "Problem") ("solution01.tex" . "")))
        (with-temp-buffer
          (insert-file-contents (expand-file-name (car entry) root))
          (should (equal (cdr entry) (buffer-string))))))))

(ert-deftest dm-alternate-file-latex/unsupported-filenames ()
  (dm-alternate-file-tests--with-files nil
    (dolist (name '("problem.tex" "problem01-notes.tex" "Problem01.tex"
                    "Solution01.tex" "problem01.TEX" "xproblem01.tex"
                    "problem01.tex.bak" "problem01.tex\n" "problem١.tex"
                    "solution１.tex" "01-pset.tex"))
      (with-temp-buffer
        (setq buffer-file-name (expand-file-name name root))
        (let ((case-fold-search t))
          (dm-alternate-file-tests--assert-user-error
           #'dm-latex-toggle-problem-solution "Not a problem/solution fragment"))))))

(ert-deftest dm-alternate-file-latex/no-visited-file ()
  (dm-alternate-file-tests--with-files nil
    (with-temp-buffer
      (dm-alternate-file-tests--assert-user-error
       #'dm-latex-toggle-problem-solution "no associated file"))))

(ert-deftest dm-alternate-file-latex/missing-counterpart ()
  (dm-alternate-file-tests--with-files '(("problem01.tex" . "Problem"))
    (find-file (expand-file-name "problem01.tex" root))
    (dm-alternate-file-tests--assert-user-error
     #'dm-latex-toggle-problem-solution (expand-file-name "solution01.tex" root))))

(ert-deftest dm-alternate-file-latex/counterpart-is-a-directory ()
  (dm-alternate-file-tests--with-files '(("problem01.tex" . "Problem"))
    (make-directory (expand-file-name "solution01.tex" root))
    (find-file (expand-file-name "problem01.tex" root))
    (dm-alternate-file-tests--assert-user-error
     #'dm-latex-toggle-problem-solution (expand-file-name "solution01.tex" root))))

(ert-deftest dm-alternate-file-latex/unsaved-only-counterpart ()
  (dm-alternate-file-tests--with-files '(("problem01.tex" . "Problem"))
    (with-current-buffer (find-file-noselect (expand-file-name "solution01.tex" root))
      (insert "Not saved yet"))
    (find-file (expand-file-name "problem01.tex" root))
    (dm-alternate-file-tests--assert-user-error
     #'dm-latex-toggle-problem-solution (expand-file-name "solution01.tex" root))))

(ert-deftest dm-alternate-file-dispatch/interactive-and-buffer-local ()
  (let ((ordinary (generate-new-buffer " *alternate-ordinary*"))
        (latex (generate-new-buffer " *alternate-latex*"))
        calls)
    (unwind-protect
        (save-window-excursion
          (cl-letf (((symbol-function 'dm-toggle-test-implementation)
                     (lambda () (interactive (progn (push 'test calls) nil))))
                    ((symbol-function 'dm-latex-toggle-problem-solution)
                     (lambda () (interactive (progn (push 'latex calls) nil)))))
            (with-current-buffer latex (latex-mode))
            (dolist (buffer (list ordinary latex ordinary latex))
              (switch-to-buffer buffer)
              (call-interactively #'dm-alternate-file)
              (should (eq (default-value 'dm-alternate-file-function)
                          #'dm-toggle-test-implementation)))
            (should (equal calls '(latex test latex test)))
            (with-current-buffer ordinary
              (should-not (local-variable-p 'dm-alternate-file-function)))
            (with-current-buffer latex
              (should (local-variable-p 'dm-alternate-file-function)))))
      (kill-buffer ordinary)
      (kill-buffer latex))))

(ert-deftest dm-alternate-file-dispatch/propagates-test-command-errors ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'dm-toggle-test-implementation)
               (lambda () (interactive) (user-error "Existing test error"))))
      (should (equal (should-error (dm-alternate-file) :type 'user-error)
                     '(user-error "Existing test error"))))))

(ert-deftest dm-alternate-file-dispatch/latex-errors-do-not-fall-back ()
  (dm-alternate-file-tests--with-files '(("01-pset.tex" . "Assignment parent"))
    (find-file (expand-file-name "01-pset.tex" root))
    (latex-mode)
    (cl-letf (((symbol-function 'dm-toggle-test-implementation)
               (lambda () (interactive) (ert-fail "Fell back to test discovery"))))
      (dm-alternate-file-tests--assert-user-error
       #'dm-alternate-file "Not a problem/solution fragment"))))

(ert-deftest dm-alternate-file-dispatch/both-latex-hooks-are-wired ()
  (dolist (hook '(LaTeX-mode-hook latex-mode-hook))
    (should (memq #'dm-latex-setup-alternate-file (symbol-value hook)))
    (with-temp-buffer
      (run-hooks hook)
      (should (local-variable-p 'dm-alternate-file-function))
      (should (eq dm-alternate-file-function #'dm-latex-toggle-problem-solution)))))

(define-derived-mode dm-alternate-file-tests--derived-latex-mode latex-mode
  "Test LaTeX")

(ert-deftest dm-alternate-file-dispatch/derived-mode-and-mode-reset ()
  (with-temp-buffer
    (dm-alternate-file-tests--derived-latex-mode)
    (should (eq dm-alternate-file-function #'dm-latex-toggle-problem-solution))
    (fundamental-mode)
    (should-not (local-variable-p 'dm-alternate-file-function))
    (should (eq dm-alternate-file-function #'dm-toggle-test-implementation))))

(ert-deftest dm-alternate-file-dispatch/unrelated-tex-mode ()
  (with-temp-buffer
    (plain-tex-mode)
    (should-not (local-variable-p 'dm-alternate-file-function))
    (should (eq dm-alternate-file-function #'dm-toggle-test-implementation))))

(ert-deftest dm-alternate-file-dispatch/does-not-load-test-toggle ()
  (should-not (featurep 'dm-test-toggle)))

(provide 'dm-alternate-file-tests)
;;; dm-alternate-file-tests.el ends here
