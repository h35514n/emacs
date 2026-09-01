;;; dm-org-persist-tests.el --- Tests for dm-org-persist  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root:
;;
;;   bin/test dm-org-persist
;;
;; or, without the runner:
;;
;;   emacs -Q --batch \
;;     -L modules -L test \
;;     -l dm-org-persist-tests.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; No Org load path is needed: the message-building tests are pure, and the
;; Git tests stub the two Org functions the module calls
;; (`org-agenda-files' and `org-save-all-org-buffers').
;;
;; Every test that touches Git works in a repository made by `make-temp-file'
;; and removed afterwards.  `GIT_CONFIG_GLOBAL' and `GIT_CONFIG_SYSTEM' are
;; pointed at /dev/null throughout, so the developer's own configuration --
;; `commit.gpgsign' above all -- cannot change what these tests observe.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'subr-x)
(require 'dm-org-persist)

;; Declared special so the discovery test can bind it dynamically.
(defvar org-directory)

;;; ————————————————————————————
;;; Commit messages
;;; ————————————————————————————

(defconst dm-org-persist-tests--todo-event
  '(:subject "Mark \"Review authentication design\" DONE"
    :data ((type . "todo")
           (file . "org/tasks.org")
           (olp . ["Current Tasks"])
           (heading . "Review authentication design")
           (old . "NEXT")
           (new . "DONE")))
  "A single fully-formed event, as the semantic layer produces them.")

(defconst dm-org-persist-tests--schedule-event
  '(:subject "Reschedule \"Submit application\" 2026-08-31 → 2026-09-02"
    :data ((type . "scheduled")
           (file . "org/tasks.org")
           (heading . "Submit application")
           (old . "2026-08-31")
           (new . "2026-09-02"))))

(defconst dm-org-persist-tests--refile-event
  '(:subject "Refile \"Research API pricing\" Inbox → Mallard"
    :data ((type . "refile")
           (file . "org/projects.org")
           (heading . "Research API pricing")
           (old . "Inbox")
           (new . "Mallard"))))

(ert-deftest dm-org-persist-message/single-event-uses-its-own-subject ()
  (let* ((dm-org-persist-commit-metadata t)
         (message (dm-org-persist-message (list dm-org-persist-tests--todo-event)))
         (lines (split-string message "\n")))
    (should (equal "Mark \"Review authentication design\" DONE" (nth 0 lines)))
    (should (equal "" (nth 1 lines)))
    (should (string-prefix-p "Org-Event: {" (nth 2 lines)))
    ;; Exactly one trailer, and nothing after it.
    (should (= 3 (length lines)))))

(ert-deftest dm-org-persist-message/coalesced-events-are-summarized-and-listed ()
  (let* ((dm-org-persist-commit-metadata t)
         (message (dm-org-persist-message
                   (list dm-org-persist-tests--todo-event
                         dm-org-persist-tests--schedule-event
                         dm-org-persist-tests--refile-event)))
         (lines (split-string message "\n")))
    (should (equal "3 agenda changes" (nth 0 lines)))
    (should (equal "- Mark \"Review authentication design\" DONE" (nth 2 lines)))
    (should (equal "- Reschedule \"Submit application\" 2026-08-31 → 2026-09-02" (nth 3 lines)))
    (should (equal "- Refile \"Research API pricing\" Inbox → Mallard" (nth 4 lines)))
    ;; One trailer per event, all in the final paragraph so Git parses them.
    (should (= 3 (cl-count-if (lambda (l) (string-prefix-p "Org-Event: " l)) lines)))))

(ert-deftest dm-org-persist-message/trailers-round-trip-through-json ()
  (let* ((dm-org-persist-commit-metadata t)
         (message (dm-org-persist-message (list dm-org-persist-tests--todo-event)))
         (payload (cadr (split-string message "Org-Event: ")))
         (parsed (json-parse-string payload :object-type 'alist)))
    (should (equal "todo" (alist-get 'type parsed)))
    (should (equal "DONE" (alist-get 'new parsed)))
    (should (equal "NEXT" (alist-get 'old parsed)))
    (should (equal ["Current Tasks"] (alist-get 'olp parsed)))))

(ert-deftest dm-org-persist-message/nil-fields-serialize-as-null ()
  ;; A newly scheduled entry has no old date.  The field stays in the record
  ;; as null rather than vanishing, so the shape of an event is stable.
  (let* ((dm-org-persist-commit-metadata t)
         (event '(:subject "Schedule \"X\" for 2026-09-01"
                  :data ((type . "scheduled") (old . nil) (new . "2026-09-01"))))
         (payload (cadr (split-string (dm-org-persist-message (list event)) "Org-Event: ")))
         (parsed (json-parse-string payload :object-type 'alist)))
    (should (eq :null (alist-get 'old parsed)))
    (should (equal "2026-09-01" (alist-get 'new parsed)))))

(ert-deftest dm-org-persist-message/trailers-are-one-line-each ()
  ;; A heading containing a newline or a quote must not break the trailer
  ;; block, or the whole message stops parsing as trailers.
  (let* ((dm-org-persist-commit-metadata t)
         (event '(:subject "Mark \"Odd\" DONE"
                  :data ((type . "todo") (heading . "Odd \"quoted\"\nheading"))))
         (message (dm-org-persist-message (list event)))
         (trailers (cl-remove-if-not (lambda (l) (string-prefix-p "Org-Event: " l))
                                     (split-string message "\n"))))
    (should (= 1 (length trailers)))
    (should (string-match-p "quoted" (car trailers)))))

(ert-deftest dm-org-persist-message/metadata-can-be-turned-off ()
  (let ((dm-org-persist-commit-metadata nil))
    (should (equal "Mark \"Review authentication design\" DONE"
                   (dm-org-persist-message (list dm-org-persist-tests--todo-event))))
    (should-not (string-match-p
                 "Org-Event:"
                 (dm-org-persist-message (list dm-org-persist-tests--todo-event
                                               dm-org-persist-tests--schedule-event))))))

(ert-deftest dm-org-persist-message/event-without-a-subject-still-commits ()
  (let ((dm-org-persist-commit-metadata nil))
    (should (equal "Update Org agenda" (dm-org-persist-message '((:data ((type . "todo")))))))))

;;; ————————————————————————————
;;; A throwaway Git repository
;;;
;;; Layout mirrors the real one: the repository root is an ancestor of the
;;; Org directory and holds unrelated files of its own.
;;; ————————————————————————————

(defun dm-org-persist-tests--run (repo &rest args)
  "Run git with ARGS in REPO and return its trimmed output."
  (string-trim (cdr (apply #'dm-org-persist--git repo args))))

(defun dm-org-persist-tests--unstaged (repo)
  "Return REPO's files with unstaged modifications, newline-separated."
  (dm-org-persist-tests--run repo "diff" "--name-only"))

(defun dm-org-persist-tests--staged (repo)
  "Return REPO's files with staged modifications, newline-separated."
  (dm-org-persist-tests--run repo "diff" "--cached" "--name-only"))

(defun dm-org-persist-tests--commits (repo)
  "Return the number of commits on REPO's current branch."
  (string-to-number (dm-org-persist-tests--run repo "rev-list" "--count" "HEAD")))

(defun dm-org-persist-tests--write (repo relative contents)
  "Write CONTENTS to RELATIVE inside REPO."
  (let ((path (expand-file-name relative repo)))
    (make-directory (file-name-directory path) t)
    (write-region contents nil path nil 'silent)
    path))

(defun dm-org-persist-tests--init (repo)
  "Turn REPO into a Git repository with one managed and one unmanaged file."
  (dm-org-persist--git repo "init" "--quiet" "--initial-branch=main")
  (dm-org-persist-tests--write repo "org/tasks.org" "* TODO Water plants\n")
  (dm-org-persist-tests--write repo "unrelated.txt" "not an agenda file\n")
  (dm-org-persist--git repo "add" "--all")
  (dm-org-persist--git repo "commit" "--quiet" "-m" "Initial commit"))

(defmacro dm-org-persist-tests--with-repo (&rest body)
  "Run BODY with `repo' bound to a fresh temporary Git repository.

Persistence is configured to use it, Org's two entry points are stubbed,
and the developer's global and system Git configuration is neutralized so
signing settings cannot leak into the suite."
  (declare (indent 0) (debug t))
  `(let* ((repo (file-name-as-directory
                 (file-truename (make-temp-file "dm-org-persist-test-" t))))
          (dm-org-git-repository repo)
          (dm-org-persist--repository nil)
          (dm-org-persist--events nil)
          (dm-org-persist--timer nil)
          (dm-org-persist--pull-process nil)
          (dm-org-persist--pull-head nil)
          (dm-org-persist-enabled t)
          (dm-org-persist-commit-metadata t)
          (dm-org-persist-sign-fallback t)
          (dm-org-git-auto-push nil)
          (dm-org-git-remote nil)
          (process-environment
           (append '("GIT_CONFIG_GLOBAL=/dev/null"
                     "GIT_CONFIG_SYSTEM=/dev/null"
                     "GIT_AUTHOR_NAME=ERT" "GIT_AUTHOR_EMAIL=ert@example.invalid"
                     "GIT_COMMITTER_NAME=ERT" "GIT_COMMITTER_EMAIL=ert@example.invalid")
                   process-environment)))
     (unwind-protect
         (progn
           (dm-org-persist-tests--init repo)
           (cl-letf (((symbol-function 'org-save-all-org-buffers) #'ignore)
                     ((symbol-function 'org-agenda-files)
                      (lambda (&rest _) (list (expand-file-name "org/tasks.org" repo)))))
             ,@body))
       (dm-org-persist--cancel-timer)
       (delete-directory repo t))))

;;; ————————————————————————————
;;; Repository discovery
;;; ————————————————————————————

(ert-deftest dm-org-persist-repository/discovers-the-root-above-org-directory ()
  (dm-org-persist-tests--with-repo
    ;; The real layout: org-directory is a subdirectory of the repository.
    (let ((dm-org-git-repository nil)
          (dm-org-persist--repository nil)
          (org-directory (expand-file-name "org" repo)))
      (should (equal repo (dm-org-persist-repository))))))

(ert-deftest dm-org-persist-repository/is-nil-outside-a-repository ()
  (let* ((dir (file-name-as-directory
               (file-truename (make-temp-file "dm-org-persist-bare-" t))))
         (dm-org-git-repository nil)
         (dm-org-persist--repository nil)
         (org-directory dir)
         (process-environment (append '("GIT_CONFIG_GLOBAL=/dev/null"
                                        "GIT_CONFIG_SYSTEM=/dev/null"
                                        "GIT_CEILING_DIRECTORIES=/")
                                      process-environment)))
    (unwind-protect
        (should-not (dm-org-persist-repository))
      (delete-directory dir t))))

(ert-deftest dm-org-persist-busy-p/detects-an-interrupted-operation ()
  (dm-org-persist-tests--with-repo
    (should-not (dm-org-persist--busy-p repo))
    (write-region "deadbeef\n" nil (expand-file-name ".git/MERGE_HEAD" repo) nil 'silent)
    (should (dm-org-persist--busy-p repo))))

;;; ————————————————————————————
;;; Which files get staged
;;; ————————————————————————————

(ert-deftest dm-org-persist-managed-files/is-the-agenda-set-plus-event-files ()
  (dm-org-persist-tests--with-repo
    (dm-org-persist-tests--write repo "org/notes.org" "* Not in the agenda set\n")
    (should (equal '("org/tasks.org")
                   (dm-org-persist--managed-files repo nil)))
    ;; A refile destination outside the agenda set still has to be committed,
    ;; or the moved subtree is left dirty and orphaned.
    (should (equal '("org/tasks.org" "org/notes.org")
                   (dm-org-persist--managed-files
                    repo (list (list :files (list (expand-file-name "org/notes.org" repo)))))))))

(ert-deftest dm-org-persist-managed-files/excludes-files-outside-the-repository ()
  (dm-org-persist-tests--with-repo
    (let ((outside (make-temp-file "dm-org-persist-outside-")))
      (unwind-protect
          (should (equal '("org/tasks.org")
                         (dm-org-persist--managed-files repo (list (list :files (list outside))))))
        (delete-file outside)))))

(ert-deftest dm-org-persist-managed-files/skips-files-that-do-not-exist ()
  (dm-org-persist-tests--with-repo
    (should (equal '("org/tasks.org")
                   (dm-org-persist--managed-files
                    repo (list (list :files (list (expand-file-name "org/gone.org" repo)))))))))

;;; ————————————————————————————
;;; Committing
;;; ————————————————————————————

(ert-deftest dm-org-persist-commit/commits-only-the-managed-files ()
  (dm-org-persist-tests--with-repo
    (dm-org-persist-tests--write repo "org/tasks.org" "* DONE Water plants\n")
    (dm-org-persist-tests--write repo "unrelated.txt" "edited by something else\n")
    (should (eq 'committed (dm-org-persist--commit repo '("org/tasks.org") "Mark it done")))
    (should (= 2 (dm-org-persist-tests--commits repo)))
    ;; The commit names the agenda file and nothing else...
    (should (equal "org/tasks.org"
                   (dm-org-persist-tests--run repo "show" "--name-only" "--format=" "HEAD")))
    ;; ...and the unrelated edit is still sitting in the working tree.
    (should (equal "unrelated.txt" (dm-org-persist-tests--unstaged repo)))
    (should (equal "" (dm-org-persist-tests--staged repo)))))

(ert-deftest dm-org-persist-commit/leaves-hand-staged-work-alone ()
  ;; Someone has staged an unrelated file by hand.  An automated commit must
  ;; not sweep it into history behind their back.
  (dm-org-persist-tests--with-repo
    (dm-org-persist-tests--write repo "unrelated.txt" "staged by hand\n")
    (dm-org-persist--git repo "add" "--" "unrelated.txt")
    (dm-org-persist-tests--write repo "org/tasks.org" "* DONE Water plants\n")
    (should (eq 'committed (dm-org-persist--commit repo '("org/tasks.org") "Mark it done")))
    (should (equal "org/tasks.org"
                   (dm-org-persist-tests--run repo "show" "--name-only" "--format=" "HEAD")))
    (should (equal "unrelated.txt" (dm-org-persist-tests--staged repo)))))

(ert-deftest dm-org-persist-commit/makes-no-commit-without-a-diff ()
  (dm-org-persist-tests--with-repo
    (let ((before (dm-org-persist-tests--commits repo)))
      (should (eq 'no-op (dm-org-persist--commit repo '("org/tasks.org") "Nothing happened")))
      (should (= before (dm-org-persist-tests--commits repo))))))

(ert-deftest dm-org-persist-commit/records-the-whole-message ()
  (dm-org-persist-tests--with-repo
    (dm-org-persist-tests--write repo "org/tasks.org" "* DONE Water plants\n")
    (let ((message (dm-org-persist-message (list dm-org-persist-tests--todo-event))))
      (should (eq 'committed (dm-org-persist--commit repo '("org/tasks.org") message)))
      (should (equal message
                     (dm-org-persist-tests--run repo "log" "-1" "--format=%B")))
      ;; Git itself agrees the metadata is a trailer.
      (should (string-prefix-p
               "{"
               (dm-org-persist-tests--run
                repo "log" "-1" "--format=%(trailers:key=Org-Event,valueonly)"))))))

(ert-deftest dm-org-persist-commit/falls-back-to-unsigned-when-signing-fails ()
  ;; `gpg.program' is pointed at a program that always fails, which is what a
  ;; missing pinentry or a cold agent looks like from git's side.
  (dm-org-persist-tests--with-repo
    (dm-org-persist--git repo "config" "commit.gpgsign" "true")
    (dm-org-persist--git repo "config" "gpg.program" "/usr/bin/false")
    (dm-org-persist-tests--write repo "org/tasks.org" "* DONE Water plants\n")
    (let ((warnings nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (type message &rest _) (push (cons type message) warnings))))
        (should (eq 'committed (dm-org-persist--commit repo '("org/tasks.org") "Mark it done"))))
      (should (= 2 (dm-org-persist-tests--commits repo)))
      ;; The mutation survived, and the degradation was reported rather than
      ;; passed off as a normal commit.
      (should (= 1 (length warnings)))
      (should (string-match-p "unsigned" (cdr (car warnings)))))))

