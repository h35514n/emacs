;;; dm-lisp --- Summary: Daymacs Lisp-specific facilities  -*- lexical-binding: t; -*-

;;; Commentary:

;; Helpers for working with Lisp.

;;; Code:

(defun dm-elisp--same-line-list-bounds ()
  "Return bounds of nearest enclosing list if it starts and ends on the same line."
  (save-excursion
    (condition-case nil
        (progn
          (backward-up-list)
          (let ((start (point))
                (end (scan-sexps (point) 1)))
            (when (= (line-number-at-pos start)
                     (line-number-at-pos end))
              (cons start end))))
      (scan-error nil))))

(defun dm-elisp--top-level-form-label ()
  "Return a compact label for the current top-level form."
  (save-excursion
    (end-of-defun)
    (beginning-of-defun)
    (ignore-errors
      (let ((form (read (current-buffer))))
        (cond
         ;; Named defining forms.
         ((and (consp form)
               (memq (car form)
                     '(defun defmacro defsubst
                        defvar defconst defcustom
                        defface defgroup
                        define-minor-mode define-derived-mode
                        use-package))
               (symbolp (cadr form)))
          (symbol-name (cadr form)))

         ;; Other top-level list forms.
         ((and (consp form)
               (symbolp (car form)))
          (symbol-name (car form)))

         ;; Fallback.
         (t
          "top-level form"))))))

(declare-function meow-cancel-selection "meow-command" ())

;;;###autoload
(defun dm-lisp-eval-sexp-dwim ()
  "Evaluate Elisp DWIM.

If a selection is active, evaluate the region.
Otherwise, if point is inside a same-line list form, evaluate that list.
Otherwise, evaluate the current top-level form.
If there is no top-level form, evaluate the buffer."
  (interactive)
  (cond
   ;; Active selection
   ((region-active-p)
    (eval-region (region-beginning) (region-end))
    (message "Evaluated region")
    (meow-cancel-selection))
   ;; Same-line sexp
   ((dm-elisp--same-line-list-bounds)
    (let* ((bounds (dm-elisp--same-line-list-bounds))
           (start (car bounds))
           (end (cdr bounds))
           (sexp (buffer-substring-no-properties start end)))
      (eval-region start end)
      (message "%s" sexp)))
   ;; Defun / Defcustom / etc
   ((bounds-of-thing-at-point 'defun)
    (let ((label (dm-elisp--top-level-form-label)))
      (eval-defun nil)
      (message "%s" label)))
   ;; Full buffer
   (t
    (eval-buffer)
    (message "buffer"))))


(provide 'dm-lisp)
;;; dm-lisp.el ends here
