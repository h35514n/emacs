;;; dm-org-repeat-days.el --- Constrain repeating TODOs to chosen weekdays  -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in support for restricting a repeating TODO to particular days of the
;; week, via a REPEAT_DAYS property:
;;
;;     * TODO Do workout
;;       SCHEDULED: <2026-09-02 Wed ++1d>
;;       :PROPERTIES:
;;       :REPEAT_DAYS: monday,wednesday,friday
;;       :END:
;;
;; Recognized values are `weekdays', `weekends', and full weekday names,
;; singly or comma-separated.  Parsing is case-insensitive, tolerates stray
;; whitespace, and ignores duplicates.
;;
;; Org stays fully in charge of repeat processing.  This module hangs off
;; `org-todo-repeat-hook', which `org-auto-repeat-maybe' runs after it has
;; reset the TODO state and shifted every repeating timestamp in the entry.
;; By then the only thing left to do is nudge the freshly written SCHEDULED
;; date forward to the next allowed weekday -- there is no reimplementation of
;; recurrence here, just a constraint applied to Org's answer.  Earlier hooks
;; (`org-after-todo-state-change-hook') would run before the shift and see a
;; stale date; advising `org-auto-repeat-maybe' would reach into Org's guts for
;; no gain.
;;
;; The shift goes through `org-timestamp-change', the same entry point Org's
;; own repeater uses.  It rewrites only the date, so the repeater cookie
;; survives verbatim (+1d, ++1d and .+1d all keep working as written), as do a
;; time of day, a time range, and any delay cookie.  It also does the
;; arithmetic on decoded calendar fields rather than by adding seconds, so
;; month, year, leap-day, and DST boundaries land on the intended date.
;;
;; Entries without REPEAT_DAYS are untouched, as are entries whose SCHEDULED
;; timestamp carries no repeater.  Only SCHEDULED is considered; a repeating
;; DEADLINE is left to Org.
;;
;; REPEAT_DAYS is read with `selective' inheritance, matching how Org reads its
;; own REPEAT_TO_STATE: inherited only if the user adds it to
;; `org-use-property-inheritance', and per-entry otherwise.
;;
;; A REPEAT_DAYS value that is empty or names something that is not a weekday
;; is reported through `display-warning' and otherwise ignored, leaving Org's
;; date in place.  A typo should be visible rather than silently rescheduling
;; the task somewhere surprising.
;;
;; Known cosmetic wart: Org's "Entry repeats: ..." echo is composed before the
;; hook runs, so on an adjusted entry it names the pre-adjustment date.  The
;; buffer is correct.

;;; Code:

(declare-function calendar-day-of-week "calendar" (date))
(declare-function org-at-planning-p "org" ())
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-entry-get "org" (epom property &optional inherit literal-nil))
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-get-repeat "org" (&optional timestamp))
(declare-function org-parse-time-string "org-macs" (s &optional nodefault))
(declare-function org-timestamp-change "org" (n &optional what updown suppress-tmp-delay))
(defvar org-scheduled-time-regexp)

(defconst dm-org-repeat-days-property "REPEAT_DAYS"
  "Org property naming the weekdays a repeating entry may land on.")

(defconst dm-org-repeat-days-tokens
  '(("sunday"    0)
    ("monday"    1)
    ("tuesday"   2)
    ("wednesday" 3)
    ("thursday"  4)
    ("friday"    5)
    ("saturday"  6)
    ("weekdays"  1 2 3 4 5)
    ("weekends"  0 6))
  "Alist mapping a `REPEAT_DAYS' token to the day numbers it stands for.
Day numbers run 0 (Sunday) through 6 (Saturday), as `calendar-day-of-week'
returns them.")

;;; ————————————————————————————
;;; Recurrence logic (no Org dependency)
;;; ————————————————————————————

(defun dm-org-repeat-days-parse (spec)
  "Parse SPEC, a `REPEAT_DAYS' property value, into a list of day numbers.

Return the allowed days sorted ascending and deduplicated, where 0 is Sunday
and 6 is Saturday.  Return nil if SPEC is nil, empty, or names any token that
is not a weekday: callers treat that as \"leave the date alone\"."
  (let ((tokens (split-string (downcase (or spec "")) "[,[:space:]]+" t))
        (days nil)
        (valid t))
    (dolist (token tokens)
      (let ((entry (assoc token dm-org-repeat-days-tokens)))
        (if entry
            ;; `append' copies its non-final arguments, so DAYS never shares
            ;; structure with the constant alist and is safe to sort in place.
            (setq days (append (cdr entry) days))
          (setq valid nil))))
    (and valid days (sort (delete-dups days) #'<))))

(defun dm-org-repeat-days-offset (day allowed)
  "Return the number of days from DAY forward to the next day in ALLOWED.

DAY and the members of ALLOWED are day numbers, 0 (Sunday) to 6 (Saturday).
Return 0 when DAY is itself allowed, and nil when ALLOWED is empty."
  (when allowed
    (let ((offset 0))
      (while (and (< offset 7)
                  (not (memq (mod (+ day offset) 7) allowed)))
        (setq offset (1+ offset)))
      (and (< offset 7) offset))))

(defun dm-org-repeat-days-adjustment (timestamp allowed)
  "Return the days to shift TIMESTAMP forward to satisfy ALLOWED.

TIMESTAMP is an Org timestamp string such as \"<2026-09-03 Thu ++1d>\".  Only
its date is read, via decoded calendar fields, so the result is independent of
time of day and of any DST transition.  Return 0 when no shift is needed and
nil when ALLOWED is empty."
  (require 'calendar)
  (let ((date (org-parse-time-string timestamp)))
    (dm-org-repeat-days-offset
     (calendar-day-of-week (list (decoded-time-month date)
                                 (decoded-time-day date)
                                 (decoded-time-year date)))
     allowed)))

;;; ————————————————————————————
;;; Org integration
;;; ————————————————————————————

(defun dm-org-repeat-days--shift-scheduled (days)
  "Move the SCHEDULED timestamp of the entry at point forward by DAYS."
  (save-excursion
    (org-back-to-heading t)
    (forward-line 1)
    (when (and (org-at-planning-p)
               (re-search-forward org-scheduled-time-regexp (line-end-position) t))
      (goto-char (match-beginning 1))
      (org-timestamp-change days 'day))))

(defun dm-org-repeat-days--adjust-h ()
  "Pull the just-repeated SCHEDULED date forward onto an allowed weekday.
Meant for `org-todo-repeat-hook'; a no-op unless the entry sets
`dm-org-repeat-days-property' and has a repeating SCHEDULED timestamp."
  (save-excursion
    (org-back-to-heading t)
    (let ((spec (org-entry-get (point) dm-org-repeat-days-property 'selective))
          (scheduled (org-entry-get (point) "SCHEDULED")))
      (when (and spec scheduled (org-get-repeat scheduled))
        (let ((allowed (dm-org-repeat-days-parse spec)))
          (if (null allowed)
              (display-warning
               'dm-org-repeat-days
               (format "Ignoring unparseable %s value %S on %S"
                       dm-org-repeat-days-property spec
                       (org-get-heading t t t t))
               :warning)
            (let ((offset (dm-org-repeat-days-adjustment scheduled allowed)))
              (when (> offset 0)
                (dm-org-repeat-days--shift-scheduled offset)))))))))

(with-eval-after-load 'org
  (add-hook 'org-todo-repeat-hook #'dm-org-repeat-days--adjust-h))

(provide 'dm-org-repeat-days)
;;; dm-org-repeat-days.el ends here
