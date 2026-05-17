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
  (org-default-notes-file (dm-org-file "notes"))
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
  (ob-mermaid-cli-path "mmdc"))

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
;;; ox-hugo
;;; ————————————————————————————
;; ox-hugo exports hugo blog content from org
(use-package ox-hugo
  :straight t
  :after ox
  :custom
  (org-hugo-export-with-section-numbers nil)
  (org-hugo-export-with-toc nil))

(defun dm-org-hugo-export-all (&optional dir)
  "Export every Hugo-ready subtree in all .org files under DIR."
  (let ((dir    (expand-file-name (or dir default-directory)))
        (files  (directory-files-recursively dir "\\.org$")))
    (dolist (f files)
      (with-temp-buffer
        (insert-file-contents f)
        (org-mode)
        (message "→ %s" f)
        (org-element-map (org-element-parse-buffer) 'headline
          (lambda (hl)
            (when (org-element-property :EXPORT_DATE hl)
              (goto-char (org-element-property :begin hl))
              (org-hugo-export-wim-to-md t))))))))


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

(defvar dm-org--cycle-agenda--current-file nil
  "Truename of the last agenda file visited by `dm-org--cycle-agenda-files'.")

(defun dm-org--cycle-agenda--file-truenames ()
  "Return a cons of (ORIGINALS . TRUENAMES) for `org-agenda-files' (existing only)."
  (let* ((orig (or (org-agenda-files t)
                   (user-error "No agenda files")))
         (tns  (mapcar #'file-truename orig)))
    (cons orig tns)))

(defun dm-org--cycle-agenda-files (&optional arg)
  "Cycle through `org-agenda-files'. Positive ARG moves forward, negative moves backward.

If called from outside an agenda file, jump to `todo.org` if present in the list
(case-insensitive basename match), otherwise the first agenda file. Do not
advance past that file on this initial jump. From within an agenda file, cycle
as usual by one step in the chosen direction."
  (interactive "p")
  (pcase-let* ((`(,orig . ,tns) (dm-org--cycle-agenda--file-truenames))
               (len (length tns))
               (step (if (and arg (< arg 0)) -1 1))
               (cur  (and buffer-file-name (file-truename buffer-file-name)))
               (in-agenda? (and cur (member cur tns)))
               ;; Find index of a basename exactly equal to "todo.org" (case-insensitive)
               (todo-idx (cl-position "todo.org" orig
                                      :test (lambda (needle f)
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
    (setq dm-org--cycle-agenda--current-file target-tn)
    (when (buffer-base-buffer)
      (pop-to-buffer-same-window (buffer-base-buffer)))))

;;;###autoload
(defun dm-org-cycle-agenda-next ()
  "Cycle forward through `org-agenda-files'."
  (interactive)
  (dm-org--cycle-agenda-files +1))

;;;###autoload
(defun dm-org-cycle-agenda-prev ()
  "Cycle backward through `org-agenda-files'."
  (interactive)
  (dm-org--cycle-agenda-files -1))

(provide 'dm-org)
;;; dm-org.el ends here
