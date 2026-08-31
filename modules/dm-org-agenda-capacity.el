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
;; Phase 1 displays total, capacity, and remaining.  `dm-org-agenda-day-load'
;; already splits the total into fixed work (a scheduled timestamp carrying a
;; clock time) and flexible work (scheduled to a bare date), which is what a
;; later interval-packing phase needs; nothing here acts on that split yet.

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

Each value is a list of plists (:marker :type :minutes :timed).  A heading
appearing more than once on the same day -- scheduled and also due, say --
contributes only its first line."
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
            (puthash day
                     (cons (list :marker marker
                                 :type (org-get-at-bol 'type)
                                 :minutes (or (org-get-at-bol 'effort-minutes) 0)
                                 ;; `time-of-day' is set when the timestamp
                                 ;; carries a clock time -- the phase 2
                                 ;; fixed/flexible split.
                                 :timed (and (org-get-at-bol 'time-of-day) t))
                           (gethash day table))
                     table)))
        (forward-line 1)))
    table))

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

;;; ————————————————————————————
;;; Rendering
;;; ————————————————————————————

(defun dm-org-agenda-capacity-format (load)
  "Return the capacity summary string for LOAD, or nil.

LOAD is a plist as returned by `dm-org-agenda-day-load'.  Durations are
rendered through `org-duration-from-minutes' with an explicit `h:mm' format,
so a day over 24 hours still reads as hours rather than as days."
  (require 'org-duration)
  (let ((capacity (plist-get load :capacity)))
    (when capacity
      (let ((remaining (plist-get load :remaining))
            (summary (format "%s / %s"
                             (org-duration-from-minutes (plist-get load :total) 'h:mm)
                             (org-duration-from-minutes capacity 'h:mm))))
        (if (< remaining 0)
            (concat summary "  OVER "
                    (org-duration-from-minutes (- remaining) 'h:mm))
          summary)))))

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
         (load (and day (dm-org-agenda-capacity--load
                         day (gethash day entries))))
         (summary (and load (dm-org-agenda-capacity-format load))))
    (when summary
      (let ((over (< (plist-get load :remaining) 0))
            (pad (max 1 (- column (- (line-end-position)
                                     (line-beginning-position)))))
            ;; Read the day face Org already stamped on the header rather than
            ;; recomputing it, so today and weekend variants come along for
            ;; free and a day within capacity gains no decoration of its own.
            (face (get-text-property (line-beginning-position) 'face)))
        (goto-char (line-end-position))
        (insert (propertize (concat (make-string pad ?\s) summary)
                            'dm-org-agenda-capacity t
                            'face (if over 'dm-org-agenda-capacity-over face)))))))

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
