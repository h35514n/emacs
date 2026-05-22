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

(defun dm-org-hugo-export-all-in-dir (&optional dir)
  "Export every Hugo-ready subtree in all .org files under DIR.
Used from bin/generate."
  (let ((dir    (expand-file-name (or dir default-directory)))
        (files  (directory-files-recursively dir "\\.org$")))
    (dolist (f files)
      (with-temp-buffer
        (insert-file-contents f)
        (org-mode)
        (message "→ %s" f)
        (org-element-map (org-element-parse-buffer) 'headline
          (lambda (hl)
            (when (org-element-property :EXPORT_FILE_NAME hl)
              (goto-char (org-element-property :begin hl))
              (org-hugo-export-wim-to-md :all-subtrees))))))))

(defun dm-org-hugo-export-all-subtrees-after-save ()
  "Export all ox-hugo post subtrees after saving the current Org buffer."
  (unless (eq real-this-command 'org-capture-finalize)
    (save-excursion
      (org-hugo-export-wim-to-md :all-subtrees))))

(define-minor-mode dm-org-hugo-auto-export-all-mode
  "Auto-export all ox-hugo subtrees in the current buffer after save."
  :global nil
  :lighter " HugoAll"
  (if dm-org-hugo-auto-export-all-mode
      (add-hook 'after-save-hook
                #'dm-org-hugo-export-all-subtrees-after-save
                :append :local)
    (remove-hook 'after-save-hook
                 #'dm-org-hugo-export-all-subtrees-after-save
                 :local)))

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

If called from outside an agenda file, jump to `org-default-notes-file' if
present in the list (case-insensitive basename match), otherwise the first
agenda file. Do not advance past that file on this initial jump. From within an
agenda file, cycle as usual by one step in the chosen direction."
  (interactive "p")
  (pcase-let* ((`(,orig . ,tns) (dm-org--cycle-agenda--file-truenames))
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

;;; ————————————————————————————
;;; Org capture
;;; ————————————————————————————

(setq org-capture-templates
      '(("i" "Inbox"     entry (file+olp org-default-notes-file "Inbox")
         "* TODO %?\n%i%a"
         :prepend t
         :after-finalize dm-org-capture--save-target-buffer-h)

        ("y" "Yak Shave" entry (file+olp org-default-notes-file "Yak Shaves")
         "* TODO %?\n%i%a"
         :prepend t
         :after-finalize dm-org-capture--save-target-buffer-h)

        ("j" "Journal"   entry (file+olp+datetree "journal.org.gpg")
         "* %U %?\n%i"
         :prepend t :tree-type month
         :after-finalize dm-org-capture--save-target-buffer-h)

        ("l" "Link"      entry (file+headline "links.org" "Inbox")
         #'dm-org-capture--make-link-entry
         :prepend t :immediate-finish t
         :after-finalize dm-org-capture--save-target-buffer-h)

        ("d" "Draft" entry (file+headline "lex/drafts.org" "Drafts")
         (function dm-org-capture--hugo-draft)
         :prepend t :jump-to-captured t
         :after-finalize dm-org-capture--hugo-save-and-export-target-buffer-h)

        ("n" "Notebook" entry (file+headline "lex/notebook.org" "Notes")
         (function dm-org-capture--hugo-draft)
         :prepend t :jump-to-captured t
         :after-finalize dm-org-capture--hugo-save-and-export-target-buffer-h)

        ("c" "Commonplace" entry (file+headline "lex/commonplaces.org" "Commonplaces")
         (function dm-org-capture--hugo-commonplace)
         :prepend t
         :after-finalize dm-org-capture--hugo-save-and-export-target-buffer-h)

        ("m" "Marginalia" entry (file+headline "lex/marginalia.org" "Marginalia")
         (function dm-org-capture--hugo-marginalia)
         :prepend t
         :after-finalize dm-org-capture--hugo-save-and-export-target-buffer-h)))

