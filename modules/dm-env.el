;;; dm-env.el --- Daymacs environment import  -*- lexical-binding: t; -*-

;;; Commentary:

;; Import the shell environment before downstream modules use it to set paths.

;;; Code:

(use-package exec-path-from-shell
  :if (memq window-system '(mac ns x))
  :demand t
  :custom
  ;; Login-only: the vars come from zshenv; `-i' would run the slow zshrc.
  (exec-path-from-shell-arguments '("-l"))
  (exec-path-from-shell-variables
   '(
     "CARGO_HOME"
     "DOCKER_HOST"
     "GIT_CG_PROVIDER"
     "GOPATH"
     "HEX_HOME"
     "HOMEBREW_PREFIX"
     "IPYTHONDIR"
     "MANPATH"
     "MISE_DIR"
     "OLLAMA_API_KEY"
     "OPENAI_API_KEY"
     "OPENAI_API_KEY_GIT"
     "ORG_HOME"
     "PATH"
     "PERL_CPANM_HOME"
     "PNPM_HOME"
     "RUSTUP_HOME"
     "XDG_CACHE_HOME"
     "XDG_CONFIG_DIRS"
     "XDG_CONFIG_HOME"
     "XDG_DATA_HOME"
     "XDG_LOCALS_DIR"
     "XDG_RUNTIME_DIR"
     "XDG_SECURE_DIR"
     "XDG_STATE_HOME"))
  :config
  (exec-path-from-shell-initialize))

(provide 'dm-env)
;;; dm-env.el ends here
