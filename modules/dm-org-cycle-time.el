;;; dm-org-cycle-time.el --- Ticket cycle-time table from Org LOGBOOKs  -*- lexical-binding: t; -*-

;;; Commentary:

;; Builds the "Ticket Durations" table in TICKETS.org.  For every heading
;; whose title starts with a ticket ID (`API-123:'), the LOGBOOK state-change
;; lines give three milestones: the first WIP, the first IN_REVIEW and the
;; latest APPROVED.  The table shows weekdays between them.
;;
;; The ticket ID is read from the heading as displayed, so a heading whose
;; label is an Org link (`[[jira:API-1][API-1]]: Title') matches like a plain
;; one.
;;
;; Put `#+BEGIN: cycle-time' and `#+END:' lines where the table belongs.  The
;; table updates on `C-c C-c' and on every save of an Org buffer that has
;; such a block, so the file needs no code or file-local variables.

;;; Code:

(require 'org)
(require 'subr-x)

(defconst dm-org-cycle-time--ticket-regexp "\\`\\(API-[0-9]+\\):"
  "Regexp matching a ticket ID at the start of a displayed heading.")

(defconst dm-org-cycle-time--state-regexp
  (concat "^[ \t]*- State \"\\(WIP\\|IN_REVIEW\\|APPROVED\\)\".*"
          "\\[\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)[^]]*\\]")
  "Regexp matching a milestone state-change line in a LOGBOOK.")

(defun dm-org-cycle-time--ticket ()
  "Return the ticket ID of the heading at point, or nil."
  (let ((title (org-link-display-format (org-get-heading t t t t))))
    (when (string-match dm-org-cycle-time--ticket-regexp title)
      (match-string 1 title))))

(defun dm-org-cycle-time--milestones (end)
  "Return (STARTED REVIEWED APPROVED) ISO dates from the LOGBOOK before END."
  (let (started reviewed approved)
    (when (re-search-forward "^[ \t]*:LOGBOOK:[ \t]*$" end t)
      (let ((log-end (save-excursion
                       (re-search-forward "^[ \t]*:END:[ \t]*$" end t))))
        (when log-end
          (while (re-search-forward dm-org-cycle-time--state-regexp log-end t)
            (let ((state (match-string 1))
                  (date (match-string 2)))
              (pcase state
                ("WIP" (when (or (null started) (string< date started))
                         (setq started date)))
                ("IN_REVIEW" (when (or (null reviewed) (string< date reviewed))
                               (setq reviewed date)))
                ("APPROVED" (when (or (null approved) (string< approved date))
                              (setq approved date)))))))))
    (list started reviewed approved)))

(defun dm-org-cycle-time--weekdays (from to)
  "Return signed weekdays from FROM to TO (ISO dates), or \"\" if either is nil.
Count includes FROM and excludes TO.  Reversed dates give a negative count."
  (if (not (and from to))
      ""
    (let* ((start (org-time-string-to-absolute from))
           (end (org-time-string-to-absolute to))
           (day (min start end))
           (limit (max start end))
           (count 0))
      (while (< day limit)
        ;; Absolute dates modulo 7: Sunday=0, Saturday=6.
        (when (<= 1 (% day 7) 5)
          (setq count (1+ count)))
        (setq day (1+ day)))
      (* (if (> start end) -1 1) count))))

(defun dm-org-cycle-time--short-date (date)
  "Format ISO DATE as MM/DD, or \"\" when DATE is nil."
  (if date (subst-char-in-string ?- ?/ (substring date 5)) ""))

(defun dm-org-cycle-time--row (ticket started reviewed approved)
  "Return a table row for TICKET from its milestone dates."
  (list ticket
        (dm-org-cycle-time--short-date started)
        (dm-org-cycle-time--weekdays started reviewed)
        (dm-org-cycle-time--short-date reviewed)
        (dm-org-cycle-time--weekdays reviewed approved)
        (dm-org-cycle-time--short-date approved)
        (dm-org-cycle-time--weekdays started approved)))

(defun dm-org-cycle-time-table ()
  "Return the cycle-time table for the current Org buffer."
  (let (rows)
    (save-excursion
      (save-restriction
        (widen)
        (org-map-entries
         (lambda ()
           (when-let* ((ticket (dm-org-cycle-time--ticket)))
             (let ((end (save-excursion (outline-next-heading) (point))))
               (pcase-let ((`(,started ,reviewed ,approved)
                            (save-excursion
                              (dm-org-cycle-time--milestones end))))
                 (when (or started reviewed approved)
                   (push (dm-org-cycle-time--row
                          ticket started reviewed approved)
                         rows)))))))))
    (append '(("Ticket" "Started" "WIP" "In review" "PR" "Approved" "Total")
              hline)
            (nreverse rows))))

;;;###autoload
(defun org-dblock-write:cycle-time (_params)
  "Write the cycle-time table for a `#+BEGIN: cycle-time' dynamic block."
  (require 'org-table)
  (insert (orgtbl-to-orgtbl (dm-org-cycle-time-table) nil))
  (org-table-align))

(defun dm-org-cycle-time--update-on-save ()
  "Update `cycle-time' dynamic blocks in the current buffer."
  (when (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-min))
            (re-search-forward "^[ \t]*#\\+BEGIN: cycle-time\\b" nil t)))
    (org-update-all-dblocks)))

(add-hook 'org-mode-hook
          (lambda ()
            (add-hook 'before-save-hook
                      #'dm-org-cycle-time--update-on-save nil t)))

(provide 'dm-org-cycle-time)
;;; dm-org-cycle-time.el ends here
