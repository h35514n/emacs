;;; dm-apps.el --- Emacs app integrations  -*- lexical-binding: t; -*-

;;; Commentary:

;; Application setup

;;; Code:

(use-package restclient
  :defer 0.5
  :config
  (add-to-list 'auto-mode-alist '("\\.http\\'" . restclient-mode)))

(provide 'dm-apps)
;;; dm-apps.el ends here
