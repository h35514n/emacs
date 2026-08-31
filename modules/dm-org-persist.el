;;; dm-org-persist.el --- Commit Org agenda mutations to Git  -*- lexical-binding: t; -*-

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
;; `dm-org-agenda-persist' is the semantic half that produces those events.
;;
;; Why events rather than a hook on saving or on `org-agenda-finalize-hook':
;; a refresh is a presentation event.  Redrawing the agenda says nothing about
;; the plan, so nothing here keys off it.  Only a caller asserting that a
;; domain mutation happened can start a commit.
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
;; A consequence worth knowing: a hand edit to an Org file inside the debounce
;; window rides along in that commit without being named in the message.  The
;; change is real and belongs in history, so it is committed rather than
;; dropped, but the message will not describe it.
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

;;; Code:

(require 'subr-x)

(declare-function org-agenda-files "org" (&optional unrestricted archives))
(declare-function org-save-all-org-buffers "org" ())
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

(defconst dm-org-persist-push-buffer-name "*dm-org-persist-push*"
  "Buffer holding the output of the most recent `git push'.")

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
                    (format "%d agenda changes" (length subjects))))
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
    (if (and (eq (process-status process) 'exit)
             (zerop (process-exit-status process)))
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

The commit does not happen here.  Events accumulate until
`dm-org-persist-debounce-seconds' of quiet, so a burst of agenda commands
becomes one commit."
  (when (and dm-org-persist-enabled event)
    (push event dm-org-persist--events)
    (dm-org-persist--cancel-timer)
    (setq dm-org-persist--timer
          (run-with-timer dm-org-persist-debounce-seconds nil #'dm-org-persist-flush))))

(defun dm-org-persist--save ()
  "Save modified Org buffers.  Return non-nil on success."
  (condition-case err
      (progn (org-save-all-org-buffers) t)
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
      (let* ((events (reverse dm-org-persist--events))
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

(provide 'dm-org-persist)
;;; dm-org-persist.el ends here
