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
  :after general
  :preface
  (defvar wc-mode)
  (defvar wc-orig-lines)
  (defvar wc-orig-words)
  (defvar wc-orig-chars)
  (defvar wc-lines-delta)
  (defvar wc-words-delta)
  (defvar wc-chars-delta)
  (defvar wc-line-goal)
  (defvar wc-word-goal)
  (defvar wc-char-goal)

  (defvar-local dm-wc-mode-line-display 'word
    "Statistic displayed by wc-mode's mode-line segment.
The value is one of `word', `char', `line', or `all'.")

  (defun dm-wc-mode-line--stat (original delta goal &optional prefix)
    "Format one wc-mode statistic from ORIGINAL, DELTA, and GOAL.
PREFIX is prepended to the statistic.  GOAL is a change goal relative to
ORIGINAL; when present, display its absolute target and highlight the
statistic once DELTA reaches it."
    (let* ((count (+ original delta))
           (target (and (numberp goal) (+ original goal)))
           (text (concat (or prefix "")
                         (if target
                             (format "%d/%d" count target)
                           (number-to-string count))))
           (goal-reached (and target
                              (if (< goal 0)
                                  (<= delta goal)
                                (>= delta goal)))))
      (if goal-reached
          (propertize text 'face 'wc-goal-face)
        text)))

  (defun dm-wc-mode-line-segment ()
    "Show wc-mode's counts and optional absolute goals."
    (when (and (bound-and-true-p wc-mode)
               (numberp wc-orig-lines)
               (numberp wc-orig-words)
               (numberp wc-orig-chars)
               (numberp wc-lines-delta)
               (numberp wc-words-delta)
               (numberp wc-chars-delta))
      (pcase dm-wc-mode-line-display
        ('all
         (mapconcat #'identity
                    (list
                     (dm-wc-mode-line--stat
                      wc-orig-lines wc-lines-delta wc-line-goal)
                     (dm-wc-mode-line--stat
                      wc-orig-words wc-words-delta wc-word-goal)
                     (dm-wc-mode-line--stat
                      wc-orig-chars wc-chars-delta wc-char-goal))
                    ":"))
        ('line
         (dm-wc-mode-line--stat
          wc-orig-lines wc-lines-delta wc-line-goal "L"))
        ('char
         (dm-wc-mode-line--stat
          wc-orig-chars wc-chars-delta wc-char-goal "C"))
        (_
         (dm-wc-mode-line--stat
          wc-orig-words wc-words-delta wc-word-goal "W")))))

  (defun dm-wc-mode-line-show (display)
    "Show DISPLAY statistics in wc-mode's mode-line segment."
    (setq dm-wc-mode-line-display display)
    (force-mode-line-update)
    (message "wc-mode line display: %s" display))

  (defun dm-wc-mode-line-show-all ()
    "Show line, word, and character counts in the mode line."
    (interactive)
    (dm-wc-mode-line-show 'all))

  (defun dm-wc-mode-line-show-words ()
    "Show the word count in the mode line."
    (interactive)
    (dm-wc-mode-line-show 'word))

  (defun dm-wc-mode-line-show-chars ()
    "Show the character count in the mode line."
    (interactive)
    (dm-wc-mode-line-show 'char))

  (defun dm-wc-mode-line-show-lines ()
    "Show the line count in the mode line."
    (interactive)
    (dm-wc-mode-line-show 'line))
  :config
  (general-define-key
   :keymaps 'wc-mode-map
   "C-c C-w" '(:prefix-command dm-wc-mode-prefix-command
                :prefix-map dm-wc-mode-prefix-map
                :which-key "word count"))
  (general-define-key
   :keymaps 'dm-wc-mode-prefix-map
   "a" '(dm-wc-mode-line-show-all   :which-key "show all counts")
   "w" '(dm-wc-mode-line-show-words :which-key "show word count")
   "c" '(dm-wc-mode-line-show-chars :which-key "show char count")
   "l" '(dm-wc-mode-line-show-lines :which-key "show line count")
   "W" '(wc-set-word-goal           :which-key "set word goal")
   "C" '(wc-set-char-goal           :which-key "set char goal")
   "L" '(wc-set-line-goal           :which-key "set line goal"))
  :hook ((text-mode . wc-mode)))

(provide 'dm-editing)
;;; dm-editing.el ends here
