;;; dm-org-agenda-persist.el --- Semantic events for Org agenda mutations  -*- lexical-binding: t; -*-

;;; Commentary:

;; The semantic half of Git persistence for Org.  It watches the agenda for
;; mutations that change the plan, describes each one in the terms a person
;; would use, and hands the description to `dm-org-persist', which does the
;; git work:
;;
;;     Mark "Review authentication design" DONE
;;     Reschedule "Submit application" 2026-08-31 → 2026-09-02
;;     Priority "Finish project proposal" B → A
;;     Refile "Research API pricing" Inbox → Mallard
;;
;; Why advice rather than a hook:
;;
;; The obvious hooks are all wrong for this.  `org-agenda-finalize-hook' fires
;; on every redraw, and a redraw is a presentation event -- pressing `g' must
;; not write history.  `org-after-todo-state-change-hook' fires for one of the
;; five commands and knows nothing about the four others, nor about where the
;; command was invoked from.  What is actually needed is a before-and-after
;; pair around a specific command, and `:around' advice is the only thing that
;; brackets one.
;;
;; The advice never reimplements anything.  It reads the entry, calls the
;; original command untouched, reads the entry again, and compares.  A command
;; that signals -- which is what a cancelled date prompt does, via `quit' --
;; never reaches the second read, so an abandoned command records nothing.
;;
;; Why state comes from the heading, not the agenda line:
;;
;; Every one of these commands finds its entry the same way: an `org-hd-marker'
;; text property on the agenda line, pointing at the heading in the source
;; file.  Reading through that marker with `org-entry-get' gets the same values
;; Org itself acts on, where scraping the rendered line would get whatever
;; `org-agenda-prefix-format' happened to render.  Markers move with buffer
;; edits, so the same marker is valid before and after.
;;
;; Refile is the exception: it cuts the subtree, which invalidates the marker
;; and moves the heading to a file the agenda line never mentioned.  The
;; destination therefore comes from `org-after-refile-insert-hook', which Org
;; runs in the destination buffer with point on the freshly pasted heading.
;; That destination is passed along as a touched file, so refiling into a file
;; outside `org-agenda-files' still gets that file committed rather than
;; leaving it dirty and orphaned.
;;
;; Why an event type is chosen rather than fixed per command:
;;
;; Most of these commands change one known thing.  The day-shifting pair does
;; not: `org-agenda-do-date-later' and `org-agenda-do-date-earlier' -- `L' and
;; `H' under evil-org-agenda, and the usual way to drag an item across days --
;; run `org-timestamp-change' on whatever timestamp sits under point.  That may
;; be the SCHEDULED line, the DEADLINE line, or a plain active timestamp in the
;; entry.  Their advice therefore offers several candidate types and takes the
;; first whose describer sees a change, so a dragged deadline is recorded as a
;; deadline rather than mislabelled.
;;
;; Bulk operations need no special handling.  `org-agenda-maybe-loop' re-enters
;; the same command symbol once per entry in the region, so each pass hits this
;; advice at its own agenda line and produces its own event; the debouncing in
;; `dm-org-persist' then collects them into one commit.
;;
;; What is deliberately not recorded:
;;
;;   - No-ops.  Setting the priority an entry already has, or rescheduling to
;;     the date it already had, compares equal and produces nothing.  (Git's
;;     own diff check is the backstop, but catching it here keeps a no-op from
;;     contributing a misleading line to an otherwise real commit.)
;;   - Cancelled commands, as described above.
;;   - Navigation.  `org-agenda-refile' with a prefix argument goes to the last
;;     refile target or clears the cache; neither moves anything.
;;
;; One case looks like a no-op and is not.  Completing a repeating task leaves
;; the entry back in its original TODO state with a shifted SCHEDULED date, so
;; the state comparison finds nothing.  It is detected as state-unchanged plus
;; date-changed and described as a completion, which matters here because
;; `dm-org-repeat-days' makes repeating entries routine.
;;
;; Adding an event type -- effort, tags, clocking, a property -- is a describer
;; function plus an entry in `dm-org-agenda-persist-describers' plus an entry
;; in `dm-org-agenda-persist--advice'.  The describers are pure functions from
;; two snapshots to a subject line and metadata, which is what makes them
;; testable without Org or Git.
;;
;; Version-sensitive assumptions, all verified against Org 10.0-pre:
;;
;;   - Agenda lines carry an `org-hd-marker' text property (`org-marker' is
;;     used as a fallback).
;;   - `org-after-refile-insert-hook' runs in the destination buffer with point
;;     on the inserted heading.
;;   - `org-entry-get' on "PRIORITY" returns `org-priority-default' when the
;;     entry carries no cookie, so an uncookied entry and one explicitly set to
;;     the default are indistinguishable.  Harmless: setting the default on an
;;     uncookied entry is a genuine no-op.

