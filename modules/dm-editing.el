;;; dm-editing.el --- Daymacs buffer editing tools  -*- lexical-binding: t; -*-

;;; Commentary:

;; Buffer-local editing ergonomics: scratch/workspace behavior, formatting,
;; completion-at-point, snippets, web helpers, and simple folding fallback.
;; Language-server and tree-sitter setup live elsewhere.
;; TODO: Move `dm-text-*' to with dm-text

;;; Code:

;; Global super-key text formatting. The underlying commands pcase on
;; `major-mode' so a single global binding works in every supported buffer.
(keymap-global-set "s-b" #'dm-text-make-bold)
(keymap-global-set "s-i" #'dm-text-make-italic)
(keymap-global-set "s-u" #'dm-text-make-underlined)
(keymap-global-set "s-X" #'dm-text-make-strikethrough)

(defun dm-text-latex-keybindings ()
  "Bind LaTeX-formatting commands in the current buffer.
Bind under `C-c m' (math/markup) so we don't shadow motion: meow's
`meow-left'/`meow-right' dispatch through `C-b'/`C-f' via
`meow--execute-kbd-macro', so binding wraps directly on those keys
would hijack basic motion."
  (local-set-key (kbd "C-c m b") #'dm-text-latex-wrap-as-boxed)
  (local-set-key (kbd "C-c m f") #'dm-text-latex-wrap-as-frac)
  (local-set-key (kbd "C-c m e") #'dm-text-latex-evaluate-selection)
  (local-set-key (kbd "C-c m m") #'dm-text-latex-wrap-as-math)
  (local-set-key (kbd "C-c m s") #'dm-text-latex-wrap-as-si))

(dolist (hook '(LaTeX-mode-hook latex-mode-hook))
  (add-hook hook #'dm-text-latex-keybindings))

(use-package persistent-scratch
  :ensure t
  :hook (emacs-startup . persistent-scratch-setup-default))

(use-package tabspaces
  :hook (emacs-startup . tabspaces-mode)
  :custom
  (tabspaces-use-filtered-buffers-as-default t)
  (tabspaces-default-tab "main")
  (tabspaces-remove-to-default t)
  (tabspaces-include-buffers '("*scratch*")))

;; Filter `consult-buffer' to show only current-workspace buffers. The nested
;; `with-eval-after-load' keeps Consult/Tabspaces internals off the boot path.
(with-eval-after-load 'consult
  (with-eval-after-load 'tabspaces
    (consult-customize consult-source-buffer :hidden t :default nil)
    ;; Hide file-loading sources from default consult-buffer view; still
    ;; accessible by narrowing (r recent, p project, m bookmarks).
    (consult-customize
     consult-source-project-recent-file
     consult-source-project-recent-file-hidden
     :hidden t)
    (defvar consult-source-workspace
      (list :name     "Workspace buffers"
            :narrow   ?w
            :history  'buffer-name-history
            :category 'buffer
            :state    #'consult--buffer-state
            :default  t
            :items    (lambda ()
                        (consult--buffer-query
                         :predicate #'tabspaces--local-buffer-p
                         :sort 'visibility
                         :as #'buffer-name))))
    (add-to-list 'consult-buffer-sources 'consult-source-workspace)))

(use-package dired
  :straight nil
  :hook ((dired-mode . dired-hide-details-mode))
  :custom
  (dired-listing-switches "-Ah --group-directories-first")
  :config
  ;; Override dired's default `negative-argument' on `-' so it goes up a
  ;; directory. This works in meow motion state because `dired-mode-map'
  ;; passes through letters that meow doesn't claim.
  (keymap-set dired-mode-map "-" #'dired-up-directory))

;; `dired-jump' (globally, via meow normal state) is wired up in `dm-meow.el'.

(use-package visual-fill-column
  :hook ((markdown-mode . visual-line-mode)
         (markdown-mode . visual-fill-column-mode))
  :custom
  (visual-fill-column-width 80))

(use-package markdown-mode
  :hook ((markdown-mode . outline-minor-mode)
         (markdown-mode . dm-disable-line-numbers-h)
         (gfm-mode . outline-minor-mode)
         (gfm-mode . dm-disable-line-numbers-h))
  :mode (("\\.md\\'" . gfm-mode)
         ("\\.markdown\\'" . gfm-mode)))

(use-package helpful
  :commands (helpful-at-point
             helpful-callable
             helpful-command
             helpful-function
             helpful-key
             helpful-symbol
             helpful-variable)
  :config
  (keymap-global-set "C-h f" #'helpful-callable)
  (keymap-global-set "C-h v" #'helpful-variable)
  (keymap-global-set "C-h k" #'helpful-key)
  (keymap-global-set "C-h x" #'helpful-command)
  ;; `helpful-mode' lives in meow motion state so single-key bindings in its
  ;; own map pass through unhindered.
  (keymap-set helpful-mode-map "K" #'helpful-at-point))

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

(use-package corfu
  ;; Popup at point for in-buffer completions. Pairs with Eglot and Cape.
  ;; Loaded on demand by editable buffers instead of at startup.
  :hook ((prog-mode . corfu-mode)
         (text-mode . corfu-mode)
         (conf-mode . corfu-mode))
  :custom
  (corfu-auto t)
  (corfu-auto-delay 0.1)
  (corfu-cycle t)
  (corfu-separator ?\s)
  (corfu-quit-at-boundary nil)
  (corfu-quit-no-match nil)
  (corfu-preview-current nil)
  :config
  ;; Keep completion acceptance on Enter so TAB remains available for snippets.
  (keymap-set corfu-map "RET" #'corfu-insert)
  (keymap-set corfu-map "<return>" #'corfu-insert)
  (keymap-unset corfu-map "TAB")
  (keymap-unset corfu-map "<tab>"))

(use-package cape
  ;; Extra completion-at-point sources: dabbrev, file paths, etc.
  :after corfu
  :config
  (defun dm-cape-dabbrev ()
    "Run `cape-dabbrev' as a quiet optional CAPF."
    (cape-wrap-silent #'cape-dabbrev))

  (add-hook 'completion-at-point-functions #'dm-cape-dabbrev)
  (add-hook 'completion-at-point-functions #'cape-file))

;;;###autoload
(defun dm-tab-dwim ()
  "Smart TAB: advance Tempel field, expand snippet, or indent."
  (interactive)
  (cond
   ((bound-and-true-p tempel--active) (tempel-next 1))
   ((tempel-expand t))
   (t (indent-for-tab-command))))

(use-package tempel
  :bind (:map tempel-map
         ("C-j" . tempel-next)
         ("C-k" . tempel-previous))
  :init
  ;; Global insert binding for explicit expansion (was bound in insert state
  ;; under evil; now plain global so it works whenever you're typing).
  (keymap-global-set "C-." #'tempel-insert)
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

(use-package hideshow
  ;; Sexp-based folding fallback for elisp buffers, where tree-sitter doesn't
  ;; always supply `treesit-fold-mode'.
  :straight nil
  :hook ((emacs-lisp-mode . hs-minor-mode)
         (lisp-interaction-mode . hs-minor-mode)))

(use-package iedit
  :commands iedit-mode)

;; Mode-local elisp DWIM evaluator. `dm-lisp-eval-sexp-dwim' is autoloaded
;; from `dm-lisp.el'; binding here ensures the elisp-mode keymap is wired
;; on first use (also reachable via `SPC c e' through meow's keypad).
(with-eval-after-load 'elisp-mode
  (keymap-set emacs-lisp-mode-map       "C-c C-e" #'dm-lisp-eval-sexp-dwim)
  (keymap-set lisp-interaction-mode-map "C-c C-e" #'dm-lisp-eval-sexp-dwim))

(provide 'dm-editing)
;;; dm-editing.el ends here
