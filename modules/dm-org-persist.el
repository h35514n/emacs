;;; dm-org-persist.el --- Commit Org mutations to Git  -*- lexical-binding: t; -*-

;;; Commentary:

;; The generic half of semantic Git persistence for Org: everything between
;; "something meaningful changed" and "it is committed and pushed".  It knows
;; nothing about TODO states, deadlines, or refiles.  Callers hand it an event
;; that already describes itself, and it does the file and process work:
;;
;;     (dm-org-persist
;;      (list :subject "Reschedule \"Submit application\" 2026-08-31 → 2026-09-02"
;;            :data '((type . "schedule") (heading . "Submit application")
;;                    (old . "2026-08-31") (new . "2026-09-02"))
;;            :files '("/home/me/Org/tasks.org")))
;;
;; Two modules produce those events.  `dm-org-agenda-persist' watches the
;; agenda and describes what a command did to the plan; `dm-org-file-persist'
;; watches saving and describes what happened to a file under `org-directory'.
;;
;; Why events rather than a hook of this module's own: a refresh is a
;; presentation event.  Redrawing the agenda says nothing about the plan, so
;; nothing here keys off it.  Only a caller asserting that something changed
;; can start a commit.
;;
;; That is a statement about where the judgment lives, not a ban on hooks.
;; Saving a file is itself such an assertion -- the file on disk is not what it
;; was -- which is why `dm-org-file-persist' can make one from
;; `after-save-hook' while `dm-org-agenda-persist' has to synthesize one from a
;; before-and-after pair bracketing a command.
;;
;; Why the work is deferred:
;;
;; Agenda commands arrive in bursts.  Cycling a TODO keyword through three
;; states is three invocations, and a bulk reschedule over a region is one
;; invocation per entry -- Org re-enters the same command through
;; `org-agenda-maybe-loop'.  Committing each one separately would mean a git
;; process (and, here, a GPG signature) per keystroke.  So events queue up and
;; `dm-org-persist-debounce-seconds' of quiet flushes them as a single commit
;; carrying one record per event.  The coalescing is also what makes the loop
;; case correct for free: N nested invocations produce N events and one commit.
;;
;; Coalescing has a consequence worth knowing.  A hand edit made inside the
;; debounce window rides along in whatever commit the window belongs to.  With
;; `dm-org-file-persist' loaded that edit names itself, because saving it queues
;; an event of its own; without it, or for a file that module does not watch,
;; the change is still committed -- it is real and belongs in history -- but the
;; message will not describe it.
;;
;; The reverse case is `dm-org-persist-relevant-events'.  An event marked
;; `:generic' says only that a file changed, and when a second event in the same
;; batch describes that same file in domain terms, the generic one would add a
;; line saying less about the same thing.  It is dropped.
;;
;; Why metadata is JSON:
;;
;; Git parses trailers only out of a message's last paragraph, so flat keys
;; from three coalesced events would interleave into one ambiguous block.
;; Each event is therefore one self-contained `Org-Event:' line holding a JSON
;; object, which keeps
;;
;;     git log --format='%(trailers:key=Org-Event,valueonly)'
;;
;; a direct event stream, decodable with `json-parse-string', and lets new
;; fields appear without changing the shape.
;;
;; Failure behavior, in order of the flush:
;;
;;   - Repository missing, or a merge/rebase/bisect in progress: warn and keep
;;     the queue.  A later flush retries.
;;   - Saving fails: warn, keep the queue, and do not commit.  Committing a
;;     buffer that would not save is how you get a snapshot that disagrees
;;     with what is on screen.
;;   - Staging or committing fails: warn with git's own output and keep the
;;     queue.  Nothing reports success it did not have.
;;   - GPG signing fails: retry once with --no-gpg-sign, if
;;     `dm-org-persist-sign-fallback' allows, and say so.  Losing a signature
;;     is recoverable; losing the mutation is not.
;;   - Pushing fails: the local commit stands, the failure is reported, and
;;     the next push carries the backlog.  Git history is never rewritten,
;;     reset, or force-pushed.
;;
;; Staging is always by explicit pathspec -- never `git add .' -- because the
;; repository root is typically an ancestor of `org-directory' and holds
;; unrelated work.  `git commit' is likewise given the pathspec, so a change
;; someone staged by hand cannot be swept into an automated commit.
;;
;; The inward direction:
;;
;; `dm-org-persist-pull' is the one command here that no event drives.  It
;; exists because the same reasoning that makes commits automatic makes a
;; hand-rolled pull awkward: the working tree is almost never clean, and there
;; may be a mutation still sitting in the debounce queue.  So it commits what
;; is queued first, with the auto-push suppressed, and only then rebases -- a
;; pending edit belongs in history as a commit, not inside an autostash.
;; After a successful pull has re-read any files it changed,
;; `dm-org-persist-after-pull-hook' gives domain modules a chance to reconcile
;; data written by clients that do not implement the same local extensions.
;; The hook runs before live agenda buffers are rebuilt, so their next render
;; sees the reconciled data.  It also runs after an already-up-to-date pull:
;; that gives a buffer skipped earlier because it held unsaved work a safe
;; opportunity to catch up later.

;;; Code:

(require 'subr-x)

(declare-function org-agenda-files "org" (&optional unrestricted archives))
(declare-function org-agenda-redo "org-agenda" (&optional all))
(declare-function org-save-all-org-buffers "org" ())
(defvar org-agenda-mode-map)
(defvar org-directory)

(defgroup dm-org-persist nil
  "Commit Org agenda mutations to Git as a semantic event log."
  :group 'org)

;;; ————————————————————————————
;;; Configuration
;;; ————————————————————————————

(defcustom dm-org-git-repository nil
  "Root of the Git repository holding the Org agenda files.

nil means discover it by running git from `org-directory', which is the
usual case: the repository root is often an ancestor of `org-directory'
rather than `org-directory' itself.  The discovered value is cached; call
`dm-org-persist-reset-repository' after moving the repository."
  :type '(choice (const :tag "Discover from `org-directory'" nil)
                 (directory :tag "Repository root"))
  :group 'dm-org-persist)

