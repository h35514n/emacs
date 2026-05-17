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
                   (json-ts-mode          . prettier-json)))
    (setf (alist-get (car entry) apheleia-mode-alist) (cdr entry)))
  (apheleia-global-mode -1))

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
    (evil-local-set-key state (kbd "C-s") #'dm-text-latex-wrap-as-si)))

(dolist (hook '(LaTeX-mode-hook latex-mode-hook))
  (add-hook hook #'dm-format-latex-keybindings))

(provide 'dm-format)
;;; dm-format.el ends here
