;;; dm-ui.el --- Daymacs visual and display setup  -*- lexical-binding: t; -*-

;;; Commentary:

;; Display behavior that should be installed eagerly, plus small visual helper
;; commands that are safe to autoload from keybindings.

;;; Code:

(defun dm-disable-line-numbers-h ()
  "Disable line numbers in the current buffer."
  (display-line-numbers-mode -1))

(defcustom dm-visual-fill-column-extra-width 5
  "Extra visual columns used when enabling visual wrapping.

`visual-fill-column-width' is specified in columns, but Emacs
ultimately wraps displayed text according to rendered pixel width.
Depending on font metrics, scaling, ligatures, and word-boundary
wrapping, an 80-column visual fill area may wrap slightly before
80 logical buffer columns.  This value adds a small cushion so
visual wrapping more closely matches the intended `fill-column'."
  :type 'integer)

;;;###autoload
(defun dm-wrapping-enable ()
  "Enable visual wrapping in the current buffer.
Prose buffers delegate to `olivetti-mode'; other buffers use
`visual-line-mode' with `visual-fill-column-mode'."
  (interactive)
  (setq-local word-wrap t)
  (setq-local truncate-lines nil)
  (cond
   ((derived-mode-p 'text-mode 'org-mode)
    (when (fboundp 'olivetti-mode)
      (olivetti-mode 1)))
   (t
    (setq-local visual-fill-column-width
                (+ fill-column dm-visual-fill-column-extra-width))
    (setq-local visual-fill-column-center-text nil)
    (visual-line-mode 1)
    (when (fboundp 'visual-fill-column-mode)
      (visual-fill-column-mode 1)
      (visual-fill-column-adjust))))
  (when (called-interactively-p 'any) (recenter)))

;;;###autoload
(defun dm-wrapping-disable ()
  "Disable visual wrapping in the current buffer.
Also turns off `olivetti-mode' when active, so centering does not
persist alongside truncated lines."
  (interactive)
  (when (bound-and-true-p olivetti-mode)
    (olivetti-mode -1))
  (visual-line-mode -1)
  (when (fboundp 'visual-fill-column-mode)
    (visual-fill-column-mode -1))
  (setq-local word-wrap nil)
  (setq-local truncate-lines t)
  (when (called-interactively-p 'any) (recenter)))

;;;###autoload
(defun dm-wrapping-toggle ()
  "Toggle visual line wrapping in the current buffer."
  (interactive)
  (if (or (bound-and-true-p visual-line-mode)
          (bound-and-true-p olivetti-mode))
      (dm-wrapping-disable)
    (dm-wrapping-enable)))

;; Code buffers default to soft-wrap at `fill-column' so long lines do not
;; silently cut off at the window edge. The toggle still flips them to
;; truncated on demand.
(add-hook 'prog-mode-hook #'dm-wrapping-enable)

(with-eval-after-load 'evil
  (evil-define-operator evil-unfill (beg end type)
    "Unfill text in motion/selection."
    :move-point nil
    (let ((fill-column most-positive-fixnum))
      (fill-region beg end))))

(defun dm-frame-title-project-or-buffer ()
  "Show project name in title bar, falling back to buffer name."
  (if-let* ((proj (project-current)))
      (project-name proj)
    (buffer-name)))

;;; Core display behavior.

;; Relative line numbers match evil's jump-count workflow (e.g. 5j, 12k).
(setq display-line-numbers-type 'relative)
(global-display-line-numbers-mode 1)

;; Highlight matching parens immediately.
(setq show-paren-delay 0)
(show-paren-mode 1)

;; Single space after sentences affects fill-paragraph.
(setq sentence-end-double-space nil)

;; Silence the audible bell entirely.
(setq ring-bell-function #'ignore)

;; Show project name in title bar, falling back to buffer name.
(setq frame-title-format
      '((:eval
         (dm-frame-title-project-or-buffer))))

;; Display column number in the modeline.
(column-number-mode)

;; Slightly wider fringe so the truncation arrow has room to render.
(fringe-mode 10)

;;; Package-backed appearance.

(set-face-attribute 'default nil :family "Source Code Pro Ligaturized" :height 170)

(use-package gruvbox-theme
  :config
  (load-theme 'gruvbox-dark-medium t)
  ;; Gruvbox tints the line-number gutter lighter than the buffer body; match
  ;; the body so the gutter blends in.
  (set-face-attribute 'line-number nil
                      :background (face-attribute 'default :background))
  (set-face-attribute 'line-number-current-line nil
                      :background (face-attribute 'default :background))
  ;; Without this the truncation arrow inherits the gruvbox fringe color and
  ;; reads as background; borrow the keyword color for contrast.
  (set-face-attribute 'fringe nil
                      :foreground (face-attribute 'font-lock-keyword-face
                                                  :foreground)))

(use-package mood-line
  :config
  (setq mood-line-glyph-alist mood-line-glyphs-fira-code)
  (setq mood-line-segment-modal-evil-state-alist
        '((normal   "N")
          (insert   "I" . font-lock-string-face)
          (visual   "V" . font-lock-keyword-face)
          (replace  "R" . font-lock-type-face)
          (motion   "M" . font-lock-constant-face)
          (operator "O" . font-lock-function-name-face)
          (emacs    "E" . font-lock-builtin-face)))
  ;; Segments:
  ;;   * init.el  4:32 Top                                         ELisp  ! Issues: 2
  ;; (setq mood-line-format mood-line-format-default)
  ;;   * init.el  4:32:52 Top                    SPCx2  LF  UTF-8  ELisp  ! Issues: 2
  ;; (setq mood-line-format mood-line-format-default-extended)
  ;;   * init.el : ELisp                                         4:32    ! Issues: 2
  (setq mood-line-format
        (mood-line-defformat
         :left (
                ((mood-line-segment-modal)            . " ")
                ((or (mood-line-segment-buffer-status)
                     (mood-line-segment-client)
                     " ")                             . " ")
                ((mood-line-segment-project)          . "/")
                ((mood-line-segment-buffer-name)      . "  ")
                (mood-line-segment-cursor-position)
                (when (fboundp 'dm-wc-mode-line-segment)
                  (when-let* ((segment (dm-wc-mode-line-segment)))
                    (concat " " segment)))
                (when (mood-line-segment-region)
                  #(" " 0 1 (face mood-line-unimportant)))
                ((mood-line-segment-region)           . " ")
                )
         :right (
                 ((mood-line-segment-vc)          . "  ")
                 ((mood-line-segment-major-mode)  . "  ")
                 ((mood-line-segment-misc-info)   . "  ")
                 ((mood-line-segment-checker)     . "  ")
                 ((mood-line-segment-process)     . "  ")
                 )))
  (mood-line-mode))

  (provide 'dm-ui)
;;; dm-ui.el ends here
