;;; dm-org-agenda-capacity.el --- Daily capacity accounting in the agenda  -*- lexical-binding: t; -*-

;;; Commentary:

;; Annotate each date header in the agenda with the day's planned effort
;; against a configured capacity for that weekday:
;;
;;     Monday     31 August 2026 W36    5:30 / 6:00
;;     Tuesday     1 September 2026     7:30 / 6:00  OVER 1:30
;;
;; Nothing is stored outside Org.  The numbers come from EFFORT properties the
;; agenda has already parsed, so there is no second task database and no
;; scheduling information to keep in sync.
;;
;; Why `org-agenda-finalize-hook':
;;
;; `org-agenda-format-date' looks like the natural place to put this, but it
;; is called before the day's entries are inserted, so at that point the
;; buffer says nothing about what is planned -- deriving the total would mean
;; scanning the Org files a second time.  `org-agenda-list' also stamps the
;; day face over the whole header line immediately after calling the
;; formatter, which would erase any face the formatter had applied.
;;
;; `org-agenda-finalize-hook' runs once the buffer is fully built, inside
;; Org's own `inhibit-read-only' binding, and by then every agenda line
;; carries what is needed as text properties: `day' (the absolute day number,
;; applied across the header and that day's entries), `effort-minutes' (Org's
;; own `org-duration-to-minutes' result, so no H:MM parsing here),
;; `todo-state', `type', `time-of-day', and `org-hd-marker'.  Reading those is
;; both cheaper and more faithful than recomputing anything.
;;
;; Which entries count is a judgment call, so it is a user option --
;; `dm-org-agenda-capacity-entry-types'.  Two exclusions in the default are
;; load-bearing rather than cosmetic:
;;
;;   - "upcoming-deadline" is a deadline previewed on today from inside its
;;     warning window.  It is also rendered on its own due date as "deadline",
;;     so counting both would charge the same work once per warning day.
;;
;;   - "block" is a <date>--<date> range, rendered on every day it spans;
;;     counting it would multiply one entry's effort across the range.
;;
;; The log-mode types ("closed", "clock", "state") are excluded for the same
;; reason completed entries are: they are history, not plan.
;;
;; A heading can legitimately appear more than once on one day -- scheduled
;; today and also due today, say.  Entries are therefore deduplicated on
;; (DAY . `org-hd-marker'), which both `org-agenda-get-scheduled' and
;; `org-agenda-get-deadlines' set to the heading's line beginning.
;;
;; Beyond the arithmetic, `dm-org-agenda-day-plan' takes the fixed/flexible
;; split -- fixed being a scheduled timestamp that carries a clock time --
;; through to the clock.  Fixed work is subtracted from the day's window from
;; `dm-org-daily-workday' to leave its free runs, and the flexible work is
;; first-fit into them.  That catches a day the totals call fine: 5:30 of work
;; against 6:00 of capacity does not fit if a meeting splits the day into runs
;; of 3:00 and 3:30 and two of the tasks are two hours each.  Such a day is
;; marked TIGHT, one severity step below OVER.
;;
;; Nothing here writes.  The commands that propose and apply clock times live
;; in `dm-org-agenda-plan', which builds on this module; the dependency runs
;; one way, so everything in this file stays safe to run on any agenda.

;;; Code:

(declare-function calendar-absolute-from-gregorian "calendar" (date))
(declare-function calendar-day-of-week "calendar" (date))
(declare-function calendar-gregorian-from-absolute "calendar" (date))
(declare-function org-duration-from-minutes "org-duration" (minutes &optional fmt canonical))
(declare-function org-get-at-bol "org" (property))
(defvar org-done-keywords-for-agenda)