(defcustom dm-org-git-auto-push t
  "Whether a successful commit is followed by an asynchronous push."
  :type 'boolean
  :group 'dm-org-persist)

(defcustom dm-org-git-remote nil
  "Remote to push to, or nil to use the current branch's upstream.

When nil, pushing is skipped entirely on a branch with no upstream, since
a bare `git push' would fail there anyway."
  :type '(choice (const :tag "Branch's configured upstream" nil)
                 (string :tag "Remote name"))
  :group 'dm-org-persist)

(defcustom dm-org-git-push-args '("--quiet")
  "Extra arguments passed to `git push'."
  :type '(repeat string)
  :group 'dm-org-persist)

(defcustom dm-org-git-pull-args '("--rebase" "--autostash")
  "Arguments passed to `git pull' by `dm-org-persist-pull'.

`--autostash' is what lets the pull run at all.  The Org repository is
rarely clean: whatever this module does not manage -- an archive file,
notes, unrelated work elsewhere under the repository root -- is still in
the working tree when the rebase starts, and would otherwise refuse it."
  :type '(repeat string)
  :group 'dm-org-persist)

(defcustom dm-org-persist-enabled t
  "Whether agenda mutations are persisted to Git at all.

Setting this to nil makes `dm-org-persist' a no-op, which leaves the
instrumenting advice installed but inert."
  :type 'boolean
  :group 'dm-org-persist)

(defcustom dm-org-persist-debounce-seconds 1.5
  "Seconds of quiet before queued events are committed.

Events arriving during the window join the same commit.  Longer values
coalesce more aggressively; shorter ones keep commits closer to one per
action, at the cost of a git process per keystroke."
  :type 'number
  :group 'dm-org-persist)

(defcustom dm-org-persist-commit-metadata t
  "Whether commits carry machine-readable `Org-Event:' trailers.

With this nil, commit messages keep their human-readable subject and body
and drop the JSON records that make the history queryable."
  :type 'boolean
  :group 'dm-org-persist)

(defcustom dm-org-persist-sign-fallback t
  "Whether a commit that fails to sign is retried unsigned.

With `commit.gpgsign' set, an automated commit runs GPG from whatever
environment Emacs was started in, which may have no usable pinentry or a
cold agent cache.  Retrying unsigned keeps the mutation; the fallback is
always reported."
  :type 'boolean
  :group 'dm-org-persist)

(defcustom dm-org-persist-git-executable (or (executable-find "git") "git")
  "Git executable used for persistence."
  :type 'string
  :group 'dm-org-persist)

;;; ————————————————————————————
;;; Internal state
;;; ————————————————————————————

(defvar dm-org-persist--events nil
  "Events awaiting a commit, most recent first.")

(defvar dm-org-persist--timer nil
  "Debounce timer that will run `dm-org-persist-flush'.")

(defvar dm-org-persist--repository nil
  "Cached result of discovering the repository root.")

(defvar dm-org-persist--push-process nil
  "The `git push' process currently running, if any.")

(defvar dm-org-persist--push-again nil
  "Non-nil when a push was requested while another was in flight.")

(defvar dm-org-persist--pull-process nil
  "The `git pull' currently running, if any.")

(defvar dm-org-persist--pull-head nil
  "HEAD as it stood when the running pull started.")

(defvar dm-org-persist-after-pull-hook nil
  "Hook run after every successful pull to reconcile external Org changes.

Each function is called with one argument, the repository root.  This hook
runs after pulled files have been re-read and before agendas are rebuilt.  It
also runs when the repository was already current, so previously deferred
work can be retried.  A function should return non-nil when it changed data;
hook errors are reported and do not prevent remaining functions or agenda
buffers from being refreshed.")

(defconst dm-org-persist-push-buffer-name "*dm-org-persist-push*"
  "Buffer holding the output of the most recent `git push'.")

(defconst dm-org-persist-pull-buffer-name "*dm-org-persist-pull*"
  "Buffer holding the output of the most recent pull.")

(defconst dm-org-persist--environment
  '("GIT_TERMINAL_PROMPT=0" "GIT_OPTIONAL_LOCKS=0" "GIT_PAGER=cat" "GIT_EDITOR=true")
  "Environment entries added to every git invocation.

`GIT_TERMINAL_PROMPT' matters most: without it a repository whose
credentials have expired makes git block on a prompt no one can answer,
which would hang the push process indefinitely.")

(defun dm-org-persist--warn (format &rest args)
  "Report a persistence failure described by FORMAT and ARGS."
  (display-warning 'dm-org-persist (apply #'format format args) :warning))

(defun dm-org-persist--log (format &rest args)
  "Record FORMAT and ARGS in the message log without disturbing the echo area."
  (let ((inhibit-message t))
    (message "%s" (apply #'format format args))))

;;; ————————————————————————————
;;; Running git
;;; ————————————————————————————

(defun dm-org-persist--git (repo &rest args)
  "Run git with ARGS in REPO.  Return a cons of (EXIT-CODE . OUTPUT).

Standard error is folded into OUTPUT so a failure can be reported with
git's own words."
  (with-temp-buffer
    (let* ((default-directory (file-name-as-directory repo))
           (process-environment (append dm-org-persist--environment process-environment))
           (status (apply #'process-file dm-org-persist-git-executable nil '(t t) nil args)))
      (cons (if (integerp status) status -1)
            (buffer-string)))))

(defun dm-org-persist--exited-cleanly-p (process)
  "Return non-nil when PROCESS has finished with exit status zero."
  (and (eq (process-status process) 'exit)
       (zerop (process-exit-status process))))

(defun dm-org-persist--head (repo)
  "Return REPO's current HEAD as a string, or nil when it has none."
  (pcase-let ((`(,code . ,out) (dm-org-persist--git repo "rev-parse" "HEAD")))
    (when (zerop code)
      (let ((head (string-trim out)))
        (unless (string-empty-p head) head)))))

(defun dm-org-persist--count (repo range)
  "Return the number of commits in RANGE within REPO, or 0 when git refuses."
  (pcase-let ((`(,code . ,out) (dm-org-persist--git repo "rev-list" "--count" range)))
    (if (zerop code) (string-to-number (string-trim out)) 0)))

(defun dm-org-persist-reset-repository ()
  "Forget the cached repository root."
  (interactive)
  (setq dm-org-persist--repository nil))

(defun dm-org-persist-repository ()
  "Return the root of the Git repository holding the Org agenda files.

Return nil when there is none.  `dm-org-git-repository' wins when set;
otherwise the root is discovered from `org-directory' and cached."
  (cond
   (dm-org-git-repository
    (file-name-as-directory (file-truename dm-org-git-repository)))
   (dm-org-persist--repository)
   (t
    (setq dm-org-persist--repository
          (when (and (boundp 'org-directory)
                     (stringp org-directory)
                     (file-directory-p org-directory))
            (pcase-let ((`(,code . ,out)
                         (dm-org-persist--git org-directory "rev-parse" "--show-toplevel")))
              (when (zerop code)
                (let ((root (string-trim out)))
                  (unless (string-empty-p root)
                    (file-name-as-directory (file-truename root)))))))))))

