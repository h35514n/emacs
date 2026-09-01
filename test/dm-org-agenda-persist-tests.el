;;; dm-org-agenda-persist-tests.el --- Tests for dm-org-agenda-persist  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root:
;;
;;   emacs -Q --batch \
;;     -L modules -L test \
;;     -L "$HOME/.dotfiles/share/emacs/straight/build/org" \
;;     -l dm-org-agenda-persist-tests.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; The Org load path is only needed for the end-to-end tests; the describers
;; and event construction are pure functions of two snapshot plists and run
;; against `dm-org-agenda-persist' alone.
;;
;; Nothing here touches Git.  `dm-org-persist' is stubbed so the end-to-end
;; tests can assert on the events an agenda command produces without a
;; repository being involved at all.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'dm-org-agenda-persist)

(defvar org-agenda-files)

;;; ————————————————————————————
;;; Reading a timestamp
;;; ————————————————————————————

(ert-deftest dm-org-agenda-persist-timestamp-date/extracts-the-date ()
  (should (equal "2026-09-02" (dm-org-agenda-persist-timestamp-date "<2026-09-02 Wed>")))
  (should (equal "2026-09-02" (dm-org-agenda-persist-timestamp-date "[2026-09-02 Wed]")))
  (should (equal "2026-09-02" (dm-org-agenda-persist-timestamp-date "2026-09-02"))))

(ert-deftest dm-org-agenda-persist-timestamp-date/keeps-a-time ()
  (should (equal "2026-09-01 10:00"
                 (dm-org-agenda-persist-timestamp-date "<2026-09-01 Tue 10:00>")))
  (should (equal "2026-09-01 09:30-10:30"
                 (dm-org-agenda-persist-timestamp-date "<2026-09-01 Tue 09:30-10:30>"))))

(ert-deftest dm-org-agenda-persist-timestamp-date/drops-repeater-and-delay-cookies ()
  ;; A cookie says how the timestamp behaves, not which moment it names, so
  ;; two dates that differ only by cookie must compare equal.
  (should (equal "2026-09-02" (dm-org-agenda-persist-timestamp-date "<2026-09-02 Wed ++1d>")))
  (should (equal "2026-09-02" (dm-org-agenda-persist-timestamp-date "<2026-09-02 Wed .+2w -3d>")))
  (should (equal "2026-09-02 09:30"
                 (dm-org-agenda-persist-timestamp-date "<2026-09-02 Wed 09:30 +1m>"))))

(ert-deftest dm-org-agenda-persist-timestamp-date/is-nil-without-a-date ()
  (should-not (dm-org-agenda-persist-timestamp-date nil))
  (should-not (dm-org-agenda-persist-timestamp-date ""))
  (should-not (dm-org-agenda-persist-timestamp-date "<no date here>")))

;;; ————————————————————————————
;;; Describers
;;; ————————————————————————————

(defun dm-org-agenda-persist-tests--snapshot (&rest overrides)
  "Return a snapshot plist for \"Review authentication design\", with OVERRIDES."
  (let ((snapshot (list :file "/repo/org/tasks.org"
                        :olp '("Current Tasks")
                        :heading "Review authentication design"
                        :todo "TODO"
                        :done nil
                        :scheduled nil
                        :deadline nil
                        :timestamp nil
                        :priority "D"
                        :id nil)))
    (while overrides
      (setq snapshot (plist-put snapshot (pop overrides) (pop overrides))))
    snapshot))

(ert-deftest dm-org-agenda-persist-describe-todo/marks-a-done-state ()
  (should (equal "Mark \"Review authentication design\" DONE"
                 (car (dm-org-agenda-persist-describe-todo
                       (dm-org-agenda-persist-tests--snapshot :todo "NEXT")
                       (dm-org-agenda-persist-tests--snapshot :todo "DONE" :done t))))))

(ert-deftest dm-org-agenda-persist-describe-todo/moves-between-open-states ()
  (should (equal "Move \"Review authentication design\" TODO → WIP"
                 (car (dm-org-agenda-persist-describe-todo
                       (dm-org-agenda-persist-tests--snapshot :todo "TODO")
                       (dm-org-agenda-persist-tests--snapshot :todo "WIP"))))))

