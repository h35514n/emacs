;;; dm-repl --- Daymacs REPL feedback-loop helpers -*- lexical-binding: t; -*-

;;; Commentary:

;; Tight feedback-loop coding for Python, Elixir, Rust, JavaScript, and
;; TypeScript.
;;
;; Emacs packages are installed through straight.el/use-package when this
;; module is loaded:
;;
;; - pet: Python executable and virtualenv discovery.
;; - drepl, drepl-ipython, drepl-node: structured REPLs for Python and Node.
;; - code-cells: lightweight cell navigation and evaluation.
;; - inf-elixir: IEx process interaction.
;; - exunit: ExUnit compilation/test commands.
;;
;; External tools expected on PATH:
;;
;; - Python: python, ipython, pytest, basedpyright-langserver.
;;
;; - Elixir: elixir, mix, iex, and either expert, elixir-ls, or
;;   language_server.sh for Eglot.
;;
;; - Rust: cargo and rust-analyzer; evcxr or evcxr_repl is optional for REPL
;;   evaluation.
;;
;; - JavaScript/TypeScript: node and npm; tsx is optional for TypeScript REPL
;;   evaluation.  Project-local node_modules/.bin/tsx is preferred when it
;;   exists.
;;
;; - Formatting/linting remains handled by the main Daymacs Apheleia/Eglot
;;   setup and therefore still depends on the project formatters configured
;;   there, such as ruff, rustfmt, and prettier.

;;; Code:

