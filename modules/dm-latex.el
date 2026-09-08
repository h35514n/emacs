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
  "Command run in the Makefile directory after saving a LaTeX buffer.")

(defvar dm-latex--compile-processes nil
  "Alist of (ROOT . PROCESS) for in-flight `make' runs, keyed by
the directory of the Makefile driving that run.")

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

(defun dm-latex--compile-sentinel (_proc event)
  "Report the outcome of a `make' run started by `dm-latex-compile-after-save'."
  (cond
   ((string= event "finished\n")
    (message "✓ LaTeX compiled"))
   ((string-prefix-p "exited abnormally" event)
    (message "✗ LaTeX compile failed — see *latex-make*"))))

(defun dm-latex-compile-after-save ()
  "Run `make' in the nearest Makefile directory after saving.
Does nothing if the buffer has no Makefile above it, or if a `make' run
for that same directory is already in flight -- sibling problem/solution
fragments (see `dm-latex-toggle-problem-solution') share one Makefile, and
saving several in quick succession should not start concurrent builds."
  (if-let* ((root (dm-latex--makefile-dir)))
      (let ((proc (alist-get root dm-latex--compile-processes nil nil #'equal)))
        (if (process-live-p proc)
            (message "… LaTeX compile already running in %s" root)
          (let ((default-directory root))
            (setf (alist-get root dm-latex--compile-processes nil nil #'equal)
                  (make-process
                   :name "latex-make"
                   :buffer "*latex-make*"
                   :command dm-latex-compile-command
                   :sentinel #'dm-latex--compile-sentinel)))))
    (message "✗ LaTeX compile: no Makefile found above %s" buffer-file-name)))

(define-minor-mode dm-latex-auto-compile-mode
  "Run `make' after saving, for files that live under a Makefile."
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
