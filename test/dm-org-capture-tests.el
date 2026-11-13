;;; dm-org-capture-tests.el --- Tests for dm-org-capture  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with: bin/test dm-org-capture

;;; Code:

(require 'ert)
(require 'subr-x)
(defvar org-capture-templates)
(defvar org-directory)
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

(ert-deftest dm-org-capture-standup-template-registered ()
  (should (assoc "u" org-capture-templates)))

(provide 'dm-org-capture-tests)
;;; dm-org-capture-tests.el ends here
