;;; dm-util.el --- -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(defun dm-util-working-dir (&optional directory)
  "Return the project root for DIRECTORY, or DIRECTORY/default-directory.

If DIRECTORY is nil, use `default-directory'.  If DIRECTORY is inside a
known project, return that project's root.  Otherwise return DIRECTORY."
  (let ((default-directory (or directory default-directory)))
    (if-let* ((project (project-current nil)))
        (project-root project)
      default-directory)))

(defun dm-util-daemon-is-tty-p ()
  "Return non-nil when this Emacs daemon name contains \"tty\"."
  (let ((daemon-name (daemonp)))
    (and (stringp daemon-name)
         (string-match-p "tty" daemon-name))))

(defun dm-util-quietly (fn &rest args)
  "Run function FN with ARGS, suppressing any messages it emits."
  (let ((inhibit-message t)
        (message-log-max nil))
    (apply fn args)))

(defun dm-util-async-shell-command-below (command &optional buffer-name proportion)
  "Execute COMMAND, displaying output in buffer (optionally named BUFFER-NAME),
which that takes up PROPORTION of the frame height (default: 0.1).
Dismiss the buffer and window on success, or switch focus to it on failure."
  (let ((buffer-name (or buffer-name "*Async Shell Command*"))
        (proportion (or proportion 0.1))
        (window-min-height 1))
    (with-current-buffer (get-buffer-create buffer-name)
      (setq truncate-lines t))
    (let ((output-window (split-window (selected-window) (floor (* (- 1 proportion) (window-total-height))) 'below)))
      (set-window-buffer output-window buffer-name)
      (set-window-text-height output-window (floor (* proportion (frame-height)))))
    (async-shell-command command buffer-name)
    (set-process-sentinel (get-buffer-process buffer-name)
                          (lambda (process event)
                            (let* ((buffer (process-buffer process))
                                   (window (get-buffer-window buffer)))
                              (if (string= event "finished\n")
                                  (progn
                                    (when (window-live-p window)
                                      (delete-window window))
                                    (kill-buffer buffer))
                                (when (process-live-p process)
                                  (interrupt-process process))
                                (when (window-live-p window)
                                  (progn
                                    (select-window window)
                                    (enlarge-window 15)
                                    (recenter -1)))))))))

;;;###autoload
(defun dm-util-open-pdf-at-right (filename)
  "Open the pdf FILENAME in a new buffer to the right of the current buffer.
If already open, reload it."
  (interactive "fOpen PDF file: ")
  (let ((buffer (get-file-buffer filename))
        (window (get-buffer-window filename)))
    (if buffer
        (if window
            (select-window window)
          (progn
            (split-window-right)
            (other-window 1)
            (switch-to-buffer buffer)
            (revert-buffer :ignore-auto :noconfirm)))
      (progn
        (split-window-right)
        (other-window 1)
        (find-file filename)))))

(defun dm-util-file-to-string (filename)
  "Read the contents of file FILENAME to a string."
  (with-temp-buffer
    (insert-file-contents filename)
    (buffer-string)))

(defun dm-util-get-url-surrounding-point ()
  (save-excursion
    (let* ((oldpoint (point)) (start (point)) (end (point))
           (syntaxes "w_")
           (not-syntaxes (concat "^" syntaxes)))
      (skip-syntax-backward syntaxes) (setq start (point))
      (goto-char oldpoint)
      (skip-syntax-forward syntaxes) (setq end (point))
      (when (and (eq start oldpoint)
                 (eq end oldpoint))
        ;; Look for preceding word in same line.
        (skip-syntax-backward not-syntaxes (line-beginning-position))
        (if (bolp)
            ;; No preceding word in same line.
            ;; Look for following word in same line.
            (progn
              (skip-syntax-forward not-syntaxes (line-end-position))
              (setq start (point))
              (skip-syntax-forward syntaxes)
              (setq end (point)))
          (setq end (point))
          (skip-syntax-backward syntaxes)
          (setq start (point))))
      ;; If we found something nonempty, return it as a string.
      (unless (= start end)
        (buffer-substring-no-properties start end)))))

(defun dm-util--ensure-url (candidate-str)
  "Ensure CANDIDATE-STR can be interpreted as a URL.
Checking for a scheme (interpolating one if missing) and a hostname with a TLD.
Return nil if the hostname is missing a TLD."
  (defun dm-util--ensure-url-scheme (candidate-str)
    "Ensure CANDIDATE-STR is prefixed with a scheme, or return the string prepended with one"
    (when candidate-str
      (if (or (string-prefix-p "https://" candidate-str t)
              (string-prefix-p "http://" candidate-str t))
          candidate-str
        (format "https://%s" (replace-regexp-in-string "^[^[:word:]]+" "" candidate-str)))))
  (when candidate-str
    (let* ((candidate-url (dm-util--ensure-url-scheme candidate-str))
           (hostname (nth 2 (split-string candidate-url "/"))))
      (when (string-match-p "\\." hostname)
        candidate-url))))

(provide 'dm-util)
;;; dm-util.el ends here