(ert-deftest dm-org-persist-commit/reports-failure-without-committing ()
  (dm-org-persist-tests--with-repo
    (dm-org-persist--git repo "config" "commit.gpgsign" "true")
    (dm-org-persist--git repo "config" "gpg.program" "/usr/bin/false")
    (dm-org-persist-tests--write repo "org/tasks.org" "* DONE Water plants\n")
    (let ((dm-org-persist-sign-fallback nil)
          (warnings nil)
          (before (dm-org-persist-tests--commits repo)))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (type message &rest _) (push (cons type message) warnings))))
        (should (eq 'retry (dm-org-persist--commit repo '("org/tasks.org") "Mark it done"))))
      (should (= before (dm-org-persist-tests--commits repo)))
      (should (= 1 (length warnings)))
      (should (string-match-p "git commit failed" (cdr (car warnings)))))))

;;; ————————————————————————————
;;; The queue
;;; ————————————————————————————

(ert-deftest dm-org-persist/queues-an-event-and-flushes-it ()
  (dm-org-persist-tests--with-repo
    (dm-org-persist-tests--write repo "org/tasks.org" "* DONE Water plants\n")
    (dm-org-persist dm-org-persist-tests--todo-event)
    (should (= 1 (length dm-org-persist--events)))
    (dm-org-persist-flush)
    (should-not dm-org-persist--events)
    (should (= 2 (dm-org-persist-tests--commits repo)))
    (should (equal "Mark \"Review authentication design\" DONE"
                   (dm-org-persist-tests--run repo "log" "-1" "--format=%s")))))

