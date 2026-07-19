;;; dm-editing.el --- Daymacs buffer editing tools  -*- lexical-binding: t; -*-

;;; Commentary:

;; Buffer-local editing ergonomics that do not warrant a narrower owner module.
;; Completion-at-point, snippets, formatting, help, and workspace/session
;; behavior live in focused companion modules.

;;; Code:

(use-package dired
  :straight nil
  :after evil
  :init
  :hook ((dired-mode . dired-hide-details-mode))
  :custom
  (dired-listing-switches "-Ah --group-directories-first"))

(use-package visual-fill-column
  :custom
  (visual-fill-column-width 80))

(use-package olivetti
  :hook (((org-mode text-mode) . olivetti-mode)
         (olivetti-mode        . visual-line-mode))
  :custom
  (olivetti-style 'fancy)
  (olivetti-body-width 92)
  (olivetti-minimum-body-width 72))

(use-package markdown-mode
  :hook ((markdown-mode . outline-minor-mode)
         (markdown-mode . dm-disable-line-numbers-h)
         (gfm-mode . outline-minor-mode)
         (gfm-mode . dm-disable-line-numbers-h))
  :mode (("\\.md\\'" . gfm-mode)
         ("\\.markdown\\'" . gfm-mode)))

(use-package hideshow
  ;; Evil's z* folds need one supported backend. Elisp does not always get
  ;; `treesit-fold-mode', so keep a sexp-based fallback active there.
  :straight nil
  :hook ((emacs-lisp-mode . hs-minor-mode)
         (lisp-interaction-mode . hs-minor-mode)))

(use-package copy-as-format
  :straight (:type git :host github :repo "h35514n/copy-as-format")
  :custom
  (copy-as-format-default "github")
  (copy-as-format-include-source-link t)
  (copy-as-format-include-metadata-comment t)
  (copy-as-format-github-folded-prompt-for-summary t))

(use-package wc-mode
  :straight (:type git :host github :repo "bnbeckwith/wc-mode")
  :hook ((text-mode . wc-mode)))

(provide 'dm-editing)
;;; dm-editing.el ends here
