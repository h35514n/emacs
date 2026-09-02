;;; dm-org-file-persist.el --- Commit saved files under org-directory  -*- lexical-binding: t; -*-

;;; Commentary:

;; The second producer of events for `dm-org-persist'.  Where
;; `dm-org-agenda-persist' watches the agenda and describes what a command did
;; to the plan, this watches saving and describes what became of a file:
;;
;;     Edit org/notes/reading.md
;;     Add org/links/scratch.org
;;
;; It exists because `org-agenda-files' is a small part of what lives under
;; `org-directory'.  Notes, link collections, templates, archives, and an
;; encrypted journal share a repository with the agenda files but reach Git
;; only by hand.  Several mutations that do start in the agenda are in the same
;; position: `org-agenda-set-tags', `org-agenda-set-effort',
;; `org-agenda-set-property', the clocking commands, and the scheduling
;; `dm-org-agenda-plan-apply' performs directly through `org-schedule' all
;; write to disk without any instrumented command describing them.  One rule
;; keyed on saving covers all of it.
;;
;; Why a hook here, when the agenda half rejects hooks:
;;
;; `dm-org-agenda-persist' cannot use `org-agenda-finalize-hook' because a
;; redraw is a presentation event; it has to synthesize the assertion "a
;; mutation happened" from a before-and-after pair bracketing one command.  A
;; save needs no such synthesis.  It is already the assertion -- the file on
;; disk is not what it was -- and `after-save-hook' is where it is announced.
;;
;; Why `git status' gates the queue:
;;
;; `dm-org-persist--commit' stages by explicit pathspec, and `git add' on a
;; path Git ignores exits non-zero.  That failure makes the flush return
;; `retry' and keep its queue, so one save of an ignored file -- `.DS_Store'
;; under `org-directory', say -- would stop every later agenda commit, not just
;; its own.  Running
;;
;;     git status --porcelain -- FILE
;;
;; before queueing settles both questions that matter in a single process:
;; empty output means Git has nothing to record for the path, whether because
;; it is ignored or because the save left the content Git already has, and
;; non-empty output carries the status code that says whether the file is new.
;; Nothing is queued that the commit could not honor.
;;
;; Why events are marked `:generic':
;;
;; A save is the weakest description of a change there is.  When an agenda
;; command has already described the same file in domain terms, the file event
;; is noise, and `dm-org-persist-relevant-events' drops it.  That case is the
;; ordinary one rather than an edge: `dm-org' advises eleven agenda commands to
;; save every Org buffer, so an instrumented command saves its own file from
;; inside the advice describing it, and this hook sees that save.
;;
;; What is deliberately not covered:
;;
;;   - Deletions and renames.  `after-save-hook' does not run for either, and
;;     `dm-org-persist--managed-files' stages only existing regular files.  A
;;     file deleted in Dired stays deleted and uncommitted until something else
;;     stages it.
;;   - Edits made outside Emacs.  Another editor over the same directory writes
;;     without running a hook here; those arrive, if at all, as commits through
;;     `dm-org-persist-pull'.
;;   - Anything outside `org-directory'.  The repository root is typically an
;;     ancestor of it and holds unrelated work -- which is the same reason
;;     `dm-org-persist' stages by pathspec rather than with `git add .'.

;;; Code:

(require 'dm-org-persist)

(defvar org-directory)

(defgroup dm-org-file-persist nil
  "Commit files under `org-directory' as they are saved."
  :group 'dm-org-persist)

;;; ————————————————————————————
;;; Configuration
;;; ————————————————————————————

(defcustom dm-org-file-persist-enabled t
  "Whether saving a file under `org-directory' records an event.

Setting this to nil leaves the hook installed but inert.  Persistence as a
whole is governed by `dm-org-persist-enabled'."
  :type 'boolean
  :group 'dm-org-file-persist)

(defcustom dm-org-file-persist-directories nil
  "Directories whose files are recorded when saved.

nil means `org-directory' alone, resolved at each save rather than at load
time: `org-directory' is set by the `org' `use-package' form and is not
reliably bound when this module loads."
  :type '(choice (const :tag "`org-directory'" nil)
                 (repeat directory))
  :group 'dm-org-file-persist)

(defcustom dm-org-file-persist-exclude-regexp
  "/\\.git/\\|~\\'\\|\\.elc\\'"
  "Files whose truename matches this are never recorded.

Git's ignore rules do most of this work already, since
`dm-org-file-persist-status' queues nothing Git would refuse to stage.  This
is for the remainder: paths Git would happily track that are still not worth
a commit of their own."
  :type 'regexp
  :group 'dm-org-file-persist)

;;; ————————————————————————————
;;; Which saves are ours
;;; ————————————————————————————

(defun dm-org-file-persist--roots ()
  "Return the directories this module watches, as truenames.

Nonexistent directories are dropped, so a stale entry in
`dm-org-file-persist-directories' narrows the watch rather than breaking it."
  (delq nil
        (mapcar (lambda (root)
                  (when (and (stringp root) (file-directory-p root))
                    (file-name-as-directory (file-truename root))))
                (or dm-org-file-persist-directories
                    (and (boundp 'org-directory)
                         (stringp org-directory)
                         (list org-directory))))))

(defun dm-org-file-persist-in-scope-p (file)
  "Return FILE's truename when saving it should record an event, else nil.

The truename is what comes back rather than t because every caller needs
it: it is what gets compared against the repository root and what the event
names."
  (when (stringp file)
    (let ((true (file-truename file)))
      (and (not (string-match-p dm-org-file-persist-exclude-regexp true))
           (seq-some (lambda (root) (string-prefix-p root true))
                     (dm-org-file-persist--roots))
           true))))

(defun dm-org-file-persist-status (repo file)
  "Return the Git status code for FILE in REPO, or nil when there is none.

FILE is repository-relative.  The code is the two-character porcelain field
with its padding trimmed: \"??\" for a path Git does not track, \"M\" for a
tracked file carrying unstaged changes, and so on.

Nil means Git has nothing to record for this path -- it is ignored, or the
save left the content Git already has.  Either way, an event would name a
file the commit could not honor."
  (pcase-let ((`(,code . ,out)
               (dm-org-persist--git repo "status" "--porcelain" "--" file)))
    (when (zerop code)
      (when-let* ((line (car (split-string out "\n" t)))
                  (status (string-trim (substring line 0 (min 2 (length line))))))
        (unless (string-empty-p status) status)))))

;;; ————————————————————————————
;;; Recording a save
;;; ————————————————————————————

(defun dm-org-file-persist-event (file relative status)
  "Return the event describing STATUS for FILE.

RELATIVE is FILE\='s path within the repository, which is how the subject and
the metadata name it -- the same way `git log --stat' does.

A path Git does not yet track was added rather than edited, and the subject
says so; every other status reads as an edit, since `after-save-hook' cannot
report a deletion or a rename."
  (list :subject (format "%s %s" (if (equal status "??") "Add" "Edit") relative)
        :data (list (cons 'type "file")
                    (cons 'file relative)
                    (cons 'status status)
                    (cons 'time (format-time-string "%FT%T%z")))
        :files (list file)
        :generic t))

(defun dm-org-file-persist-record (file)
  "Record the save of FILE, and return the event queued, or nil.

Nil means the save was none of this module's business: persistence is off,
`dm-org-persist' is doing the saving itself, FILE lives outside the watched
directories or outside the repository, or Git has nothing to record for it."
  (when-let* (((and dm-org-file-persist-enabled dm-org-persist-enabled))
              ((not (dm-org-persist-saving-p)))
              (true (dm-org-file-persist-in-scope-p file))
              (repo (dm-org-persist-repository))
              ((string-prefix-p repo true))
              (relative (file-relative-name true repo))
              (status (dm-org-file-persist-status repo relative))
              (event (dm-org-file-persist-event true relative status)))
    (dm-org-persist event)
    event))

(defun dm-org-file-persist--after-save-h ()
  "Record the save of a file under `org-directory'.  For `after-save-hook'.

Every failure is contained here, for the same reason it is in
`dm-org-agenda-persist--record': recording history must never be able to
break the thing that triggered it, and here that thing is `C-x C-s'."
  (condition-case err
      (dm-org-file-persist-record buffer-file-name)
    (error
     (display-warning 'dm-org-file-persist
                      (format "Could not record the save of %s: %s"
                              (abbreviate-file-name (or buffer-file-name "?"))
                              (error-message-string err))
                      :warning))))

(defun dm-org-file-persist-install ()
  "Record saves of files under `org-directory'."
  (interactive)
  (add-hook 'after-save-hook #'dm-org-file-persist--after-save-h))

(defun dm-org-file-persist-uninstall ()
  "Stop recording saves."
  (interactive)
  (remove-hook 'after-save-hook #'dm-org-file-persist--after-save-h))

(dm-org-file-persist-install)

(provide 'dm-org-file-persist)
;;; dm-org-file-persist.el ends here