;;; Code:

(require 'dm-org-persist)

(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-entry-get "org" (epom property &optional inherit literal-nil))
(declare-function org-entry-is-done-p "org" ())
(declare-function org-get-at-bol "org" (property))
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-get-outline-path "org" (&optional with-self use-cache))
(defvar org-after-refile-insert-hook)

(defgroup dm-org-agenda-persist nil
  "Record Org agenda mutations as semantic Git events."
  :group 'dm-org-persist)

(defcustom dm-org-agenda-persist-commands
  '(org-agenda-todo
    org-agenda-schedule
    org-agenda-deadline
    org-agenda-priority
    org-agenda-do-date-later
    org-agenda-do-date-earlier
    org-agenda-refile)
  "Agenda commands instrumented to record a semantic event.

Only commands `dm-org-agenda-persist--advice' knows how to describe can be
listed.  Changing this takes effect on the next call to
`dm-org-agenda-persist-install'."
  :type '(repeat function)
  :group 'dm-org-agenda-persist)

;;; ————————————————————————————
;;; Reading the entry behind an agenda line
;;; ————————————————————————————

(defun dm-org-agenda-persist--marker ()
  "Return the marker on the current agenda line pointing at its Org heading."
  (or (org-get-at-bol 'org-hd-marker)
      (org-get-at-bol 'org-marker)))

(defun dm-org-agenda-persist--file ()
  "Return the file behind the current buffer, following any indirect base."
  (or (buffer-file-name)
      (and (buffer-base-buffer) (buffer-file-name (buffer-base-buffer)))))

(defun dm-org-agenda-persist--plain (value)
  "Return VALUE with text properties stripped.

`org-get-heading' and `org-get-outline-path' hand back propertized strings
-- fontification, `org-todo-head', and the like.  Those properties would
survive into a commit message, where `format' prints a propertized string
in its `#(\"text\" 0 4 (prop val))' read syntax."
  (cond ((stringp value) (substring-no-properties value))
        ((listp value) (mapcar #'dm-org-agenda-persist--plain value))
        (t value)))

(defun dm-org-agenda-persist--read ()
  "Return a snapshot of the Org entry at point.

Point is assumed to be inside the entry; the heading is located from
there.  See `dm-org-agenda-persist--snapshot' for the plist shape."
  (org-back-to-heading t)
  (list :file (dm-org-agenda-persist--file)
        :olp (dm-org-agenda-persist--plain (org-get-outline-path))
        :heading (dm-org-agenda-persist--plain (org-get-heading t t t t))
        :todo (org-entry-get nil "TODO")
        :done (and (org-entry-is-done-p) t)
        :scheduled (org-entry-get nil "SCHEDULED")
        :deadline (org-entry-get nil "DEADLINE")
        ;; The entry's first plain active timestamp, which is what an
        ;; appointment-style agenda entry is shown by and what the
        ;; day-shifting commands move when there is no planning line.
        :timestamp (org-entry-get nil "TIMESTAMP")
        :priority (org-entry-get nil "PRIORITY")
        :id (org-entry-get nil "ID")))

(defun dm-org-agenda-persist--snapshot (marker)
  "Return a snapshot of the Org entry MARKER points at, or nil.

The snapshot is a plist of :file, :olp, :heading, :todo, :done,
:scheduled, :deadline, :timestamp, :priority, and :id.  Everything is
read through public Org accessors, and nothing is written -- an entry
without an ID does not acquire one."
  (when (and (markerp marker) (buffer-live-p (marker-buffer marker)))
    ;; This is what `org-with-point-at' does for a marker, spelled out so the
    ;; module does not have to pull `org-macs' into the startup path just for
    ;; one macro.
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (save-restriction
          (widen)
          (goto-char marker)
          (dm-org-agenda-persist--read))))))

;;; ————————————————————————————
;;; Describing a change
;;;
;;; Pure functions of two snapshots.  Each returns nil for a no-op, or a
;;; cons of (SUBJECT . METADATA) where METADATA is an alist of the fields
;;; particular to that kind of change.
;;; ————————————————————————————

(defconst dm-org-agenda-persist--timestamp-regexp
  (concat "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)"   ; date
          "\\(?: [^][<>\n 0-9]+\\)?"                        ; day name
          "\\(?: \\([0-9]\\{1,2\\}:[0-9]\\{2\\}"            ; time
          "\\(?:-[0-9]\\{1,2\\}:[0-9]\\{2\\}\\)?\\)\\)?")   ; time range
  "Regexp matching the date and optional time inside an Org timestamp.")

(defun dm-org-agenda-persist-timestamp-date (timestamp)
  "Return the date, and time if present, held in TIMESTAMP.

TIMESTAMP is an Org timestamp string such as \"<2026-09-02 Wed 10:00 ++1d>\";
the result is \"2026-09-02 10:00\".  Brackets, day name, and repeater and
delay cookies are dropped: they describe how the timestamp behaves, not
which moment it names, and a message about a reschedule should show the
moment.  Return nil for nil or for anything without a date."
  (when (and timestamp (string-match dm-org-agenda-persist--timestamp-regexp timestamp))
    (concat (match-string 1 timestamp)
            (when (match-string 2 timestamp)
              (concat " " (match-string 2 timestamp))))))

(defun dm-org-agenda-persist-describe-todo (before after)
  "Describe the TODO transition between snapshots BEFORE and AFTER."
  (let ((old (plist-get before :todo))
        (new (plist-get after :todo))
        (title (plist-get after :heading)))
    (cond
     ((not (equal old new))
      (cons (if (plist-get after :done)
                (format "Mark %S %s" title new)
              (format "Move %S %s → %s" title (or old "none") (or new "none")))
            (list (cons 'old old) (cons 'new new))))
     ;; A repeating entry completed: Org has reset the keyword and advanced
     ;; the timestamp, so the state comparison alone would call this a no-op.
     ((let ((old-date (dm-org-agenda-persist-timestamp-date (plist-get before :scheduled)))
            (new-date (dm-org-agenda-persist-timestamp-date (plist-get after :scheduled))))
        (and old-date new-date (not (equal old-date new-date))
             (cons (format "Complete %S (repeats → %s)" title new-date)
                   (list (cons 'old old) (cons 'new new) (cons 'repeat new-date)))))))))

(defun dm-org-agenda-persist--describe-planning (before after key wordings)
  "Describe the change to planning line KEY between BEFORE and AFTER.

KEY is :scheduled or :deadline.  WORDINGS is a list of three format
strings, for removing, adding, and moving the timestamp respectively."
  (let ((old (dm-org-agenda-persist-timestamp-date (plist-get before key)))
        (new (dm-org-agenda-persist-timestamp-date (plist-get after key)))
        (title (plist-get after :heading)))
    (unless (equal old new)
      (cons (cond
             ((null new) (format (nth 0 wordings) title))
             ((null old) (format (nth 1 wordings) title new))
             (t (format (nth 2 wordings) title old new)))
            (list (cons 'old old) (cons 'new new))))))

(defun dm-org-agenda-persist-describe-scheduled (before after)
  "Describe the SCHEDULED change between snapshots BEFORE and AFTER."
  (dm-org-agenda-persist--describe-planning
   before after :scheduled
   '("Unschedule %S" "Schedule %S for %s" "Reschedule %S %s → %s")))

(defun dm-org-agenda-persist-describe-deadline (before after)
  "Describe the DEADLINE change between snapshots BEFORE and AFTER."
  (dm-org-agenda-persist--describe-planning
   before after :deadline
   '("Remove deadline from %S" "Deadline %S %s" "Move deadline %S %s → %s")))

(defun dm-org-agenda-persist-describe-priority (before after)
  "Describe the priority change between snapshots BEFORE and AFTER."
  (let ((old (plist-get before :priority))
        (new (plist-get after :priority))
        (title (plist-get after :heading)))
    (unless (equal old new)
      (cons (format "Priority %S %s → %s" title (or old "none") (or new "none"))
            (list (cons 'old old) (cons 'new new))))))

(defun dm-org-agenda-persist-describe-timestamp (before after)
  "Describe the change to a plain timestamp between snapshots BEFORE and AFTER.

This is the appointment case: an entry that appears in the agenda on the
strength of an active timestamp rather than a SCHEDULED or DEADLINE line."
  (dm-org-agenda-persist--describe-planning
   before after :timestamp
   '("Remove timestamp from %S" "Timestamp %S %s" "Move %S %s → %s")))

(defun dm-org-agenda-persist-container (snapshot)
  "Return a short name for where SNAPSHOT's entry lives.

The immediate parent heading, or the file's base name when the entry sits
at the top level of a file."
  (or (car (last (plist-get snapshot :olp)))
      (when-let* ((file (plist-get snapshot :file)))
        (capitalize (file-name-base file)))))

(defun dm-org-agenda-persist-describe-refile (before after)
  "Describe the move from snapshot BEFORE to snapshot AFTER."
  (let ((from (dm-org-agenda-persist-container before))
        (to (dm-org-agenda-persist-container after)))
    (unless (and (equal from to)
                 (equal (plist-get before :file) (plist-get after :file)))
      (cons (format "Refile %S %s → %s" (plist-get before :heading) from to)
            (list (cons 'old from) (cons 'new to)
                  (cons 'from-file (dm-org-persist-relative-name
                                    (plist-get before :file))))))))

(defconst dm-org-agenda-persist-describers
  '((todo . dm-org-agenda-persist-describe-todo)
    (scheduled . dm-org-agenda-persist-describe-scheduled)
    (deadline . dm-org-agenda-persist-describe-deadline)
    (timestamp . dm-org-agenda-persist-describe-timestamp)
    (priority . dm-org-agenda-persist-describe-priority)
    (refile . dm-org-agenda-persist-describe-refile))
  "Alist mapping an event type to the function that describes it.

A describer takes the before and after snapshots and returns nil for a
no-op, or a cons of the subject line and an alist of metadata.")

;;; ————————————————————————————
;;; Turning a described change into an event
;;; ————————————————————————————

(defun dm-org-agenda-persist--identity (snapshot)
  "Return the metadata fields identifying SNAPSHOT's entry.

An `id' field appears only when the heading already carries an ID; none is
ever created, so reading state never writes to an Org file.  Without one,
file plus outline path plus heading text is the identity."
  (append
   (when-let* ((id (plist-get snapshot :id))) (list (cons 'id id)))
   (list (cons 'file (dm-org-persist-relative-name (plist-get snapshot :file)))
         (cons 'olp (vconcat (plist-get snapshot :olp)))
         (cons 'heading (plist-get snapshot :heading)))))

(defun dm-org-agenda-persist-event (type before after)
  "Return the event describing a TYPE change from BEFORE to AFTER, or nil.

Nil means nothing worth recording happened: a missing snapshot, or a
describer that found the two states equivalent."
  (when-let* (((and before after))
              (describer (alist-get type dm-org-agenda-persist-describers))
              (described (funcall describer before after)))
    (list :subject (car described)
          :data (append (list (cons 'type (symbol-name type)))
                        (dm-org-agenda-persist--identity after)
                        (cdr described)
                        (list (cons 'time (format-time-string "%FT%T%z"))))
          :files (delete-dups (delq nil (list (plist-get before :file)
                                              (plist-get after :file)))))))

(defun dm-org-agenda-persist--record (types before after)
  "Persist an event for the first of TYPES describing BEFORE to AFTER.

TYPES is tried in order and the first describer to report a change wins,
which is how one command can record whichever kind of date it moved.

Every failure here is contained: recording history must never be able to
break the agenda command that triggered it."
  (condition-case err
      (when-let* ((event (seq-some (lambda (type)
                                     (dm-org-agenda-persist-event type before after))
                                   types)))
        (dm-org-persist event))
    (error
     (display-warning 'dm-org-agenda-persist
                      (format "Could not record %s event: %s"
                              (car types) (error-message-string err))
                      :warning))))

;;; ————————————————————————————
;;; Advice
;;; ————————————————————————————

(defun dm-org-agenda-persist--active-marker ()
  "Return the agenda line's heading marker when persistence should run."
  (and dm-org-persist-enabled
       (eq major-mode 'org-agenda-mode)
       (ignore-errors (dm-org-agenda-persist--marker))))

(defun dm-org-agenda-persist--around (types fn args)
  "Run FN on ARGS, recording the first of TYPES whose describer sees a change."
  (let* ((marker (dm-org-agenda-persist--active-marker))
         (before (and marker (ignore-errors (dm-org-agenda-persist--snapshot marker)))))
    (prog1 (apply fn args)
      (when before
        (dm-org-agenda-persist--record
         types before (ignore-errors (dm-org-agenda-persist--snapshot marker)))))))

(defun dm-org-agenda-persist-todo-a (fn &rest args)
  "Record a TODO transition around FN, which is `org-agenda-todo'.
ARGS are passed through untouched."
  (dm-org-agenda-persist--around '(todo) fn args))

(defun dm-org-agenda-persist-schedule-a (fn &rest args)
  "Record a scheduling change around FN, which is `org-agenda-schedule'.
ARGS are passed through untouched."
  (dm-org-agenda-persist--around '(scheduled) fn args))

(defun dm-org-agenda-persist-deadline-a (fn &rest args)
  "Record a deadline change around FN, which is `org-agenda-deadline'.
ARGS are passed through untouched."
  (dm-org-agenda-persist--around '(deadline) fn args))

(defun dm-org-agenda-persist-priority-a (fn &rest args)
  "Record a priority change around FN, which is `org-agenda-priority'.
ARGS are passed through untouched."
  (dm-org-agenda-persist--around '(priority) fn args))

(defun dm-org-agenda-persist-date-shift-a (fn &rest args)
  "Record a day shift around FN, one of the `org-agenda-do-date-*' pair.

Those commands move whatever timestamp is under point, so every kind of
date it could have been is offered.  ARGS are passed through untouched."
  (dm-org-agenda-persist--around '(scheduled deadline timestamp) fn args))

(defvar dm-org-agenda-persist--destination nil
  "Where the refile in progress landed, as a snapshot.
Bound around `org-agenda-refile' and filled in by
`dm-org-agenda-persist--destination-h'.")

(defun dm-org-agenda-persist--destination-h ()
  "Record where a refile landed.  For `org-after-refile-insert-hook'.

Org runs this hook in the destination buffer with point on the pasted
heading, which is the only moment the destination is knowable: the marker
the agenda line carried pointed into the source file and the subtree is no
longer there."
  (setq dm-org-agenda-persist--destination
        (ignore-errors (dm-org-agenda-persist--read))))

(defun dm-org-agenda-persist-refile-a (fn &rest args)
  "Record a refile around FN, which is `org-agenda-refile'.
ARGS are passed through untouched."
  ;; A non-nil GOTO means go to the last refile target or clear the refile
  ;; cache.  Neither moves anything, so there is nothing to record.
  (let ((marker (and (null (car args)) (dm-org-agenda-persist--active-marker))))
    (if (not marker)
        (apply fn args)
      (let ((before (ignore-errors (dm-org-agenda-persist--snapshot marker)))
            (dm-org-agenda-persist--destination nil))
        (unwind-protect
            (progn
              (add-hook 'org-after-refile-insert-hook #'dm-org-agenda-persist--destination-h)
              (prog1 (apply fn args)
                (when before
                  (dm-org-agenda-persist--record
                   '(refile) before dm-org-agenda-persist--destination))))
          (remove-hook 'org-after-refile-insert-hook
                       #'dm-org-agenda-persist--destination-h))))))

(defconst dm-org-agenda-persist--advice
  '((org-agenda-todo . dm-org-agenda-persist-todo-a)
    (org-agenda-schedule . dm-org-agenda-persist-schedule-a)
    (org-agenda-deadline . dm-org-agenda-persist-deadline-a)
    (org-agenda-priority . dm-org-agenda-persist-priority-a)
    (org-agenda-do-date-later . dm-org-agenda-persist-date-shift-a)
    (org-agenda-do-date-earlier . dm-org-agenda-persist-date-shift-a)
    (org-agenda-refile . dm-org-agenda-persist-refile-a))
  "Alist mapping an agenda command to the advice that instruments it.")

(defun dm-org-agenda-persist-install ()
  "Advise every command in `dm-org-agenda-persist-commands'."
  (interactive)
  (pcase-dolist (`(,command . ,advice) dm-org-agenda-persist--advice)
    (when (memq command dm-org-agenda-persist-commands)
      (advice-add command :around advice))))

(defun dm-org-agenda-persist-uninstall ()
  "Remove every advice this module installs."
  (interactive)
  (pcase-dolist (`(,command . ,advice) dm-org-agenda-persist--advice)
    (advice-remove command advice)))

(with-eval-after-load 'org-agenda
  (dm-org-agenda-persist-install))

(provide 'dm-org-agenda-persist)
;;; dm-org-agenda-persist.el ends here
