;;; dm-org-agenda-plan.el --- Propose and apply Org agenda day plans  -*- lexical-binding: t; -*-

;;; Commentary:

;; Commands that turn the accounting in `dm-org-agenda-capacity' into a day
;; plan: give the day's flexible work clock times that fit around what is
;; already fixed, and move work off a day that cannot hold it.
;;
;;   `dm-org-agenda-pack-day'        propose times for the day's flexible work
;;   `dm-org-agenda-spill-overflow'  move work off a day that does not work
;;   `dm-org-agenda-unpack-day'      undo what this module scheduled
;;
;; Each acts on the day at point, or on every day in the agenda with a prefix
;; argument.  The day at point comes from the `day' text property, which Org
;; puts on the date header and on that day's entries alike, so the commands
;; work from anywhere in the block.
;;
;; This is the only part of the feature that writes to Org files, so the shape
;; is deliberately conservative.  Nothing is written when a command runs: it
;; opens a preview buffer describing exactly what it would change and what it
;; refused to touch, and waits for \\[dm-org-agenda-plan-apply].  Every write
;; goes through `org-schedule', which knows how to write a time range and
;; carries a repeater cookie across untouched, rather than through timestamp
;; string surgery of our own.
;;
;; Before it retimes anything the planner records the entry's SCHEDULED value
;; in a DM_PACKED property, so `dm-org-agenda-unpack-day' restores what was
;; there rather than reconstructing a guess, and a second pack is not confused
;; by the output of the first.  It is stored inactive -- [2026-08-31 Mon] --
;; because an active timestamp parked in a drawer is still a timestamp to the
;; agenda's scanner, which would show the entry a second time on the date it
;; came from and count that phantom toward the day's effort.
;;
;; Four things are never touched, each for its own reason:
;;
;;   - Repeating entries.  `org-schedule' would rewrite one happily, cookie
;;     and all, which is exactly the trap: Org owns recurrence, as does
;;     `dm-org-repeat-days', and a plan has no business stepping into it.
;;   - Fixed-time work.  An entry with a clock time is a constraint the plan
;;     is built around, not cargo to move.
;;   - Entries whose DEADLINE would be passed by the move.
;;   - Entries with no EFFORT.  There is no size to place, so they are
;;     reported rather than guessed at.
;;
;; Because everything is derived from the agenda buffer -- no independent scan
;; of the Org files -- spill can only consider days the agenda actually shows.
;; With a nine day span that is a nine day horizon; if nothing in it has room,
;; the preview says so rather than inventing a date.

;;; Code:

(require 'subr-x)
(require 'dm-org-agenda-capacity)

(declare-function calendar-gregorian-from-absolute "calendar" (date))
(declare-function org-agenda-format-date-aligned "org-agenda" (date))
(declare-function org-agenda-redo "org-agenda" (&optional all))
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-entry-delete "org" (epom property &optional values))
(declare-function org-entry-get "org" (epom property &optional inherit literal-nil))
(declare-function org-entry-put "org" (epom property value))
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-get-repeat "org" (&optional timestamp))
(declare-function org-get-at-bol "org" (property))
(declare-function org-schedule "org" (arg &optional time))
(declare-function org-time-string-to-time "org" (s))
(declare-function dm-org-agenda-save-all-files "dm-org" (&rest _))

(defconst dm-org-agenda-plan-property "DM_PACKED"
  "Org property holding the SCHEDULED value an entry had before it was packed.
Its presence is also what marks an entry as this module's to undo.")

(defvar-local dm-org-agenda-plan--pending nil
  "The changes the preview buffer would apply, as a list of change plists.")

(defvar-local dm-org-agenda-plan--origin nil
  "The agenda buffer the preview in this buffer was computed from.")

;;; ————————————————————————————
;;; Formatting
;;; ————————————————————————————

(defun dm-org-agenda-plan--clock (minutes)
  "Format MINUTES from midnight as HH:MM."
  (format "%02d:%02d" (/ minutes 60) (mod minutes 60)))

(defun dm-org-agenda-plan--date (day)
  "Format absolute DAY as YYYY-MM-DD, the form `org-schedule' reads."
  (require 'calendar)
  (let ((date (calendar-gregorian-from-absolute day)))
    (format "%04d-%02d-%02d" (nth 2 date) (nth 0 date) (nth 1 date))))

