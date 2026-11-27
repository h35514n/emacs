;;; dm-org-capture-tests.el --- Tests for dm-org-capture  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with: bin/test dm-org-capture

;;; Code:

(require 'ert)
(require 'subr-x)
(defvar org-capture-templates)
(defvar org-directory)
(defvar org-overriding-default-time)
(require 'dm-org-capture)

(defconst dm-org-capture-tests--standup
  "* 2026
** 2026-W45
*** 2026-11-12 Thursday
*Yesterday*:
- old
*Today*:
- [[jira:API-1][API-1]] WIP: thing
- [[jira:API-2][API-2]] review
*Blocked / Waiting*:
- nothing
*** 2026-11-13 Friday
")

(ert-deftest dm-org-capture-standup-copies-previous-today ()
  (should (equal (dm-org-capture--standup-previous-today
                  dm-org-capture-tests--standup "2026-11-13")
                 "- [[jira:API-1][API-1]] WIP: thing\n- [[jira:API-2][API-2]] review")))

(ert-deftest dm-org-capture-standup-skips-today-and-later ()
  (should-not (dm-org-capture--standup-previous-today
               dm-org-capture-tests--standup "2026-11-12")))

(ert-deftest dm-org-capture-standup-empty-today-yields-nil ()
  (should-not (dm-org-capture--standup-previous-today
               "*** 2026-11-12 Thursday\n*Today*:\n*Blocked / Waiting*:\n- x\n"
               "2026-11-13")))

(ert-deftest dm-org-capture-standup-carries-previous-blocked ()
  (let ((text "*** 2026-11-12 Thursday\n*Today*:\n- a\n*Blocked / Waiting*:\n- waiting on X\n"))
    (should (equal (dm-org-capture--standup-previous-blocked text "2026-11-13")
                   "- waiting on X"))
    (should-not (dm-org-capture--standup-previous-blocked
                 "*** 2026-11-12 Thursday\n*Today*:\n- a\n*Blocked / Waiting*:\n- \n"
                 "2026-11-13"))))

(ert-deftest dm-org-capture-standup-tomorrow-template ()
  (let* ((org-directory (make-temp-file "standup" t))
         (org-overriding-default-time (encode-time 0 0 12 14 11 2026)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "STANDUP.org" org-directory)
            (insert "*** 2026-11-13 Friday\n*Today*:\n- a\n- b\n"
                    "*Blocked / Waiting*:\n- waiting\n"))
          (should (equal (dm-org-capture--standup)
                         (concat "*Friday*:\n- a\n- b\n*Today*:\n- %?\n"
                                 "*Blocked / Waiting*:\n- waiting\n"))))
      (delete-directory org-directory t))))

(ert-deftest dm-org-capture-next-workday-skips-weekend ()
  (let ((fmt (lambda (d m)
               (format-time-string
                "%F" (dm-org-capture--next-workday
                      (encode-time 0 0 12 d m 2026))))))
    (should (equal (funcall fmt 26 11) "2026-11-27"))
    (should (equal (funcall fmt 27 11) "2026-11-30"))
    (should (equal (funcall fmt 28 11) "2026-11-30"))
    (should (equal (funcall fmt 29 11) "2026-11-30"))))

(ert-deftest dm-org-capture-standup-template-registered ()
  (should (assoc "u" org-capture-templates)))

(provide 'dm-org-capture-tests)
;;; dm-org-capture-tests.el ends here
