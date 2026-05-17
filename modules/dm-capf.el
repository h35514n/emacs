;;; dm-capf.el --- Daymacs in-buffer completion setup  -*- lexical-binding: t; -*-

;;; Commentary:

;; Corfu popup completion and Cape completion-at-point sources.

;;; Code:

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

(provide 'dm-capf)
;;; dm-capf.el ends here