(defun dm-org-agenda-plan--day-name (day)
  "Format absolute DAY the way the agenda's date headers do."
  (require 'org-agenda)
  (org-agenda-format-date-aligned (calendar-gregorian-from-absolute day)))

;;; ————————————————————————————
;;; Reading entries
;;; ————————————————————————————

(defun dm-org-agenda-plan--call-at (marker function)
  "Call FUNCTION with point at MARKER, in its buffer, widened.

The plain-function equivalent of `org-with-point-at'.  That is a macro, and
using it would mean loading Org merely to byte-compile this file, which the
rest of this configuration is careful to avoid."
  (with-current-buffer (marker-buffer marker)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char marker)
        (funcall function)))))

(defun dm-org-agenda-plan--park (timestamp)
  "Return TIMESTAMP made inactive, for parking in a property drawer.

An active timestamp stored in a property is still a timestamp as far as the
agenda's scanner is concerned, and Org would show the entry a second time on
the parked date -- a phantom that also counts toward that day's effort.  The
inactive form is inert, which is the same reason CLOSED uses it.

Org reads the inactive form back happily, so nothing is lost.  Enabling
`org-agenda-include-inactive-timestamps' would make these visible again."
  (when timestamp
    (replace-regexp-in-string
     ">\\'" "]" (replace-regexp-in-string "\\`<" "[" timestamp))))

(defun dm-org-agenda-plan--info (marker)
  "Return a plist describing the Org entry at MARKER.

Keys are :heading, :scheduled (verbatim), :packed (the DM_PACKED value, if
any), :repeat (the SCHEDULED repeater cookie, if any) and :deadline, an
absolute day number or nil.  One visit to the entry answers every guard."
  (dm-org-agenda-plan--call-at
   marker
   (lambda ()
     (org-back-to-heading t)
     (let ((scheduled (org-entry-get (point) "SCHEDULED"))
           (deadline (org-entry-get (point) "DEADLINE")))
       (list :heading (org-get-heading t t t t)
             :scheduled scheduled
             :packed (org-entry-get (point) dm-org-agenda-plan-property)
             :repeat (and scheduled (org-get-repeat scheduled))
             :deadline (and deadline
                            (time-to-days (org-time-string-to-time deadline))))))))

(defun dm-org-agenda-plan--refusal (info day)
  "Return why the entry described by INFO may not be retimed onto DAY, or nil."
  (cond
   ((plist-get info :repeat) "repeats; Org owns its schedule")
   ((and (plist-get info :deadline) (> day (plist-get info :deadline)))
    "would pass its deadline")))

(defun dm-org-agenda-plan--change (marker info day beg end)
  "Return the change plist retiming MARKER onto DAY from BEG to END minutes.
INFO is the entry description from `dm-org-agenda-plan--info'."
  (list :marker marker
        :heading (plist-get info :heading)
        :old (plist-get info :scheduled)
        ;; Keep the first original seen: re-packing an already packed entry
        ;; must still restore the bare date it started from.
        :original (or (plist-get info :packed)
                      (dm-org-agenda-plan--park (plist-get info :scheduled)))
        :new (format "%s %s-%s"
                     (dm-org-agenda-plan--date day)
                     (dm-org-agenda-plan--clock beg)
                     (dm-org-agenda-plan--clock end))))

;;; ————————————————————————————
;;; Planners
;;; ————————————————————————————

(defun dm-org-agenda-plan--pack (day entries)
  "Return (CHANGES . SKIPPED) for packing absolute DAY's flexible work.

ENTRIES is the day's list from `dm-org-agenda-capacity--collect'."
  (let ((plan (dm-org-agenda-capacity--plan day entries))
        (changes nil)
        (skipped nil))
    (if (null (plist-get plan :window))
        (cons nil (list (list :heading (string-trim (dm-org-agenda-plan--day-name day))
                              :reason "no workday window configured")))
      (dolist (placement (plist-get plan :placements))
        (let* ((marker (car placement))
               (info (dm-org-agenda-plan--info marker))
               (refusal (dm-org-agenda-plan--refusal info day)))
          (if refusal
              (push (list :heading (plist-get info :heading) :reason refusal) skipped)
            (push (dm-org-agenda-plan--change
                   marker info day (cadr placement) (cddr placement))
                  changes))))
      (dolist (marker (plist-get plan :unplaced))
        (push (list :heading (plist-get (dm-org-agenda-plan--info marker) :heading)
                    :reason "no free run long enough")
              skipped))
      ;; Flexible work with no EFFORT never reaches the packer at all.
      (dolist (entry entries)
        (when (and (not (plist-get entry :timed))
                   (zerop (plist-get entry :minutes)))
          (push (list :heading (plist-get (dm-org-agenda-plan--info
                                           (plist-get entry :marker))
                                          :heading)
                      :reason "no EFFORT to size it")
                skipped)))
      (cons (nreverse changes) (nreverse skipped)))))

(defun dm-org-agenda-plan--broken-p (day entries)
  "Non-nil when absolute DAY cannot hold ENTRIES as they stand."
  (let ((plan (dm-org-agenda-capacity--plan day entries)))
    (or (let ((remaining (plist-get plan :remaining)))
          (and remaining (< remaining 0)))
        (and (plist-get plan :window) (not (plist-get plan :fits))))))

(defun dm-org-agenda-plan--room-p (day entries entry)
  "Non-nil when ENTRY could be added to absolute DAY alongside ENTRIES.

Composes both layers: the day must stay within capacity and the entry must
still fit one of its free runs."
  (let ((plan (dm-org-agenda-capacity--plan day (append entries (list entry)))))
    (and (plist-get plan :capacity)
         (plist-get plan :window)
         (>= (plist-get plan :remaining) 0)
         (plist-get plan :fits))))

(defun dm-org-agenda-plan--spill (days table targets)
  "Return (CHANGES . SKIPPED) moving work off the broken days among DAYS.

TABLE is a `dm-org-agenda-capacity--collect' hash, mutated as work is
reassigned so each decision sees the consequences of the last.  TARGETS is
every day the agenda shows, which is where displaced work may land; it has to
be the buffer's days rather than TABLE's keys, because a day with nothing on
it is absent from TABLE and is the likeliest destination of all."
  (let ((targets (sort (copy-sequence targets) #'<))
        (changes nil)
        (skipped nil))
    (dolist (day (sort (copy-sequence days) #'<))
      ;; Entries already found to have nowhere to go.  Setting them aside is
      ;; what makes the loop terminate: every pass either moves something off
      ;; the day or shortens the candidate list.
      (let ((immovable nil)
            (exhausted nil))
        (while (and (not exhausted)
                    (dm-org-agenda-plan--broken-p day (gethash day table)))
          ;; Shed from the end of the agenda's own order, so the work it
          ;; ranks lowest is the work that moves.
          (let ((candidate
                 (car (last (seq-filter
                             (lambda (entry)
                               (and (dm-org-agenda-capacity--packable-p entry)
                                    (not (memq entry immovable))))
                             (gethash day table))))))
            (if (null candidate)
                (setq exhausted t)
              (let* ((info (dm-org-agenda-plan--info (plist-get candidate :marker)))
                     (target (seq-find
                              (lambda (other)
                                (and (> other day)
                                     (not (dm-org-agenda-plan--refusal info other))
                                     (dm-org-agenda-plan--room-p
                                      other (gethash other table) candidate)))
                              targets)))
                (if (null target)
                    (progn
                      (push candidate immovable)
                      (push (list :heading (plist-get info :heading)
                                  :reason (or (dm-org-agenda-plan--refusal info (1+ day))
                                              "no later day in the agenda has room"))
                            skipped))
                  (puthash day (delq candidate (gethash day table)) table)
                  (puthash target (append (gethash target table) (list candidate)) table)
                  (push (list :marker (plist-get candidate :marker)
                              :heading (plist-get info :heading)
                              :old (plist-get info :scheduled)
                              :original (or (plist-get info :packed)
                                            (dm-org-agenda-plan--park
                                             (plist-get info :scheduled)))
                              :new (dm-org-agenda-plan--date target)
                              :moved (cons day target))
                        changes))))))))
    (cons (nreverse changes) (nreverse skipped))))

(defun dm-org-agenda-plan--unpack (days table)
  "Return (CHANGES . SKIPPED) restoring DAYS' entries to their original times.
TABLE is a `dm-org-agenda-capacity--collect' hash; only entries carrying
`dm-org-agenda-plan-property' are proposed for restoring."
  (let ((changes nil))
    (dolist (day (sort (copy-sequence days) #'<))
      (dolist (entry (gethash day table))
        (let* ((marker (plist-get entry :marker))
               (info (dm-org-agenda-plan--info marker))
               (packed (plist-get info :packed)))
          (when packed
            (push (list :marker marker
                        :heading (plist-get info :heading)
                        :old (plist-get info :scheduled)
                        :new packed
                        :restore t)
                  changes)))))
    (cons (nreverse changes) nil)))

;;; ————————————————————————————
;;; Preview
;;; ————————————————————————————

(defvar dm-org-agenda-plan-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'dm-org-agenda-plan-apply)
    map)
  "Keymap for `dm-org-agenda-plan-mode'.")

(define-derived-mode dm-org-agenda-plan-mode special-mode "Org Day Plan"
  "Major mode for reviewing a proposed Org day plan before applying it.
\\{dm-org-agenda-plan-mode-map}")

(defun dm-org-agenda-plan--render (title changes skipped)
  "Show TITLE, CHANGES and SKIPPED in the preview buffer and select it."
  (let ((origin (current-buffer))
        (buffer (get-buffer-create "*Org Day Plan*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dm-org-agenda-plan-mode)
        (setq dm-org-agenda-plan--pending changes
              dm-org-agenda-plan--origin origin)
        (insert (propertize title 'face 'org-agenda-structure) "\n\n")
        (if (null changes)
            (insert "  Nothing to change.\n")
          (dolist (change changes)
            (insert (format "  %-52s %s\n"
                            (truncate-string-to-width
                             (plist-get change :heading) 52 nil nil t)
                            (or (plist-get change :new) "")))
            (insert (format "  %-52s   was %s\n" ""
                            (or (plist-get change :old) "unscheduled")))))
        (when skipped
          (insert "\n" (propertize "  Left alone" 'face 'org-agenda-structure) "\n")
          (dolist (entry skipped)
            (insert (format "  %-52s %s\n"
                            (truncate-string-to-width
                             (plist-get entry :heading) 52 nil nil t)
                            (plist-get entry :reason)))))
        (insert "\n")
        (insert (if changes
                    (substitute-command-keys
                     "  \\[dm-org-agenda-plan-apply] to apply, \\[quit-window] to discard.\n")
                  (substitute-command-keys "  \\[quit-window] to close.\n")))
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun dm-org-agenda-plan-apply ()
  "Write the changes the preview buffer proposes, then refresh the agenda."
  (interactive)
  (unless (derived-mode-p 'dm-org-agenda-plan-mode)
    (user-error "Not in an Org day plan buffer"))
  (let ((changes dm-org-agenda-plan--pending)
        (origin dm-org-agenda-plan--origin))
    (unless changes
      (user-error "Nothing to apply"))
    (dolist (change changes)
      (dm-org-agenda-plan--call-at
       (plist-get change :marker)
       (lambda ()
         (org-back-to-heading t)
         (if (plist-get change :restore)
             (org-entry-delete (point) dm-org-agenda-plan-property)
           (org-entry-put (point) dm-org-agenda-plan-property
                          (plist-get change :original)))
         ;; `org-schedule' rather than `org-agenda-schedule': the latter is
         ;; advised in `dm-org' to save every Org buffer, which would fire
         ;; once per entry.  Save once, below.
         (org-schedule nil (plist-get change :new)))))
    (dm-org-agenda-save-all-files)
    (let* ((count (length changes))
           (preview (current-buffer))
           (window (get-buffer-window preview)))
      ;; Dismiss this buffer by name rather than with `quit-window', which
      ;; acts on the selected window and would take out whatever happens to be
      ;; showing there if the preview is not it.
      (if window
          (quit-restore-window window 'kill)
        (kill-buffer preview))
      (when (buffer-live-p origin)
        (with-current-buffer origin
          (when (derived-mode-p 'org-agenda-mode)
            (org-agenda-redo))))
      (message "Applied %d change%s" count (if (= count 1) "" "s")))))

;;; ————————————————————————————
;;; Commands
;;; ————————————————————————————

(defun dm-org-agenda-plan--days (whole-span)
  "Return the absolute days to act on: all of them when WHOLE-SPAN, else one.

Signals when point is not on a day, which in an agenda means a block header or
the space between days rather than anywhere useful."
  (unless (derived-mode-p 'org-agenda-mode)
    (user-error "Not in an Org agenda buffer"))
  (if whole-span
      (dm-org-agenda-capacity--buffer-days)
    (list (or (org-get-at-bol 'day)
              (user-error "Point is not on a day in the agenda")))))

;;;###autoload
(defun dm-org-agenda-pack-day (&optional whole-span)
  "Propose clock times for the flexible work on the agenda day at point.

Fixed-time work is subtracted from the day's window in `dm-org-daily-workday'
and the flexible work is first-fit into what is left, in the order the agenda
lists it.  With a prefix argument WHOLE-SPAN, do this for every day the agenda
shows.

Packing settles rather than churns: what it places acquires a clock time and
so becomes fixed work, which a later pack builds around instead of moving.
To reshuffle a day, unpack it first with `dm-org-agenda-unpack-day'.

Nothing is written: the proposal opens in a preview buffer to be applied with
`dm-org-agenda-plan-apply' or discarded."
  (interactive "P" org-agenda-mode)
  (let ((days (dm-org-agenda-plan--days whole-span))
        (table (dm-org-agenda-capacity--collect))
        (changes nil)
        (skipped nil))
    (dolist (day days)
      (let ((result (dm-org-agenda-plan--pack day (gethash day table))))
        (setq changes (append changes (car result))
              skipped (append skipped (cdr result)))))
    (dm-org-agenda-plan--render
     (if (cdr days)
         (format "Pack %d days" (length days))
       (format "Pack %s" (string-trim (dm-org-agenda-plan--day-name (car days)))))
     changes skipped)))

;;;###autoload
(defun dm-org-agenda-spill-overflow (&optional whole-span)
  "Propose moving flexible work off the agenda day at point until it fits.

A day needs shedding when it is over capacity or when its flexible work will
not fit the free runs around its fixed-time work.  Work is shed from the end
of the agenda's own order, so what the agenda ranks lowest moves first, onto
the earliest later day with both capacity and a run long enough.

With a prefix argument WHOLE-SPAN, consider every day the agenda shows.
Target days are always drawn from the whole agenda, which is therefore the
horizon: nothing beyond the agenda's span can be reasoned about from the
buffer alone.

Nothing is written; the proposal opens in a preview buffer."
  (interactive "P" org-agenda-mode)
  (let* ((days (dm-org-agenda-plan--days whole-span))
         (table (dm-org-agenda-capacity--collect))
         (result (dm-org-agenda-plan--spill
                  days table (dm-org-agenda-capacity--buffer-days))))
    (dm-org-agenda-plan--render
     (if (cdr days)
         (format "Spill overflow from %d days" (length days))
       (format "Spill overflow from %s"
               (string-trim (dm-org-agenda-plan--day-name (car days)))))
     (car result) (cdr result))))

;;;###autoload
(defun dm-org-agenda-unpack-day (&optional whole-span)
  "Restore the timestamps this module rewrote on the agenda day at point.

Only entries carrying a DM_PACKED property are touched, and each is restored
to the value recorded there verbatim.  With a prefix argument WHOLE-SPAN, do
this for every day the agenda shows.

Nothing is written; the proposal opens in a preview buffer."
  (interactive "P" org-agenda-mode)
  (let* ((days (dm-org-agenda-plan--days whole-span))
         (table (dm-org-agenda-capacity--collect))
         (result (dm-org-agenda-plan--unpack days table)))
    (dm-org-agenda-plan--render
     (if (cdr days)
         (format "Unpack %d days" (length days))
       (format "Unpack %s" (string-trim (dm-org-agenda-plan--day-name (car days)))))
     (car result) (cdr result))))

(provide 'dm-org-agenda-plan)
;;; dm-org-agenda-plan.el ends here
