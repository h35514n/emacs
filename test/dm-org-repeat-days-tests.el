;;; dm-org-repeat-days-tests.el --- Tests for dm-org-repeat-days  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root:
;;
;;   emacs -Q --batch \
;;     -L modules -L test \
;;     -L "$HOME/.dotfiles/share/emacs/straight/build/org" \
;;     -l dm-org-repeat-days-tests.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; The Org load path is only needed for the end-to-end tests; the parsing and
;; day-selection tests run against `dm-org-repeat-days' alone.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'calendar)
(require 'dm-org-repeat-days)

;;; ————————————————————————————
;;; Parsing
;;; ————————————————————————————

(ert-deftest dm-org-repeat-days-parse/groups ()
  (should (equal '(1 2 3 4 5) (dm-org-repeat-days-parse "weekdays")))
  (should (equal '(0 6) (dm-org-repeat-days-parse "weekends"))))

(ert-deftest dm-org-repeat-days-parse/single-and-multiple ()
  (should (equal '(1) (dm-org-repeat-days-parse "monday")))
  (should (equal '(1 3 5) (dm-org-repeat-days-parse "monday,wednesday,friday")))
  (should (equal '(0 1 2 3 4 5 6)
                 (dm-org-repeat-days-parse
                  "sunday,monday,tuesday,wednesday,thursday,friday,saturday"))))

(ert-deftest dm-org-repeat-days-parse/normalizes-case-and-whitespace ()
  (should (equal '(1 3 5) (dm-org-repeat-days-parse "Monday,Wednesday,FRIDAY")))
  (should (equal '(1 3 5) (dm-org-repeat-days-parse "  monday ,\twednesday , friday  ")))
  (should (equal '(1 3 5) (dm-org-repeat-days-parse "monday wednesday friday")))
  (should (equal '(1 2 3 4 5) (dm-org-repeat-days-parse " WeekDays "))))

(ert-deftest dm-org-repeat-days-parse/deduplicates-and-sorts ()
  (should (equal '(1 5) (dm-org-repeat-days-parse "friday,monday,friday")))
  ;; Groups and individual days may overlap.
  (should (equal '(1 2 3 4 5) (dm-org-repeat-days-parse "weekdays,monday")))
  (should (equal '(0 1 2 3 4 5 6) (dm-org-repeat-days-parse "weekdays,weekends"))))

(ert-deftest dm-org-repeat-days-parse/rejects-malformed ()
  (should-not (dm-org-repeat-days-parse "blursday"))
  ;; One bad token invalidates the whole spec rather than silently
  ;; scheduling on the subset that happened to parse.
  (should-not (dm-org-repeat-days-parse "monday,blursday"))
  (should-not (dm-org-repeat-days-parse "mon,wed"))
  (should-not (dm-org-repeat-days-parse "1,3,5")))

(ert-deftest dm-org-repeat-days-parse/rejects-empty ()
  (should-not (dm-org-repeat-days-parse nil))
  (should-not (dm-org-repeat-days-parse ""))
  (should-not (dm-org-repeat-days-parse "   "))
  (should-not (dm-org-repeat-days-parse ",,")))

(ert-deftest dm-org-repeat-days-parse/does-not-mutate-token-table ()
  (let ((before (copy-tree dm-org-repeat-days-tokens)))
    (dm-org-repeat-days-parse "weekdays,weekends,monday")
    (should (equal before dm-org-repeat-days-tokens))))

;;; ————————————————————————————
;;; Day selection
;;; ————————————————————————————

(ert-deftest dm-org-repeat-days-offset/allowed-day-does-not-move ()
  (should (= 0 (dm-org-repeat-days-offset 1 '(1 3 5))))
  (should (= 0 (dm-org-repeat-days-offset 0 '(0 6)))))

(ert-deftest dm-org-repeat-days-offset/advances-to-next-allowed ()
  ;; Tuesday -> Wednesday, Thursday -> Friday, Saturday -> Monday.
  (should (= 1 (dm-org-repeat-days-offset 2 '(1 3 5))))
  (should (= 1 (dm-org-repeat-days-offset 4 '(1 3 5))))
  (should (= 2 (dm-org-repeat-days-offset 6 '(1 3 5)))))

(ert-deftest dm-org-repeat-days-offset/empty-allowed-is-nil ()
  (should-not (dm-org-repeat-days-offset 3 nil)))

;;; ————————————————————————————
;;; Adjustment of a timestamp Org has already advanced
;;;
;;; Each case names the day the entry was completed on; the timestamp under
;;; test is the one Org produces from it, and the expectation is the final
;;; scheduled date.
;;; ————————————————————————————

(defun dm-org-repeat-days-tests--adjusted (timestamp spec)
  "Return the date TIMESTAMP lands on under SPEC, as \"YYYY-MM-DD Day\".

The arithmetic goes through absolute day numbers rather than encoded time
values, so these expectations hold in any timezone."
  (let* ((allowed (dm-org-repeat-days-parse spec))
         (offset (dm-org-repeat-days-adjustment timestamp allowed))
         (date (org-parse-time-string timestamp))
         (gregorian (calendar-gregorian-from-absolute
                     (+ offset
                        (calendar-absolute-from-gregorian
                         (list (decoded-time-month date)
                               (decoded-time-day date)
                               (decoded-time-year date)))))))
    (format "%04d-%02d-%02d %s"
            (calendar-extract-year gregorian)
            (calendar-extract-month gregorian)
            (calendar-extract-day gregorian)
            (aref calendar-day-abbrev-array (calendar-day-of-week gregorian)))))

(ert-deftest dm-org-repeat-days-adjustment/weekdays ()
  ;; Completed Friday: Org advances to Saturday, which must become Monday.
  (should (equal "2026-09-07 Mon"
                 (dm-org-repeat-days-tests--adjusted "<2026-09-05 Sat ++1d>" "weekdays")))
  ;; Completed Monday: Org advances to Tuesday, which is already allowed.
  (should (equal "2026-09-01 Tue"
                 (dm-org-repeat-days-tests--adjusted "<2026-09-01 Tue ++1d>" "weekdays"))))

(ert-deftest dm-org-repeat-days-adjustment/weekends ()
  ;; Completed Saturday: Org advances to Sunday, which is allowed.
  (should (equal "2026-09-06 Sun"
                 (dm-org-repeat-days-tests--adjusted "<2026-09-06 Sun ++1d>" "weekends")))
  ;; Completed Sunday: Org advances to Monday, which must become Saturday.
  (should (equal "2026-09-12 Sat"
                 (dm-org-repeat-days-tests--adjusted "<2026-09-07 Mon ++1d>" "weekends"))))

(ert-deftest dm-org-repeat-days-adjustment/monday-wednesday-friday ()
  ;; Mon -> Wed, Wed -> Fri, Fri -> Mon.
  (should (equal "2026-09-02 Wed"
                 (dm-org-repeat-days-tests--adjusted "<2026-09-01 Tue ++1d>" "monday,wednesday,friday")))
  (should (equal "2026-09-04 Fri"
                 (dm-org-repeat-days-tests--adjusted "<2026-09-03 Thu ++1d>" "monday,wednesday,friday")))
  (should (equal "2026-09-07 Mon"
                 (dm-org-repeat-days-tests--adjusted "<2026-09-05 Sat ++1d>" "monday,wednesday,friday"))))

(ert-deftest dm-org-repeat-days-adjustment/single-day-skips-a-full-week ()
  ;; Completed Monday: Org advances to Tuesday, which must become next Monday.
  (should (equal "2026-09-07 Mon"
                 (dm-org-repeat-days-tests--adjusted "<2026-09-01 Tue ++1d>" "monday"))))

(ert-deftest dm-org-repeat-days-adjustment/ignores-time-of-day ()
  (should (= 2 (dm-org-repeat-days-adjustment "<2026-09-05 Sat 23:59 ++1d>" '(1 3 5))))
  (should (= 2 (dm-org-repeat-days-adjustment "<2026-09-05 Sat 00:00 ++1d>" '(1 3 5))))
  (should (= 2 (dm-org-repeat-days-adjustment "<2026-09-05 Sat 09:30-10:30 ++1d>" '(1 3 5)))))

;;; ————————————————————————————
;;; Calendar boundaries
;;; ————————————————————————————

(ert-deftest dm-org-repeat-days-adjustment/crosses-month-boundary ()
  ;; 2026-09-30 is a Wednesday; the next weekend day is Saturday 2026-10-03.
  (should (equal "2026-10-03 Sat"
                 (dm-org-repeat-days-tests--adjusted "<2026-09-30 Wed ++1d>" "weekends"))))

(ert-deftest dm-org-repeat-days-adjustment/crosses-year-boundary ()
  ;; 2026-12-31 is a Thursday; the next Monday is 2027-01-04.
  (should (equal "2027-01-04 Mon"
                 (dm-org-repeat-days-tests--adjusted "<2026-12-31 Thu ++1d>" "monday"))))

(ert-deftest dm-org-repeat-days-adjustment/crosses-leap-day ()
  ;; 2028 is a leap year: 2028-02-28 is a Monday, and Wednesday is 2028-03-01
  ;; only because February has a 29th.
  (should (equal "2028-03-01 Wed"
                 (dm-org-repeat-days-tests--adjusted "<2028-02-28 Mon ++1d>" "wednesday")))
  ;; Non-leap 2027: 2027-02-28 is a Sunday, so Wednesday is 2027-03-03.
  (should (equal "2027-03-03 Wed"
                 (dm-org-repeat-days-tests--adjusted "<2027-02-28 Sun ++1d>" "wednesday"))))

(ert-deftest dm-org-repeat-days-adjustment/spans-dst-transitions ()
  ;; The offset is chosen from decoded calendar fields, so a span that crosses
  ;; a DST change is just three days like any other.
  ;; Spring forward 2026-03-08: Friday 2026-03-06 -> Monday 2026-03-09.
  (should (equal "2026-03-09 Mon"
                 (dm-org-repeat-days-tests--adjusted "<2026-03-06 Fri 00:30 ++1d>" "monday")))
  ;; Fall back 2026-11-01: Friday 2026-10-30 -> Monday 2026-11-02.
  (should (equal "2026-11-02 Mon"
                 (dm-org-repeat-days-tests--adjusted "<2026-10-30 Fri 00:30 ++1d>" "monday"))))

;;; ————————————————————————————
;;; End to end, through `org-todo'
;;;
;;; Each case pins the day the entry is completed on, because Org's own `++'
;;; handling shifts a repeater forward until it passes today.  Pinning keeps
;;; the expectations stable no matter when the suite runs.
;;; ————————————————————————————

