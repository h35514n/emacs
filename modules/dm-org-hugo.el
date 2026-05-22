;;; dm-org-hugo.el --- Daymacs Org Hugo setup  -*- lexical-binding: t; -*-

;;; Commentary:

;; ox-hugo exports hugo blog content from org docs

;;; Code:

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

(defun dm-org-hugo-capture--save-and-export-target-buffer-h ()
  "Save and export the target Org buffer after an Org capture is finalized."
  (when-let* ((marker org-capture-last-stored-marker)
              (buffer (marker-buffer marker)))
    (with-current-buffer buffer
      (when (and (buffer-file-name)
                 (derived-mode-p 'org-mode))
        (save-buffer)
        (require 'ox-hugo)
        (org-hugo-export-wim-to-md :all-subtrees)))))


(provide 'dm-org-hugo)
;;; dm-org-hugo.el ends here
