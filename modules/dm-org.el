;;; dm-org.el --- Daymacs Org setup  -*- lexical-binding: t; -*-

;;; Commentary:

;; Org setup is kept together because its first-load cost is meaningful.

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
  (org-agenda-files (dm-util-list-sans
                     (directory-files org-directory nil "\\.org\\'")
                     "beorg-reminders.org"
                     "beorg-calendar.org"
                     "beorg-customize-init.org"))
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

(provide 'dm-org)
;;; dm-org.el ends here
