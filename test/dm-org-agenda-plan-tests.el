;;; dm-org-agenda-plan-tests.el --- Tests for dm-org-agenda-plan  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root:
;;
;;   bin/test dm-org-agenda-plan
;;
;; or, without the runner:
;;
;;   emacs -Q --batch \
;;     -L modules -L test \
;;     -L "$HOME/.dotfiles/share/emacs/straight/build/org" \
;;     -l dm-org-agenda-plan-tests.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; These build a real agenda over a temporary Org file and, where the test is
;; about a write, apply the proposal and read the file back.  What is under
;; test is largely the interaction with Org itself -- which lines it produces,
;; what it writes for a time range, what it does with a repeater -- so there
;; is not much to learn from mocking any of it.
;;
;; `dm-org-agenda-save-all-files' lives in `dm-org', which drags in the whole
;; use-package startup path, so it is stubbed to the one thing it does.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'org)
(require 'org-agenda)
(require 'dm-org-agenda-capacity)
(require 'dm-org-agenda-plan)

(unless (fboundp 'dm-org-agenda-save-all-files)
  (defun dm-org-agenda-save-all-files (&rest _)
    (org-save-all-org-buffers)))

;;; ————————————————————————————
;;; Fixture
;;; ————————————————————————————

(defvar dm-org-agenda-plan-tests--fixture "\
* TODO Design review
  SCHEDULED: <2026-08-31 Mon 11:00-13:00>
* TODO Write the report
  SCHEDULED: <2026-08-31 Mon>
  :PROPERTIES:
  :EFFORT:   2:00
  :END:
* TODO Review the PRs
  SCHEDULED: <2026-08-31 Mon>
  :PROPERTIES:
  :EFFORT:   2:00
  :END:
* TODO Draft the proposal
  SCHEDULED: <2026-08-31 Mon>
  :PROPERTIES:
  :EFFORT:   1:30
  :END:
* TODO Unestimated errand
  SCHEDULED: <2026-08-31 Mon>
* DONE Already finished
  SCHEDULED: <2026-08-31 Mon>
  :PROPERTIES:
  :EFFORT:   4:00
  :END:
* TODO Daily standup
  SCHEDULED: <2026-08-31 Mon ++1d>
  :PROPERTIES:
  :EFFORT:   0:15
  :END:
"
  "A Monday holding one fixed meeting and every kind of entry a plan must
decide about: sizeable flexible work, an unestimated task, a completed task
and a repeater.")

(defvar dm-org-agenda-plan-tests--file nil
  "Path of the temporary Org file the current test is running against.")

(defmacro dm-org-agenda-plan-tests--with-agenda (fixture &rest body)
  "Build a three day agenda over FIXTURE from 2026-08-31 and run BODY.

BODY runs in the agenda buffer with `dm-org-agenda-plan-tests--file' bound to
the Org file, so a test can read back what an apply wrote.

The clock is pinned to the Monday the fixtures schedule their work on.
`org-agenda-list' fixes which days the buffer spans but not which of them is
today, and Org draws undone work scheduled before today a second time on
today, as `past-scheduled'.  Unpinned, a day inside the span eventually
becomes today, every overloaded Monday turns up on Tuesday as well, and the
spill tests start proposing the day after the one they expect."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'org-today)
              (lambda () (time-to-days (org-time-string-to-time "2026-08-31")))))
     (let ((dm-org-agenda-plan-tests--file
            (make-temp-file "dm-org-agenda-plan" nil ".org" ,fixture))
           (org-agenda-buffer-name "*dm-org-agenda-plan-test*"))
       (unwind-protect
           (let ((org-agenda-files (list dm-org-agenda-plan-tests--file))
                 (org-agenda-format-date
                  (lambda (date) (concat "\n" (org-agenda-format-date-aligned date))))
                 (org-agenda-prefix-format '((agenda . "[%4e] %5t ")))
                 (org-agenda-skip-scheduled-if-done t)
                 (org-agenda-use-time-grid nil)
                 (org-agenda-window-setup 'current-window)
                 (org-agenda-sticky nil)
                 (org-log-reschedule nil)
                 (dm-org-daily-capacity '((1 . 360) (2 . 360) (3 . 360)))
                 (dm-org-daily-workday '((1 . (540 . 1080))
                                         (2 . (540 . 1080))
                                         (3 . (540 . 1080)))))
             (save-window-excursion
               (org-agenda-list nil "2026-08-31" 3))
             (with-current-buffer org-agenda-buffer-name ,@body))
         (dolist (buffer (org-buffer-list 'files))
           (kill-buffer buffer))
         (dolist (name (list "*Org Day Plan*" org-agenda-buffer-name))
           (when (get-buffer name) (kill-buffer name)))
         (delete-file dm-org-agenda-plan-tests--file)))))

(defun dm-org-agenda-plan-tests--agenda ()
  "Return the live agenda buffer.

Looked up by name every time rather than captured once: `org-agenda-list'
assigns `org-agenda-buffer-name' itself, and an apply rebuilds the buffer."
  (or (get-buffer org-agenda-buffer-name)
      (error "No agenda buffer")))

(defun dm-org-agenda-plan-tests--goto (text)
  "Move to the agenda line containing TEXT, selecting the agenda buffer."
  (set-buffer (dm-org-agenda-plan-tests--agenda))
  (goto-char (point-min))
  (search-forward text)
  (forward-line 0))

(defun dm-org-agenda-plan-tests--contents ()
  "Return the current test's Org file as a string, read from disk."
  (with-temp-buffer
    (insert-file-contents dm-org-agenda-plan-tests--file)
    (buffer-string)))

(defun dm-org-agenda-plan-tests--pending ()
  "Return the changes the preview buffer is holding."
  (with-current-buffer "*Org Day Plan*" dm-org-agenda-plan--pending))

(defun dm-org-agenda-plan-tests--skipped-text ()
  "Return the text of the preview buffer's `Left alone' section."
  (with-current-buffer "*Org Day Plan*"
    (goto-char (point-min))
    (if (search-forward "Left alone" nil t)
        (buffer-substring-no-properties (point) (point-max))
      "")))

(defun dm-org-agenda-plan-tests--apply ()
  "Apply whatever the preview buffer proposes."
  (with-current-buffer "*Org Day Plan*"
    (dm-org-agenda-plan-apply)))

;;; ————————————————————————————
;;; Packing
;;; ————————————————————————————

(ert-deftest dm-org-agenda-plan-pack/proposes-times-in-agenda-order ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--fixture
    (dm-org-agenda-plan-tests--goto "Monday")
    (dm-org-agenda-pack-day)
    (let ((changes (dm-org-agenda-plan-tests--pending)))
      ;; The 11:00-13:00 meeting leaves runs of 09:00-11:00 and 13:00-18:00.
      (should (equal '("Write the report" "Review the PRs" "Draft the proposal")
                     (mapcar (lambda (c) (plist-get c :heading)) changes)))
      (should (equal '("2026-08-31 09:00-11:00"
                       "2026-08-31 13:00-15:00"
                       "2026-08-31 15:00-16:30")
                     (mapcar (lambda (c) (plist-get c :new)) changes))))))

(ert-deftest dm-org-agenda-plan-pack/writes-ranges-and-records-the-original ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--fixture
    (dm-org-agenda-plan-tests--goto "Monday")
    (dm-org-agenda-pack-day)
    (dm-org-agenda-plan-tests--apply)
    (let ((contents (dm-org-agenda-plan-tests--contents)))
      (should (string-match-p "SCHEDULED: <2026-08-31 Mon 09:00-11:00>" contents))
      ;; The original is parked inactive: an active timestamp in a drawer is
      ;; still a timestamp to the agenda, and would show up as a phantom.
      (should (string-match-p ":DM_PACKED: \\[2026-08-31 Mon\\]" contents))
      (should-not (string-match-p ":DM_PACKED: <" contents)))))

(ert-deftest dm-org-agenda-plan-pack/leaves-a-repeater-alone ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--fixture
    (dm-org-agenda-plan-tests--goto "Monday")
    (dm-org-agenda-pack-day)
    (should-not (seq-find (lambda (c) (equal (plist-get c :heading) "Daily standup"))
                          (dm-org-agenda-plan-tests--pending)))
    (should (string-match-p "Daily standup.*repeats"
                            (dm-org-agenda-plan-tests--skipped-text)))
    (dm-org-agenda-plan-tests--apply)
    ;; `org-schedule' would have rewritten it and kept the cookie, which is
    ;; exactly the silent corruption the guard exists to prevent.
    (should (string-match-p "SCHEDULED: <2026-08-31 Mon \\+\\+1d>"
                            (dm-org-agenda-plan-tests--contents)))))

(ert-deftest dm-org-agenda-plan-pack/reports-an-entry-with-no-effort ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--fixture
    (dm-org-agenda-plan-tests--goto "Monday")
    (dm-org-agenda-pack-day)
    (should-not (seq-find (lambda (c) (equal (plist-get c :heading) "Unestimated errand"))
                          (dm-org-agenda-plan-tests--pending)))
    (should (string-match-p "Unestimated errand.*no EFFORT"
                            (dm-org-agenda-plan-tests--skipped-text)))))

(ert-deftest dm-org-agenda-plan-pack/leaves-done-and-fixed-work-alone ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--fixture
    (dm-org-agenda-plan-tests--goto "Monday")
    (dm-org-agenda-pack-day)
    (let ((headings (mapcar (lambda (c) (plist-get c :heading))
                            (dm-org-agenda-plan-tests--pending))))
      ;; The meeting is a constraint the plan is built around, not cargo.
      (should-not (member "Design review" headings))
      (should-not (member "Already finished" headings)))))

(ert-deftest dm-org-agenda-plan-pack/reports-work-that-will-not-fit ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--fixture
    (let ((dm-org-daily-workday '((1 . (540 . 660)))))
      (dm-org-agenda-plan-tests--goto "Monday")
      (dm-org-agenda-pack-day)
      ;; Only 09:00-11:00 of window, so the 2:00 task takes it and the rest
      ;; have nowhere to go.
      (should (= 1 (length (dm-org-agenda-plan-tests--pending))))
      (should (string-match-p "no free run long enough"
                              (dm-org-agenda-plan-tests--skipped-text))))))

(ert-deftest dm-org-agenda-plan-pack/without-a-window-changes-nothing ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--fixture
    (let ((dm-org-daily-workday nil))
      (dm-org-agenda-plan-tests--goto "Monday")
      (dm-org-agenda-pack-day)
      (should-not (dm-org-agenda-plan-tests--pending))
      (should (string-match-p "no workday window"
                              (dm-org-agenda-plan-tests--skipped-text))))))

;;; ————————————————————————————
;;; Unpacking
;;; ————————————————————————————

(ert-deftest dm-org-agenda-plan-unpack/restores-the-file-exactly ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--fixture
    (let ((before (dm-org-agenda-plan-tests--contents)))
      (dm-org-agenda-plan-tests--goto "Monday")
      (dm-org-agenda-pack-day)
      (dm-org-agenda-plan-tests--apply)
      (should-not (equal before (dm-org-agenda-plan-tests--contents)))
      (dm-org-agenda-plan-tests--goto "Monday")
      (dm-org-agenda-unpack-day)
      (dm-org-agenda-plan-tests--apply)
      ;; Byte for byte, including the property drawer that has to disappear.
      (should (equal before (dm-org-agenda-plan-tests--contents))))))

(ert-deftest dm-org-agenda-plan-unpack/ignores-entries-it-did-not-write ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--fixture
    (dm-org-agenda-plan-tests--goto "Monday")
    (dm-org-agenda-unpack-day)
    (should-not (dm-org-agenda-plan-tests--pending))))

(ert-deftest dm-org-agenda-plan-pack/a-second-pack-has-nothing-to-do ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--fixture
    (let ((before (dm-org-agenda-plan-tests--contents)))
      (dm-org-agenda-plan-tests--goto "Monday")
      (dm-org-agenda-pack-day)
      (dm-org-agenda-plan-tests--apply)
      (dm-org-agenda-plan-tests--goto "Monday")
      (dm-org-agenda-pack-day)
      ;; The first pack's output carries clock times, so it is fixed work now
      ;; and there is nothing flexible left to place.  Packing settles rather
      ;; than churns; reshuffling a day means unpacking it first.
      (should-not (dm-org-agenda-plan-tests--pending))
      (dm-org-agenda-plan-tests--goto "Monday")
      (dm-org-agenda-unpack-day)
      (dm-org-agenda-plan-tests--apply)
      (should (equal before (dm-org-agenda-plan-tests--contents))))))

;;; ————————————————————————————
;;; Spilling
;;; ————————————————————————————

(defvar dm-org-agenda-plan-tests--overloaded "\
* TODO Alpha
  SCHEDULED: <2026-08-31 Mon>
  :PROPERTIES:
  :EFFORT:   3:00
  :END:
* TODO Beta
  SCHEDULED: <2026-08-31 Mon>
  :PROPERTIES:
  :EFFORT:   3:00
  :END:
* TODO Gamma
  DEADLINE: <2026-08-31 Mon> SCHEDULED: <2026-08-31 Mon>
  :PROPERTIES:
  :EFFORT:   1:30
  :END:
"
  "7:30 of work on a Monday with 6:00 of capacity, one piece deadline-bound.")

(ert-deftest dm-org-agenda-plan-spill/moves-work-to-the-next-day-with-room ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--overloaded
    (dm-org-agenda-plan-tests--goto "Monday")
    (dm-org-agenda-spill-overflow)
    (let ((changes (dm-org-agenda-plan-tests--pending)))
      ;; Shed from the end of the agenda's order, and only as much as needed.
      (should (= 1 (length changes)))
      (should (equal "Beta" (plist-get (car changes) :heading)))
      (should (equal "2026-09-01" (plist-get (car changes) :new))))
    (dm-org-agenda-plan-tests--apply)
    (should (string-match-p "\\* TODO Beta\n  SCHEDULED: <2026-09-01 Tue>"
                            (dm-org-agenda-plan-tests--contents)))))

(ert-deftest dm-org-agenda-plan-spill/never-moves-past-a-deadline ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--overloaded
    (dm-org-agenda-plan-tests--goto "Monday")
    (dm-org-agenda-spill-overflow)
    (should-not (seq-find (lambda (c) (equal (plist-get c :heading) "Gamma"))
                          (dm-org-agenda-plan-tests--pending)))
    (should (string-match-p "Gamma.*deadline"
                            (dm-org-agenda-plan-tests--skipped-text)))))

(ert-deftest dm-org-agenda-plan-spill/reports-when-the-span-has-no-room ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--overloaded
    ;; Only Monday has any capacity at all, so there is nowhere to go.
    (let ((dm-org-daily-capacity '((1 . 360)))
          (dm-org-daily-workday '((1 . (540 . 1080)))))
      (dm-org-agenda-plan-tests--goto "Monday")
      (dm-org-agenda-spill-overflow)
      (should-not (dm-org-agenda-plan-tests--pending))
      (should (string-match-p "no later day in the agenda has room"
                              (dm-org-agenda-plan-tests--skipped-text))))))

(ert-deftest dm-org-agenda-plan-spill/leaves-a-day-that-works-alone ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--fixture
    (dm-org-agenda-plan-tests--goto "Monday")
    (dm-org-agenda-spill-overflow)
    (should-not (dm-org-agenda-plan-tests--pending))))

;;; ————————————————————————————
;;; Command surface
;;; ————————————————————————————

(ert-deftest dm-org-agenda-plan-days/prefix-argument-widens-to-the-span ()
  (dm-org-agenda-plan-tests--with-agenda dm-org-agenda-plan-tests--fixture
    (dm-org-agenda-plan-tests--goto "Monday")
    (should (= 1 (length (dm-org-agenda-plan--days nil))))
    ;; Every day the agenda shows, including the two with nothing on them.
    (should (= 3 (length (dm-org-agenda-plan--days t))))))

(ert-deftest dm-org-agenda-plan-days/outside-an-agenda-buffer-errors ()
  (with-temp-buffer
    (should-error (dm-org-agenda-plan--days nil) :type 'user-error)))

(ert-deftest dm-org-agenda-plan-apply/outside-a-preview-buffer-errors ()
  (with-temp-buffer
    (should-error (dm-org-agenda-plan-apply) :type 'user-error)))

(ert-deftest dm-org-agenda-plan-park/makes-a-timestamp-inert ()
  (should (equal "[2026-08-31 Mon]"
                 (dm-org-agenda-plan--park "<2026-08-31 Mon>")))
  (should (equal "[2026-08-31 Mon 11:00-13:00]"
                 (dm-org-agenda-plan--park "<2026-08-31 Mon 11:00-13:00>")))
  (should-not (dm-org-agenda-plan--park nil)))

(provide 'dm-org-agenda-plan-tests)
;;; dm-org-agenda-plan-tests.el ends here
