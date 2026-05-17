;;; dm-workspace.el --- Daymacs workspace persistence setup  -*- lexical-binding: t; -*-

;;; Commentary:

;; Scratch and tab/workspace persistence.

;;; Code:

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

(provide 'dm-workspace)
;;; dm-workspace.el ends here