(ert-deftest dm-org-agenda-persist-describe-todo/records-the-states ()
  (should (equal '((old . "NEXT") (new . "DONE"))
                 (cdr (dm-org-agenda-persist-describe-todo
                       (dm-org-agenda-persist-tests--snapshot :todo "NEXT")
                       (dm-org-agenda-persist-tests--snapshot :todo "DONE" :done t))))))

(ert-deftest dm-org-agenda-persist-describe-todo/names-a-missing-state ()
  (should (equal "Move \"Review authentication design\" none → TODO"
                 (car (dm-org-agenda-persist-describe-todo
                       (dm-org-agenda-persist-tests--snapshot :todo nil)
                       (dm-org-agenda-persist-tests--snapshot :todo "TODO"))))))

(ert-deftest dm-org-agenda-persist-describe-todo/detects-a-completed-repeater ()
  ;; Org resets the keyword and advances SCHEDULED, so the states match even
  ;; though something definitely happened.
  (let ((described (dm-org-agenda-persist-describe-todo
                    (dm-org-agenda-persist-tests--snapshot
                     :todo "TODO" :scheduled "<2026-09-02 Wed ++1d>")
                    (dm-org-agenda-persist-tests--snapshot
                     :todo "TODO" :scheduled "<2026-09-04 Fri ++1d>"))))
    (should (equal "Complete \"Review authentication design\" (repeats → 2026-09-04)"
                   (car described)))
    (should (equal "2026-09-04" (alist-get 'repeat (cdr described))))))

(ert-deftest dm-org-agenda-persist-describe-todo/is-nil-for-a-no-op ()
  (should-not (dm-org-agenda-persist-describe-todo
               (dm-org-agenda-persist-tests--snapshot :todo "TODO")
               (dm-org-agenda-persist-tests--snapshot :todo "TODO"))))

(ert-deftest dm-org-agenda-persist-describe-scheduled/covers-all-three-shapes ()
  (should (equal "Schedule \"Review authentication design\" for 2026-09-01 10:00"
                 (car (dm-org-agenda-persist-describe-scheduled
                       (dm-org-agenda-persist-tests--snapshot :scheduled nil)
                       (dm-org-agenda-persist-tests--snapshot
                        :scheduled "<2026-09-01 Tue 10:00>")))))
  (should (equal "Reschedule \"Review authentication design\" 2026-08-31 → 2026-09-02"
                 (car (dm-org-agenda-persist-describe-scheduled
                       (dm-org-agenda-persist-tests--snapshot :scheduled "<2026-08-31 Mon>")
                       (dm-org-agenda-persist-tests--snapshot :scheduled "<2026-09-02 Wed>")))))
  (should (equal "Unschedule \"Review authentication design\""
                 (car (dm-org-agenda-persist-describe-scheduled
                       (dm-org-agenda-persist-tests--snapshot :scheduled "<2026-08-31 Mon>")
                       (dm-org-agenda-persist-tests--snapshot :scheduled nil))))))

(ert-deftest dm-org-agenda-persist-describe-scheduled/is-nil-for-a-no-op ()
  (should-not (dm-org-agenda-persist-describe-scheduled
               (dm-org-agenda-persist-tests--snapshot :scheduled "<2026-08-31 Mon>")
               (dm-org-agenda-persist-tests--snapshot :scheduled "<2026-08-31 Mon>")))
  ;; The day name is derived from the date, so a corrected one is not a change.
  (should-not (dm-org-agenda-persist-describe-scheduled
               (dm-org-agenda-persist-tests--snapshot :scheduled "<2026-08-31 Mon>")
               (dm-org-agenda-persist-tests--snapshot :scheduled "<2026-08-31 Monday>"))))

(ert-deftest dm-org-agenda-persist-describe-deadline/covers-all-three-shapes ()
  (should (equal "Deadline \"Review authentication design\" 2026-09-05"
                 (car (dm-org-agenda-persist-describe-deadline
                       (dm-org-agenda-persist-tests--snapshot :deadline nil)
                       (dm-org-agenda-persist-tests--snapshot :deadline "<2026-09-05 Sat>")))))
  (should (equal "Move deadline \"Review authentication design\" 2026-09-05 → 2026-09-08"
                 (car (dm-org-agenda-persist-describe-deadline
                       (dm-org-agenda-persist-tests--snapshot :deadline "<2026-09-05 Sat>")
                       (dm-org-agenda-persist-tests--snapshot :deadline "<2026-09-08 Tue>")))))
  (should (equal "Remove deadline from \"Review authentication design\""
                 (car (dm-org-agenda-persist-describe-deadline
                       (dm-org-agenda-persist-tests--snapshot :deadline "<2026-09-05 Sat>")
                       (dm-org-agenda-persist-tests--snapshot :deadline nil))))))

(ert-deftest dm-org-agenda-persist-describe-deadline/ignores-the-scheduled-date ()
  ;; Scheduling and deadlines live on the same planning line; each describer
  ;; must only look at its own.
  (should-not (dm-org-agenda-persist-describe-deadline
               (dm-org-agenda-persist-tests--snapshot :scheduled "<2026-08-31 Mon>")
               (dm-org-agenda-persist-tests--snapshot :scheduled "<2026-09-02 Wed>"))))

(ert-deftest dm-org-agenda-persist-describe-priority/reports-the-transition ()
  (should (equal "Priority \"Review authentication design\" B → A"
                 (car (dm-org-agenda-persist-describe-priority
                       (dm-org-agenda-persist-tests--snapshot :priority "B")
                       (dm-org-agenda-persist-tests--snapshot :priority "A")))))
  (should-not (dm-org-agenda-persist-describe-priority
               (dm-org-agenda-persist-tests--snapshot :priority "B")
               (dm-org-agenda-persist-tests--snapshot :priority "B"))))

(ert-deftest dm-org-agenda-persist-describe-timestamp/reports-a-moved-appointment ()
  (should (equal "Move \"Review authentication design\" 2026-09-01 10:00 → 2026-09-02 10:00"
                 (car (dm-org-agenda-persist-describe-timestamp
                       (dm-org-agenda-persist-tests--snapshot
                        :timestamp "<2026-09-01 Tue 10:00>")
                       (dm-org-agenda-persist-tests--snapshot
                        :timestamp "<2026-09-02 Wed 10:00>")))))
  (should-not (dm-org-agenda-persist-describe-timestamp
               (dm-org-agenda-persist-tests--snapshot :timestamp "<2026-09-01 Tue>")
               (dm-org-agenda-persist-tests--snapshot :timestamp "<2026-09-01 Tue>"))))

(ert-deftest dm-org-agenda-persist-container/names-the-parent-or-the-file ()
  (should (equal "Current Tasks"
                 (dm-org-agenda-persist-container
                  (dm-org-agenda-persist-tests--snapshot :olp '("Projects" "Current Tasks")))))
  ;; A top-level entry belongs to its file.
  (should (equal "Inbox"
                 (dm-org-agenda-persist-container
                  (dm-org-agenda-persist-tests--snapshot
                   :olp nil :file "/repo/org/inbox.org")))))

(ert-deftest dm-org-agenda-persist-describe-refile/names-both-ends ()
  (should (equal "Refile \"Research API pricing\" Inbox → Mallard"
                 (car (dm-org-agenda-persist-describe-refile
                       (dm-org-agenda-persist-tests--snapshot
                        :heading "Research API pricing" :olp nil :file "/repo/org/inbox.org")
                       (dm-org-agenda-persist-tests--snapshot
                        :heading "Research API pricing" :olp '("Mallard")
                        :file "/repo/org/projects.org"))))))

(ert-deftest dm-org-agenda-persist-describe-refile/is-nil-when-nothing-moved ()
  (let ((snapshot (dm-org-agenda-persist-tests--snapshot :olp '("Mallard"))))
    (should-not (dm-org-agenda-persist-describe-refile snapshot snapshot))))

(ert-deftest dm-org-agenda-persist-describe-archive/names-the-archive-file ()
  ;; The archive file is the whole point of the move, and it is the part that
  ;; is not in `org-agenda-files', so the subject names it as git would.
  (dm-org-agenda-persist-tests--in-repo
    (should (equal "Archive \"Water plants\" Current Tasks → org/archive/tasks.org_archive"
                   (car (dm-org-agenda-persist-describe-archive
                         (dm-org-agenda-persist-tests--snapshot :heading "Water plants")
                         (dm-org-agenda-persist-tests--snapshot
                          :heading "Water plants" :olp nil
                          :file "/repo/org/archive/tasks.org_archive")))))))

(ert-deftest dm-org-agenda-persist-describe-archive/names-the-sibling-heading ()
  ;; Archiving to a sibling never leaves the file, so repeating the file name
  ;; would say nothing; the heading it landed under is the news.
  (dm-org-agenda-persist-tests--in-repo
    (should (equal "Archive \"Water plants\" Current Tasks → Archive"
                   (car (dm-org-agenda-persist-describe-archive
                         (dm-org-agenda-persist-tests--snapshot :heading "Water plants")
                         (dm-org-agenda-persist-tests--snapshot
                          :heading "Water plants" :olp '("Archive"))))))))

(ert-deftest dm-org-agenda-persist-describe-archive/has-no-no-op-case ()
  ;; Every other describer can compare two states and find them equal.  An
  ;; archive that reached its describer moved a subtree out of the plan.
  (dm-org-agenda-persist-tests--in-repo
    (let ((snapshot (dm-org-agenda-persist-tests--snapshot)))
      (should (dm-org-agenda-persist-describe-archive snapshot snapshot)))))

;;; ————————————————————————————
;;; Building an event
;;; ————————————————————————————

(defmacro dm-org-agenda-persist-tests--in-repo (&rest body)
  "Run BODY with a fixed repository root, so paths are stable and no git runs."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'dm-org-persist-repository) (lambda () "/repo/")))
     ,@body))

(ert-deftest dm-org-agenda-persist-event/carries-subject-metadata-and-files ()
  (dm-org-agenda-persist-tests--in-repo
    (let ((event (dm-org-agenda-persist-event
                  'todo
                  (dm-org-agenda-persist-tests--snapshot :todo "NEXT")
                  (dm-org-agenda-persist-tests--snapshot :todo "DONE" :done t))))
      (should (equal "Mark \"Review authentication design\" DONE" (plist-get event :subject)))
      (should (equal "todo" (alist-get 'type (plist-get event :data))))
      (should (equal "org/tasks.org" (alist-get 'file (plist-get event :data))))
      (should (equal "DONE" (alist-get 'new (plist-get event :data))))
      (should (equal '("/repo/org/tasks.org") (plist-get event :files)))
      ;; The outline path is a vector so it serializes as a JSON array.
      (should (equal ["Current Tasks"] (alist-get 'olp (plist-get event :data)))))))

(ert-deftest dm-org-agenda-persist-event/includes-an-id-only-when-one-exists ()
  (dm-org-agenda-persist-tests--in-repo
    (let ((without (dm-org-agenda-persist-event
                    'todo
                    (dm-org-agenda-persist-tests--snapshot :todo "NEXT")
                    (dm-org-agenda-persist-tests--snapshot :todo "DONE" :done t)))
          (with (dm-org-agenda-persist-event
                 'todo
                 (dm-org-agenda-persist-tests--snapshot :todo "NEXT")
                 (dm-org-agenda-persist-tests--snapshot
                  :todo "DONE" :done t :id "73adbb4c-0000-0000-0000-000000000000"))))
      (should-not (assq 'id (plist-get without :data)))
      (should (equal "73adbb4c-0000-0000-0000-000000000000"
                     (alist-get 'id (plist-get with :data)))))))

(ert-deftest dm-org-agenda-persist-event/is-nil-for-a-no-op ()
  (dm-org-agenda-persist-tests--in-repo
    (let ((snapshot (dm-org-agenda-persist-tests--snapshot)))
      (should-not (dm-org-agenda-persist-event 'todo snapshot snapshot))
      (should-not (dm-org-agenda-persist-event 'scheduled snapshot snapshot))
      (should-not (dm-org-agenda-persist-event 'deadline snapshot snapshot))
      (should-not (dm-org-agenda-persist-event 'priority snapshot snapshot))
      (should-not (dm-org-agenda-persist-event 'refile snapshot snapshot)))))

(ert-deftest dm-org-agenda-persist-event/is-nil-without-both-snapshots ()
  (dm-org-agenda-persist-tests--in-repo
    (let ((snapshot (dm-org-agenda-persist-tests--snapshot)))
      (should-not (dm-org-agenda-persist-event 'todo nil snapshot))
      (should-not (dm-org-agenda-persist-event 'todo snapshot nil)))))

(ert-deftest dm-org-agenda-persist-event/names-both-files-of-a-refile ()
  (dm-org-agenda-persist-tests--in-repo
    (let ((event (dm-org-agenda-persist-event
                  'refile
                  (dm-org-agenda-persist-tests--snapshot
                   :olp nil :file "/repo/org/inbox.org")
                  (dm-org-agenda-persist-tests--snapshot
                   :olp '("Mallard") :file "/repo/org/projects.org"))))
      ;; The destination has to be staged too, or a refile out of the agenda
      ;; set leaves the destination file dirty and orphaned.
      (should (equal '("/repo/org/inbox.org" "/repo/org/projects.org")
                     (plist-get event :files)))
      (should (equal "org/inbox.org" (alist-get 'from-file (plist-get event :data)))))))

(ert-deftest dm-org-agenda-persist-event/names-the-archive-file-it-created ()
  (dm-org-agenda-persist-tests--in-repo
    (let ((event (dm-org-agenda-persist-event
                  'archive
                  (dm-org-agenda-persist-tests--snapshot :heading "Water plants")
                  (dm-org-agenda-persist-tests--snapshot
                   :heading "Water plants" :olp nil
                   :file "/repo/org/archive/tasks.org_archive"))))
      ;; `org-archive-location' points outside `org-agenda-files', and the
      ;; first archive out of a file creates the destination, so nothing but
      ;; `:files' can get it staged.
      (should (equal '("/repo/org/tasks.org" "/repo/org/archive/tasks.org_archive")
                     (plist-get event :files)))
      (should (equal "archive" (alist-get 'type (plist-get event :data)))))))

;;; ————————————————————————————
;;; End to end, through the agenda
;;;
;;; `dm-org-persist' is stubbed, so these assert on the events the advice
;;; produces rather than on anything Git does.
;;; ————————————————————————————

(require 'org)
(require 'org-agenda)
(require 'org-archive)

(defconst dm-org-agenda-persist-tests--file-contents
  "#+TITLE: Tasks
#+TODO: TODO(t) WIP(w) | DONE(d) CANCELED(c)

* Current Tasks
** TODO Water plants
SCHEDULED: <2026-08-31 Mon>
** WIP Review authentication design
SCHEDULED: <2026-08-31 Mon>
** TODO Research API pricing
SCHEDULED: <2026-08-31 Mon>
** TODO File the quarterly report
DEADLINE: <2026-08-31 Mon>
** Dentist
<2026-08-31 Mon 14:00>
* Mallard
"
  "Fixture Org file, with every entry scheduled on one pinned day.")

(defvar dm-org-agenda-persist-tests--captured nil
  "Events the stubbed `dm-org-persist' received.")

(defmacro dm-org-agenda-persist-tests--with-agenda (&rest body)
  "Build an agenda over a temporary Org file and run BODY inside it.

`file' is bound to the Org file.  Events are collected in
`dm-org-agenda-persist-tests--captured' instead of reaching Git."
  (declare (indent 0) (debug t))
  `(let* ((directory (file-name-as-directory
                      (file-truename (make-temp-file "dm-org-agenda-persist-" t))))
          (file (expand-file-name "tasks.org" directory))
          (org-agenda-files (list file))
          (org-agenda-span 1)
          (org-agenda-start-day "2026-08-31")
          (org-agenda-sticky nil)
          (org-log-done nil)
          (org-log-refile nil)
          ;; The fixture defines fast-access keys, as the real file does.
          ;; Left on, `org-todo' would open its fast-selection reader, which
          ;; blocks in `read-char-exclusive' with quitting inhibited.  Off, it
          ;; cycles to the next keyword, which is what these tests assert on.
          (org-use-fast-todo-selection nil)
          (org-priority-default ?D)
          (dm-org-persist-enabled t)
          (dm-org-agenda-persist-tests--captured nil))
     (unwind-protect
         (progn
           (write-region dm-org-agenda-persist-tests--file-contents nil file nil 'silent)
           (dm-org-agenda-persist-install)
           (cl-letf (((symbol-function 'dm-org-persist)
                      (lambda (event) (push event dm-org-agenda-persist-tests--captured))))
             (save-window-excursion
               (org-agenda-list)
               (with-current-buffer org-agenda-buffer-name
                 ,@body))))
       (dm-org-agenda-persist-uninstall)
       (when-let* ((buffer (get-file-buffer file)))
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (when (get-buffer org-agenda-buffer-name)
         (kill-buffer org-agenda-buffer-name))
       (delete-directory directory t))))

(defun dm-org-agenda-persist-tests--goto (heading)
  "Move to the agenda line for HEADING."
  (goto-char (point-min))
  (should (search-forward heading nil t))
  (forward-line 0))

(defun dm-org-agenda-persist-tests--events ()
  "Return the captured events, oldest first."
  (reverse dm-org-agenda-persist-tests--captured))

(defun dm-org-agenda-persist-tests--subjects ()
  "Return the subject line of every captured event, oldest first."
  (mapcar (lambda (event) (plist-get event :subject))
          (dm-org-agenda-persist-tests--events)))

(ert-deftest dm-org-agenda-persist-e2e/snapshots-carry-no-text-properties ()
  ;; `org-get-heading' and `org-get-outline-path' return propertized strings.
  ;; Left alone, `format "%S"' renders one as #("Water plants" 0 12 (...)) and
  ;; that read syntax lands verbatim in the commit subject.
  (dm-org-agenda-persist-tests--with-agenda
    (dm-org-agenda-persist-tests--goto "Water plants")
    (let ((snapshot (dm-org-agenda-persist--snapshot (dm-org-agenda-persist--marker))))
      (should (equal-including-properties "Water plants" (plist-get snapshot :heading)))
      (should (equal-including-properties '("Current Tasks") (plist-get snapshot :olp))))
    (org-agenda-priority ?A)
    (let ((subject (plist-get (car (dm-org-agenda-persist-tests--events)) :subject)))
      (should-not (string-match-p "#(" subject)))))

(ert-deftest dm-org-agenda-persist-e2e/records-a-todo-transition ()
  (dm-org-agenda-persist-tests--with-agenda
    (dm-org-agenda-persist-tests--goto "Review authentication design")
    (org-agenda-todo)
    (should (equal '("Mark \"Review authentication design\" DONE")
                   (dm-org-agenda-persist-tests--subjects)))
    (let ((data (plist-get (car (dm-org-agenda-persist-tests--events)) :data)))
      (should (equal "todo" (alist-get 'type data)))
      (should (equal "WIP" (alist-get 'old data)))
      (should (equal "DONE" (alist-get 'new data)))
      (should (equal ["Current Tasks"] (alist-get 'olp data))))))

(ert-deftest dm-org-agenda-persist-e2e/records-a-reschedule ()
  (dm-org-agenda-persist-tests--with-agenda
    (dm-org-agenda-persist-tests--goto "Water plants")
    (org-agenda-schedule nil "2026-09-02")
    (should (equal '("Reschedule \"Water plants\" 2026-08-31 → 2026-09-02")
                   (dm-org-agenda-persist-tests--subjects)))))

(ert-deftest dm-org-agenda-persist-e2e/records-a-deadline ()
  (dm-org-agenda-persist-tests--with-agenda
    (dm-org-agenda-persist-tests--goto "Water plants")
    (org-agenda-deadline nil "2026-09-05")
    (should (equal '("Deadline \"Water plants\" 2026-09-05")
                   (dm-org-agenda-persist-tests--subjects)))))

(ert-deftest dm-org-agenda-persist-e2e/records-a-priority-change ()
  (dm-org-agenda-persist-tests--with-agenda
    (dm-org-agenda-persist-tests--goto "Water plants")
    (org-agenda-priority ?A)
    (should (equal '("Priority \"Water plants\" D → A")
                   (dm-org-agenda-persist-tests--subjects)))))

(ert-deftest dm-org-agenda-persist-e2e/records-a-refile ()
  (dm-org-agenda-persist-tests--with-agenda
    (let ((target (with-current-buffer (find-file-noselect file)
                    (goto-char (point-min))
                    (search-forward "* Mallard")
                    (list "Mallard" file nil (line-beginning-position)))))
      (dm-org-agenda-persist-tests--goto "Research API pricing")
      (org-agenda-refile nil target))
    (should (equal '("Refile \"Research API pricing\" Current Tasks → Mallard")
                   (dm-org-agenda-persist-tests--subjects)))))

(ert-deftest dm-org-agenda-persist-e2e/records-an-archive-to-a-new-file ()
  (dm-org-agenda-persist-tests--with-agenda
    (let* ((org-archive-location "archive/%s_archive::")
           ;; What `dm-org' sets.  Left at its default, Org declines to save
           ;; an archive file it filled from the agenda, and the file this
           ;; test is about would exist only in a buffer.
           (org-archive-subtree-save-file-p t)
           (archive (expand-file-name "archive/tasks.org_archive" directory)))
      (make-directory (file-name-directory archive) t)
      (unwind-protect
          ;; The temporary directory stands in for the repository root, so the
          ;; subject names the archive file the way `git log --stat' would.
          (cl-letf (((symbol-function 'dm-org-persist-repository)
                     (lambda () directory)))
            (dm-org-agenda-persist-tests--goto "Water plants")
            (org-agenda-archive)
            (let ((event (car (dm-org-agenda-persist-tests--events))))
              (should (equal "archive" (alist-get 'type (plist-get event :data))))
              (should (equal "Archive \"Water plants\" Current Tasks → archive/tasks.org_archive"
                             (plist-get event :subject)))
              ;; The destination is outside `org-agenda-files' and did not
              ;; exist a moment ago, so nothing but `:files' can stage it.
              (should (member (file-truename archive)
                              (mapcar #'file-truename (plist-get event :files))))
              (should (file-regular-p archive))))
        (when-let* ((buffer (get-file-buffer archive)))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest dm-org-agenda-persist-e2e/records-an-archive-to-the-sibling ()
  ;; `org-archive-to-archive-sibling' runs no hook, so this is the one archive
  ;; whose destination the advice supplies rather than observes.
  (dm-org-agenda-persist-tests--with-agenda
    (dm-org-agenda-persist-tests--goto "Water plants")
    (org-agenda-archive-to-archive-sibling)
    (should (equal '("Archive \"Water plants\" Current Tasks → Archive")
                   (dm-org-agenda-persist-tests--subjects)))
    ;; Nothing left the file, so nothing beyond it needs staging.
    (should (equal (list file)
                   (plist-get (car (dm-org-agenda-persist-tests--events)) :files)))))

(ert-deftest dm-org-agenda-persist-e2e/records-a-day-shift-as-a-reschedule ()
  ;; `L' in the agenda under evil-org-agenda.  This is the command that
  ;; actually drags an item across days; `org-agenda-schedule' is the one that
  ;; prompts for a date.
  (dm-org-agenda-persist-tests--with-agenda
    (dm-org-agenda-persist-tests--goto "Water plants")
    (org-agenda-do-date-later 1)
    (should (equal '("Reschedule \"Water plants\" 2026-08-31 → 2026-09-01")
                   (dm-org-agenda-persist-tests--subjects)))
    (should (equal "scheduled"
                   (alist-get 'type (plist-get (car (dm-org-agenda-persist-tests--events))
                                               :data))))))

(ert-deftest dm-org-agenda-persist-e2e/records-a-backward-day-shift ()
  (dm-org-agenda-persist-tests--with-agenda
    (dm-org-agenda-persist-tests--goto "Water plants")
    (org-agenda-do-date-earlier 1)
    (should (equal '("Reschedule \"Water plants\" 2026-08-31 → 2026-08-30")
                   (dm-org-agenda-persist-tests--subjects)))))

(ert-deftest dm-org-agenda-persist-e2e/labels-a-shifted-deadline-as-a-deadline ()
  ;; The day-shifting commands move whatever timestamp is under point, so the
  ;; event type has to follow the entry rather than the command.
  (dm-org-agenda-persist-tests--with-agenda
    (dm-org-agenda-persist-tests--goto "File the quarterly report")
    (org-agenda-do-date-later 1)
    (should (equal '("Move deadline \"File the quarterly report\" 2026-08-31 → 2026-09-01")
                   (dm-org-agenda-persist-tests--subjects)))
    (should (equal "deadline"
                   (alist-get 'type (plist-get (car (dm-org-agenda-persist-tests--events))
                                               :data))))))

(ert-deftest dm-org-agenda-persist-e2e/labels-a-shifted-appointment-as-a-timestamp ()
  (dm-org-agenda-persist-tests--with-agenda
    (dm-org-agenda-persist-tests--goto "Dentist")
    (org-agenda-do-date-later 1)
    (should (equal '("Move \"Dentist\" 2026-08-31 14:00 → 2026-09-01 14:00")
                   (dm-org-agenda-persist-tests--subjects)))
    (should (equal "timestamp"
                   (alist-get 'type (plist-get (car (dm-org-agenda-persist-tests--events))
                                               :data))))))

(ert-deftest dm-org-agenda-persist-e2e/records-nothing-for-a-no-op ()
  (dm-org-agenda-persist-tests--with-agenda
    (dm-org-agenda-persist-tests--goto "Water plants")
    ;; Rescheduling to the date it already has.
    (org-agenda-schedule nil "2026-08-31")
    (should-not (dm-org-agenda-persist-tests--events))))

(ert-deftest dm-org-agenda-persist-e2e/records-nothing-for-a-cancelled-command ()
  (dm-org-agenda-persist-tests--with-agenda
    (dm-org-agenda-persist-tests--goto "Water plants")
    ;; Abandoning the date prompt is a `quit', which never reaches the
    ;; after-snapshot.
    (let ((quit nil))
      (cl-letf (((symbol-function 'org-schedule) (lambda (&rest _) (signal 'quit nil))))
        (condition-case nil
            (org-agenda-schedule nil)
          (quit (setq quit t))))
      ;; The advice must let the quit through rather than swallowing it...
      (should quit))
    ;; ...and must not have recorded the command that never happened.
    (should-not (dm-org-agenda-persist-tests--events))))

(ert-deftest dm-org-agenda-persist-e2e/records-nothing-when-disabled ()
  (dm-org-agenda-persist-tests--with-agenda
    (let ((dm-org-persist-enabled nil))
      (dm-org-agenda-persist-tests--goto "Water plants")
      (org-agenda-schedule nil "2026-09-02"))
    (should-not (dm-org-agenda-persist-tests--events))))

(ert-deftest dm-org-agenda-persist-e2e/records-nothing-for-a-refresh ()
  ;; The whole point: redrawing the agenda is a presentation event.
  (dm-org-agenda-persist-tests--with-agenda
    (org-agenda-redo)
    (should-not (dm-org-agenda-persist-tests--events))))

(ert-deftest dm-org-agenda-persist-e2e/records-one-event-per-entry-in-a-burst ()
  (dm-org-agenda-persist-tests--with-agenda
    (dm-org-agenda-persist-tests--goto "Water plants")
    (org-agenda-schedule nil "2026-09-02")
    (dm-org-agenda-persist-tests--goto "Review authentication design")
    (org-agenda-todo)
    (should (equal '("Reschedule \"Water plants\" 2026-08-31 → 2026-09-02"
                     "Mark \"Review authentication design\" DONE")
                   (dm-org-agenda-persist-tests--subjects)))))

(ert-deftest dm-org-agenda-persist-e2e/reads-state-from-the-heading-not-the-line ()
  ;; The agenda renders whatever `org-agenda-prefix-format' says; the event
  ;; must reflect the file.
  (dm-org-agenda-persist-tests--with-agenda
    (let ((org-agenda-prefix-format '((agenda . "  "))))
      (org-agenda-redo)
      (dm-org-agenda-persist-tests--goto "Water plants")
      (org-agenda-priority ?B)
      (let ((data (plist-get (car (dm-org-agenda-persist-tests--events)) :data)))
        (should (equal "Water plants" (alist-get 'heading data)))
        (should (equal "B" (alist-get 'new data)))))))

(provide 'dm-org-agenda-persist-tests)
;;; dm-org-agenda-persist-tests.el ends here
