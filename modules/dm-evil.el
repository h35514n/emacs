;;; dm-evil.el --- Daymacs Evil setup  -*- lexical-binding: t; -*-

;;; Commentary:

;; Vim-style editing packages and the key policy that needs Evil state maps.
;; Package-local maps still live with their package modules when the binding is
;; part of that package's behavior.

;;; Code:

(use-package evil
  :init
  ;; These must be set before evil loads.
  (setq evil-echo-state nil)
  (setq evil-respect-visual-line-mode t) ; j/k act like gj/gk when VL mode enabled
  (setq evil-split-window-below  t)
  (setq evil-undo-system 'undo-redo) ; use native Emacs 28+ undo/redo
  (setq evil-vsplit-window-right t)
  (setq evil-want-C-u-scroll nil)
  (setq evil-want-integration t)
  (setq evil-want-keybinding nil)    ; evil-collection provides these instead
  :config
  (evil-mode 1)
  (dm-evil-text-setup)
  (evil-define-command dm-evil-toggle-test-implementation ()
    "Toggle between implementation and test file."
    :repeat nil
    (dm-toggle-test-implementation))
  (evil-ex-define-cmd "A" #'dm-evil-toggle-test-implementation)
  ;; Let the main readline-style keys fall through to the global map in insert
  ;; state. C-k/C-t/C-y keep their Evil insert-state meanings.
  (dolist (key '("C-a" "C-e" "C-b" "C-f" "C-n" "C-p" "C-d"))
    (define-key evil-insert-state-map (kbd key) nil))
  ;; Global normal-state vocabulary.
  (evil-define-key 'normal 'global
    (kbd "-")   #'dired-jump
    (kbd "gQ")  #'evil-unfill
    (kbd "g-")  #'evil-numbers/dec-at-pt
    (kbd "g=")  #'evil-numbers/inc-at-pt
    (kbd "[b")  #'evil-prev-buffer
    (kbd "]b")  #'evil-next-buffer
    (kbd "[e")  #'flymake-goto-prev-error
    (kbd "]e")  #'flymake-goto-next-error
    (kbd "[h")  #'diff-hl-show-hunk-previous
    (kbd "]h")  #'diff-hl-show-hunk-next
    (kbd "[t")  #'tab-bar-switch-to-prev-tab
    (kbd "]t")  #'tab-bar-switch-to-next-tab)
  (evil-define-key 'normal emacs-lisp-mode-map
    (kbd "K")   #'helpful-at-point
    (kbd "g e") #'dm-evil-eval-sexp-dwim)
  (evil-define-key 'visual emacs-lisp-mode-map
    (kbd "g e") #'dm-evil-eval-sexp-dwim)
  (evil-define-key 'normal lisp-interaction-mode-map
    (kbd "K") #'helpful-at-point)
  (evil-define-key 'insert 'global
    (kbd "C-.") #'tempel-insert)
  (with-eval-after-load 'eglot
    (evil-define-key 'normal eglot-mode-map
      (kbd "K") #'eldoc-print-current-symbol-info))
  (with-eval-after-load 'helpful
    (evil-define-key 'normal helpful-mode-map
      (kbd "K") #'helpful-at-point)))

(use-package evil-collection
  ;; Provides sensible evil keybindings for magit, dired, help, ibuffer, etc.
  ;; Must load after evil.
  :after evil
  :defer 0.3
  :init
  (setq evil-collection-mode-list
        '(
          consult
          corfu
          diff-hl
          diff-mode
          dired
          eat
          ediff
          eglot
          elisp-mode
          embark
          flymake
          git-timemachine
          helpful
          hideshow
          ibuffer
          imenu
          magit-repos
          magit-section
          magit-todos
          (magit magit-submodule)
          markdown-mode
          org
          vertico
          which-key
          xwidget
          )
          ;; -- rejected --
          ;; minibuffer
        )
    (setq evil-collection-calendar-want-org-bindings  nil)
    (setq evil-collection-setup-debugger-keys         nil)
    (setq evil-collection-want-find-usages-bindings   nil)
    (setq evil-collection-want-unimpaired-p           nil)
    (setq evil-collection-state-denylist              nil)
    (setq evil-collection-state-passlist              nil)
    (setq evil-collection-key-blacklist               nil)
    (setq evil-collection-key-whitelist               nil)
    ;; disabled: induces hitting ESC in normal mode and accidentally quitting
    (setq evil-collection-setup-minibuffer            nil)
  :config
  (evil-collection-init))

(use-package evil-commentary
  :after evil
  :config (evil-commentary-mode))

(use-package evil-numbers
  :after evil
  :commands (evil-numbers/dec-at-pt evil-numbers/inc-at-pt))

(use-package evil-surround
  :after evil
  :config
  (global-evil-surround-mode 1))

(use-package evil-iedit-state
  :commands (evil-iedit-state/iedit-mode evil-iedit-state)
  :custom (iedit-toggle-key-default nil))

(use-package avy
  :commands (avy-goto-char-2 avy-goto-char avy-goto-line avy-goto-word-1
             avy-setup-default)
  :hook (org-mode . avy-setup-default)
  :custom
  (avy-keys '(?a ?s ?d ?f ?g ?h ?j ?k ?l))
  (avy-style 'at-full))

(use-package evil-lion
  :after evil
  :defer 0.5
  :init
  (setq evil-lion-left-align-key (kbd "g l"))
  (setq evil-lion-right-align-key (kbd "g L"))
  :config
  (evil-lion-mode 1))

(use-package evil-visualstar
  :after evil
  :config
  (global-evil-visualstar-mode))

(provide 'dm-evil)
;;; dm-evil.el ends here
