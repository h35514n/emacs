;;; dm-org-capture.el --- Daymacs Org capture setup  -*- lexical-binding: t; -*-

;;; Commentary:

;;; Org capture templates and associated helper functions

;;; Code:

(setq org-capture-templates
      '(("i" "Inbox"     entry (file+olp org-default-notes-file "Inbox")
         "* TODO %?\n%i%a"
         :prepend t
         :after-finalize dm-org-capture--save-target-buffer-h)

        ("y" "Yak Shave" entry (file+olp org-default-notes-file "Inbox")
         "* TODO %?\n%i%a"
         :prepend t
         :after-finalize dm-org-capture--save-target-buffer-h)

        ("j" "Journal"   entry (file+olp+datetree "journal.org.gpg")
         "* %U %?\n%i"
         :prepend t :tree-type month
         :after-finalize dm-org-capture--save-target-buffer-h)

        ("l" "Link"      entry (file+olp org-default-notes-file "Inbox")
         #'dm-org-capture--make-link-entry
         :prepend t :immediate-finish t
         :after-finalize dm-org-capture--save-target-buffer-h)

        ("d" "Draft" entry (file+headline "writing/drafts.org" "Drafts")
         (function dm-org-capture--hugo-draft)
         :prepend t :jump-to-captured t
         :after-finalize dm-org-hugo-capture--save-and-export-target-buffer-h)

        ("s" "Scratch" entry (file+headline "writing/scratch.org" "Scratch")
         (function dm-org-capture--hugo-scratch)
         :prepend t
         :after-finalize dm-org-hugo-capture--save-and-export-target-buffer-h)

        ("n" "Notebook" entry (file+headline "reference/technical/notebook.org" "Notes")
         (function dm-org-capture--hugo-draft)
         :prepend t :jump-to-captured t
         :after-finalize dm-org-hugo-capture--save-and-export-target-buffer-h)

        ("c" "Commonplace" entry (file+headline "reference/collections/commonplaces.org" "Commonplaces")
         (function dm-org-capture--hugo-commonplace)
         :prepend t
         :after-finalize dm-org-hugo-capture--save-and-export-target-buffer-h)

        ("m" "Marginalia" entry (file+headline "reference/collections/marginalia.org" "Marginalia")
         (function dm-org-capture--hugo-marginalia)
         :prepend t
         :after-finalize dm-org-hugo-capture--save-and-export-target-buffer-h)

        ("u" "Standup" plain (file+olp+datetree "STANDUP.org")
         (function dm-org-capture--standup)
         :tree-type week :unnarrowed t :jump-to-captured t
         :after-finalize dm-org-capture--save-target-buffer-h)))

(defun dm-org-capture--standup-section (text date)
  "Return the body of the day entry for DATE in TEXT, or nil.
DATE is a string like \"2026-11-13\"."
  (when (string-match
         (concat "^\\*\\*\\* " (regexp-quote date) "\\b.*\n"
                 "\\(\\(?:^[^*\n].*\n?\\|^\\*[^*\n].*\n?\\|^\n\\)*\\)")
         text)
    (match-string 1 text)))

(defun dm-org-capture--standup-previous-today (text today)
  "Return the `*Today*:' items from the latest day before TODAY in TEXT.
TEXT is the contents of STANDUP.org and TODAY is a \"YYYY-MM-DD\" string.
Return nil when no earlier day has any items."
  (let ((best nil) (pos 0))
    (while (string-match "^\\*\\*\\* \\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)\\b"
                         text pos)
      (let ((d (match-string 1 text)))
        (setq pos (match-end 0))
        (when (and (string< d today) (or (null best) (string< best d)))
          (setq best d))))
    (when-let* ((body (and best (dm-org-capture--standup-section text best)))
                ((string-match
                  "^\\*Today\\*:[ \t]*\n\\(\\(?:\\(?:[ \t]*[-+0-9].*\\|[ \t]+.*\\)\n?\\)*\\)"
                  body))
                (items (string-trim-right (match-string 1 body)))
                ((not (string-empty-p items))))
      items)))