(defun dm-org-persist--busy-p (repo)
  "Return non-nil when REPO is mid-merge, mid-rebase, or mid-bisect.

Committing into one of those states would entangle an automated commit
with an operation the user is in the middle of."
  (let ((git (expand-file-name ".git" repo)))
    (seq-some (lambda (name) (file-exists-p (expand-file-name name git)))
              '("MERGE_HEAD" "CHERRY_PICK_HEAD" "REVERT_HEAD" "BISECT_LOG"
                "rebase-merge" "rebase-apply"))))

;;; ————————————————————————————
;;; Which files are ours to stage
;;; ————————————————————————————

(defun dm-org-persist-relative-name (file)
  "Return FILE relative to the repository root, or its absolute truename.

Used for the `file' field of event metadata so records read the same way
`git log --stat' does."
  (let ((repo (dm-org-persist-repository))
        (true (and (stringp file) (file-truename file))))
    (cond
     ((null true) nil)
     ((and repo (string-prefix-p repo true)) (file-relative-name true repo))
     (t true))))

(defun dm-org-persist--managed-files (repo events)
  "Return the repository-relative paths REPO may stage for EVENTS.

The set is `org-agenda-files' plus any file an event names in `:files',
restricted to existing regular files inside REPO.  Everything else in the
repository -- notes, attachments, unrelated projects -- is out of scope,
which is why staging never goes through `git add .'."
  (let ((candidates (append (ignore-errors (org-agenda-files t))
                            (mapcan (lambda (event)
                                      (copy-sequence (plist-get event :files)))
                                    events)))
        (found nil))
    (dolist (file candidates (nreverse found))
      (when (stringp file)
        (let ((true (file-truename file)))
          (when (and (string-prefix-p repo true)
                     (file-regular-p true))
            (let ((relative (file-relative-name true repo)))
              (unless (member relative found)
                (push relative found)))))))))

;;; ————————————————————————————
;;; Commit messages
;;; ————————————————————————————

(defun dm-org-persist--encode (data)
  "Return DATA, an alist, as a single-line JSON object.

nil values become JSON null rather than being dropped, so a field that is
meaningfully absent -- the old date of a newly scheduled entry, say -- is
still visible in the record.  Values that should serialize as arrays must
already be vectors; a list is ambiguous with an alist."
  (json-serialize
   (mapcar (lambda (cell)
             (cons (car cell) (or (cdr cell) :null)))
           data)))

(defun dm-org-persist--trailer (event)
  "Return the `Org-Event:' trailer line for EVENT, or nil when it has no data."
  (when-let* ((data (plist-get event :data)))
    (concat "Org-Event: " (dm-org-persist--encode data))))

