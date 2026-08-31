;;; dm-org-agenda-capacity-tests.el --- Tests for dm-org-agenda-capacity  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root:
;;
;;   emacs -Q --batch \
;;     -L modules -L test \
;;     -L "$HOME/.dotfiles/share/emacs/straight/build/org" \
;;     -l dm-org-agenda-capacity-tests.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; The capacity-lookup and formatting tests need only the module itself; the
;; accounting tests build a real agenda over a temporary Org file, because
;; what is under test is precisely which lines Org puts in the buffer and what
;; it hangs on them.
;;
;; The fixture is pinned to the week of Monday 2026-08-31 and the agenda is
;; asked for that week explicitly, so the tests do not depend on the day they
;; are run.  The one exception is noted on the deadline-preview test.

;;; Code:

(require 'ert)
(require 'calendar)
(require 'org)
(require 'org-agenda)
(require 'dm-org-agenda-capacity)

;;; ————————————————————————————
;;; Capacity lookup
;;; ————————————————————————————

(defun dm-org-agenda-capacity-tests--absolute (month day year)
  (calendar-absolute-from-gregorian (list month day year)))

(ert-deftest dm-org-agenda-capacity-for-day/reads-the-weekday ()
  (let ((dm-org-daily-capacity '((1 . 360) (5 . 300) (0 . 180))))
    ;; 2026-08-31 is a Monday, 2026-09-04 a Friday, 2026-09-06 a Sunday.
    (should (= 360 (dm-org-agenda-capacity-for-day
                    (dm-org-agenda-capacity-tests--absolute 8 31 2026))))
    (should (= 300 (dm-org-agenda-capacity-for-day
                    (dm-org-agenda-capacity-tests--absolute 9 4 2026))))
    (should (= 180 (dm-org-agenda-capacity-for-day
                    (dm-org-agenda-capacity-tests--absolute 9 6 2026))))))

(ert-deftest dm-org-agenda-capacity-for-day/unconfigured-weekday-is-nil ()
  (let ((dm-org-daily-capacity '((1 . 360))))
    ;; Tuesday has no entry.
    (should-not (dm-org-agenda-capacity-for-day
                 (dm-org-agenda-capacity-tests--absolute 9 1 2026)))))

(ert-deftest dm-org-agenda-capacity--absolute/accepts-both-forms ()
  (let ((day (dm-org-agenda-capacity-tests--absolute 8 31 2026)))
    (should (= day (dm-org-agenda-capacity--absolute '(8 31 2026))))
    (should (= day (dm-org-agenda-capacity--absolute day)))))

;;; ————————————————————————————
;;; Intervals
;;; ————————————————————————————

(ert-deftest dm-org-agenda-capacity--hhmm-to-minutes/converts-military-time ()
  (should (= 0 (dm-org-agenda-capacity--hhmm-to-minutes 0)))
  (should (= 540 (dm-org-agenda-capacity--hhmm-to-minutes 900)))
  (should (= 1230 (dm-org-agenda-capacity--hhmm-to-minutes 2030)))
  (should (= 1439 (dm-org-agenda-capacity--hhmm-to-minutes 2359))))

(ert-deftest dm-org-agenda-capacity--merge-intervals/sorts-and-coalesces ()
  (should (equal '((60 . 120) (180 . 240))
                 (dm-org-agenda-capacity--merge-intervals '((180 . 240) (60 . 120)))))
  ;; Overlapping, touching and nested all collapse to one.
  (should (equal '((60 . 180))
                 (dm-org-agenda-capacity--merge-intervals '((60 . 120) (90 . 180)))))
  (should (equal '((60 . 180))
                 (dm-org-agenda-capacity--merge-intervals '((60 . 120) (120 . 180)))))
  (should (equal '((60 . 180))
                 (dm-org-agenda-capacity--merge-intervals '((60 . 180) (90 . 120)))))
  (should-not (dm-org-agenda-capacity--merge-intervals nil)))

(ert-deftest dm-org-agenda-capacity--merge-intervals/does-not-mutate-input ()
  (let* ((blocks (list (cons 180 240) (cons 60 120)))
         (before (copy-tree blocks)))
    (dm-org-agenda-capacity--merge-intervals blocks)
    (should (equal before blocks))))

(ert-deftest dm-org-agenda-capacity--free-runs/no-blocks-is-the-whole-window ()
  (should (equal '((540 . 1080))
                 (dm-org-agenda-capacity--free-runs '(540 . 1080) nil))))

(ert-deftest dm-org-agenda-capacity--free-runs/splits-around-a-block ()
  (should (equal '((540 . 660) (780 . 1080))
                 (dm-org-agenda-capacity--free-runs '(540 . 1080) '((660 . 780))))))

(ert-deftest dm-org-agenda-capacity--free-runs/blocks-at-the-edges ()
  (should (equal '((660 . 1080))
                 (dm-org-agenda-capacity--free-runs '(540 . 1080) '((540 . 660)))))
  (should (equal '((540 . 960))
                 (dm-org-agenda-capacity--free-runs '(540 . 1080) '((960 . 1080)))))
  (should-not (dm-org-agenda-capacity--free-runs '(540 . 1080) '((540 . 1080)))))

(ert-deftest dm-org-agenda-capacity--free-runs/ignores-blocks-outside-the-window ()
  ;; A 20:30 appointment does not shorten a nine-to-five.
  (should (equal '((540 . 1080))
                 (dm-org-agenda-capacity--free-runs '(540 . 1080) '((1230 . 1290)))))
  ;; One overhanging an edge is clipped rather than dropped.
  (should (equal '((600 . 1080))
                 (dm-org-agenda-capacity--free-runs '(540 . 1080) '((420 . 600))))))

(ert-deftest dm-org-agenda-capacity--fit/places-in-order ()
  (let ((result (dm-org-agenda-capacity--fit '((540 . 1080))
                                             '((a . 120) (b . 60)))))
    (should (equal '((a 540 . 660) (b 660 . 720)) (car result)))
    (should-not (cdr result))))

(ert-deftest dm-org-agenda-capacity--fit/fragmentation-defeats-a-fitting-total ()
  ;; 5:30 of work into 6:00 of free time that no run can hold two of.
  (let ((result (dm-org-agenda-capacity--fit '((540 . 720) (900 . 1080))
                                             '((a . 120) (b . 120) (c . 90)))))
    (should (equal '((a 540 . 660) (b 900 . 1020)) (car result)))
    (should (equal '(c) (cdr result)))))

(ert-deftest dm-org-agenda-capacity--fit/task-larger-than-any-run ()
  (let ((result (dm-org-agenda-capacity--fit '((540 . 600)) '((a . 120)))))
    (should-not (car result))
    (should (equal '(a) (cdr result)))))

(ert-deftest dm-org-agenda-capacity--fit/no-runs-places-nothing ()
  (let ((result (dm-org-agenda-capacity--fit nil '((a . 60)))))
    (should-not (car result))
    (should (equal '(a) (cdr result)))))

(ert-deftest dm-org-agenda-capacity--fit/does-not-mutate-the-runs ()
  (let* ((runs (list (cons 540 1080)))
         (before (copy-tree runs)))
    (dm-org-agenda-capacity--fit runs '((a . 120)))
    (should (equal before runs))))

;;; ————————————————————————————
;;; Formatting
;;; ————————————————————————————

(ert-deftest dm-org-agenda-capacity-format/within-capacity ()
  (should (equal "5:30 / 6:00"
                 (dm-org-agenda-capacity-format
                  '(:capacity 360 :total 330 :remaining 30)))))

(ert-deftest dm-org-agenda-capacity-format/over-capacity ()
  (should (equal "7:30 / 6:00  OVER 1:30"
                 (dm-org-agenda-capacity-format
                  '(:capacity 360 :total 450 :remaining -90)))))

(ert-deftest dm-org-agenda-capacity-format/exactly-at-capacity-is-not-over ()
  (should (equal "6:00 / 6:00"
                 (dm-org-agenda-capacity-format
                  '(:capacity 360 :total 360 :remaining 0)))))

(ert-deftest dm-org-agenda-capacity-format/stays-in-hours-past-a-day ()
  ;; The default `org-duration-format' would render this as "1d 2:00", which
  ;; reads as nonsense beside a capacity in H:MM.
  (should (equal "26:00 / 6:00  OVER 20:00"
                 (dm-org-agenda-capacity-format
                  '(:capacity 360 :total 1560 :remaining -1200)))))

(ert-deftest dm-org-agenda-capacity-format/no-capacity-shows-nothing ()
  (should-not (dm-org-agenda-capacity-format
               '(:capacity nil :total 330 :remaining nil))))

;;; ————————————————————————————
;;; Accounting against a real agenda buffer
;;; ————————————————————————————

(defconst dm-org-agenda-capacity-tests--fixture "\
* TODO Write the report
  SCHEDULED: <2026-08-31 Mon>
  :PROPERTIES:
  :EFFORT:   2:00
  :END:
* TODO Review the PRs
  SCHEDULED: <2026-08-31 Mon>
  :PROPERTIES:
  :EFFORT:   1:30
  :END:
* TODO Standup sync
  SCHEDULED: <2026-08-31 Mon 20:30>
  :PROPERTIES:
  :EFFORT:   0:30
  :END:
* TODO Unestimated errand
  SCHEDULED: <2026-08-31 Mon>
* DONE Already finished
  CLOSED: [2026-08-31 Mon 09:00]
  SCHEDULED: <2026-08-31 Mon>
  :PROPERTIES:
  :EFFORT:   4:00
  :END:
* TODO Scheduled and due the same day
  DEADLINE: <2026-08-31 Mon> SCHEDULED: <2026-08-31 Mon>
  :PROPERTIES:
  :EFFORT:   1:00
  :END:
* TODO Due later this week
  DEADLINE: <2026-09-03 Thu>
  :PROPERTIES:
  :EFFORT:   3:00
  :END:
"
  "One week of entries covering every case the accounting has to separate.")

(defmacro dm-org-agenda-capacity-tests--with-agenda (&rest body)
  "Build an agenda over the fixture for the week of 2026-08-31 and run BODY.

BODY runs in the agenda buffer.  The agenda settings mirror the ones in
`dm-org' that change what lands in the buffer -- log mode especially, which
adds the \"Closed:\" lines the accounting has to ignore."
  (declare (indent 0) (debug t))
  `(let ((file (make-temp-file "dm-org-agenda-capacity" nil ".org"
                               dm-org-agenda-capacity-tests--fixture))
         (org-agenda-buffer-name "*dm-org-agenda-capacity-test*"))
     (unwind-protect
         (let ((org-agenda-files (list file))
               (org-agenda-entry-types '(:deadline :scheduled :timestamp :sexp))
               (org-agenda-format-date
                (lambda (date) (concat "\n" (org-agenda-format-date-aligned date))))
               (org-agenda-prefix-format '((agenda . "[%4e] %5t ")))
               (org-agenda-skip-deadline-if-done t)
               (org-agenda-skip-scheduled-if-done t)
               (org-agenda-start-with-log-mode t)
               (org-agenda-use-time-grid nil)
               (org-agenda-window-setup 'current-window)
               (org-agenda-sticky nil)
               (org-deadline-warning-days 7)
               (dm-org-daily-capacity '((1 . 360) (4 . 360)))
               (dm-org-daily-workday '((1 . (540 . 1080)) (4 . (540 . 1080)))))
           (save-window-excursion
             (org-agenda-list nil "2026-08-31" 7))
           (with-current-buffer org-agenda-buffer-name ,@body))
       (when (get-buffer org-agenda-buffer-name)
         (kill-buffer org-agenda-buffer-name))
       (delete-file file))))

(ert-deftest dm-org-agenda-day-load/sums-only-actionable-effort ()
  (dm-org-agenda-capacity-tests--with-agenda
    (let ((load (dm-org-agenda-day-load '(8 31 2026))))
      ;; 2:00 + 1:30 flexible, 0:30 fixed, 1:00 scheduled-and-due counted once.
      ;; The DONE 4:00 entry and the unestimated errand add nothing.
      (should (= 30 (plist-get load :fixed)))
      (should (= 270 (plist-get load :flexible)))
      (should (= 300 (plist-get load :total)))
      (should (= 360 (plist-get load :capacity)))
      (should (= 60 (plist-get load :remaining)))
      (should (= 1 (plist-get load :unestimated))))))

(ert-deftest dm-org-agenda-day-load/counts-a-deadline-on-its-own-day ()
  (dm-org-agenda-capacity-tests--with-agenda
    ;; The 3:00 deadline is due Thursday and previewed on today from inside
    ;; the seven-day warning window.  It must be charged here and nowhere
    ;; else; the preview is what the "upcoming-deadline" exclusion drops.
    (let ((load (dm-org-agenda-day-load '(9 3 2026))))
      (should (= 180 (plist-get load :total)))
      (should (= 180 (plist-get load :remaining))))))

(ert-deftest dm-org-agenda-day-load/unconfigured-weekday-reports-nil ()
  (dm-org-agenda-capacity-tests--with-agenda
    ;; Only Monday and Thursday have capacity in the fixture's binding.
    (let ((load (dm-org-agenda-day-load '(9 1 2026))))
      (should-not (plist-get load :capacity))
      (should-not (plist-get load :remaining))
      (should (= 0 (plist-get load :total))))))

(ert-deftest dm-org-agenda-day-load/outside-an-agenda-buffer-errors ()
  (with-temp-buffer
    (should-error (dm-org-agenda-day-load '(8 31 2026)) :type 'user-error)))

;;; ————————————————————————————
;;; Rendering into the date header
;;; ————————————————————————————

(defun dm-org-agenda-capacity-tests--annotations ()
  "Return an alist of (HEADER-TEXT . (SUMMARY . FACE)) for the current buffer."
  (let (result)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (dm-org-agenda-capacity--date-header-p)
          (let ((beg (text-property-any (line-beginning-position)
                                        (line-end-position)
                                        'dm-org-agenda-capacity t)))
            (push (cons (string-trim
                         (buffer-substring-no-properties
                          (line-beginning-position) (or beg (line-end-position))))
                        (and beg
                             (cons (string-trim
                                    (buffer-substring-no-properties
                                     beg (line-end-position)))
                                   (get-text-property beg 'face))))
                  result)))
        (forward-line 1)))
    (nreverse result)))

(ert-deftest dm-org-agenda-capacity-annotate/marks-only-overloaded-days ()
  (dm-org-agenda-capacity-tests--with-agenda
    (let* ((dm-org-daily-capacity '((1 . 240) (4 . 360)))
           (_ (dm-org-agenda-capacity-annotate-h))
           (annotations (dm-org-agenda-capacity-tests--annotations))
           (monday (cdr (assoc "Monday     31 August 2026 W36" annotations)))
           (thursday (cdr (assoc "Thursday    3 September 2026" annotations))))
      ;; Monday is planned to 5:00 against a 4:00 capacity.
      (should (equal "5:00 / 4:00  OVER 1:00" (car monday)))
      (should (eq 'dm-org-agenda-capacity-over (cdr monday)))
      ;; Thursday is within capacity and keeps the date header's own face.
      (should (equal "3:00 / 6:00" (car thursday)))
      (should-not (eq 'dm-org-agenda-capacity-over (cdr thursday))))))

(ert-deftest dm-org-agenda-capacity-annotate/marks-a-day-that-does-not-fit ()
  (dm-org-agenda-capacity-tests--with-agenda
    ;; 4:30 of flexible work against 4:00 of window but 6:00 of capacity: the
    ;; arithmetic is fine and the clock is not.
    (let* ((dm-org-daily-workday '((1 . (540 . 780))))
           (_ (dm-org-agenda-capacity-annotate-h))
           (monday (cdr (assoc "Monday     31 August 2026 W36"
                               (dm-org-agenda-capacity-tests--annotations)))))
      (should (equal "5:00 / 6:00  TIGHT" (car monday)))
      (should (eq 'dm-org-agenda-capacity-tight (cdr monday))))))

(ert-deftest dm-org-agenda-capacity-annotate/over-outranks-tight ()
  (dm-org-agenda-capacity-tests--with-agenda
    ;; Both conditions hold; only the more serious one is reported.
    (let* ((dm-org-daily-capacity '((1 . 240)))
           (dm-org-daily-workday '((1 . (540 . 780))))
           (_ (dm-org-agenda-capacity-annotate-h))
           (monday (cdr (assoc "Monday     31 August 2026 W36"
                               (dm-org-agenda-capacity-tests--annotations)))))
      (should (equal "5:00 / 4:00  OVER 1:00" (car monday)))
      (should (eq 'dm-org-agenda-capacity-over (cdr monday))))))

(ert-deftest dm-org-agenda-capacity-annotate/no-window-means-no-fit-check ()
  (dm-org-agenda-capacity-tests--with-agenda
    (let* ((dm-org-daily-workday nil)
           (_ (dm-org-agenda-capacity-annotate-h))
           (monday (cdr (assoc "Monday     31 August 2026 W36"
                               (dm-org-agenda-capacity-tests--annotations)))))
      ;; Same work, no window configured: nothing to fail to fit.
      (should (equal "5:00 / 6:00" (car monday)))
      (should-not (eq 'dm-org-agenda-capacity-tight (cdr monday))))))

(ert-deftest dm-org-agenda-day-plan/reports-runs-and-fit ()
  (dm-org-agenda-capacity-tests--with-agenda
    (let ((plan (dm-org-agenda-day-plan '(8 31 2026))))
      (should (equal '(540 . 1080) (plist-get plan :window)))
      ;; The 20:30 fixed item lies outside the window and reserves nothing,
      ;; so the day is one unbroken run despite having fixed work on it.
      (should (equal '((1230 . 1260)) (plist-get plan :blocks)))
      (should (equal '((540 . 1080)) (plist-get plan :runs)))
      (should (plist-get plan :fits))
      (should-not (plist-get plan :unplaced))
      ;; The arithmetic keys still read as they did before the plan existed.
      (should (= 300 (plist-get plan :total))))))

(ert-deftest dm-org-agenda-day-plan/fixed-work-carves-up-the-window ()
  (dm-org-agenda-capacity-tests--with-agenda
    ;; Widen the window to swallow the 20:30 appointment and it starts to bite.
    (let ((dm-org-daily-workday '((1 . (540 . 1320)))))
      (let ((plan (dm-org-agenda-day-plan '(8 31 2026))))
        (should (equal '((1230 . 1260)) (plist-get plan :blocks)))
        (should (equal '((540 . 1230) (1260 . 1320)) (plist-get plan :runs)))))))

(ert-deftest dm-org-agenda-capacity-annotate/is-idempotent ()
  (dm-org-agenda-capacity-tests--with-agenda
    (let ((once (buffer-string)))
      (dm-org-agenda-capacity-annotate-h)
      (dm-org-agenda-capacity-annotate-h)
      ;; Org finalizes the buffer again every time an agenda line changes, so
      ;; the annotation has to be rewritten rather than appended.
      (should (equal once (buffer-string))))))

(ert-deftest dm-org-agenda-capacity-annotate/aligns-summaries-in-one-column ()
  (dm-org-agenda-capacity-tests--with-agenda
    ;; Date headers vary in width -- only a Monday carries a week number, and
    ;; month names differ -- so the summaries have to be padded to a shared
    ;; column rather than appended at a fixed offset.  The annotation starts
    ;; at its padding; what has to line up is the text after it.
    (let ((columns nil))
      (goto-char (point-min))
      (while (not (eobp))
        (when (dm-org-agenda-capacity--date-header-p)
          (let ((beg (text-property-any (line-beginning-position)
                                        (line-end-position)
                                        'dm-org-agenda-capacity t)))
            (when beg
              (goto-char beg)
              (skip-chars-forward " ")
              (push (current-column) columns))))
        (forward-line 1))
      (should (= 2 (length columns)))
      (should (= 1 (length (delete-dups columns)))))))

(ert-deftest dm-org-agenda-capacity-annotate/leaves-headerless-views-alone ()
  (let ((org-agenda-buffer-name "*dm-org-agenda-capacity-test*")
        (file (make-temp-file "dm-org-agenda-capacity" nil ".org"
                              dm-org-agenda-capacity-tests--fixture)))
    (unwind-protect
        (let ((org-agenda-files (list file))
              (org-agenda-window-setup 'current-window)
              (org-agenda-sticky nil))
          (save-window-excursion (org-todo-list))
          (with-current-buffer org-agenda-buffer-name
            (should-not (text-property-any (point-min) (point-max)
                                           'dm-org-agenda-capacity t))))
      (when (get-buffer org-agenda-buffer-name)
        (kill-buffer org-agenda-buffer-name))
      (delete-file file))))

(provide 'dm-org-agenda-capacity-tests)
;;; dm-org-agenda-capacity-tests.el ends here
