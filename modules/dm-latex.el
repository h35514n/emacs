;;; dm-latex.el --- Daymacs LaTeX authoring  -*- lexical-binding: t; -*-

;;; Commentary:

;; AUCTeX as the TeX major mode, plus the two fast-input layers that suit math
;; better than a template picker does:
;;
;;   cdlatex -- TAB-driven environment and math-symbol insertion
;;   laas    -- as-you-type snippets (// -> \frac{}{}, sr -> ^{2}, `a -> \alpha)
;;
;; Both are gated on `texmathp', so prose is untouched and only math expands.
;; Tempel keeps the document scaffolding -- see dm-snippets.el and
;; templates/latex.eld -- reachable with C-. in insert state.

;;; Code:

(require 'dm-files)
(require 'cl-lib)
(require 'seq)

;;;###autoload
(defun dm-latex-toggle-problem-solution ()
  "Toggle between sibling problemNN.tex and solutionNN.tex fragments.
Preserve the exact number string and require an existing regular file."
  (interactive)
  (let* ((file (dm-current-file-or-error))
         (name (file-name-nondirectory file))
         (case-fold-search nil))
    (unless (string-match "\\`\\(problem\\|solution\\)\\([0-9]+\\)\\.tex\\'" name)
      (user-error "Not a problem/solution fragment: %s" name))
    (let ((counterpart
           (expand-file-name
            (concat (if (string= (match-string 1 name) "problem")
                        "solution"
                      "problem")
                    (match-string 2 name) ".tex")
            (file-name-directory file))))
      (unless (file-regular-p counterpart)
        (user-error "Counterpart is not an existing regular file: %s" counterpart))
      (find-file counterpart))))

