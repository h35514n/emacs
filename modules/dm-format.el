;;; dm-format.el --- Daymacs formatting setup and bindings  -*- lexical-binding: t; -*-

;;; Commentary:

;; External formatters plus text-markup bindings for prose formats.

;;; Code:

(use-package apheleia
  :commands (apheleia-format-buffer apheleia-mode apheleia-global-mode)
  :config
  ;; Prefer ecosystem-standard formatters for common editing modes.
  ;; These tools still need to be installed on PATH for Apheleia to run them.
  (dolist (entry '((emacs-lisp-mode       . lisp-indent)
                   (lisp-interaction-mode . lisp-indent)
                   (sh-mode               . shfmt)
                   (bash-ts-mode          . shfmt)
                   (ruby-mode             . rubocop)
                   (ruby-ts-mode          . rubocop)
                   (python-mode           . (ruff-isort ruff))
                   (python-ts-mode        . (ruff-isort ruff))
                   (go-mode               . goimports)
                   (go-ts-mode            . goimports)
                   (rust-mode             . rustfmt)
                   (rust-ts-mode          . rustfmt)
                   (js-mode               . prettier-javascript)
                   (js-ts-mode            . prettier-javascript)
                   (jsx-ts-mode           . prettier)
                   (typescript-mode       . prettier-typescript)
                   (typescript-ts-mode    . prettier-typescript)
                   (tsx-ts-mode           . prettier-typescript)
                   (css-mode              . prettier-css)
                   (css-ts-mode           . prettier-css)
                   (json-mode             . prettier-json)
                   (json-ts-mode          . prettier-json)
                   (LaTeX-mode            . latexindent)
                   (latex-mode            . latexindent)
                   (TeX-latex-mode        . latexindent)))
    (setf (alist-get (car entry) apheleia-mode-alist) (cdr entry)))

  ;; latexindent indents with a literal tab out of the box. This config is
  ;; spaces everywhere (`indent-tabs-mode' is nil), and two spaces matches
  ;; AUCTeX's `LaTeX-indent-level'. `--yaml' layers over any indentconfig.yaml
  ;; a document supplies, so per-project settings still apply.
  ;;
  ;; Deliberately no `-m': that lets latexindent add and remove line breaks,
  ;; which rewraps prose paragraphs and is too invasive to run on every save.
  (setf (alist-get 'latexindent apheleia-formatters)
        '("latexindent" "--logfile=/dev/null" "--yaml=defaultIndent: '  '")))

;; No `apheleia-global-mode' here, and not merely because it is off by default:
;; calling `(apheleia-global-mode -1)' would run `(apheleia-mode -1)' in every
;; live buffer, as any globalized minor mode's disable path does. Apheleia loads
;; lazily on the first save, so that call would land mid-save and switch the
;; buffer being saved back off. Buffers opt in per-mode via `apheleia-mode'
;; instead -- see the LaTeX hook in dm-latex.el.

(defun dm-format-text-keybindings ()
  "Bind Super text-formatting commands in the current buffer."
  (dolist (state '(normal visual insert))
    (evil-local-set-key state (kbd "s-b") #'dm-text-make-bold)
    (evil-local-set-key state (kbd "s-i") #'dm-text-make-italic)
    (evil-local-set-key state (kbd "s-u") #'dm-text-make-underlined)
    (evil-local-set-key state (kbd "s-X") #'dm-text-make-strikethrough)))

(dolist (hook '(LaTeX-mode-hook
                latex-mode-hook
                markdown-mode-hook
                gfm-mode-hook
                org-mode-hook))
  (add-hook hook #'dm-format-text-keybindings))

(defun dm-format-latex-keybindings ()
  "Bind latex-formatting commands in the current buffer."
  (dolist (state '(visual))
    (evil-local-set-key state (kbd "C-b") #'dm-text-latex-wrap-as-boxed)
    (evil-local-set-key state (kbd "C-f") #'dm-text-latex-wrap-as-frac)
    (evil-local-set-key state (kbd "C-e") #'dm-text-latex-evaluate-selection)
    (evil-local-set-key state (kbd "C-m") #'dm-text-latex-wrap-as-math)
    (evil-local-set-key state (kbd "C-S-m") #'dm-text-latex-wrap-as-math-display)
    (evil-local-set-key state (kbd "C-s") #'dm-text-latex-wrap-as-si))
  ;; `C-m' is indistinguishable from RET in a terminal, so insert state gets
  ;; the Super bindings instead -- same convention as the bold/italic/underline
  ;; keys in `dm-format-text-keybindings'. `dm-text-latex-wrap-as-math'
  ;; already special-cases `evil-insert-state-p' to drop in empty delimiters
  ;; and leave point between them, ready to type.
  (evil-local-set-key 'insert (kbd "s-m") #'dm-text-latex-wrap-as-math)
  (evil-local-set-key 'insert (kbd "s-M") #'dm-text-latex-wrap-as-math-display))

(dolist (hook '(LaTeX-mode-hook latex-mode-hook))
  (add-hook hook #'dm-format-latex-keybindings))

(provide 'dm-format)
;;; dm-format.el ends here