(defun dm-org-persist-message (events)
  "Return the commit message describing EVENTS, oldest first.

A single event supplies the subject directly.  Several are summarized in
the subject and listed in the body, so the coalesced case stays readable
in `git log --oneline'.  Metadata, when enabled, is one trailer per event
regardless of count."
  (let* ((subjects (mapcar (lambda (event)
                             (or (plist-get event :subject) "Update Org agenda"))
                           events))
         (single (= 1 (length subjects)))
         (subject (if single
                      (car subjects)
                    (format "%d Org changes" (length subjects))))
         (body (unless single
                 (mapconcat (lambda (line) (concat "- " line)) subjects "\n")))
         (trailers (when dm-org-persist-commit-metadata
                     (let ((lines (delq nil (mapcar #'dm-org-persist--trailer events))))
                       (and lines (string-join lines "\n"))))))
    (string-join (delq nil (list subject body trailers)) "\n\n")))

;;; ————————————————————————————
;;; Committing
;;; ————————————————————————————

(defconst dm-org-persist--signing-failure-regexp
  (regexp-opt '("gpg failed to sign"
                "failed to write commit object"
                "secret key not available"
                "No secret key"
                "Inappropriate ioctl for device"))
  "Regexp matching git output that indicates GPG signing, not the commit, failed.")

(defun dm-org-persist--commit (repo files message)
  "Stage FILES in REPO and commit them with MESSAGE.

Return `committed' on success, `no-op' when FILES turn out to hold no
change, and `retry' when something failed and the events should be kept."
  (pcase-let ((`(,added . ,add-output)
               (apply #'dm-org-persist--git repo "add" "--" files)))
    (if (not (zerop added))
        (progn (dm-org-persist--warn "git add failed: %s" (string-trim add-output))
               'retry)
      ;; `git diff --cached --quiet' exits 1 when there is something staged,
      ;; which is the only case worth a commit.  This is the structural
      ;; backstop behind whatever no-op detection the caller already did.
      (pcase (car (apply #'dm-org-persist--git repo "diff" "--cached" "--quiet" "--" files))
        (0 'no-op)
        (1 (dm-org-persist--run-commit repo files message))
        (_ (dm-org-persist--warn "git diff --cached failed in %s" repo)
           'retry)))))

(defun dm-org-persist--run-commit (repo files message)
  "Commit FILES in REPO with MESSAGE, retrying unsigned if signing fails.

FILES is passed as a pathspec, so anything staged by hand outside that set
stays staged and uncommitted."
  (pcase-let ((`(,code . ,output)
               (apply #'dm-org-persist--git repo
                      (append (list "commit" "-m" message "--") files))))
    (cond
     ((zerop code)
      (dm-org-persist--log "✓ Org agenda committed: %s" (car (split-string message "\n")))
      'committed)
     ((and dm-org-persist-sign-fallback
           (string-match-p dm-org-persist--signing-failure-regexp output))
      (pcase-let ((`(,retry-code . ,retry-output)
                   (apply #'dm-org-persist--git repo
                          (append (list "commit" "--no-gpg-sign" "-m" message "--") files))))
        (if (zerop retry-code)
            (progn
              (dm-org-persist--warn
               "Committed Org agenda unsigned; GPG signing failed: %s"
               (string-trim output))
              'committed)
          (dm-org-persist--warn "git commit failed: %s" (string-trim retry-output))
          'retry)))
     (t
      (dm-org-persist--warn "git commit failed: %s" (string-trim output))
      'retry))))

;;; ————————————————————————————
;;; Pushing
;;; ————————————————————————————

(defun dm-org-persist--upstream-p (repo)
  "Return non-nil when REPO's current branch has a configured upstream."
  (zerop (car (dm-org-persist--git
               repo "rev-parse" "--abbrev-ref" "--symbolic-full-name" "@{u}"))))

(defun dm-org-persist-push ()
  "Push the Org repository asynchronously.

At most one `git push' runs at a time.  A request arriving while one is in
flight is remembered and satisfied by a single follow-up push, so a burst
of commits cannot fan out into a crowd of processes."
  (interactive)
  (let ((repo (dm-org-persist-repository)))
    (cond
     ((null repo) nil)
     ((process-live-p dm-org-persist--push-process)
      (setq dm-org-persist--push-again t))
     ((and (null dm-org-git-remote) (not (dm-org-persist--upstream-p repo)))
      (dm-org-persist--log "Org agenda committed locally; branch has no upstream to push to"))
     (t (dm-org-persist--start-push repo)))))

(defun dm-org-persist--start-push (repo)
  "Start `git push' in REPO."
  (let ((buffer (get-buffer-create dm-org-persist-push-buffer-name))
        (default-directory (file-name-as-directory repo))
        (process-environment (append dm-org-persist--environment process-environment)))
    (with-current-buffer buffer (erase-buffer))
    (setq dm-org-persist--push-again nil)
    (setq dm-org-persist--push-process
          (make-process
           :name "dm-org-persist-push"
           :buffer buffer
           :noquery t
           :connection-type 'pipe
           :command (append (list dm-org-persist-git-executable "push")
                            dm-org-git-push-args
                            (when dm-org-git-remote (list dm-org-git-remote)))
           :sentinel #'dm-org-persist--push-sentinel))))

(defun dm-org-persist--push-sentinel (process _event)
  "Report the outcome of PROCESS and honor any push deferred while it ran."
  (unless (process-live-p process)
    (setq dm-org-persist--push-process nil)
    (if (dm-org-persist--exited-cleanly-p process)
        (dm-org-persist--log "✓ Org agenda pushed")
      ;; The commit is already in the local history; a failed push costs
      ;; replication, not the record.
      (message "✗ Org agenda push failed — commits are safe locally, see %s"
               dm-org-persist-push-buffer-name))
    (when dm-org-persist--push-again
      (setq dm-org-persist--push-again nil)
      (dm-org-persist-push))))

;;; ————————————————————————————
;;; Queue and flush
;;; ————————————————————————————

(defun dm-org-persist--cancel-timer ()
  "Cancel any pending debounce timer."
  (when (timerp dm-org-persist--timer)
    (cancel-timer dm-org-persist--timer))
  (setq dm-org-persist--timer nil))

(defun dm-org-persist (event)
  "Queue EVENT and arrange for it to be committed.

EVENT is a plist:

  :subject  one line describing the mutation in human terms.
  :data     an alist of metadata, emitted as an `Org-Event:' trailer.
  :files    absolute paths the mutation touched beyond `org-agenda-files',
            such as a refile destination outside the agenda set.
  :generic  non-nil when the event knows only that a file changed, and
            should yield to any event describing the same file in domain
            terms.  See `dm-org-persist-relevant-events'.

The commit does not happen here.  Events accumulate until
`dm-org-persist-debounce-seconds' of quiet, so a burst of agenda commands
becomes one commit."
  (when (and dm-org-persist-enabled event)
    (push event dm-org-persist--events)
    (dm-org-persist--cancel-timer)
    (setq dm-org-persist--timer
          (run-with-timer dm-org-persist-debounce-seconds nil #'dm-org-persist-flush))))

(defvar dm-org-persist--saving nil
  "Non-nil while `dm-org-persist--save' is writing Org buffers to disk.")

(defun dm-org-persist-saving-p ()
  "Return non-nil while this module is saving Org buffers itself.

`org-save-all-org-buffers' runs `after-save-hook' for every buffer it
writes, so a producer keyed on that hook -- `dm-org-file-persist' -- would
otherwise read the flush's own save as a fresh edit.  That would re-arm the
debounce timer from inside the flush, and on a `retry' outcome would add one
duplicate event per attempt, forever."
  dm-org-persist--saving)

(defun dm-org-persist-relevant-events (events)
  "Return EVENTS with redundant generic events removed.

An event carrying `:generic' asserts only that a file changed.  When
another event in the same batch describes that same file in domain terms
-- \"Mark \\=`Water plants\\=' DONE\" rather than \"Edit org/tasks.org\" --
the generic event contributes a line that says less about the same change,
so it is dropped.

This is the common case rather than an edge.  `dm-org' advises eleven
agenda commands with `:after #\\='dm-org-agenda-save-all-files--h', so an
instrumented command saves its own file from inside the advice that is
describing it, and a producer on `after-save-hook' sees that save.
Resolving it here rather than at the producer keeps the rule independent of
which advice happens to nest outside which.

Staging is unaffected: a dropped event's files are named by the event that
displaced it, so `dm-org-persist--managed-files' returns the same set."
  (let ((described (make-hash-table :test #'equal)))
    (dolist (event events)
      (unless (plist-get event :generic)
        (dolist (file (plist-get event :files))
          (puthash (file-truename file) t described))))
    (seq-filter
     (lambda (event)
       (not (and (plist-get event :generic)
                 (plist-get event :files)
                 (seq-every-p (lambda (file)
                                (gethash (file-truename file) described))
                              (plist-get event :files)))))
     events)))

(defun dm-org-persist--save ()
  "Save modified Org buffers.  Return non-nil on success."
  (condition-case err
      (let ((dm-org-persist--saving t))
        (org-save-all-org-buffers)
        t)
    (error
     (dm-org-persist--warn "Not committing: saving Org buffers failed: %s"
                           (error-message-string err))
     nil)))

(defun dm-org-persist--persist-queue ()
  "Save, stage, and commit the queued events.

Return `committed', `no-op', or `retry'; the caller decides what that means
for the queue."
  (let ((repo (dm-org-persist-repository)))
    (cond
     ((null repo)
      (dm-org-persist--warn "No Git repository found for %s"
                            (abbreviate-file-name (or (bound-and-true-p org-directory) "?")))
      'retry)
     ((dm-org-persist--busy-p repo)
      (dm-org-persist--warn
       "Deferring Org commit: a merge, rebase, or bisect is in progress in %s"
       (abbreviate-file-name repo))
      'retry)
     ((not (dm-org-persist--save)) 'retry)
     (t
      (let* ((events (dm-org-persist-relevant-events
                      (reverse dm-org-persist--events)))
             (files (dm-org-persist--managed-files repo events)))
        (if (null files)
            (progn (dm-org-persist--warn "No managed Org files to stage in %s"
                                         (abbreviate-file-name repo))
                   'no-op)
          (dm-org-persist--commit repo files (dm-org-persist-message events))))))))

(defun dm-org-persist-flush ()
  "Commit every queued event now, then push if configured.

Safe to call with an empty queue.  Events survive a failure so a later
flush can retry them; they are dropped once committed, or once git
confirms they amounted to no change on disk."
  (interactive)
  (dm-org-persist--cancel-timer)
  (when dm-org-persist--events
    (pcase (dm-org-persist--persist-queue)
      ('committed
       (setq dm-org-persist--events nil)
       (when dm-org-git-auto-push (dm-org-persist-push)))
      ('no-op
       (setq dm-org-persist--events nil))
      (_ nil))))

(defun dm-org-persist--flush-before-exit-h ()
  "Commit anything still queued before Emacs exits.

Without this, a mutation made inside the debounce window would lose both
its commit and its save.  Pushing is skipped: an asynchronous push cannot
finish during exit, and the next session's first commit carries the
backlog anyway."
  (when dm-org-persist--events
    (let ((dm-org-git-auto-push nil))
      (ignore-errors (dm-org-persist-flush)))))

(add-hook 'kill-emacs-hook #'dm-org-persist--flush-before-exit-h)

;;; ————————————————————————————
;;; Pulling
;;; ————————————————————————————

;; `--autostash' is what lets this run at all: the Org repository is rarely
;; clean, and what is dirty is usually something this module does not manage,
;; so there is nothing for the pre-pull flush to commit and nothing to do but
;; carry it across the rebase.
;;
;; The command refuses rather than queues.  The push has a mutex because
;; commits arrive on their own schedule and must not be dropped; a pull is
;; asked for by hand, so when the repository is busy the honest answer is to
;; say so and let the request be repeated.

(defun dm-org-persist--pull-failed ()
  "Report that the pull failed."
  (let ((repo (dm-org-persist-repository)))
    (if (and repo (dm-org-persist--busy-p repo))
        ;; Worth saying out loud, because the consequence outlives the command:
        ;; `dm-org-persist--busy-p' makes every later flush defer with only a
        ;; warning, so agenda edits would quietly stop being committed until
        ;; the rebase is finished or aborted.
        (message (concat "✗ Org agenda pull stopped — %s is mid-rebase, and agenda "
                         "commits are paused until it is resolved or aborted (see %s)")
                 (abbreviate-file-name repo) dm-org-persist-pull-buffer-name)
      (message "✗ Org agenda pull failed — see %s" dm-org-persist-pull-buffer-name))))

(defun dm-org-persist--reread-files (repo)
  "Re-read Org buffers under REPO whose files the pull rewrote.

This has to happen before the agenda is rebuilt, because the agenda is
built from buffers rather than from files: `org-get-agenda-file-buffer'
reuses whatever buffer already visits an agenda file, so a rebuild over
buffers that still hold the pre-pull text just redraws the old plan.

`global-auto-revert-mode' does get there on its own, but not by the time
git exits.  A rebase writes each file several times -- checkout, apply,
and again for the autostash pop -- and notification-driven reverts are
rate-limited to one per `auto-revert--lockout-interval' (2.5s), so the
last write of a pull is routinely still unread seconds after the sentinel
has run.  That gap is what made a second, hand-issued redo look
necessary."
  (let ((root (file-name-as-directory (file-truename repo))))
    (dolist (buffer (buffer-list))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and buffer-file-name
                     (derived-mode-p 'org-mode)
                     ;; Never discard unsaved work.  `dm-org-persist-pull'
                     ;; saves every Org buffer before it starts, so anything
                     ;; modified now was typed while git was running and is
                     ;; the user's, not the rebase's.  Auto-revert leaves
                     ;; these alone too.
                     (not (buffer-modified-p))
                     (string-prefix-p root (file-truename buffer-file-name))
                     (file-exists-p buffer-file-name)
                     (not (verify-visited-file-modtime buffer)))
            ;; The same call auto-revert would have made, just at the moment
            ;; the contents are known to be final.
            (ignore-errors
              (revert-buffer 'ignore-auto 'noconfirm 'preserve-modes))))))))

(defun dm-org-persist--run-after-pull-hook (repo)
  "Run reconciliation hooks for REPO, returning non-nil if any changed data."
  (let (changed)
    (run-hook-wrapped
     'dm-org-persist-after-pull-hook
     (lambda (function &rest args)
       (condition-case err
           (when (apply function args)
             (setq changed t))
         (error
          (display-warning
           'dm-org-persist
           (format "Could not reconcile pulled Org files: %s"
                   (error-message-string err))
           :warning)))
       ;; A nil wrapper result tells `run-hook-wrapped' to keep going, even
       ;; after a function reports that it changed something.
       nil)
     repo)
    changed))

(defun dm-org-persist--redraw-agendas ()
  "Rebuild every live agenda buffer."
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'org-agenda-mode)
          ;; An agenda built from a command that cannot be replayed will
          ;; signal; a stale agenda is not worth failing a successful pull.
          (ignore-errors (org-agenda-redo)))))))

(defun dm-org-persist--refresh-agenda ()
  "Re-read and reconcile what the pull changed, then rebuild live agendas.

An agenda buffer is a rendering rather than a file, so nothing reverts it:
without this it keeps showing the plan as it stood before the pull."
  (let ((repo (dm-org-persist-repository)))
    (when repo
      (dm-org-persist--reread-files repo)
      (dm-org-persist--run-after-pull-hook repo)))
  (dm-org-persist--redraw-agendas))

(defun dm-org-persist--start-pull (repo)
  "Start `git pull' in REPO."
  (let ((default-directory (file-name-as-directory repo))
        (process-environment (append dm-org-persist--environment process-environment)))
    (setq dm-org-persist--pull-process
          (make-process
           :name "dm-org-persist-pull"
           :buffer (get-buffer-create dm-org-persist-pull-buffer-name)
           :noquery t
           :connection-type 'pipe
           :command (append (list dm-org-persist-git-executable "pull")
                            dm-org-git-pull-args
                            (when dm-org-git-remote (list dm-org-git-remote)))
           :sentinel #'dm-org-persist--pull-sentinel))))

(defun dm-org-persist--pull-sentinel (process _event)
  "Report the outcome of PROCESS and refresh what it changed."
  (unless (process-live-p process)
    (setq dm-org-persist--pull-process nil)
    (if (not (dm-org-persist--exited-cleanly-p process))
        (dm-org-persist--pull-failed)
      (let* ((repo (dm-org-persist-repository))
             ;; Measured against the upstream, not HEAD: `OLD..HEAD' would also
             ;; count the local commits the rebase replayed under new hashes,
             ;; and reporting those as newly arrived would be a lie.
             (arrived (if dm-org-persist--pull-head
                          (dm-org-persist--count
                           repo (concat dm-org-persist--pull-head "..@{u}"))
                        0)))
        (if (zerop arrived)
            ;; Nothing arrived, so nothing on disk changed and what is on
            ;; screen is already right.  Reconciliation still gets a chance
            ;; to retry work an earlier pull deferred due to unsaved edits.
            ;; Redraw only if such a retry actually changed something; this
            ;; normally keeps `dm-org-persist-pull-and-redo' to one rebuild.
            (progn
              (message "✓ Org agenda already up to date")
              (when (dm-org-persist--run-after-pull-hook repo)
                (dm-org-persist--redraw-agendas)))
          (message "✓ Org agenda pulled (%d new commit%s)"
                   arrived (if (= arrived 1) "" "s"))
          (dm-org-persist--refresh-agenda))
        ;; The push `dm-org-persist-flush' was not allowed to start, reissued
        ;; now that it can succeed.
        (when (and dm-org-git-auto-push
                   (> (dm-org-persist--count repo "@{u}..HEAD") 0))
          (dm-org-persist-push))))))

(defun dm-org-persist-pull ()
  "Fetch the Org repository and rebase onto its upstream.

Anything still queued is committed first, so a mutation made moments ago
rebases as a commit rather than riding through the autostash.  The push
that commit would normally trigger is held back until after the rebase:
it would race the very commits it uploads, and would be refused as a
non-fast-forward anyway.

The pull runs asynchronously; its output collects in
`dm-org-persist-pull-buffer-name'.  Any live agenda buffer is rebuilt once
it brings something in, or if post-pull reconciliation repairs previously
deferred external changes.  See `dm-org-git-pull-args' for the pull itself."
  (interactive)
  (let ((repo (dm-org-persist-repository)))
    (cond
     ((null repo)
      (dm-org-persist--warn "No Git repository found for %s"
                            (abbreviate-file-name (or (bound-and-true-p org-directory) "?"))))
     ((dm-org-persist--busy-p repo)
      (dm-org-persist--warn
       "Not pulling: a merge, rebase, or bisect is already in progress in %s"
       (abbreviate-file-name repo)))
     ((process-live-p dm-org-persist--pull-process)
      (message "Org agenda pull already running"))
     ;; A rebase rewrites the commits an in-flight push is uploading.
     ((process-live-p dm-org-persist--push-process)
      (message "Org agenda push in flight — try the pull again in a moment"))
     ((not (dm-org-persist--upstream-p repo))
      (message "Org agenda branch has no upstream to pull from"))
     ((not (dm-org-persist--save)) nil)
     (t
      (let ((dm-org-git-auto-push nil))
        (dm-org-persist-flush))
      (if dm-org-persist--events
          ;; `dm-org-persist-flush' keeps the queue when a commit fails, and it
          ;; has already warned.  Rebasing over uncommitted mutations would
          ;; hand them to the autostash, which is what the flush was for.
          (dm-org-persist--warn "Not pulling: queued Org events are still uncommitted")
        (setq dm-org-persist--pull-head (dm-org-persist--head repo))
        (with-current-buffer (get-buffer-create dm-org-persist-pull-buffer-name)
          (erase-buffer))
        (dm-org-persist--start-pull repo))))))

(defun dm-org-persist-pull-and-redo (&optional all)
  "Pull the Org repository, then rebuild the agenda in this buffer.

ALL is passed through to `org-agenda-redo', so a prefix argument still
means what it means there.

The rebuild does not wait for the pull, because the pull is a git process
and waiting on it would freeze the keystroke: this redraws what is on
disk now, and `dm-org-persist--pull-sentinel' rebuilds again if anything
arrived.  A pull that is refused, or that finds nothing new, therefore
costs exactly the one rebuild a plain redo would have."
  (interactive "P" org-agenda-mode)
  (dm-org-persist-pull)
  (org-agenda-redo all))

(with-eval-after-load 'org-agenda
  ;; `C-c C-u' is unbound in `org-agenda-mode-map', and a C-c chord falls
  ;; through evil's motion state to the buffer's own map, so this needs no
  ;; evil-specific handling.  `SPC o p' already reaches the same command from
  ;; the agenda; this is the one-chord version for when it is already open.
  (define-key org-agenda-mode-map (kbd "C-c C-u") #'dm-org-persist-pull)
  ;; A command remap rather than a `g r' of our own, for two reasons.  The key
  ;; belongs to evil-org-agenda's motion-state map, set up from `dm-org', so a
  ;; literal rebinding here would be a load-order race; the remap is found
  ;; whatever map the key came from, and covers plain `r' as well.  And it is
  ;; keys only: Org itself calls `org-agenda-redo' from filters, bulk edits,
  ;; and view changes, and `dm-org-persist--refresh-agenda' calls it from the
  ;; pull's own sentinel -- advising the command would turn every one of those
  ;; into a pull, the last of them recursively.
  ;;
  ;; `g R' (`org-agenda-redo-all') is deliberately left alone: it reaches
  ;; `org-agenda-redo' by a function call, not a key, so it stays a plain
  ;; rebuild of every view in the buffer.
  (define-key org-agenda-mode-map
              [remap org-agenda-redo] #'dm-org-persist-pull-and-redo))

(provide 'dm-org-persist)
;;; dm-org-persist.el ends here