(defun dm-latex-setup-alternate-file ()
  "Select problem/solution navigation for the current LaTeX buffer."
  (setq-local dm-alternate-file-function #'dm-latex-toggle-problem-solution))

(add-hook 'LaTeX-mode-hook #'dm-latex-setup-alternate-file)
(add-hook 'latex-mode-hook #'dm-latex-setup-alternate-file)

;; Fragments can lack the commands AUCTeX uses to recognize LaTeX content.
;; Select their mode by filename; tex-site remaps `latex-mode' to `LaTeX-mode'.
(add-to-list 'auto-mode-alist
             '("/\\(?:problem\\|solution\\)[0-9]+\\.tex\\'" . latex-mode))

;; ------------------------------------------------------------------
;; compile-on-save for Makefile-driven documents (psets, course repos)
;; ------------------------------------------------------------------

(defvar dm-latex-compile-command '("make" "-k")
  "Executable and argument strings run after saving a LaTeX buffer.
The command runs in the nearest Makefile directory, with the saved
filename relative to that directory in the DM_LATEX_SAVED_FILE
environment variable.  For example, a project can select
\(\"make\" \"-k\" \"on-save\") in its .dir-locals.el and let its Makefile
choose the output from that filename.  No shell expansion is performed.")

;; Trust the one opt-in project convention, independent of the saved file.
(add-to-list 'safe-local-variable-values
             '(dm-latex-compile-command . ("make" "-k" "on-save")))

(defvar dm-latex--compile-processes nil
  "Alist of (ROOT . PROCESS) for active save commands.")

(defvar dm-latex--compile-queues nil
  "Alist of (ROOT . BUILDS) waiting for the active save command.
BUILDS is a FIFO list of `dm-latex--build' records, with at most one
pending build per saved filename.  ROOT is the Makefile directory.")

(cl-defstruct (dm-latex--build (:constructor dm-latex--build-create))
  file command environment exec-path)

(defun dm-latex--makefile-dir ()
  "Return the nearest directory above the current file with a Makefile.
Checks for `Makefile', `makefile', and `GNUmakefile'. Return nil if the
buffer has no file, or no such directory exists above it."
  (when buffer-file-name
    (locate-dominating-file
     buffer-file-name
     (lambda (dir)
       (seq-some (lambda (name) (file-exists-p (expand-file-name name dir)))
                 '("Makefile" "makefile" "GNUmakefile"))))))

(defun dm-latex--compile-log (format-string &rest args)
  "Append FORMAT-STRING and ARGS to the save command output."
  (with-current-buffer (get-buffer-create "*latex-make*")
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (apply #'format format-string args)))))

(defun dm-latex--compile-sentinel (proc event)
  "Report PROC's terminal EVENT and start the next queued save command."
  (when (and (memq (process-status proc) '(exit signal failed))
             (not (process-get proc 'dm-latex-finished)))
    (process-put proc 'dm-latex-finished t)
    (let ((root (process-get proc 'dm-latex-root))
          (file (process-get proc 'dm-latex-file)))
      (dm-latex--compile-log "\n[%s] %s: %s" root file event)
      (if (and (eq (process-status proc) 'exit)
               (zerop (process-exit-status proc)))
          (message "✓ LaTeX save command finished: %s" file)
        (message "✗ LaTeX save command failed: %s — see *latex-make*" file))
      ;; A save can start the next build before this sentinel is delivered.
      ;; An older process must not clear its replacement or drain its queue.
      (when (eq proc (alist-get root dm-latex--compile-processes nil nil #'equal))
        (setq dm-latex--compile-processes
              (assoc-delete-all root dm-latex--compile-processes))
        (dm-latex--compile-next root)))))

(defun dm-latex--compile-next (root)
  "Start the next pending command for ROOT unless one is already running.
Report launch errors and continue to the next request without retrying."
  (while (and (alist-get root dm-latex--compile-queues nil nil #'equal)
              (not (process-live-p
                    (alist-get root dm-latex--compile-processes nil nil #'equal))))
    (let* ((build (pop (alist-get root dm-latex--compile-queues nil nil #'equal)))
           (default-directory root)
           (process-environment (dm-latex--build-environment build))
           (exec-path (dm-latex--build-exec-path build))
           (file (dm-latex--build-file build)))
      (setq dm-latex--compile-processes
            (assoc-delete-all root dm-latex--compile-processes))
      (dm-latex--compile-log "\n[%s] Saved %s\nCommand: %S\n"
                             root file (dm-latex--build-command build))
      (condition-case err
          (let ((proc (make-process
                       :name "latex-make"
                       :buffer "*latex-make*"
                       :command (dm-latex--build-command build)
                       :sentinel #'dm-latex--compile-sentinel)))
            (process-put proc 'dm-latex-root root)
            (process-put proc 'dm-latex-file file)
            (setf (alist-get root dm-latex--compile-processes nil nil #'equal) proc))
        (error
         (dm-latex--compile-log "Could not start %s: %s\n" file (error-message-string err))
         (message "✗ LaTeX save command could not start: %s — see *latex-make*" file)))))
  (unless (alist-get root dm-latex--compile-queues nil nil #'equal)
    (setq dm-latex--compile-queues
          (assoc-delete-all root dm-latex--compile-queues))))

(defun dm-latex-compile-after-save ()
  "Run `dm-latex-compile-command' in the nearest Makefile directory.
Queue saves while that directory has an active command.  Repeated saves
of a pending file replace its request, preserving its place in the queue.
Each request captures its command and environment from the saved buffer."
  (if-let* ((root (dm-latex--makefile-dir)))
      (let* ((file (file-relative-name buffer-file-name root))
             (process-environment (copy-sequence process-environment))
             (_ (setenv "DM_LATEX_SAVED_FILE" file))
             (build (dm-latex--build-create
                     :file file
                     :command (copy-sequence dm-latex-compile-command)
                     :environment process-environment
                     :exec-path (copy-sequence exec-path)))
             (pending (cl-member file
                                 (alist-get root dm-latex--compile-queues nil nil #'equal)
                                 :key #'dm-latex--build-file :test #'equal)))
        (if pending
            (setcar pending build)
          (setf (alist-get root dm-latex--compile-queues nil nil #'equal)
                (nconc (alist-get root dm-latex--compile-queues nil nil #'equal)
                       (list build))))
        (when (process-live-p
               (alist-get root dm-latex--compile-processes nil nil #'equal))
          (message "… LaTeX save command queued: %s" file))
        (dm-latex--compile-next root))
    (message "✗ LaTeX compile: no Makefile found above %s" buffer-file-name)))

(define-minor-mode dm-latex-auto-compile-mode
  "Run `dm-latex-compile-command' after saving files under a Makefile."
  :lighter " Make"
  (if dm-latex-auto-compile-mode
      (add-hook 'after-save-hook #'dm-latex-compile-after-save nil :local)
    (remove-hook 'after-save-hook #'dm-latex-compile-after-save :local)))

(defun dm-latex-maybe-enable-auto-compile ()
  "Turn on `dm-latex-auto-compile-mode' when a Makefile governs this file."
  (when (dm-latex--makefile-dir)
    (dm-latex-auto-compile-mode 1)))

(add-hook 'LaTeX-mode-hook #'dm-latex-maybe-enable-auto-compile)
(add-hook 'latex-mode-hook #'dm-latex-maybe-enable-auto-compile)

(use-package tex-site
  ;; The package is `auctex'. `tex-site' is the small shim that redirects the
  ;; built-in TeX modes to AUCTeX's via `major-mode-remap-defaults', which is
  ;; what makes .tex open in `LaTeX-mode'. Loading it eagerly is cheap; the
  ;; bulk of AUCTeX still loads on first use.
  :straight auctex
  :demand t)

(use-package latex
  ;; Shipped by the auctex package installed above.
  :straight nil
  :hook ((LaTeX-mode . turn-on-cdlatex)
         (LaTeX-mode . laas-mode)
         ;; Format on save with latexindent. `apheleia-global-mode' is off, so
         ;; modes opt in one at a time; the formatter itself is configured in
         ;; dm-format.el. `docTeX-mode' derives from `LaTeX-mode', so .dtx
         ;; files are covered by this hook too.
         (LaTeX-mode . apheleia-mode))
  :custom
  ;; Parse the document on open and save so AUCTeX knows its own labels,
  ;; environments, and macros.
  (TeX-parse-self t)
  (TeX-auto-save t)
  (TeX-PDF-mode t)
  ;; Leave sub/superscript insertion to cdlatex and laas, which both bind it.
  (TeX-electric-sub-and-superscript nil))

;; Eglot derives the LSP languageId from the major-mode name by stripping
;; "-mode", without downcasing (see `eglot--language-ids'). AUCTeX's modes are
;; CamelCase, so `LaTeX-mode' yields "LaTeX". Digestif's translation table is
;; keyed on lowercase ids only, so it raises "Invalid LSP language id" out of
;; `textDocument/didOpen', never registers the document, and then fails every
;; later request with "Trying to access unopened document". Name the ids
;; explicitly; `eglot--language-ids' consults this property first.
(dolist (cell '((LaTeX-mode     . "latex")
                (docTeX-mode    . "doctex")
                (plain-TeX-mode . "plaintex")
                (ConTeXt-mode   . "context")
                (Texinfo-mode   . "texinfo")
                (TeX-tex-mode   . "tex")))
  (put (car cell) 'eglot-language-id (cdr cell)))

(defun dm-latex-tempel-tab ()
  "Give TAB back to Tempel when Tempel has something to do.

`cdlatex-mode' is a minor mode, so its TAB shadows `dm-tab-dwim' from
dm-snippets.el in LaTeX buffers. This runs from `cdlatex-tab-hook', which
stops `cdlatex-tab' from taking its own action as soon as a hook function
returns non-nil. `tempel-expand' only fires on an exact template-name
match, so anything cdlatex would have expanded still reaches it."
  (cond
   ((bound-and-true-p tempel--active)
    (tempel-next 1)
    t)
   ;; Called interactively, `tempel-expand' signals a `user-error' when nothing
   ;; matches rather than returning nil, which would abort `cdlatex-tab' instead
   ;; of letting it fall through to its own actions. Probe with the Capf form,
   ;; which returns nil, and only then expand for real.
   ((and (looking-back "\\(?:\\sw\\|\\s_\\)+" (line-beginning-position))
         (tempel-expand))
    (tempel-expand t)
    t)))

(use-package cdlatex
  :commands (turn-on-cdlatex turn-on-org-cdlatex)
  :hook (org-mode . turn-on-org-cdlatex)
  :config
  (add-hook 'cdlatex-tab-hook #'dm-latex-tempel-tab))

(use-package laas
  ;; Pulls in `aas' (the expansion engine) and `texmathp' (from auctex).
  :commands laas-mode
  :hook (org-mode . laas-mode))

(provide 'dm-latex)
;;; dm-latex.el ends here