(defgroup dm-org-agenda-capacity nil
  "Daily capacity accounting for the Org agenda."
  :group 'org-agenda)

(defcustom dm-org-daily-capacity
  '((1 . 360)   ; Monday
    (2 . 360)   ; Tuesday
    (3 . 360)   ; Wednesday
    (4 . 360)   ; Thursday
    (5 . 300)   ; Friday
    (6 . 180)   ; Saturday
    (0 . 180))  ; Sunday
  "Realistic working capacity per weekday, in minutes.

Keys are day numbers as `calendar-day-of-week' returns them, 0 for Sunday
through 6 for Saturday.  Values are whole minutes of focused work the day can
absorb, which is normally well under its waking hours.

A weekday with no entry has no configured capacity: the agenda leaves its date
header alone, and `dm-org-agenda-day-load' reports :capacity and :remaining as
nil.  Drop a day from this alist to opt it out of capacity accounting
entirely."
  :type '(alist :key-type (choice (const :tag "Sunday" 0)
                                  (const :tag "Monday" 1)
                                  (const :tag "Tuesday" 2)
                                  (const :tag "Wednesday" 3)
                                  (const :tag "Thursday" 4)
                                  (const :tag "Friday" 5)
                                  (const :tag "Saturday" 6))
                :value-type (integer :tag "Minutes"))
  :group 'dm-org-agenda-capacity)

(defcustom dm-org-daily-workday
  '((1 . (540 . 1080))   ; Monday    09:00-18:00
    (2 . (540 . 1080))   ; Tuesday   09:00-18:00
    (3 . (540 . 1080))   ; Wednesday 09:00-18:00
    (4 . (540 . 1080))   ; Thursday  09:00-18:00
    (5 . (540 . 1020))   ; Friday    09:00-17:00
    (6 . (600 . 780))    ; Saturday  10:00-13:00
    (0 . (600 . 780)))   ; Sunday    10:00-13:00
  "Wall-clock bounds of the working day per weekday, in minutes from midnight.

Keys are day numbers as in `dm-org-daily-capacity'.  Values are a cons of the
first and last minute of the day, so 540 is 09:00 and 1080 is 18:00.

This is deliberately independent of `dm-org-daily-capacity': the window says
when work can be placed, capacity says how much of it you can absorb, and the
difference between a nine hour window and six hours of capacity is the slack
that keeps a plan survivable.  A weekday with no entry here gets no fit check
and cannot be packed, the way a weekday missing from `dm-org-daily-capacity'
opts out of capacity accounting."
  :type '(alist :key-type (choice (const :tag "Sunday" 0)
                                  (const :tag "Monday" 1)
                                  (const :tag "Tuesday" 2)
                                  (const :tag "Wednesday" 3)
                                  (const :tag "Thursday" 4)
                                  (const :tag "Friday" 5)
                                  (const :tag "Saturday" 6))
                :value-type (cons (integer :tag "Start (minutes from midnight)")
                                  (integer :tag "End (minutes from midnight)")))
  :group 'dm-org-agenda-capacity)

;; Six hours on weekdays, four on weekends.
(setq dm-org-daily-capacity
      '((1 . 360)   ; Monday
        (2 . 360)   ; Tuesday
        (3 . 360)   ; Wednesday
        (4 . 360)   ; Thursday
        (5 . 360)   ; Friday
        (6 . 240)   ; Saturday
        (0 . 240))) ; Sunday

;; Weekend windows are sized to hold the weekend capacity set above with the
;; same proportional slack the weekdays get: six hours of clock for four hours
;; of work, as nine holds six.
(setq dm-org-daily-workday
      '((1 . (540 . 1080))   ; Monday    09:00-18:00
        (2 . (540 . 1080))   ; Tuesday   09:00-18:00
        (3 . (540 . 1080))   ; Wednesday 09:00-18:00
        (4 . (540 . 1080))   ; Thursday  09:00-18:00
        (5 . (540 . 1080))   ; Friday    09:00-17:00
        (6 . (600 . 960))    ; Saturday  10:00-16:00
        (0 . (600 . 960))))  ; Sunday    10:00-16:00

(defcustom dm-org-agenda-capacity-entry-types
  '("scheduled" "past-scheduled" "deadline" "timestamp" "sexp")
  "Agenda entry types whose EFFORT counts toward a day's planned load.

These are the strings Org puts in the `type' text property of an agenda line.
The default counts work assigned to the day and nothing else; see the
Commentary for why \"upcoming-deadline\", \"block\", and the log-mode types
\"closed\", \"clock\" and \"state\" are left out."
  :type '(repeat string)
  :group 'dm-org-agenda-capacity)

