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

  (org-adapt-indentation t)
  (org-archive-location "archive/%s_archive::")
  (org-blank-before-new-entry '((heading . nil) (plain-list-item . nil)))
  (org-catch-invisible-edits 'show-and-error)
  (org-confirm-babel-evaluate nil)
  (org-cycle-separator-lines 2)
  (org-edit-src-content-indentation 0)
  (org-fontify-quote-and-verse-blocks t)
  (org-fontify-whole-heading-line t)
  (org-hide-emphasis-markers t)
  (org-image-actual-width 500)
  (org-list-use-circular-motion t)
  (org-log-done 'time)
  (org-log-into-drawer t)
  (org-outline-path-complete-in-steps nil)
  (org-pretty-entities nil)
  (org-priority-highest ?A)
  (org-priority-lowest  ?Z)
  (org-priority-default ?Z)
  (org-refile-allow-creating-parent-nodes 'confirm)
  (org-refile-use-outline-path 'file)
  (org-src-ask-before-returning-to-edit-buffer nil)
  (org-src-tab-acts-natively t)
  (org-src-window-setup 'current-window)
  (org-startup-folded 'overview)
  (org-startup-indented t)
  (org-startup-with-inline-images t)
  (org-tags-column 0)
  :config
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((python . t))))

(use-package evil-org
  ;; Evil keybindings for org: heading navigation, table editing, agenda.
  ;; :demand t overrides :hook-implied deferral so the with-eval-after-load
  ;; 'org-agenda callback is registered before the user first opens the agenda.
  :after (evil org)
  :demand t
  :hook (org-mode . evil-org-mode)
  :config
  ;; Agenda bindings only matter once `org-agenda' loads, which happens on
  ;; first `M-x org-agenda'. Don't pull in evil-org-agenda before then.
  (with-eval-after-load 'org-agenda
    (require 'evil-org-agenda)
    (evil-org-agenda-set-keys)))

;;; ————————————————————————————
;;; Org agenda
;;; ————————————————————————————

(defun dm-org-agenda-save-all-files--h (&rest _)
  (org-save-all-org-buffers))

;;;###autoload
(defun dm-org-agenda-save-all-files (&rest _)
  "Save all Org buffers.
Usable interactively or as :after advice on agenda-mutating commands."
  (interactive)
  (org-save-all-org-buffers))

(use-package org-agenda
  ;; Part of Org (installed via the `org' form above), so don't let straight
  ;; try to manage it. `:defer t' keeps it lazy: it loads on first
  ;; `M-x org-agenda', at which point `:config' runs. `:custom' settings apply
  ;; at startup, which is harmless since `defcustom' won't clobber them.
  :straight nil
  :after (evil org)
  :custom
  (org-agenda-files (expand-file-name ".agenda-files.el" org-directory))
  (org-agenda-block-separator ?⎯)
  (org-agenda-entry-types '(:deadline :scheduled :timestamp :sexp))
  (org-agenda-format-date (lambda (date) (concat "\n" (org-agenda-format-date-aligned date))))
  (org-agenda-restore-windows-after-quit t)
  (org-agenda-remove-tags 'prefix)
  (org-agenda-skip-deadline-if-done t)
  (org-agenda-skip-deadline-prewarning-if-scheduled t)
  (org-agenda-skip-scheduled-if-done t)
  (org-agenda-span 9)
  (org-agenda-start-day "-1d")
  (org-agenda-start-on-weekday nil)
  (org-agenda-start-with-log-mode t)
  (org-agenda-use-time-grid nil)
  (org-agenda-view-columns-initially nil)
  (org-agenda-window-setup 'only-window)
  (org-columns-default-format "%TODO(State) %3PRIORITY(Pri) %6Effort(Effort){:} %TAGS(Tags) %50ITEM(Task)")
  (org-deadline-warning-days 7)
  (org-agenda-prefix-format '((agenda . "  %s%-12t[%5e]%10T ")
                              (todo   . "  %-12:c")
                              (tags   . "  %-12:c")
                              (search . "  %-12:c")))
  :config
  ;; Custom command: completed tasks in the past week.
  (add-to-list
   'org-agenda-custom-commands
   '("W" "Completed tasks in past week"
     ((agenda ""
              ((org-agenda-span 7)
               (org-agenda-start-day "-7d")
               (org-agenda-log-mode-items '(closed clock state))
               (org-agenda-skip-function
                '(org-agenda-skip-entry-if 'notregexp "CLOSED:")))))))

  ;; Persist edits made from the agenda by saving after any mutating command.
  (dolist (cmd '(org-agenda-clock-in
                 org-agenda-clock-out
                 org-agenda-deadline
                 org-agenda-do-date-earlier
                 org-agenda-do-date-later
                 org-agenda-priority
                 org-agenda-schedule
                 org-agenda-set-effort
                 org-agenda-set-property
                 org-agenda-set-tags
                 org-agenda-todo))
    (advice-add cmd :after #'dm-org-agenda-save-all-files--h)))

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

;;;###autoload
(defun dm-org-schedule-subtree-items-on-successive-days (start-date target-level)
  "Set scheduled dates for all headings of the TARGET-LEVEL in subtree, starting from START-DATE."
  (interactive
   (list
    (read-string "Start date (YYYY-MM-DD): " (format-time-string "%Y-%m-%d"))
    (read-string "Target heading level (1-?): " "4")))
  (let ((current-date start-date))
    (org-map-entries
     (lambda ()
       (message (format "target-level %s" target-level))
       (when (= (org-current-level) (string-to-number target-level))
         (org-schedule nil current-date)
         (setq current-date
               (format-time-string "%Y-%m-%d"
                 (time-add (date-to-time current-date)
                           (days-to-time 1))))))
     nil 'tree)))

;;;###autoload
(defun dm-org-set-effort-on-subtree (effort)
  "Bulk set EFFORT property on all subheadings of the current tree."
  (interactive "sEffort: ")
  (org-map-entries
   (lambda () (org-set-property "EFFORT" effort))
   nil
   'tree))

;;;###autoload
(defun dm-org-sum-effort-from-subtree ()
  "Sum the Effort estimates of all child headings one level below the current heading,
and store the total Effort in the current heading's property drawer.

Effort values are assumed to be in standard Org time format, e.g., \"0:30\" or \"2:15\"."
  (interactive)
  (require 'org-duration)
  (save-excursion
    (org-back-to-heading t)
    (let* ((current-level (org-current-level))
           (sum 0))
      ;; Iterate through all subheadings of current heading
      (org-map-entries
       (lambda ()
         (when (= (org-current-level) (1+ current-level))
           (let ((effort (org-entry-get (point) "Effort")))
             (when effort
               (setq sum (+ sum (org-duration-to-minutes effort)))))))
       nil 'tree)
      ;; Write summed effort back to current heading as Org time string
      (org-entry-put (point) "Effort" (org-duration-from-minutes sum))
      (message "Set Effort to %s" (org-duration-from-minutes sum)))))

(provide 'dm-org)
;;; dm-org.el ends here
