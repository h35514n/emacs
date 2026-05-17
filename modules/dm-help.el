;;; dm-help.el --- Daymacs help buffers and lookup commands  -*- lexical-binding: t; -*-

;;; Commentary:

;; Helpful command autoloads. Global help key policy lives in `dm-keys', while
;; Evil lookup bindings live in `dm-evil'.

;;; Code:

(use-package helpful
  :commands (helpful-at-point
             helpful-callable
             helpful-command
             helpful-function
             helpful-key
             helpful-symbol
             helpful-variable))

(provide 'dm-help)
;;; dm-help.el ends here
