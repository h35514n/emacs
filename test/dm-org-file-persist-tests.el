;;; dm-org-file-persist-tests.el --- Tests for dm-org-file-persist  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root:
;;
;;   bin/test dm-org-file-persist
;;
;; or, without the runner:
;;
;;   emacs -Q --batch \
;;     -L modules -L test \
;;     -l dm-org-file-persist-tests.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; No Org load path is needed: nothing here calls Org, and the two entry
;; points `dm-org-persist' uses are stubbed.
;;
;; Every test works in a repository made by `make-temp-file' and removed
;; afterwards, laid out like the real one -- the repository root is an
;; ancestor of `org-directory' and holds unrelated files of its own.
;; `GIT_CONFIG_GLOBAL' and `GIT_CONFIG_SYSTEM' are pointed at /dev/null
;; throughout, so the developer's own configuration -- `commit.gpgsign' above
;; all -- cannot change what these tests observe.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'subr-x)
(require 'dm-org-file-persist)

;; Declared special so the tests can bind it dynamically.
(defvar org-directory)

;;; ————————————————————————————
;;; A throwaway Git repository
;;; ————————————————————————————

(defun dm-org-file-persist-tests--run (repo &rest args)
  "Run git with ARGS in REPO and return its trimmed output."
  (string-trim (cdr (apply #'dm-org-persist--git repo args))))

(defun dm-org-file-persist-tests--commits (repo)
  "Return the number of commits on REPO's current branch."
  (string-to-number (dm-org-file-persist-tests--run repo "rev-list" "--count" "HEAD")))

(defun dm-org-file-persist-tests--write (repo relative contents)
  "Write CONTENTS to RELATIVE inside REPO and return its absolute truename."
  (let ((path (expand-file-name relative repo)))
    (make-directory (file-name-directory path) t)
    (write-region contents nil path nil 'silent)
    (file-truename path)))

(defun dm-org-file-persist-tests--init (repo)
  "Turn REPO into a Git repository laid out like the real one.

`org/tasks.org' is an agenda file, `org/notes/reading.md' is not but is
still watched, `org/scratch.tmp' is ignored, and `unrelated.txt' sits
outside `org-directory' altogether."
  (dm-org-persist--git repo "init" "--quiet" "--initial-branch=main")
  (dm-org-file-persist-tests--write repo ".gitignore" "*.tmp\n")
  (dm-org-file-persist-tests--write repo "org/tasks.org" "* TODO Water plants\n")
  (dm-org-file-persist-tests--write repo "org/notes/reading.md" "# Reading\n")
  (dm-org-file-persist-tests--write repo "unrelated.txt" "not under org/\n")
  (dm-org-persist--git repo "add" "--all")
  (dm-org-persist--git repo "commit" "--quiet" "-m" "Initial commit"))

(defmacro dm-org-file-persist-tests--with-repo (&rest body)
  "Run BODY with `repo' bound to a fresh temporary Git repository.

`org-directory' is its `org' subdirectory, persistence is pointed at the
repository, and Org's two entry points are stubbed."
  (declare (indent 0) (debug t))
  `(let* ((repo (file-name-as-directory
                 (file-truename (make-temp-file "dm-org-file-persist-test-" t))))
          (org-directory (expand-file-name "org" repo))
          (dm-org-git-repository repo)
          (dm-org-persist--repository nil)
          (dm-org-persist--events nil)
          (dm-org-persist--timer nil)
          (dm-org-persist--saving nil)
          (dm-org-persist-enabled t)
          (dm-org-persist-commit-metadata t)
          (dm-org-file-persist-enabled t)
          (dm-org-file-persist-directories nil)
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
           (dm-org-file-persist-tests--init repo)
           (make-directory org-directory t)
           (cl-letf (((symbol-function 'org-save-all-org-buffers) #'ignore)
                     ((symbol-function 'org-agenda-files)
                      (lambda (&rest _) (list (expand-file-name "org/tasks.org" repo)))))
             ,@body))
       (dm-org-persist--cancel-timer)
       (delete-directory repo t))))

;;; ————————————————————————————
;;; Which saves are ours
;;; ————————————————————————————

(ert-deftest dm-org-file-persist-in-scope-p/accepts-a-file-under-org-directory ()
  (dm-org-file-persist-tests--with-repo
    (let ((notes (expand-file-name "org/notes/reading.md" repo)))
      (should (equal (file-truename notes)
                     (dm-org-file-persist-in-scope-p notes))))))

(ert-deftest dm-org-file-persist-in-scope-p/rejects-a-sibling-of-org-directory ()
  ;; The repository root is an ancestor of `org-directory' and holds unrelated
  ;; work.  That work is not this module's to commit.
  (dm-org-file-persist-tests--with-repo
    (should-not (dm-org-file-persist-in-scope-p
                 (expand-file-name "unrelated.txt" repo)))))

(ert-deftest dm-org-file-persist-in-scope-p/rejects-an-excluded-name ()
  (dm-org-file-persist-tests--with-repo
    (should-not (dm-org-file-persist-in-scope-p
                 (expand-file-name "org/notes/reading.md~" repo)))))

(ert-deftest dm-org-file-persist-in-scope-p/rejects-a-buffer-visiting-no-file ()
  (dm-org-file-persist-tests--with-repo
    (should-not (dm-org-file-persist-in-scope-p nil))))

(ert-deftest dm-org-file-persist-in-scope-p/honors-an-explicit-directory-list ()
  (dm-org-file-persist-tests--with-repo
    (let ((dm-org-file-persist-directories
           (list (expand-file-name "org/notes" repo))))
      (should (dm-org-file-persist-in-scope-p
               (expand-file-name "org/notes/reading.md" repo)))
      (should-not (dm-org-file-persist-in-scope-p
                   (expand-file-name "org/tasks.org" repo))))))

;;; ————————————————————————————
;;; What Git has to say about the file
;;; ————————————————————————————

(ert-deftest dm-org-file-persist-status/reports-a-tracked-file-as-modified ()
  (dm-org-file-persist-tests--with-repo
    (dm-org-file-persist-tests--write repo "org/notes/reading.md" "# Reading\n\nMore.\n")
    (should (equal "M" (dm-org-file-persist-status repo "org/notes/reading.md")))))

(ert-deftest dm-org-file-persist-status/reports-a-new-file-as-untracked ()
  (dm-org-file-persist-tests--with-repo
    (dm-org-file-persist-tests--write repo "org/links/scratch.org" "* Links\n")
    (should (equal "??" (dm-org-file-persist-status repo "org/links/scratch.org")))))

(ert-deftest dm-org-file-persist-status/is-nil-for-an-ignored-file ()
  ;; The one that matters most: `git add' on an ignored path exits non-zero,
  ;; which would make every later flush retry and keep its queue forever.
  (dm-org-file-persist-tests--with-repo
    (dm-org-file-persist-tests--write repo "org/scratch.tmp" "noise\n")
    (should-not (dm-org-file-persist-status repo "org/scratch.tmp"))))

(ert-deftest dm-org-file-persist-status/is-nil-when-the-save-changed-nothing ()
  (dm-org-file-persist-tests--with-repo
    (should-not (dm-org-file-persist-status repo "org/notes/reading.md"))))

;;; ————————————————————————————
;;; The event
;;; ————————————————————————————

(ert-deftest dm-org-file-persist-event/describes-a-modified-file-as-an-edit ()
  (let ((event (dm-org-file-persist-event
                "/knowledge/org/notes/reading.md" "org/notes/reading.md" "M")))
    (should (equal "Edit org/notes/reading.md" (plist-get event :subject)))
    (should (equal '("/knowledge/org/notes/reading.md") (plist-get event :files)))
    (should (plist-get event :generic))
    (should (equal "file" (alist-get 'type (plist-get event :data))))
    (should (equal "org/notes/reading.md" (alist-get 'file (plist-get event :data))))
    (should (equal "M" (alist-get 'status (plist-get event :data))))))

(ert-deftest dm-org-file-persist-event/describes-an-untracked-file-as-an-addition ()
  (let ((event (dm-org-file-persist-event
                "/knowledge/org/links/scratch.org" "org/links/scratch.org" "??")))
    (should (equal "Add org/links/scratch.org" (plist-get event :subject)))))

(ert-deftest dm-org-file-persist-event/metadata-survives-the-json-round-trip ()
  (let* ((event (dm-org-file-persist-event
                 "/knowledge/org/notes/reading.md" "org/notes/reading.md" "M"))
         (trailer (dm-org-persist-message (list event)))
         (json (string-remove-prefix
                "Org-Event: "
                (car (last (split-string trailer "\n" t))))))
    (should (equal "org/notes/reading.md"
                   (alist-get 'file (json-parse-string json :object-type 'alist))))))

;;; ————————————————————————————
;;; Recording a save
;;; ————————————————————————————

(ert-deftest dm-org-file-persist-record/queues-an-event-for-a-watched-file ()
  (dm-org-file-persist-tests--with-repo
    (let ((notes (dm-org-file-persist-tests--write
                  repo "org/notes/reading.md" "# Reading\n\nMore.\n")))
      (should (dm-org-file-persist-record notes))
      (should (= 1 (length dm-org-persist--events)))
      (should (equal "Edit org/notes/reading.md"
                     (plist-get (car dm-org-persist--events) :subject))))))

(ert-deftest dm-org-file-persist-record/ignores-a-file-outside-org-directory ()
  (dm-org-file-persist-tests--with-repo
    (let ((other (dm-org-file-persist-tests--write repo "unrelated.txt" "changed\n")))
      (should-not (dm-org-file-persist-record other))
      (should-not dm-org-persist--events))))

(ert-deftest dm-org-file-persist-record/ignores-a-file-git-ignores ()
  (dm-org-file-persist-tests--with-repo
    (let ((noise (dm-org-file-persist-tests--write repo "org/scratch.tmp" "noise\n")))
      (should-not (dm-org-file-persist-record noise))
      (should-not dm-org-persist--events))))

(ert-deftest dm-org-file-persist-record/ignores-a-save-this-module-did-not-cause ()
  ;; `dm-org-persist--save' runs `org-save-all-org-buffers', which fires
  ;; `after-save-hook' for every buffer it writes.  Recording those would
  ;; re-arm the debounce timer from inside the flush.
  (dm-org-file-persist-tests--with-repo
    (let ((notes (dm-org-file-persist-tests--write
                  repo "org/notes/reading.md" "# Reading\n\nMore.\n"))
          (dm-org-persist--saving t))
      (should-not (dm-org-file-persist-record notes))
      (should-not dm-org-persist--events))))

(ert-deftest dm-org-file-persist-record/is-inert-when-disabled ()
  (dm-org-file-persist-tests--with-repo
    (let ((notes (dm-org-file-persist-tests--write
                  repo "org/notes/reading.md" "# Reading\n\nMore.\n")))
      (let ((dm-org-file-persist-enabled nil))
        (should-not (dm-org-file-persist-record notes)))
      (let ((dm-org-persist-enabled nil))
        (should-not (dm-org-file-persist-record notes)))
      (should-not dm-org-persist--events))))

;;; ————————————————————————————
;;; End to end
;;; ————————————————————————————

(ert-deftest dm-org-file-persist/commits-a-file-outside-the-agenda-set ()
  (dm-org-file-persist-tests--with-repo
    (let ((notes (dm-org-file-persist-tests--write
                  repo "org/notes/reading.md" "# Reading\n\nMore.\n")))
      (dm-org-file-persist-record notes)
      (dm-org-persist-flush)
      (should-not dm-org-persist--events)
      (should (= 2 (dm-org-file-persist-tests--commits repo)))
      (should (equal "Edit org/notes/reading.md"
                     (dm-org-file-persist-tests--run repo "log" "-1" "--format=%s")))
      (should (equal "org/notes/reading.md"
                     (dm-org-file-persist-tests--run
                      repo "show" "--name-only" "--format=" "HEAD"))))))

(ert-deftest dm-org-file-persist/commits-a-file-git-did-not-track ()
  (dm-org-file-persist-tests--with-repo
    (let ((links (dm-org-file-persist-tests--write
                  repo "org/links/scratch.org" "* Links\n")))
      (dm-org-file-persist-record links)
      (dm-org-persist-flush)
      (should (= 2 (dm-org-file-persist-tests--commits repo)))
      (should (equal "Add org/links/scratch.org"
                     (dm-org-file-persist-tests--run repo "log" "-1" "--format=%s"))))))

(ert-deftest dm-org-file-persist/an-ignored-file-cannot-wedge-the-queue ()
  ;; Before the status gate, saving an ignored file put it in `:files', `git
  ;; add' refused it, and the flush returned `retry' -- so every later agenda
  ;; commit was blocked by one `.DS_Store'.
  (dm-org-file-persist-tests--with-repo
    (dm-org-file-persist-record
     (dm-org-file-persist-tests--write repo "org/scratch.tmp" "noise\n"))
    (dm-org-file-persist-record
     (dm-org-file-persist-tests--write repo "org/notes/reading.md" "# Reading\n\nMore.\n"))
    (dm-org-persist-flush)
    (should-not dm-org-persist--events)
    (should (= 2 (dm-org-file-persist-tests--commits repo)))
    (should (equal "Edit org/notes/reading.md"
                   (dm-org-file-persist-tests--run repo "log" "-1" "--format=%s")))))

(ert-deftest dm-org-file-persist/several-saves-coalesce-into-one-commit ()
  (dm-org-file-persist-tests--with-repo
    (dm-org-file-persist-record
     (dm-org-file-persist-tests--write repo "org/notes/reading.md" "# Reading\n\nMore.\n"))
    (dm-org-file-persist-record
     (dm-org-file-persist-tests--write repo "org/links/scratch.org" "* Links\n"))
    (dm-org-persist-flush)
    (should (= 2 (dm-org-file-persist-tests--commits repo)))
    (should (equal "2 Org changes"
                   (dm-org-file-persist-tests--run repo "log" "-1" "--format=%s")))))

;;; ————————————————————————————
;;; Installation
;;; ————————————————————————————

(ert-deftest dm-org-file-persist-install/puts-the-hook-on-after-save-hook ()
  (let ((after-save-hook nil))
    (dm-org-file-persist-install)
    (should (memq #'dm-org-file-persist--after-save-h after-save-hook))
    (dm-org-file-persist-uninstall)
    (should-not (memq #'dm-org-file-persist--after-save-h after-save-hook))))

(ert-deftest dm-org-file-persist-install/a-real-save-queues-an-event ()
  ;; The whole wiring in one test: `save-buffer' runs `after-save-hook', which
  ;; is where this module lives.  Everything above tests the parts.
  (dm-org-file-persist-tests--with-repo
    (let ((after-save-hook nil)
          (make-backup-files nil))
      (dm-org-file-persist-install)
      (let ((buffer (find-file-noselect
                     (expand-file-name "org/notes/reading.md" repo))))
        (unwind-protect
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "More.\n")
              (save-buffer)
              (should (= 1 (length dm-org-persist--events)))
              (should (equal "Edit org/notes/reading.md"
                             (plist-get (car dm-org-persist--events) :subject))))
          (kill-buffer buffer))))))

(ert-deftest dm-org-file-persist-after-save-h/never-lets-a-failure-reach-the-save ()
  ;; A save must complete even when recording it cannot.
  (let ((warnings nil))
    (cl-letf (((symbol-function 'dm-org-file-persist-record)
               (lambda (&rest _) (error "Git went missing")))
              ((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      ;; The return value is nobody's business -- `run-hooks' discards it.
      ;; What matters is that nothing signals out of the hook.
      (dm-org-file-persist--after-save-h))
    (should (= 1 (length warnings)))
    (should (eq 'dm-org-file-persist (car (car warnings))))))

(provide 'dm-org-file-persist-tests)
;;; dm-org-file-persist-tests.el ends here