(defcustom dm-org-agenda-capacity-column-gap 4
  "Blank columns between the widest agenda date header and its capacity summary.

Summaries are aligned to a column derived from the headers actually present in
the buffer, so the layout does not depend on the width of the window."
  :type 'integer
  :group 'dm-org-agenda-capacity)

;; `org-warning' is the right existing face for this, but going through a
;; defface of our own keeps the overload marker customizable on its own.
(defface dm-org-agenda-capacity-over
  '((t :inherit org-warning))
  "Face for the capacity summary of a day planned beyond its capacity.
Days within capacity are deliberately left in the date header's own face."
  :group 'dm-org-agenda-capacity)

;; One severity step below the overload marker: `org-upcoming-deadline' is the
;; face Org itself uses for something approaching that is not yet critical.
(defface dm-org-agenda-capacity-tight
  '((t :inherit org-upcoming-deadline))
  "Face for the summary of a day whose work fits by total but not by the clock.
See `dm-org-agenda-day-plan'."
  :group 'dm-org-agenda-capacity)

;;; ————————————————————————————
;;; Capacity lookup
;;; ————————————————————————————

(defun dm-org-agenda-capacity--absolute (date)
  "Return DATE as an absolute day number.

DATE is either an absolute day number, as agenda lines carry in their `day'
text property, or a Gregorian date (MONTH DAY YEAR), the form `calendar' and
`org-agenda-format-date' use."
  (require 'calendar)
  (if (consp date) (calendar-absolute-from-gregorian date) date))

(defun dm-org-agenda-capacity-for-day (day)
  "Return the capacity in minutes configured for absolute DAY, or nil.
See `dm-org-daily-capacity'."
  (require 'calendar)
  (cdr (assq (calendar-day-of-week (calendar-gregorian-from-absolute day))
             dm-org-daily-capacity)))

(defun dm-org-agenda-capacity-workday-for-day (day)
  "Return the working window for absolute DAY as a cons of minutes, or nil.
See `dm-org-daily-workday'."
  (require 'calendar)
  (cdr (assq (calendar-day-of-week (calendar-gregorian-from-absolute day))
             dm-org-daily-workday)))

;;; ————————————————————————————
;;; Intervals
;;;
;;; Plain arithmetic on minutes from midnight, with no Org dependency, so the
;;; packing rules can be read and tested without building an agenda.
;;; ————————————————————————————

(defun dm-org-agenda-capacity--hhmm-to-minutes (hhmm)
  "Return HHMM as minutes from midnight, so 2030 becomes 1230.
HHMM is a military time, the form Org's `time-of-day' property carries."
  (+ (* 60 (/ hhmm 100)) (mod hhmm 100)))

(defun dm-org-agenda-capacity--merge-intervals (intervals)
  "Return INTERVALS sorted by start with overlapping and touching ones merged.

INTERVALS is a list of (START . END) conses in minutes.  Double-booked
appointments would otherwise be subtracted from the day twice."
  (let ((sorted (sort (copy-sequence intervals)
                      (lambda (a b) (< (car a) (car b)))))
        (merged nil))
    (dolist (interval sorted)
      (let ((previous (car merged)))
        (if (and previous (<= (car interval) (cdr previous)))
            (setcdr previous (max (cdr previous) (cdr interval)))
          (push (cons (car interval) (cdr interval)) merged))))
    (nreverse merged)))

(defun dm-org-agenda-capacity--free-runs (window blocks)
  "Return the free stretches of WINDOW left over once BLOCKS are removed.

WINDOW is a (START . END) cons and BLOCKS a list of them, all in minutes from
midnight.  Blocks lying wholly outside WINDOW are ignored -- a 20:30 meeting
does not shorten a nine-to-five -- and blocks overhanging an edge are clipped
to it.  Zero-length stretches are dropped."
  (let ((point (car window))
        (end (cdr window))
        (runs nil))
    (dolist (block (dm-org-agenda-capacity--merge-intervals blocks))
      (let ((block-start (max (car block) (car window)))
            (block-end (min (cdr block) end)))
        (when (< block-start block-end)
          (when (< point block-start)
            (push (cons point block-start) runs))
          (setq point (max point block-end)))))
    (when (< point end)
      (push (cons point end) runs))
    (nreverse runs)))

(defun dm-org-agenda-capacity--fit (runs tasks)
  "Place TASKS into RUNS, returning a cons of (PLACEMENTS . UNPLACED).

RUNS is a list of (START . END) conses in minutes.  TASKS is a list of
\(KEY . MINUTES), taken in the order given: this is the agenda's own order, so
a proposed day reads down the page the way the agenda does.  Each task takes
the front of the earliest run long enough to hold it.

PLACEMENTS is a list of (KEY START . END) in placement order; UNPLACED holds
the keys of tasks no single run could take.  First fit rather than anything
cleverer -- exact bin packing is NP-hard, and a day holds a handful of tasks."
  (let ((remaining (mapcar (lambda (run) (cons (car run) (cdr run))) runs))
        (placements nil)
        (unplaced nil))
    (dolist (task tasks)
      (let ((minutes (cdr task))
            (run (seq-find (lambda (run) (>= (- (cdr run) (car run)) (cdr task)))
                           remaining)))
        (if (null run)
            (push (car task) unplaced)
          (push (cons (car task) (cons (car run) (+ (car run) minutes)))
                placements)
          (setcar run (+ (car run) minutes)))))
    (cons (nreverse placements) (nreverse unplaced))))

;;; ————————————————————————————
;;; Reading the agenda buffer
;;; ————————————————————————————

(defun dm-org-agenda-capacity--done-p ()
  "Non-nil when the agenda line at point stands for a completed entry."
  (let ((state (org-get-at-bol 'todo-state))
        (done-face (org-get-at-bol 'done-face)))
    (or (member state org-done-keywords-for-agenda)
        ;; `org-agenda-change-all-lines' reapplies the line's pre-change text
        ;; properties, so `todo-state' goes stale the moment a TODO is
        ;; completed from the agenda itself.  The face it refreshes does not,
        ;; which is what lets the day's total drop without a redo.
        (and done-face (eq (org-get-at-bol 'face) done-face)))))

(defun dm-org-agenda-capacity--countable-p ()
  "Non-nil when the agenda line at point counts toward planned effort.

An entry with no EFFORT counts as zero minutes rather than being dropped, so
it still shows up in the :unestimated tally of `dm-org-agenda-day-load'."
  (and (member (org-get-at-bol 'type) dm-org-agenda-capacity-entry-types)
       (not (dm-org-agenda-capacity--done-p))))

(defun dm-org-agenda-capacity--collect ()
  "Return a hash table mapping an absolute day number to its counted entries.

Each value is a list of plists, in the order the agenda lists them:

  :marker    the entry's `org-hd-marker'
  :type      the agenda `type' property
  :minutes   EFFORT in minutes, 0 when the entry has none
  :timed     non-nil when the timestamp carries a clock time
  :start     minutes from midnight when :timed, else nil
  :block     the wall-clock span the entry occupies, or nil when unknowable

A heading appearing more than once on the same day -- scheduled and also due,
say -- contributes only its first line.

:block prefers Org's `duration' property, which it sets only for a timestamp
range, and falls back to EFFORT.  A bare <... 20:30> with no EFFORT has no
knowable footprint and reserves nothing."
  (let ((table (make-hash-table :test #'eql))
        (seen (make-hash-table :test #'equal)))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((day (org-get-at-bol 'day))
              (marker (org-get-at-bol 'org-hd-marker)))
          ;; Date headers, the time grid and diary lines carry no
          ;; `org-hd-marker', which excludes them here.
          (when (and day marker
                     (dm-org-agenda-capacity--countable-p)
                     (not (gethash (cons day marker) seen)))
            (puthash (cons day marker) t seen)
            (let* ((time-of-day (org-get-at-bol 'time-of-day))
                   (effort (org-get-at-bol 'effort-minutes))
                   (duration (org-get-at-bol 'duration)))
              (puthash day
                       (cons (list :marker marker
                                   :type (org-get-at-bol 'type)
                                   :minutes (or effort 0)
                                   :timed (and time-of-day t)
                                   :start (and time-of-day
                                               (dm-org-agenda-capacity--hhmm-to-minutes
                                                time-of-day))
                                   :block (and time-of-day
                                               (or duration effort)))
                             (gethash day table))
                       table))))
        (forward-line 1)))
    ;; Entries were pushed, so each day is in reverse buffer order.  Packing
    ;; takes tasks in agenda order, which makes this ordering load-bearing.
    (maphash (lambda (day entries) (puthash day (nreverse entries) table)) table)
    table))

(defun dm-org-agenda-capacity--buffer-days ()
  "Return the absolute day numbers the current agenda buffer shows, ascending.

Unlike the keys of `dm-org-agenda-capacity--collect', this includes days with
no entries at all -- which is the whole point, since an empty day is exactly
where work moved off a full one wants to land."
  (let ((days nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((day (org-get-at-bol 'day)))
          (when (and day (not (memq day days)))
            (push day days)))
        (forward-line 1)))
    (sort days #'<)))

(defun dm-org-agenda-capacity--load (day entries)
  "Return the capacity plist for absolute DAY given its counted ENTRIES."
  (let ((capacity (dm-org-agenda-capacity-for-day day))
        (fixed 0)
        (flexible 0)
        (unestimated 0))
    (dolist (entry entries)
      (let ((minutes (plist-get entry :minutes)))
        (if (plist-get entry :timed)
            (setq fixed (+ fixed minutes))
          (setq flexible (+ flexible minutes)))
        (when (zerop minutes)
          (setq unestimated (1+ unestimated)))))
    (list :capacity capacity
          :fixed (round fixed)
          :flexible (round flexible)
          :total (round (+ fixed flexible))
          :remaining (and capacity (round (- capacity fixed flexible)))
          :unestimated unestimated)))

;;;###autoload
(defun dm-org-agenda-day-load (date)
  "Return the planned load for DATE as a plist, read from the current agenda.

DATE is an absolute day number or a Gregorian date (MONTH DAY YEAR).  The
result is

    (:capacity 360 :fixed 90 :flexible 240 :total 330 :remaining 30
     :unestimated 1)

in minutes, where :fixed is work whose timestamp carries a clock time,
:flexible is work scheduled to a bare date, and :unestimated counts entries
that would have counted but have no EFFORT.  :capacity and :remaining are nil
when the weekday has no entry in `dm-org-daily-capacity'.

Must be called in an Org agenda buffer; the figures describe what that buffer
shows, including entries currently hidden by an agenda filter."
  (unless (derived-mode-p 'org-agenda-mode)
    (user-error "Not in an Org agenda buffer"))
  (let ((day (dm-org-agenda-capacity--absolute date)))
    (dm-org-agenda-capacity--load
     day (gethash day (dm-org-agenda-capacity--collect)))))

(defun dm-org-agenda-capacity--packable-p (entry)
  "Non-nil when ENTRY is flexible work with a known size.

Fixed-time work is a constraint on the day rather than something to place, and
an entry with no EFFORT has no size to place, so neither is a candidate."
  (and (not (plist-get entry :timed))
       (> (plist-get entry :minutes) 0)))

(defun dm-org-agenda-capacity--plan (day entries)
  "Return the interval plan for absolute DAY given its counted ENTRIES.
A superset of `dm-org-agenda-capacity--load'; see `dm-org-agenda-day-plan'."
  (let* ((load (dm-org-agenda-capacity--load day entries))
         (window (dm-org-agenda-capacity-workday-for-day day))
         (blocks (delq nil
                       (mapcar (lambda (entry)
                                 (let ((start (plist-get entry :start))
                                       (block (plist-get entry :block)))
                                   (and start block
                                        (cons start (+ start (round block))))))
                               entries)))
         (tasks (mapcar (lambda (entry)
                          (cons (plist-get entry :marker)
                                (round (plist-get entry :minutes))))
                        (seq-filter #'dm-org-agenda-capacity--packable-p entries)))
         (runs (and window (dm-org-agenda-capacity--free-runs window blocks)))
         (fit (and window (dm-org-agenda-capacity--fit runs tasks))))
    (append load
            (list :window window
                  :blocks (dm-org-agenda-capacity--merge-intervals blocks)
                  :runs runs
                  :placements (car fit)
                  :unplaced (cdr fit)
                  ;; nil when there is no window to reason about, so callers
                  ;; can tell "does not fit" from "not asked".
                  :fits (and window (null (cdr fit)))))))

;;;###autoload
(defun dm-org-agenda-day-plan (date)
  "Return the interval plan for DATE as a plist, read from the current agenda.

A superset of `dm-org-agenda-day-load', adding the wall-clock view:

  :window      the working day from `dm-org-daily-workday', or nil
  :blocks      fixed-time footprints, merged, in minutes from midnight
  :runs        the free stretches of :window left once :blocks are removed
  :placements  (MARKER START . END) for each flexible task first-fit into :runs
  :unplaced    markers of flexible tasks no single run could hold
  :fits        non-nil when every flexible task was placed; nil when the
               weekday has no window configured

A day can be within capacity and still not fit: 5:30 of work against 6:00 of
capacity fails if a meeting splits the day into runs of 3:00 and 3:30 and no
run can take two two-hour tasks.  That is the case :fits reports and the
capacity total cannot.

Must be called in an Org agenda buffer."
  (unless (derived-mode-p 'org-agenda-mode)
    (user-error "Not in an Org agenda buffer"))
  (let ((day (dm-org-agenda-capacity--absolute date)))
    (dm-org-agenda-capacity--plan
     day (gethash day (dm-org-agenda-capacity--collect)))))

;;; ————————————————————————————
;;; Rendering
;;; ————————————————————————————

(defun dm-org-agenda-capacity-format (plan)
  "Return the capacity summary string for PLAN, or nil.

PLAN is a plist as returned by `dm-org-agenda-day-load' or, for the fit
marker, `dm-org-agenda-day-plan'.  At most one marker is appended: OVER when
the day exceeds its capacity, otherwise TIGHT when its flexible work does not
fit the day's free runs.  Only days that need attention are marked.

Durations are rendered through `org-duration-from-minutes' with an explicit
`h:mm' format, so a day over 24 hours still reads as hours rather than days."
  (require 'org-duration)
  (let ((capacity (plist-get plan :capacity)))
    (when capacity
      (let ((remaining (plist-get plan :remaining))
            (summary (format "%s / %s"
                             (org-duration-from-minutes (plist-get plan :total) 'h:mm)
                             (org-duration-from-minutes capacity 'h:mm))))
        (cond
         ((< remaining 0)
          (concat summary "  OVER "
                  (org-duration-from-minutes (- remaining) 'h:mm)))
         ;; :fits is nil both when nothing fits and when no window is
         ;; configured, so ask for the window before trusting it.
         ((and (plist-get plan :window) (not (plist-get plan :fits)))
          (concat summary "  TIGHT"))
         (t summary))))))

(defun dm-org-agenda-capacity--marker-face (plan)
  "Return the face the summary for PLAN should carry, or nil for none."
  (let ((remaining (plist-get plan :remaining)))
    (cond
     ((and remaining (< remaining 0)) 'dm-org-agenda-capacity-over)
     ((and (plist-get plan :window) (not (plist-get plan :fits)))
      'dm-org-agenda-capacity-tight))))

(defun dm-org-agenda-capacity--date-header-p ()
  "Non-nil when point is on an agenda date header line that has text on it.

Org puts `org-agenda-date-header' on everything `org-agenda-format-date'
inserts.  A formatter that opens with a newline -- as this configuration's
does, to space the days apart -- therefore also stamps the blank line above
the header, which is not somewhere an annotation can go."
  (and (org-get-at-bol 'org-agenda-date-header)
       (not (looking-at-p "[ \t]*$"))))

(defun dm-org-agenda-capacity--strip ()
  "Delete the capacity annotation on the line at point, if there is one."
  (let ((beg (text-property-any (line-beginning-position) (line-end-position)
                                'dm-org-agenda-capacity t)))
    (when beg
      (delete-region beg (line-end-position)))))

(defun dm-org-agenda-capacity--annotate-line (entries column)
  "Append the capacity summary to the date header line at point.

ENTRIES is the table from `dm-org-agenda-capacity--collect'.  COLUMN is the
column the summaries across the buffer are aligned to."
  (let* ((day (org-get-at-bol 'day))
         (plan (and day (dm-org-agenda-capacity--plan
                         day (gethash day entries))))
         (summary (and plan (dm-org-agenda-capacity-format plan))))
    (when summary
      (let ((pad (max 1 (- column (- (line-end-position)
                                     (line-beginning-position)))))
            ;; Read the day face Org already stamped on the header rather than
            ;; recomputing it, so today and weekend variants come along for
            ;; free and an unremarkable day gains no decoration of its own.
            (face (or (dm-org-agenda-capacity--marker-face plan)
                      (get-text-property (line-beginning-position) 'face))))
        (goto-char (line-end-position))
        (insert (propertize (concat (make-string pad ?\s) summary)
                            'dm-org-agenda-capacity t
                            'face face))))))

(defun dm-org-agenda-capacity-annotate-h ()
  "Append a capacity summary to every date header in the agenda buffer.

Meant for `org-agenda-finalize-hook'.  Rewrites rather than accumulates, so it
is safe on the repeat finalizations Org runs after an agenda line changes, and
a no-op in agenda views that have no date headers."
  (when (derived-mode-p 'org-agenda-mode)
    (let ((inhibit-read-only t))
      (save-restriction
        ;; `org-agenda-change-all-lines' narrows to a single entry line before
        ;; re-running `org-agenda-finalize' -- the same reason
        ;; `org-agenda-mark-clocking-task' widens.  Only text within existing
        ;; lines is touched, so that walk's line arithmetic is unaffected.
        (widen)
        (save-excursion
          (let ((width 0))
            ;; Pass 1: drop any annotation from an earlier run, then measure
            ;; the bare headers so the summaries can share one column.
            (goto-char (point-min))
            (while (not (eobp))
              (when (dm-org-agenda-capacity--date-header-p)
                (dm-org-agenda-capacity--strip)
                (setq width (max width (- (line-end-position)
                                          (line-beginning-position)))))
              (forward-line 1))
            ;; Pass 2: annotate.
            (let ((entries (dm-org-agenda-capacity--collect))
                  (column (+ width dm-org-agenda-capacity-column-gap)))
              (goto-char (point-min))
              (while (not (eobp))
                (when (dm-org-agenda-capacity--date-header-p)
                  (dm-org-agenda-capacity--annotate-line entries column))
                (forward-line 1)))))))))

(with-eval-after-load 'org-agenda
  (add-hook 'org-agenda-finalize-hook #'dm-org-agenda-capacity-annotate-h))

(provide 'dm-org-agenda-capacity)
;;; dm-org-agenda-capacity.el ends here