(defun dm-org-capture--save-target-buffer-h ()
  "Save the target buffer after an Org capture is finalized.
  Intended for use as :after-finalize in org-capture-templates, or
  as a global hook via `org-capture-after-finalize-hook'."
  (when (and (buffer-file-name)
             (derived-mode-p 'org-mode))
    (save-buffer)))

(defun dm-org-capture--hugo-save-and-export-target-buffer-h ()
  "Save and export the target Org buffer after an Org capture is finalized."
  (when-let* ((marker org-capture-last-stored-marker)
              (buffer (marker-buffer marker)))
    (with-current-buffer buffer
      (when (and (buffer-file-name)
                 (derived-mode-p 'org-mode))
        (save-buffer)
        (require 'ox-hugo)
        (save-excursion
          (goto-char marker)
          (org-hugo-export-wim-to-md :all-subtrees))))))

(defun dm-org--timestamp ()
  "Return a timestamp in ISO 8601 format."
  (concat
   (format-time-string "%Y-%m-%dT%T")
   ((lambda (x) (concat (substring x 0 3) ":" (substring x 3 5)))
    (format-time-string "%z"))))

(defun dm-org-capture--hugo-marginalia ()
  "Return `org-capture' template string for new Hugo marginalia post.
    See `org-capture-templates' for more information."
  (save-match-data
    (let ((timestamp (dm-org--timestamp))
          (date (format-time-string "%Y-%m-%d" (current-time)))
          (title (read-from-minibuffer "Description: " "")))
      (mapconcat #'identity
                 `(
                   ,(concat "* " title)
                   ":PROPERTIES:"
                   ,(concat ":EXPORT_FILE_NAME: " date "-" (org-hugo-slug title))
                   ,(concat ":EXPORT_DATE: " timestamp)
                   ":END:"
                   "%?\n")
                 "\n"))))

(defun dm-org-capture--hugo-commonplace ()
  "Return `org-capture' template string for new Hugo commonplace post.
    See `org-capture-templates' for more information."
  (save-match-data
    (let ((title (read-from-minibuffer "Title: "))
          (desc (read-from-minibuffer "Description: "))
          (author (read-from-minibuffer "Author: "))
          (source (read-from-minibuffer "Source Title: "))
          (cite (read-from-minibuffer "Citation Date: "))
          (url (read-from-minibuffer "Source URL: "))
          (timestamp (dm-org--timestamp))
          (type (car (cdr  (read-multiple-choice
                            "Source Type: "
                            '((?b "book" "Book / Magazine / Film / Album")
                              (?a "article" "Blog post / Article / Essay")
                              (?p "poem" "Poem")
                              (?t "tweet" "Tweet")))))))
      (mapconcat #'identity
                 `(
                   ,(concat "* " title)
                   ":PROPERTIES:"
                   ,(concat ":EXPORT_FILE_NAME: " (org-hugo-slug title))
                   ,(concat ":EXPORT_AUTHOR: " author)
                   ,(concat ":EXPORT_DATE: " timestamp)
                   ,(concat ":EXPORT_HUGO_CUSTOM_FRONT_MATTER: "
                            ":source " source
                            " :cite " cite
                            " :type " type
                            " :sourceurl " url)
                   ,(concat ":EXPORT_DESCRIPTION: " desc)
                   ":END:"
                   "%?\n")
                 "\n"))))

(defun dm-org-capture--hugo-draft ()
  "Return `org-capture' template string for new Hugo blog post.
See `org-capture-templates' for more information."
  (save-match-data
    (let ((date (format-time-string "%Y-%m-%d" (current-time)))
          (timestamp (dm-org--timestamp))
          (title (read-from-minibuffer "Title: " ""))
          (summary (read-from-minibuffer "Summary: " "")))
      (mapconcat #'identity
                 `(
                   ,(concat "* " title)
                   ":PROPERTIES:"
                   ,(concat ":EXPORT_DATE: " timestamp)
                   ,(concat ":EXPORT_FILE_NAME: " date "-" (org-hugo-slug title))
                   ,(concat ":EXPORT_HUGO_SLUG: " date "-" (org-hugo-slug title))
                   ,(concat ":EXPORT_HUGO_CUSTOM_FRONT_MATTER: :toc true :summary " summary)
                   ":END:"
                   "%?\n")
                 "\n"))))

(defun dm-org-capture-link--get-clipboard-url ()
  "Return a URL from the system clipboard if it looks like one, else prompt the user."
  (let* ((clip (string-trim (shell-command-to-string "pbpaste")))
         (url (if (string-match-p "^https?://" clip)
                  clip
                (read-string "URL: "))))
    url))

(defun dm-org-capture--make-link-entry ()
  "Return an Org capture entry string for a clipboard or prompted URL."
  (let ((url (dm-org-capture--link--get-clipboard-url))
        (title (read-string "Link title: ")))
    (format "** [[%s][%s]]\n%s"
            url title (format-time-string "[%Y-%m-%d %a]"))))

(provide 'dm-org)
;;; dm-org.el ends here