(defun dm-org-capture--standup ()
  "Return `org-capture' template string for today's standup entry.
Prefill *Yesterday* from the previous entry's *Today* items."
  (let* ((file (expand-file-name "STANDUP.org" org-directory))
         (text (if (file-readable-p file)
                   (with-temp-buffer (insert-file-contents file) (buffer-string))
                 ""))
         (today (format-time-string "%Y-%m-%d")))
    (when-let* ((section (dm-org-capture--standup-section text today))
                ((string-match-p "^\\*Yesterday\\*:" section)))
      (user-error "Standup entry for %s already exists" today))
    (concat "*Yesterday*:\n"
            (or (dm-org-capture--standup-previous-today text today) "- ")
            "\n*Today*:\n- %?\n*Blocked / Waiting*:\n- \n")))

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
          (timestamp (dm-org-capture--timestamp))
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
  "Return `org-capture' template string for a Hugo blog post.
See `org-capture-templates' for more information."
  (save-match-data
    (let* ((date (format-time-string "%Y-%m-%d" (current-time)))
           (timestamp (dm-org-capture--timestamp))
           (title (read-from-minibuffer "Title: " ""))
           (slug (concat date "-" (org-hugo-slug title)))
           (summary (and with-summary (read-from-minibuffer "Summary: " ""))))
      (mapconcat #'identity
                 (delq nil
                       `(,(concat "* " title)
                         ":PROPERTIES:"
                         ,(concat ":EXPORT_DATE: " timestamp)
                         ,(concat ":EXPORT_FILE_NAME: " slug)
                         ,(concat ":EXPORT_HUGO_SLUG: " slug)
                         ,(when summary
                            (concat ":EXPORT_HUGO_CUSTOM_FRONT_MATTER: :toc true :summary "
                                    summary))
                         ":END:"
                         "%?\n"))
                 "\n"))))

(defun dm-org-capture--hugo-scratch ()
  "Return `org-capture' template string for a Hugo blog post.
See `org-capture-templates' for more information."
  (save-match-data
    (let* ((date (format-time-string "%Y-%m-%d" (current-time)))
           (timestamp (dm-org-capture--timestamp))
           (title (concat "Scratch work " (format-time-string "%m/%d" (current-time))))
           (slug (concat date "-scratch"))
           (summary (and with-summary (read-from-minibuffer "Summary: " ""))))
      (mapconcat #'identity
                 (delq nil
                       `(,(concat "* " title)
                         ":PROPERTIES:"
                         ,(concat ":EXPORT_DATE: " timestamp)
                         ,(concat ":EXPORT_FILE_NAME: " slug)
                         ,(concat ":EXPORT_HUGO_SLUG: " slug)
                         ,(when summary
                            (concat ":EXPORT_HUGO_CUSTOM_FRONT_MATTER: :toc false :summary "
                                    summary))
                         ":END:"
                         "%?\n"))
                 "\n"))))

(defun dm-org-capture--hugo-marginalia ()
  "Return `org-capture' template string for new Hugo marginalia post.
    See `org-capture-templates' for more information."
  (save-match-data
    (let ((timestamp (dm-org-capture--timestamp))
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

(defun dm-org-capture--timestamp ()
  "Return a timestamp in ISO 8601 format."
  (concat
   (format-time-string "%Y-%m-%dT%T")
   ((lambda (x) (concat (substring x 0 3) ":" (substring x 3 5)))
    (format-time-string "%z"))))

(defun dm-org-capture--get-clipboard-url ()
  "Return a URL from the system clipboard if it looks like one, else prompt the user."
  (let* ((clip (string-trim (shell-command-to-string "pbpaste")))
         (url (if (string-match-p "^https?://" clip)
                  clip
                (read-string "URL: "))))
    url))

(defun dm-org-capture--make-link-entry ()
  "Return an Org capture entry string for a clipboard or prompted URL."
  (let ((url (dm-org-capture--get-clipboard-url))
        (title (read-string "Link title: ")))
    (format "** [[%s][%s]]\n%s"
            url title (format-time-string "[%Y-%m-%d %a]"))))

(defun dm-org-capture--save-target-buffer-h ()
  "Save the target buffer after an Org capture is finalized.
  Intended for use as :after-finalize in org-capture-templates, or
  as a global hook via `org-capture-after-finalize-hook'."
  (when (and (buffer-file-name)
             (derived-mode-p 'org-mode))
    (save-buffer)))

(provide 'dm-org-capture)
;;; dm-org-capture.el ends here
