;;; init.el --- -*- lexical-binding: t; -*-

;;; Commentary:

;; A bare-metal Emacs config.

;;; Code:

(require 'dm-paths)
(require 'dm-util)

(require 'dm-straight)
(require 'dm-autoload)

;; Eager, cross-cutting setup lives in cohesive modules;
;; Command-only helpers use autoload cookies and stay out of the startup path.
(require 'dm-session)
(require 'dm-core)
(require 'dm-ui)
(require 'dm-evil)
(require 'dm-window)
(require 'dm-completion)
(require 'dm-editing)
(require 'dm-workspace)
(require 'dm-help)
(require 'dm-format)
(require 'dm-capf)
(require 'dm-snippets)
(require 'dm-files)
(require 'dm-repl)
(require 'dm-env)
(require 'dm-vcs)
(require 'dm-ai)
(require 'dm-apps)
(require 'dm-terminal)
(require 'dm-org)
(require 'dm-org-hugo)
(require 'dm-org-capture)
(require 'dm-org-repeat-days)
(require 'dm-org-agenda-capacity)
(require 'dm-langs)
(require 'dm-keys)

(when (dm-util-daemon-is-tty-p)
  (require 'dm-tty))

(message (emacs-init-time "%.3fs"))

(provide 'init)
;;; init.el ends here