(ert-deftest dm-org-persist/coalesces-a-burst-into-one-commit ()
  (dm-org-persist-tests--with-repo
    (dm-org-persist-tests--write repo "org/tasks.org" "* DONE Water plants\n")
    (dm-org-persist dm-org-persist-tests--todo-event)
    (dm-org-persist dm-org-persist-tests--schedule-event)
    (dm-org-persist dm-org-persist-tests--refile-event)
    (dm-org-persist-flush)
    (should (= 2 (dm-org-persist-tests--commits repo)))
    (should (equal "3 agenda changes"
                   (dm-org-persist-tests--run repo "log" "-1" "--format=%s")))
    ;; Events keep the order they happened in, not the order they were pushed.
    (should (equal '("todo" "scheduled" "refile")
                   (mapcar (lambda (line)
                             (alist-get 'type (json-parse-string line :object-type 'alist)))
                           (split-string
                            (dm-org-persist-tests--run
                             repo "log" "-1" "--format=%(trailers:key=Org-Event,valueonly)")
                            "\n" t))))))

(ert-deftest dm-org-persist-flush/does-nothing-when-disabled ()
  (dm-org-persist-tests--with-repo
    (let ((dm-org-persist-enabled nil))
      (dm-org-persist dm-org-persist-tests--todo-event)
      (should-not dm-org-persist--events))))

