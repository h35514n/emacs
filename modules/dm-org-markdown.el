;;; dm-org-markdown.el --- Convert Org text to Markdown  -*- lexical-binding: t; -*-

;;; Commentary:

;; `dm-org-region-to-markdown' converts the active region from Org markup to
;; Markdown and copies the result to the clipboard (via the `kill-ring').  The
;; buffer is unchanged.
;;
;; The converter is a small line-based pass, not a full `ox-md' export, so
;; fragments such as stand-up notes convert without a document wrapper.  It
;; expands link abbreviations from `#+LINK:' lines and `org-link-abbrev-alist'.
;; It handles links, bold, italic, code, strike-through, headings and lists.  A
;; blank line follows every list so Markdown renderers end the list there.

;;; Code:

(require 'subr-x)
(require 'seq)
(require 'format-spec)
(require 'url-util)

(defconst dm-org-markdown--list-item-re "^[ \t]*\\(?:[-+]\\|[0-9]+[.)]\\)[ \t]+"
  "Match the start of an Org list item.")

(defvar dm-org-markdown--abbrevs nil
  "Alist of (NAME . TEMPLATE) used to expand link abbreviations.")

(defun dm-org-markdown--buffer-abbrevs ()
  "Return link abbreviations from `#+LINK:' lines and `org-link-abbrev-alist'."
  (let (alist)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (re-search-forward
                "^[ \t]*#\\+LINK:[ \t]+\\(\\S-+\\)[ \t]+\\(\\S-+\\)" nil t)
          (push (cons (match-string-no-properties 1)
                      (match-string-no-properties 2))
                alist))))
    (append (nreverse alist)
            (and (boundp 'org-link-abbrev-alist)
                 (seq-filter (lambda (c) (stringp (cdr c)))
                             org-link-abbrev-alist)))))

(defun dm-org-markdown--expand (target)
  "Expand a link abbreviation prefix in TARGET, if one is defined."
  (save-match-data
    (let* ((target (string-trim target))
           (entry (and (string-match "\\`\\([^:/ ]+\\):\\(.*\\)\\'" target)
                       (assoc (match-string 1 target) dm-org-markdown--abbrevs))))
      (if (not entry)
          target
        (let ((tag (match-string 2 target))
              (tpl (cdr entry)))
          (cond ((string-match-p "%s" tpl) (format-spec tpl `((?s . ,tag)) t))
                ((string-match-p "%h" tpl)
                 (format-spec tpl `((?h . ,(url-hexify-string tag))) t))
                (t (concat tpl tag))))))))

(defun dm-org-markdown--links (line)
  "Convert Org links in LINE to Markdown links."
  (let ((line (replace-regexp-in-string
               "\\[\\[\\([^][]+?\\)\\]\\[\\([^][]+?\\)\\]\\]"
               (lambda (m)
                 (string-match "\\[\\[\\(.*?\\)\\]\\[\\(.*\\)\\]\\]" m)
                 (format "[%s](%s)"
                         (string-trim (match-string 2 m))
                         (dm-org-markdown--expand (match-string 1 m))))
               line t t)))
    (replace-regexp-in-string
     "\\[\\[\\([^][]+?\\)\\]\\]"
     (lambda (m) (format "<%s>" (dm-org-markdown--expand (substring m 2 -2))))
     line t t)))

(defconst dm-org-markdown--emphasis-rules
  '(("\\(?:^\\|[^[:alnum:]*]\\)\\(\\*\\([^* \t][^*]*?\\)\\*\\)\\(?:$\\|[^[:alnum:]*]\\)" . "**%s**")
    ("\\(?:^\\|[^[:alnum:]/]\\)\\(/\\([^/ \t][^/]*?\\)/\\)\\(?:$\\|[^[:alnum:]/]\\)" . "*%s*")
    ("\\(?:^\\|[^[:alnum:]~]\\)\\(~\\([^~]+?\\)~\\)\\(?:$\\|[^[:alnum:]~]\\)" . "`%s`")
    ("\\(?:^\\|[^[:alnum:]=]\\)\\(=\\([^=]+?\\)=\\)\\(?:$\\|[^[:alnum:]=]\\)" . "`%s`")
    ("\\(?:^\\|[^[:alnum:]+]\\)\\(\\+\\([^+ \t][^+]*?\\)\\+\\)\\(?:$\\|[^[:alnum:]+]\\)" . "~~%s~~"))
  "Alist of (REGEXP . FORMAT) rewriting Org emphasis to Markdown.
Group 1 is the marked-up span; group 2 is its content.")

(defun dm-org-markdown--emphasis-plain (s)
  "Convert Org emphasis markers in S."
  (dolist (rule dm-org-markdown--emphasis-rules s)
    (let ((pos 0))
      (while (string-match (car rule) s pos)
        (let ((rep (format (cdr rule) (match-string 2 s))))
          (setq s (replace-match rep t t s 1)
                pos (+ (match-beginning 1) (length rep))))))))

(defun dm-org-markdown--emphasis (line)
  "Convert Org emphasis in LINE, leaving link targets untouched."
  (let ((parts '()) (pos 0)
        (link-re "\\[[^][]*\\]([^)]*)\\|<[^>]+>"))
    (while (string-match link-re line pos)
      (push (dm-org-markdown--emphasis-plain
             (substring line pos (match-beginning 0)))
            parts)
      (push (match-string 0 line) parts)
      (setq pos (match-end 0)))
    (push (dm-org-markdown--emphasis-plain (substring line pos)) parts)
    (apply #'concat (nreverse parts))))

(defun dm-org-markdown--line (line)
  "Convert a single Org LINE to Markdown."
  (setq line (string-trim-right line))
  (if (string-match "^\\(\\*+\\)[ \t]+\\(.*\\)$" line)
      (concat (make-string (length (match-string 1 line)) ?#) " "
              (dm-org-markdown--emphasis
               (dm-org-markdown--links (match-string 2 line))))
    (dm-org-markdown--emphasis (dm-org-markdown--links line))))

;;;###autoload
(defun dm-org-to-markdown (text &optional abbrevs)
  "Return TEXT converted from Org markup to Markdown.
Every list is followed by a blank line.  ABBREVS is an alist of
\(NAME . TEMPLATE) used to expand link abbreviations such as `jira:API-1'."
  (let ((out '()) (in-list nil) (dm-org-markdown--abbrevs abbrevs))
    (dolist (raw (split-string text "\n"))
      (let* ((item (string-match-p dm-org-markdown--list-item-re raw))
             (cont (and in-list (not item) (string-match-p "^[ \t]+[^ \t]" raw)))
             (line (dm-org-markdown--line raw)))
        (when (and in-list (not item) (not cont))
          (unless (string-empty-p line) (push "" out))
          (setq in-list nil))
        (when item (setq in-list t))
        (push line out)))
    (when in-list (push "" out))
    (let ((lines (nreverse out)))
      (while (and (cdr lines)
                  (string-empty-p (car (last lines)))
                  (string-empty-p (car (last lines 2))))
        (setq lines (butlast lines)))
      (concat (string-join lines "\n") "\n"))))

;;;###autoload
(defun dm-org-region-to-markdown (beg end)
  "Copy the Org text between BEG and END to the clipboard as Markdown."
  (interactive "r")
  (unless (use-region-p) (user-error "Select the Org text to convert first"))
  (kill-new (dm-org-to-markdown (buffer-substring-no-properties beg end)
                                (dm-org-markdown--buffer-abbrevs)))
  (deactivate-mark)
  (message "Markdown copied to clipboard"))

(provide 'dm-org-markdown)
;;; dm-org-markdown.el ends here
