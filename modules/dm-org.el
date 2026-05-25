;;; dm-org.el --- Daymacs Org setup  -*- lexical-binding: t; -*-

;;; Commentary:

;; Org setup is kept together because its first-load cost is meaningful and the
;; Evil integration depends on Org's own load lifecycle.

;;; Code:

(defun dm-org-file (name)
  "Return the absolute path to the file in `org-directory' named NAME.org."
  (expand-file-name (format "%s.org" name) org-directory))

(use-package org
  ;; Use the ELPA version rather than the built-in one for up-to-date features.
  :straight t
  :hook ((org-mode . dm-disable-line-numbers-h))
  :custom
  ;; Skip the default `org-modules' cascade (ol-doi ol-w3m ol-bbdb ol-bibtex
  ;; ol-docview ol-gnus ol-info ol-irc ol-mhe ol-rmail ol-eww). Loading them
  ;; via `org-load-modules-maybe' on first org-mode activation accounted for
  ;; roughly half of the open cost. Add specific modules back here as needed.
  (org-modules nil)
  ;; ORG_HOME is set in env/emacs.sh; fall back to ~/Org.
  (org-directory (or (getenv "ORG_HOME") (expand-file-name "~/Org")))
  (org-default-notes-file (dm-org-file "inbox"))
  (org-agenda-files (expand-file-name ".agenda-files.el" org-directory))
  ;; Visual preferences.
  (org-startup-indented t)
  (org-hide-leading-stars t)
  (org-ellipsis " ▾")
  ;; Capture and logging.
  (org-log-done 'time)
  (org-log-into-drawer t)
  ;; package-specific settings
  (org-latex-packages-alist '(("" "tikz") ("" "amssymb") ("" "amssymb")))
  (ob-mermaid-cli-path "mmdc")
  :config
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((python . t))))

(use-package evil-org
  ;; Evil keybindings for org: heading navigation, table editing, agenda.
  :after (evil org)
  :hook (org-mode . evil-org-mode)
  :config
  ;; Agenda bindings only matter once `org-agenda' loads, which happens on
  ;; first `M-x org-agenda'. Don't pull in evil-org-agenda before then.
  (with-eval-after-load 'org-agenda
    (require 'evil-org-agenda)
    (evil-org-agenda-set-keys)))

;;; ————————————————————————————
;;; Org agenda custom commands
;;; ————————————————————————————

(with-eval-after-load 'org-agenda
  (add-to-list
   'org-agenda-custom-commands
   '("W" "Completed tasks in past week"
     ((agenda ""
              ((org-agenda-span 7)
               (org-agenda-start-day "-7d")
               (org-agenda-log-mode-items '(closed clock state))
               (org-agenda-skip-function
                '(org-agenda-skip-entry-if 'notregexp "CLOSED:"))))))))


;;; ————————————————————————————
;;; Org agenda cycling
;;; ————————————————————————————

(defvar dm-org-agenda-cycle--current-file nil
  "Truename of the last agenda file visited by `dm-org-agenda-cycle-files'.")

(defun dm-org-agenda-cycle--file-truenames ()
  "Return a cons of (ORIGINALS . TRUENAMES) for `org-agenda-files' (existing only)."
  (let* ((orig (or (org-agenda-files t)
                   (user-error "No agenda files")))
         (tns  (mapcar #'file-truename orig)))
    (cons orig tns)))

;;;###autoload
(defun dm-org-agenda-cycle-files (&optional arg)
  "Cycle through `org-agenda-files'. Positive ARG moves forward, negative moves backward.

If called from outside an agenda file, jump to `org-default-notes-file' if
present in the list (case-insensitive basename match), otherwise the first
agenda file. Do not advance past that file on this initial jump. From within an
agenda file, cycle as usual by one step in the chosen direction."
  (interactive "p")
  (pcase-let* ((`(,orig . ,tns) (dm-org-agenda-cycle--file-truenames))
               (len (length tns))
               (step (if (and arg (< arg 0)) -1 1))
               (cur  (and buffer-file-name (file-truename buffer-file-name)))
               (in-agenda? (and cur (member cur tns)))
               ;; Find index of a basename exactly equal to that of
               ;; `org-default-notes-file' or "inbox.org" (case-insensitive)
               (todo-file (file-name-nondirectory (or org-default-notes-file "inbox.org")))
               (todo-idx (cl-position todo-file orig :test
                                      (lambda (needle f)
                                        (string= needle (downcase (file-name-nondirectory f))))))
               (start-idx
                (cond
                 (in-agenda?
                  (cl-position cur tns :test #'string=))
                 ((integerp todo-idx)
                  todo-idx)
                 (t 0)))  ;; first file
               ;; If we're outside an agenda file, don't offset; otherwise do the ±1 step
               (next-idx (if in-agenda?
                             (mod (+ start-idx step) len)
                           start-idx))
               (target    (nth next-idx orig))
               (target-tn (nth next-idx tns)))
    (find-file target)
    (setq dm-org-agenda-cycle--current-file target-tn)
    (when (buffer-base-buffer)
      (pop-to-buffer-same-window (buffer-base-buffer)))))

;;;###autoload
(defun dm-org-agenda-cycle-next ()
  "Cycle forward through `org-agenda-files'."
  (interactive)
  (dm-org-agenda-cycle-files +1))

;;;###autoload
(defun dm-org-agenda-cycle-prev ()
  "Cycle backward through `org-agenda-files'."
  (interactive)
  (dm-org-agenda-cycle-files -1))

(provide 'dm-org)
;;; dm-org.el ends here
