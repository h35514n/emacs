;;; dm-snippets.el --- Daymacs snippets and abbreviation expansion  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tempel snippet expansion, TAB DWIM behavior, and Emmet web abbreviations.

;;; Code:

;;;###autoload
(defun dm-tab-dwim ()
  "Smart TAB: advance Tempel field, expand snippet, indent, or insert tab."
  (interactive)
  (cond
   ((bound-and-true-p tempel--active)
    (tempel-next 1))
   ;; Blank or whitespace-only line: don't try Tempel.
   ((save-excursion
      (back-to-indentation)
      (eolp))
    (dm--indent-or-insert-tab))
   ;; After a plausible snippet trigger: try Tempel, then indent.
   ((looking-back "\\(?:\\sw\\|\\s_\\)+" (line-beginning-position))
    (or (tempel-expand t)
        (dm--indent-or-insert-tab)))
   (t
    (dm--indent-or-insert-tab))))

(defun dm--indent-or-insert-tab ()
  "Indent the current line, or insert a tab if indentation does nothing."
  (let ((point-before (point))
        (column-before (current-column)))
    (indent-for-tab-command)
    (when (and (= point-before (point))
               (= column-before (current-column)))
      (insert-tab))))

(use-package tempel
  :after evil
  :bind (:map tempel-map
         ("C-j" . tempel-next)
         ("C-k" . tempel-previous))
  :init
  (defun dm-tempel-setup-capf ()
    "Add Tempel template expansion before the mode's main CAPF."
    (setq-local completion-at-point-functions
                (cons #'tempel-expand completion-at-point-functions)))
  (add-hook 'conf-mode-hook #'dm-tempel-setup-capf)
  (add-hook 'prog-mode-hook #'dm-tempel-setup-capf)
  (add-hook 'text-mode-hook #'dm-tempel-setup-capf)
  ;; Bind tab to complete selectively in editable buffers.
  (defun dm-tab-dwim-setup ()
    (local-set-key (kbd "<tab>") #'dm-tab-dwim)
    (local-set-key (kbd "TAB")   #'dm-tab-dwim))
  (add-hook 'conf-mode-hook #'dm-tab-dwim-setup)
  (add-hook 'prog-mode-hook #'dm-tab-dwim-setup)
  (add-hook 'text-mode-hook #'dm-tab-dwim-setup))

(use-package tempel-collection
  :after tempel)

(use-package emmet-mode
  ;; Abbreviation expansion for HTML, CSS, JSX, and TSX buffers.
  :hook ((mhtml-mode   . emmet-mode)
         (html-mode    . emmet-mode)
         (html-ts-mode . emmet-mode)
         (css-mode     . emmet-mode)
         (css-ts-mode  . emmet-mode)
         (js-ts-mode   . emmet-mode)
         (tsx-ts-mode  . emmet-mode))
  :custom
  (emmet-move-cursor-between-quotes t)
  :config
  (keymap-set emmet-mode-keymap "TAB" #'emmet-expand-line)
  (keymap-set emmet-mode-keymap "<tab>" #'emmet-expand-line)
  (dolist (mode '(js-ts-mode tsx-ts-mode))
    (add-to-list 'emmet-jsx-major-modes mode)))

(provide 'dm-snippets)
;;; dm-snippets.el ends here
