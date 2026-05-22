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

;; ------------------------------------------------------------
;; generate markdown from all org files in dir (from the shell)
;; ------------------------------------------------------------

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

;; ----------------------------------------------------------------
;; auto-export-all mode (from org buffer, not on capture finalize)
;; ----------------------------------------------------------------
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

(defun dm-org-hugo-export-all-subtrees-after-save ()
  "Export all ox-hugo post subtrees after saving the current Org buffer."
  (unless (eq real-this-command 'org-capture-finalize)
    (save-excursion
      (org-hugo-export-wim-to-md :all-subtrees))))

;; ----------------------------------
;; save, export, publish (on capture)
;; ----------------------------------
(defun dm-org-hugo-capture--save-and-export-target-buffer-h ()
  "Save and export the target Org buffer after an Org capture is finalized."
  (when-let* ((marker org-capture-last-stored-marker)
              (buffer (marker-buffer marker)))
    (with-current-buffer buffer
      (when (and (buffer-file-name)
                 (derived-mode-p 'org-mode))
        (save-buffer)
        (require 'ox-hugo)
        (org-hugo-export-wim-to-md :all-subtrees)
        (dm-hugo-publish)))))

;; ----------------------------------------------------------------
;; auto-publish-after-save mode (from org buffer, not on capture finalize)
;; ----------------------------------------------------------------
(define-minor-mode dm-org-hugo-auto-publish-mode
  "Auto-build and push the Hugo site after saving the current Org buffer."
  :global nil
  :lighter " HugoPub"
  (if dm-org-hugo-auto-publish-mode
      (add-hook 'after-save-hook #'dm-hugo-publish-after-save :append :local)
    (remove-hook 'after-save-hook #'dm-hugo-publish-after-save :local)))

(defun dm-hugo-publish-after-save ()
  "Publish after save, unless the save was triggered by capture-finalize."
  (unless (eq real-this-command 'org-capture-finalize)
    (dm-hugo-publish)))

;; --------------------------------------------------------------------
;; publish script glue (resolve HUGO_BASE_DIR, run bin/build-and-push)
;; --------------------------------------------------------------------
(defvar dm-hugo-publish-script "bin/build-and-push"
  "Path to the publish script, relative to the Hugo site root.")

(defun dm-hugo--site-dir ()
  "Return the Hugo site directory for the current org buffer.
Checks the `EXPORT_HUGO_BASE_DIR' subtree property (with inheritance),
then the `#+HUGO_BASE_DIR' file keyword. Relative paths are resolved
against the buffer's directory, matching ox-hugo's behaviour."
  (when-let* (((derived-mode-p 'org-mode))
              (raw (or (org-entry-get nil "EXPORT_HUGO_BASE_DIR" t)
                       (cadr (assoc "HUGO_BASE_DIR"
                                    (org-collect-keywords '("HUGO_BASE_DIR"))))))
              (base (file-name-directory (or (buffer-file-name) ""))))
    (expand-file-name raw base)))

(defun dm-hugo-publish ()
  "Build and push the Hugo site for the current org buffer asynchronously."
  (let ((root (dm-hugo--site-dir)))
    (cond
     ((not root)
      (message "✗ Hugo publish: no HUGO_BASE_DIR found for %s"
               (buffer-file-name)))
     (t
      (let* ((default-directory (file-name-as-directory root))
             (script (expand-file-name dm-hugo-publish-script root)))
        (if (not (file-executable-p script))
            (message "✗ Hugo publish: %s not found or not executable" script)
          (make-process
           :name "hugo-publish"
           :buffer "*hugo-publish*"
           :command (list script)
           :sentinel
           (lambda (_proc event)
             (cond
              ((string= event "finished\n")
               (message "✓ Blog published"))
              ((string-prefix-p "exited abnormally" event)
               (message "✗ Blog publish failed — see *hugo-publish*")))))))))))

(provide 'dm-org-hugo)
;;; dm-org-hugo.el ends here