(require 'comint)
(require 'compile)
(require 'project)
(require 'seq)
(require 'subr-x)

(defvar code-cells-mode)
(defvar drepl--current)
(defvar inf-elixir-switch-to-repl-on-send)

(defvar-local dm-repl-comint-buffer nil
  "Comint REPL buffer associated with the current source buffer.")

(defconst dm-repl-local-binding-hooks
  '(python-base-mode-hook
    elixir-mode-hook
    elixir-ts-mode-hook
    rust-mode-hook
    rust-ts-mode-hook
    js-mode-hook
    js-ts-mode-hook
    jsx-ts-mode-hook
    typescript-mode-hook
    typescript-ts-mode-hook
    tsx-ts-mode-hook)
  "Mode hooks that should receive Daymacs REPL local bindings.")

(defun dm-repl-project-root ()
  "Return the current project root, falling back to `default-directory'."
  (if-let* ((project (project-current nil)))
      (expand-file-name (project-root project))
    default-directory))

(defun dm-repl-project-executable (program)
  "Find PROGRAM, preferring a project-local Node executable."
  (or (when-let* ((root (dm-repl-project-root)))
        (let ((local (expand-file-name
                      (format "node_modules/.bin/%s" program)
                      root)))
          (when (file-executable-p local) local)))
      (executable-find program)))

(defun dm-repl--mode-p (&rest modes)
  "Return non-nil if the current buffer derives from any of MODES."
  (apply #'derived-mode-p modes))

(defun dm-drepl-buffer-live-p ()
  "Return non-nil when this buffer has a live dREPL association."
  (and (boundp 'drepl--current)
       (bufferp drepl--current)
       (buffer-live-p drepl--current)
       (comint-check-proc drepl--current)))

(defun dm-drepl-start (command &optional stay-in-source)
  "Start dREPL COMMAND and associate it with the current source buffer.
When STAY-IN-SOURCE is non-nil, restore the source window after starting."
  (require 'drepl)
  (let ((source-buffer (current-buffer))
        (source-window (selected-window)))
    (call-interactively command)
    (let ((repl-buffer (current-buffer)))
      (with-current-buffer source-buffer
        (setq-local drepl--current repl-buffer))
      (when (and stay-in-source (window-live-p source-window))
        (select-window source-window))
      repl-buffer)))

(defun dm-python-repl (&optional stay-in-source)
  "Start or pop to an IPython dREPL for the current project."
  (interactive)
  (require 'drepl-ipython)
  (dm-drepl-start #'drepl-ipython stay-in-source))

(defun dm-node-repl (&optional stay-in-source)
  "Start or pop to a Node.js dREPL for the current project."
  (interactive)
  (require 'drepl-node)
  (dm-drepl-start #'drepl-node stay-in-source))

(defun dm-drepl-ensure (starter)
  "Ensure the current buffer has a live dREPL, using STARTER if needed."
  (unless (dm-drepl-buffer-live-p)
    (funcall starter t)))

(defun dm-repl--comint-live-p (buffer)
  "Return non-nil when BUFFER has a live comint process."
  (and buffer
       (buffer-live-p buffer)
       (comint-check-proc buffer)))

(defun dm-repl--comint-start (display-name command &optional stay-in-source mode)
  "Start a project comint REPL.
DISPLAY-NAME names the buffer, COMMAND is a list of program and args, and
MODE is an optional major mode for the REPL buffer."
  (unless (and command (car command))
    (user-error "No command configured for %s" display-name))
  (let* ((source-buffer (current-buffer))
         (source-window (selected-window))
         (root (dm-repl-project-root))
         (default-directory root)
         (project-name (file-name-nondirectory
                        (directory-file-name root)))
         (buffer-name (format "%s/*%s*" project-name display-name))
         (buffer (get-buffer-create buffer-name)))
    (unless (dm-repl--comint-live-p buffer)
      (with-current-buffer buffer
        (setq-local default-directory root)
        (let ((inhibit-read-only t))
          (erase-buffer))
        (apply #'make-comint-in-buffer
               display-name buffer (car command) nil (cdr command))
        (if mode
            (funcall mode)
          (comint-mode))
        (setq-local list-buffers-directory root)))
    (with-current-buffer source-buffer
      (setq-local dm-repl-comint-buffer buffer))
    (unless stay-in-source
      (pop-to-buffer buffer))
    (when (and stay-in-source (window-live-p source-window))
      (select-window source-window))
    buffer))

(defun dm-typescript-repl (&optional stay-in-source)
  "Start or pop to a TypeScript REPL using tsx."
  (interactive)
  (dm-repl--comint-start
   "tsx" (list (dm-repl-project-executable "tsx")) stay-in-source))

(defun dm-rust-repl (&optional stay-in-source)
  "Start or pop to an evcxr Rust REPL."
  (interactive)
  (dm-repl--comint-start
   "evcxr" (list (or (executable-find "evcxr")
                     (executable-find "evcxr_repl")))
   stay-in-source))

(defun dm-repl--send-string-to-comint (buffer string)
  "Send STRING to the comint process in BUFFER."
  (unless (dm-repl--comint-live-p buffer)
    (user-error "No live REPL for this buffer"))
  (let ((proc (get-buffer-process buffer))
        (text (string-trim-right (substring-no-properties string))))
    (with-current-buffer buffer
      (goto-char (process-mark proc))
      (comint-send-string proc text)
      (comint-send-string proc "\n"))))

(defun dm-repl--send-region-to-comint (start end starter)
  "Send region START END to a comint REPL, starting it with STARTER if needed."
  (unless (dm-repl--comint-live-p dm-repl-comint-buffer)
    (funcall starter t))
  (dm-repl--send-string-to-comint
   dm-repl-comint-buffer
   (buffer-substring-no-properties start end)))

(defun dm-elixir-send-region (start end)
  "Send region START END to the project IEx buffer."
  (require 'inf-elixir)
  (let ((inf-elixir-switch-to-repl-on-send nil))
    (inf-elixir--send (buffer-substring-no-properties start end))))

(defun dm-typescript-send-region (start end)
  "Send region START END to the project TypeScript REPL."
  (dm-repl--send-region-to-comint start end #'dm-typescript-repl))

(defun dm-rust-send-region (start end)
  "Send region START END to the project Rust REPL."
  (dm-repl--send-region-to-comint start end #'dm-rust-repl))

(defun dm-python-start-or-pop ()
  "Start or pop to the current Python dREPL."
  (if (dm-drepl-buffer-live-p)
      (drepl-pop-to-repl nil)
    (dm-python-repl)))

(defun dm-node-start-or-pop ()
  "Start or pop to the current Node dREPL."
  (if (dm-drepl-buffer-live-p)
      (drepl-pop-to-repl nil)
    (dm-node-repl)))

(defun dm-elixir-start-or-pop ()
  "Start or pop to the current project IEx process."
  (require 'inf-elixir)
  (inf-elixir-project))

(defun dm-python-eval-region (start end)
  "Evaluate region START END in the current Python dREPL."
  (dm-drepl-ensure #'dm-python-repl)
  (drepl-eval-region start end))

(defun dm-node-eval-region (start end)
  "Evaluate region START END in the current Node dREPL."
  (dm-drepl-ensure #'dm-node-repl)
  (drepl-eval-region start end))

(defun dm-elixir-check ()
  "Compile the current Elixir project with warnings as errors."
  (let ((default-directory (dm-repl-project-root)))
    (compile "mix compile --warnings-as-errors")))

(defun dm-node-check ()
  "Run the JavaScript/TypeScript typecheck command."
  (let ((default-directory (dm-repl-project-root)))
    (compile "npm run typecheck")))

(defun dm-elixir-test-dwim ()
  "Run the nearest or current-buffer Elixir test."
  (require 'exunit)
  (if (and buffer-file-name (string-match-p "_test\\.exs\\'" buffer-file-name))
      (exunit-verify-single)
    (exunit-verify)))

(defun dm-elixir-test-all ()
  "Run all Elixir tests."
  (require 'exunit)
  (exunit-verify-all))

(defun dm-python-repl-setup ()
  "Enable Python REPL helpers in the current buffer."
  (when (fboundp 'pet-mode)
    (pet-mode 1)))

(defun dm-elixir-repl-setup ()
  "Enable Elixir REPL and test helpers in the current buffer."
  (when (fboundp 'inf-elixir-minor-mode)
    (inf-elixir-minor-mode 1))
  (when (fboundp 'exunit-mode)
    (exunit-mode 1)))

(defconst dm-repl-language-specs
  '((python
     :modes (python-base-mode python-mode python-ts-mode)
     :start-pop dm-python-start-or-pop
     :eval-region dm-python-eval-region
     :check dm-python-test-buffer
     :test dm-python-test-buffer
     :test-all dm-python-test-all
     :setup dm-python-repl-setup)
    (elixir
     :modes (elixir-mode elixir-ts-mode)
     :start-pop dm-elixir-start-or-pop
     :eval-region dm-elixir-send-region
     :check dm-elixir-check
     :test dm-elixir-test-dwim
     :test-all dm-elixir-test-all
     :setup dm-elixir-repl-setup)
    (rust
     :modes (rust-mode rust-ts-mode)
     :start-pop dm-rust-repl
     :eval-region dm-rust-send-region
     :check dm-rust-cargo-check
     :test dm-rust-cargo-test
     :test-all dm-rust-cargo-test)
    (typescript
     :modes (typescript-mode typescript-ts-mode tsx-ts-mode)
     :start-pop dm-typescript-repl
     :eval-region dm-typescript-send-region
     :check dm-node-check
     :test dm-node-test
     :test-all dm-node-test)
    (javascript
     :modes (js-mode js-ts-mode jsx-ts-mode)
     :start-pop dm-node-start-or-pop
     :eval-region dm-node-eval-region
     :check dm-node-check
     :test dm-node-test
     :test-all dm-node-test))
  "Language-specific REPL, eval, check, test, and setup commands.")

(defun dm-repl-language-spec ()
  "Return the current buffer's language spec, or nil."
  (seq-find
   (lambda (spec)
     (apply #'dm-repl--mode-p (plist-get (cdr spec) :modes)))
   dm-repl-language-specs))

(defun dm-repl-command (key error-message)
  "Return the current language command for KEY, or signal ERROR-MESSAGE."
  (if-let* ((spec (dm-repl-language-spec))
            (command (plist-get (cdr spec) key)))
      command
    (user-error error-message major-mode)))

(defun dm-pop-to-window-right ()
  "Select a right-side window, creating one if necessary."
  (let ((win (or (window-in-direction 'right)
                 (split-window-right))))
    (select-window win)))

;;;###autoload
(defun dm-repl-start-or-pop ()
  "Start or pop to the REPL appropriate for the current buffer."
  (interactive)
  (let ((command (dm-repl-command
                  :start-pop "No REPL configured for %s")))
    (dm-pop-to-window-right)
    (funcall command)))

;;;###autoload
(defun dm-repl-eval-region (start end)
  "Evaluate region START END in the language-appropriate REPL."
  (interactive "r")
  (funcall (dm-repl-command
            :eval-region "No eval command configured for %s")
           start end))

;;;###autoload
(defun dm-repl-eval-line ()
  "Evaluate the current line in the language-appropriate REPL."
  (interactive)
  (dm-repl-eval-region (line-beginning-position) (line-end-position)))

;;;###autoload
(defun dm-repl-eval-buffer ()
  "Evaluate the current buffer in the language-appropriate REPL."
  (interactive)
  (dm-repl-eval-region (point-min) (point-max)))

;;;###autoload
(defun dm-repl-eval-dwim ()
  "Evaluate active region, current code cell, or current line."
  (interactive)
  (cond
   ((use-region-p)
    (dm-repl-eval-region (region-beginning) (region-end)))
   ((bound-and-true-p code-cells-mode)
    (call-interactively #'code-cells-eval))
   (t
    (dm-repl-eval-line))))

;;;###autoload
(defun dm-repl-eval-cell ()
  "Evaluate the current code cell."
  (interactive)
  (require 'code-cells)
  (call-interactively #'code-cells-eval))

;;;###autoload
(defun dm-repl-next-cell ()
  "Move to the next code cell."
  (interactive)
  (require 'code-cells)
  (call-interactively #'code-cells-forward-cell))

;;;###autoload
(defun dm-repl-previous-cell ()
  "Move to the previous code cell."
  (interactive)
  (require 'code-cells)
  (call-interactively #'code-cells-backward-cell))

(defun dm-python-test-buffer ()
  "Run pytest for the current Python buffer."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let* ((default-directory (dm-repl-project-root))
         (python (or (bound-and-true-p python-shell-interpreter) "python"))
         (file (file-relative-name buffer-file-name default-directory)))
    (compile (format "%s -m pytest %s"
                     (shell-quote-argument python)
                     (shell-quote-argument file)))))

(defun dm-python-test-all ()
  "Run pytest for the current Python project."
  (interactive)
  (let ((default-directory (dm-repl-project-root))
        (python (or (bound-and-true-p python-shell-interpreter) "python")))
    (compile (format "%s -m pytest" (shell-quote-argument python)))))

(defun dm-rust-cargo-check ()
  "Run `cargo check' in the current project."
  (interactive)
  (let ((default-directory (dm-repl-project-root)))
    (compile "cargo check")))

(defun dm-rust-cargo-test ()
  "Run `cargo test' in the current project."
  (interactive)
  (let ((default-directory (dm-repl-project-root)))
    (compile "cargo test")))

(defun dm-node-test ()
  "Run `npm test' in the current project."
  (interactive)
  (let ((default-directory (dm-repl-project-root)))
    (unless (file-exists-p (expand-file-name "package.json" default-directory))
      (user-error "No package.json at project root"))
    (compile "npm test")))

;;;###autoload
(defun dm-repl-check-dwim ()
  "Run the fastest project check for the current language."
  (interactive)
  (funcall (dm-repl-command
            :check "No check command configured for %s")))

;;;###autoload
(defun dm-repl-test-dwim ()
  "Run the nearest or current-buffer test for the current language."
  (interactive)
  (funcall (dm-repl-command
            :test "No test command configured for %s")))

;;;###autoload
(defun dm-repl-test-all ()
  "Run all tests for the current language."
  (interactive)
  (funcall (dm-repl-command
            :test-all "No test command configured for %s")))

;;;###autoload
(defun dm-repl-local-keybindings ()
  "Install tight-loop local bindings and mode helpers in programming buffers."
  (local-set-key (kbd "C-c C-c") #'dm-repl-eval-dwim)
  (local-set-key (kbd "C-c C-b") #'dm-repl-eval-buffer)
  (local-set-key (kbd "C-c C-z") #'dm-repl-start-or-pop)
  (when-let* ((spec (dm-repl-language-spec))
              (setup (plist-get (cdr spec) :setup)))
    (funcall setup))
  (when (fboundp 'code-cells-mode-maybe)
    (code-cells-mode-maybe)))

(dolist (hook dm-repl-local-binding-hooks)
  (add-hook hook #'dm-repl-local-keybindings))

(use-package pet
  :commands (pet-mode pet-verify-setup))

(use-package drepl
  :commands (drepl-associate
             drepl-eval
             drepl-eval-region
             drepl-eval-buffer
             drepl-pop-to-repl
             drepl-restart)
  :custom
  (drepl-use-savehist-mode t))

(use-package drepl-ipython
  :straight nil
  :after drepl
  :commands (drepl-ipython))

(use-package drepl-node
  :straight nil
  :after drepl
  :commands (drepl-node))

(use-package code-cells
  :commands (code-cells-eval
             code-cells-forward-cell
             code-cells-backward-cell
             code-cells-eval-and-step
             code-cells-mode-maybe)
  :config
  (dolist (entry '((elixir-mode        . dm-elixir-send-region)
                   (elixir-ts-mode     . dm-elixir-send-region)
                   (typescript-mode    . dm-typescript-send-region)
                   (typescript-ts-mode . dm-typescript-send-region)
                   (tsx-ts-mode        . dm-typescript-send-region)
                   (rust-mode          . dm-rust-send-region)
                   (rust-ts-mode       . dm-rust-send-region)))
    (setf (alist-get (car entry) code-cells-eval-region-commands)
          (cdr entry))))

(use-package inf-elixir
  :commands (inf-elixir
             inf-elixir-minor-mode
             inf-elixir-project
             inf-elixir-send-buffer
             inf-elixir-send-line
             inf-elixir-send-region))

(use-package exunit
  :commands (exunit-mode
             exunit-verify
             exunit-verify-all
             exunit-verify-single))

(provide 'dm-repl)
;;; dm-repl.el ends here