(ert-deftest dm-org-persist-flush/keeps-events-when-saving-fails ()
  (dm-org-persist-tests--with-repo
    (dm-org-persist-tests--write repo "org/tasks.org" "* DONE Water plants\n")
    (let ((before (dm-org-persist-tests--commits repo))
          (warnings nil))
      (cl-letf (((symbol-function 'org-save-all-org-buffers)
                 (lambda () (error "Buffer is read-only")))
                ((symbol-function 'display-warning)
                 (lambda (type message &rest _) (push (cons type message) warnings))))
        (dm-org-persist dm-org-persist-tests--todo-event)
        (dm-org-persist-flush))
      ;; Nothing committed, and the event is still queued for a later attempt.
      (should (= before (dm-org-persist-tests--commits repo)))
      (should (= 1 (length dm-org-persist--events)))
      (should (string-match-p "saving Org buffers failed" (cdr (car warnings)))))))

(ert-deftest dm-org-persist-flush/keeps-events-while-a-merge-is-in-progress ()
  (dm-org-persist-tests--with-repo
    (dm-org-persist-tests--write repo "org/tasks.org" "* DONE Water plants\n")
    (write-region "deadbeef\n" nil (expand-file-name ".git/MERGE_HEAD" repo) nil 'silent)
    (let ((before (dm-org-persist-tests--commits repo)))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (dm-org-persist dm-org-persist-tests--todo-event)
        (dm-org-persist-flush))
      (should (= before (dm-org-persist-tests--commits repo)))
      (should (= 1 (length dm-org-persist--events))))))

(ert-deftest dm-org-persist-flush/drops-events-that-changed-nothing ()
  (dm-org-persist-tests--with-repo
    (let ((before (dm-org-persist-tests--commits repo)))
      (dm-org-persist dm-org-persist-tests--todo-event)
      (dm-org-persist-flush)
      (should (= before (dm-org-persist-tests--commits repo)))
      (should-not dm-org-persist--events))))

;;; ————————————————————————————
;;; Pushing
;;; ————————————————————————————

(defun dm-org-persist-tests--await-push (&optional seconds)
  "Block until the push process finishes, or SECONDS elapse."
  (let ((deadline (+ (float-time) (or seconds 20))))
    (while (and (process-live-p dm-org-persist--push-process)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (while (and dm-org-persist--push-process (< (float-time) deadline))
      (accept-process-output nil 0.05))))

(ert-deftest dm-org-persist-push/failure-leaves-the-local-commit-intact ()
  (dm-org-persist-tests--with-repo
    (dm-org-persist-tests--write repo "org/tasks.org" "* DONE Water plants\n")
    (dm-org-persist--commit repo '("org/tasks.org") "Mark it done")
    (dm-org-persist--git repo "remote" "add" "origin"
                         (expand-file-name "definitely-not-here.git" repo))
    (let ((dm-org-git-remote "origin")
          (reported nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) reported))))
        (dm-org-persist-push)
        (dm-org-persist-tests--await-push))
      ;; The commit is still there; only replication was lost.
      (should (= 2 (dm-org-persist-tests--commits repo)))
      (should (cl-some (lambda (line) (string-match-p "push failed" line)) reported))
      (should (cl-some (lambda (line) (string-match-p "safe locally" line)) reported)))))

(ert-deftest dm-org-persist-push/succeeds-against-a-real-remote ()
  ;; The default configuration: no explicit remote, no extra arguments, and a
  ;; branch whose upstream is already set -- which is what a repository someone
  ;; has been pushing by hand looks like.
  (dm-org-persist-tests--with-repo
    (let ((remote (file-truename (make-temp-file "dm-org-persist-remote-" t))))
      (unwind-protect
          (progn
            (dm-org-persist--git remote "init" "--quiet" "--bare" "--initial-branch=main")
            (dm-org-persist--git repo "remote" "add" "origin" remote)
            (dm-org-persist--git repo "push" "--quiet" "--set-upstream" "origin" "main")
            (should (dm-org-persist--upstream-p repo))
            (dm-org-persist-tests--write repo "org/tasks.org" "* DONE Water plants\n")
            (dm-org-persist--commit repo '("org/tasks.org") "Mark it done")
            (dm-org-persist-push)
            (dm-org-persist-tests--await-push)
            (should (equal (dm-org-persist-tests--run repo "rev-parse" "HEAD")
                           (dm-org-persist-tests--run remote "rev-parse" "main"))))
        (delete-directory remote t)))))

(ert-deftest dm-org-persist-push/skips-a-branch-with-no-upstream ()
  (dm-org-persist-tests--with-repo
    (should-not (dm-org-persist--upstream-p repo))
    (dm-org-persist-push)
    (should-not dm-org-persist--push-process)))

(ert-deftest dm-org-persist-push/never-runs-two-pushes-at-once ()
  ;; A burst of commits must not fan out into a crowd of git processes: a
  ;; request arriving mid-push is remembered, not spawned.
  (dm-org-persist-tests--with-repo
    (let ((standing (start-process "dm-org-persist-tests-sleep" nil "sleep" "30")))
      (unwind-protect
          (let ((dm-org-persist--push-process standing)
                (dm-org-persist--push-again nil)
                (dm-org-git-remote "origin"))
            (dm-org-persist-push)
            (should dm-org-persist--push-again)
            (should (eq standing dm-org-persist--push-process)))
        (delete-process standing)))))

;;; ————————————————————————————
;;; Pulling
;;;
;;; These run against a real bare remote, and a second clone stands in for the
;;; other machine.  What is under test is mostly the interaction with git --
;;; whether `--autostash' returns an unmanaged edit to the working tree,
;;; whether the rebase really does replay local work on top of what arrived --
;;; so there would be nothing left to learn from mocking git out.
;;; ————————————————————————————

(defmacro dm-org-persist-tests--with-upstream (&rest body)
  "Run BODY with `repo' on a branch tracking a bare `remote'."
  (declare (indent 0) (debug t))
  `(dm-org-persist-tests--with-repo
     (let ((remote (file-name-as-directory
                    (file-truename (make-temp-file "dm-org-persist-remote-" t)))))
       (unwind-protect
           (progn
             (dm-org-persist--git remote "init" "--quiet" "--bare" "--initial-branch=main")
             (dm-org-persist--git repo "remote" "add" "origin" remote)
             (dm-org-persist--git repo "push" "--quiet" "--set-upstream" "origin" "main")
             ,@body)
         (delete-directory remote t)))))

(defun dm-org-persist-tests--await-pull (&optional seconds)
  "Block until the pull finishes, or SECONDS elapse."
  (let ((deadline (+ (float-time) (or seconds 20))))
    (while (and (process-live-p dm-org-persist--pull-process)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (while (and dm-org-persist--pull-process (< (float-time) deadline))
      (accept-process-output nil 0.05))))

(defun dm-org-persist-tests--advance-remote (remote relative contents message)
  "Commit CONTENTS at RELATIVE onto REMOTE from a scratch clone.

Stands in for the same repository being edited on another machine."
  (let ((clone (file-name-as-directory
                (file-truename (make-temp-file "dm-org-persist-clone-" t)))))
    (unwind-protect
        (progn
          (dm-org-persist--git clone "clone" "--quiet" remote ".")
          (dm-org-persist-tests--write clone relative contents)
          (dm-org-persist--git clone "add" "--all")
          (dm-org-persist--git clone "commit" "--quiet" "-m" message)
          (dm-org-persist--git clone "push" "--quiet" "origin" "main"))
      (delete-directory clone t))))

(defun dm-org-persist-tests--contents (repo relative)
  "Return the contents of RELATIVE inside REPO."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative repo))
    (buffer-string)))

(ert-deftest dm-org-persist-pull/brings-in-an-upstream-commit ()
  (dm-org-persist-tests--with-upstream
    (dm-org-persist-tests--advance-remote
     remote "org/notes.org" "* Written on the laptop\n" "Add notes")
    (let ((before (dm-org-persist-tests--commits repo)))
      (dm-org-persist-pull)
      (dm-org-persist-tests--await-pull)
      (should (= (1+ before) (dm-org-persist-tests--commits repo)))
      (should (file-exists-p (expand-file-name "org/notes.org" repo))))))

(ert-deftest dm-org-persist-pull/replays-local-commits-on-top-of-upstream ()
  ;; Rebase, not merge: local work ends up on top of what arrived, and the
  ;; history stays linear.  Two machines editing the same agenda would
  ;; otherwise accumulate a merge commit per sync.
  (dm-org-persist-tests--with-upstream
    (dm-org-persist-tests--write repo "org/tasks.org" "* DONE Water plants\n")
    (dm-org-persist--commit repo '("org/tasks.org") "Mark it done")
    (dm-org-persist-tests--advance-remote
     remote "org/notes.org" "* Written on the laptop\n" "Add notes")
    (dm-org-persist-pull)
    (dm-org-persist-tests--await-pull)
    (should (equal "Mark it done"
                   (dm-org-persist-tests--run repo "log" "-1" "--format=%s")))
    (should (equal "Add notes"
                   (dm-org-persist-tests--run repo "log" "-1" "--format=%s" "HEAD~1")))
    (should (string-empty-p
             (dm-org-persist-tests--run repo "log" "--merges" "--format=%H")))))

(ert-deftest dm-org-persist-pull/leaves-unmanaged-changes-in-the-working-tree ()
  ;; The Org repository is almost never clean, and what is dirty is usually
  ;; something this module does not manage.  `--autostash' has to give it back.
  (dm-org-persist-tests--with-upstream
    (dm-org-persist-tests--advance-remote
     remote "org/notes.org" "* Written on the laptop\n" "Add notes")
    (dm-org-persist-tests--write repo "unrelated.txt" "edited while pulling\n")
    (dm-org-persist-pull)
    (dm-org-persist-tests--await-pull)
    (should (file-exists-p (expand-file-name "org/notes.org" repo)))
    (should (equal "unrelated.txt" (dm-org-persist-tests--unstaged repo)))
    (should (equal "edited while pulling\n"
                   (dm-org-persist-tests--contents repo "unrelated.txt")))
    ;; A stash left behind would mean the pop failed and the edit is only
    ;; recoverable by hand.
    (should (string-empty-p (dm-org-persist-tests--run repo "stash" "list")))))

(ert-deftest dm-org-persist-pull/commits-queued-events-before-rebasing ()
  ;; A mutation made moments before the pull belongs in history as its own
  ;; commit, not inside the autostash -- and the push it would normally
  ;; trigger has to wait until the rebase that rewrites it is done.
  (dm-org-persist-tests--with-upstream
    (dm-org-persist-tests--advance-remote
     remote "org/notes.org" "* Written on the laptop\n" "Add notes")
    (dm-org-persist-tests--write repo "org/tasks.org" "* DONE Water plants\n")
    (let ((before (dm-org-persist-tests--commits repo))
          (dm-org-git-auto-push t)
          (dm-org-git-remote "origin"))
      (dm-org-persist (list :subject "Mark \"Water plants\" DONE"
                            :data '((type . "todo"))))
      (dm-org-persist-pull)
      ;; Flushed synchronously, before a single git process was started...
      (should-not dm-org-persist--events)
      ;; ...and its push held back rather than raced against the rebase.
      (should-not dm-org-persist--push-process)
      (dm-org-persist-tests--await-pull)
      (dm-org-persist-tests--await-push)
      ;; The local commit, plus the one that came from upstream.
      (should (= (+ 2 before) (dm-org-persist-tests--commits repo)))
      (should (equal "Mark \"Water plants\" DONE"
                     (dm-org-persist-tests--run repo "log" "-1" "--format=%s")))
      ;; Deferred, not dropped: the remote has it once the rebase is done.
      (should (equal (dm-org-persist-tests--run repo "rev-parse" "HEAD")
                     (dm-org-persist-tests--run remote "rev-parse" "main"))))))

(ert-deftest dm-org-persist-pull/refuses-while-a-rebase-is-in-progress ()
  (dm-org-persist-tests--with-upstream
    (make-directory (expand-file-name ".git/rebase-merge" repo) t)
    (cl-letf (((symbol-function 'display-warning) #'ignore))
      (dm-org-persist-pull))
    (should-not dm-org-persist--pull-process)))

(ert-deftest dm-org-persist-pull/refuses-a-branch-with-no-upstream ()
  (dm-org-persist-tests--with-repo
    (should-not (dm-org-persist--upstream-p repo))
    (dm-org-persist-pull)
    (should-not dm-org-persist--pull-process)))

(ert-deftest dm-org-persist-pull/refuses-while-a-push-is-in-flight ()
  ;; The rebase would rewrite the very commits the push is uploading.
  (dm-org-persist-tests--with-upstream
    (let ((standing (start-process "dm-org-persist-tests-sleep" nil "sleep" "30")))
      (unwind-protect
          (let ((dm-org-persist--push-process standing))
            (dm-org-persist-pull)
            (should-not dm-org-persist--pull-process))
        (delete-process standing)))))

(provide 'dm-org-persist-tests)
;;; dm-org-persist-tests.el ends here
