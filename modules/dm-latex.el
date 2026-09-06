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
         (LaTeX-mode . laas-mode))
  :custom
  ;; Parse the document on open and save so AUCTeX knows its own labels,
  ;; environments, and macros.
  (TeX-parse-self t)
  (TeX-auto-save t)
  (TeX-PDF-mode t)
  ;; Leave sub/superscript insertion to cdlatex and laas, which both bind it.
  (TeX-electric-sub-and-superscript nil))

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
   ((and (looking-back "\\(?:\\sw\\|\\s_\\)+" (line-beginning-position))
         (tempel-expand t))
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
