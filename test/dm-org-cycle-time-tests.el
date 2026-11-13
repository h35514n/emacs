;;; dm-org-cycle-time-tests.el --- Tests for dm-org-cycle-time  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root:
;;
;;   bin/test dm-org-cycle-time

;;; Code:

(require 'ert)
(require 'org)
(require 'dm-org-cycle-time)

(defun dm-org-cycle-time-tests--entry (heading)
  "Return Org text for HEADING with WIP 2026-11-02 and APPROVED 2026-11-09."
  (format "* APPROVED %s
:LOGBOOK:
- State \"APPROVED\"   from \"IN_REVIEW\" [2026-11-09 Mon 10:00]
- State \"IN_REVIEW\"  from \"WIP\"       [2026-11-05 Thu 10:00]
- State \"WIP\"        from \"TODO\"      [2026-11-02 Mon 09:00]
:END:
" heading))

(defun dm-org-cycle-time-tests--rows (text)
  "Return data rows of the table for Org TEXT."
  (with-temp-buffer
    (insert "#+TODO: TODO WIP IN_REVIEW | APPROVED\n" text)
    (delay-mode-hooks (org-mode))
    (cddr (dm-org-cycle-time-table))))

(ert-deftest dm-org-cycle-time-plain-heading ()
  (should (equal (dm-org-cycle-time-tests--rows
                  (dm-org-cycle-time-tests--entry "API-1: Plain"))
                 '(("API-1" "11/02" 3 "11/05" 2 "11/09" 5)))))

(ert-deftest dm-org-cycle-time-link-headings ()
  (dolist (heading '("[[jira:API-2][API-2]]: Jira link"
                     "[[https://example.com/browse/API-2][API-2]]: URL link"))
    (should (equal (dm-org-cycle-time-tests--rows
                    (dm-org-cycle-time-tests--entry heading))
                   '(("API-2" "11/02" 3 "11/05" 2 "11/09" 5))))))

(ert-deftest dm-org-cycle-time-skips-untracked-headings ()
  (should-not (dm-org-cycle-time-tests--rows
               (dm-org-cycle-time-tests--entry "Not a ticket"))))

(ert-deftest dm-org-cycle-time-missing-milestones ()
  (should (equal (dm-org-cycle-time-tests--rows
                  "* WIP API-3: Only started
:LOGBOOK:
- State \"WIP\"        from \"TODO\"      [2026-11-02 Mon 09:00]
:END:
")
                 '(("API-3" "11/02" "" "" "" "" "")))))

(ert-deftest dm-org-cycle-time-dblock-fills-table ()
  (with-temp-buffer
    (insert "#+TODO: TODO WIP IN_REVIEW | APPROVED\n"
            (dm-org-cycle-time-tests--entry "[[jira:API-4][API-4]]: Linked")
            "#+BEGIN: cycle-time\n#+END:\n")
    (delay-mode-hooks (org-mode))
    (org-update-all-dblocks)
    (should (string-match-p "| API-4 +| 11/02 +| +3 | 11/05 +| +2 | 11/09 +| +5 |"
                            (buffer-string)))))

(provide 'dm-org-cycle-time-tests)
;;; dm-org-cycle-time-tests.el ends here