(require 'org)

(defmacro dm-org-repeat-days-tests--completing-on (today entry &rest body)
  "Mark ENTRY DONE in a temporary Org buffer as of TODAY, then run BODY."
  (declare (indent 2) (debug t))
  `(cl-letf (((symbol-function 'org-today)
              (lambda () (time-to-days (org-time-string-to-time ,today)))))
     (with-temp-buffer
       (org-mode)
       (insert ,entry)
       (goto-char (point-min))
       (let ((org-log-done nil)
             (org-log-repeat nil)
             (org-todo-repeat-hook '(dm-org-repeat-days--adjust-h)))
         (org-todo "DONE"))
       ,@body)))

(defun dm-org-repeat-days-tests--scheduled ()
  "Return the SCHEDULED timestamp of the first entry in the buffer."
  (org-entry-get (point-min) "SCHEDULED"))

(ert-deftest dm-org-repeat-days-e2e/adjusts-to-next-allowed-day ()
  ;; Completed on its Wednesday: ++1d gives Thursday, which becomes Friday.
  (dm-org-repeat-days-tests--completing-on "<2026-09-02 Wed>"
      "* TODO Do workout
SCHEDULED: <2026-09-02 Wed ++1d>
:PROPERTIES:
:REPEAT_DAYS: monday,wednesday,friday
:END:
"
    (should (equal "<2026-09-04 Fri ++1d>" (dm-org-repeat-days-tests--scheduled)))
    ;; Org's own repeat handling is untouched: the entry is TODO again.
    (should (equal "TODO" (org-entry-get (point-min) "TODO")))))

(ert-deftest dm-org-repeat-days-e2e/leaves-allowed-day-alone ()
  ;; ++1d gives Tuesday, which weekdays already allows.
  (dm-org-repeat-days-tests--completing-on "<2026-08-31 Mon>"
      "* TODO Check job postings
SCHEDULED: <2026-08-31 Mon ++1d>
:PROPERTIES:
:REPEAT_DAYS: weekdays
:END:
"
    (should (equal "<2026-09-01 Tue ++1d>" (dm-org-repeat-days-tests--scheduled)))))

(ert-deftest dm-org-repeat-days-e2e/preserves-repeater-variants-and-time ()
  ;; All three variants advance Wednesday to Thursday when the entry is
  ;; completed on its scheduled day, and all three survive the adjustment
  ;; to Friday unrewritten, time of day included.
  (dolist (repeater '("+1d" "++1d" ".+1d"))
    (dm-org-repeat-days-tests--completing-on "<2026-09-02 Wed>"
        (format "* TODO Do workout
SCHEDULED: <2026-09-02 Wed 09:30 %s>
:PROPERTIES:
:REPEAT_DAYS: monday,wednesday,friday
:END:
" repeater)
      (should (equal (format "<2026-09-04 Fri 09:30 %s>" repeater)
                     (dm-org-repeat-days-tests--scheduled))))))

(ert-deftest dm-org-repeat-days-e2e/lands-on-the-right-date-across-dst ()
  ;; Adding elapsed seconds instead of calendar days lands a day early here:
  ;; three times 86400s from 00:30 on Friday 2026-10-30 is 23:30 on Sunday the
  ;; 1st, because that night the clock falls back an hour.
  (let ((original-tz (getenv "TZ")))
    (unwind-protect
        (progn
          (setenv "TZ" "America/New_York")
          ;; Fall back, 2026-11-01: Thu -> Fri -> Monday the 2nd.
          (dm-org-repeat-days-tests--completing-on "<2026-10-28 Wed>"
              "* TODO Early standup
SCHEDULED: <2026-10-29 Thu 00:30 ++1d>
:PROPERTIES:
:REPEAT_DAYS: monday
:END:
"
            (should (equal "<2026-11-02 Mon 00:30 ++1d>"
                           (dm-org-repeat-days-tests--scheduled))))
          ;; Spring forward, 2026-03-08: Thu -> Fri -> Monday the 9th.
          (dm-org-repeat-days-tests--completing-on "<2026-03-04 Wed>"
              "* TODO Early standup
SCHEDULED: <2026-03-05 Thu 00:30 ++1d>
:PROPERTIES:
:REPEAT_DAYS: monday
:END:
"
            (should (equal "<2026-03-09 Mon 00:30 ++1d>"
                           (dm-org-repeat-days-tests--scheduled)))))
      (setenv "TZ" original-tz))))

(ert-deftest dm-org-repeat-days-e2e/ignores-entries-without-the-property ()
  (dm-org-repeat-days-tests--completing-on "<2026-09-02 Wed>"
      "* TODO Water plants
SCHEDULED: <2026-09-02 Wed ++1d>
"
    (should (equal "<2026-09-03 Thu ++1d>" (dm-org-repeat-days-tests--scheduled)))))

(ert-deftest dm-org-repeat-days-e2e/ignores-non-repeating-entries ()
  ;; No repeater, so nothing repeats and REPEAT_DAYS has nothing to constrain.
  (dm-org-repeat-days-tests--completing-on "<2026-09-02 Wed>"
      "* TODO Water plants
SCHEDULED: <2026-09-02 Wed>
:PROPERTIES:
:REPEAT_DAYS: monday,wednesday,friday
:END:
"
    (should (equal "<2026-09-02 Wed>" (dm-org-repeat-days-tests--scheduled)))
    (should (equal "DONE" (org-entry-get (point-min) "TODO")))))

(ert-deftest dm-org-repeat-days-e2e/warns-and-keeps-org-date-when-malformed ()
  (let (warnings)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (type message &optional _level &rest _)
                 (push (cons type message) warnings))))
      (dm-org-repeat-days-tests--completing-on "<2026-09-02 Wed>"
          "* TODO Do workout
SCHEDULED: <2026-09-02 Wed ++1d>
:PROPERTIES:
:REPEAT_DAYS: monday,blursday
:END:
"
        (should (equal "<2026-09-03 Thu ++1d>" (dm-org-repeat-days-tests--scheduled)))))
    (should (= 1 (length warnings)))
    (should (eq 'dm-org-repeat-days (car (car warnings))))
    (should (string-match-p "blursday" (cdr (car warnings))))))

(ert-deftest dm-org-repeat-days-e2e/leaves-a-repeating-deadline-to-org ()
  ;; Only SCHEDULED is in scope: the DEADLINE keeps Org's own date.
  (dm-org-repeat-days-tests--completing-on "<2026-09-02 Wed>"
      "* TODO File report
DEADLINE: <2026-09-02 Wed ++1d> SCHEDULED: <2026-09-02 Wed ++1d>
:PROPERTIES:
:REPEAT_DAYS: monday,wednesday,friday
:END:
"
    (should (equal "<2026-09-04 Fri ++1d>" (dm-org-repeat-days-tests--scheduled)))
    (should (equal "<2026-09-03 Thu ++1d>" (org-entry-get (point-min) "DEADLINE")))))

(provide 'dm-org-repeat-days-tests)
;;; dm-org-repeat-days-tests.el ends here
