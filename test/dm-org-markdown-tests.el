;;; dm-org-markdown-tests.el --- Tests for dm-org-markdown  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root:  bin/test dm-org-markdown

;;; Code:

(require 'ert)
(require 'dm-org-markdown)

(ert-deftest dm-org-markdown-standup-example ()
  (should (equal
           (dm-org-to-markdown
            (concat "*Yesterday*:\n"
                    "- [[https://j.example/browse/API-1][API-1]] merged: fix\n"
                    "- [[https://j.example/browse/API-2 ][API-2]] blocked\n"
                    "*Today*:\n"
                    "- [[https://j.example/browse/API-3 ][API-3]] WIP\n"
                    "*Blocked / Waiting*:\n"
                    "- API-2: team is [[https://s.example/p1][investigating]] \n"
                    "- [[https://g.example/pull/1][API-4]]: [[https://s.example/p?a=1&b=2][Kafka role]] from VES: pending\n"))
           (concat "**Yesterday**:\n"
                   "- [API-1](https://j.example/browse/API-1) merged: fix\n"
                   "- [API-2](https://j.example/browse/API-2) blocked\n"
                   "\n"
                   "**Today**:\n"
                   "- [API-3](https://j.example/browse/API-3) WIP\n"
                   "\n"
                   "**Blocked / Waiting**:\n"
                   "- API-2: team is [investigating](https://s.example/p1)\n"
                   "- [API-4](https://g.example/pull/1): [Kafka role](https://s.example/p?a=1&b=2) from VES: pending\n"
                   "\n"))))

(ert-deftest dm-org-markdown-bare-link-and-inline ()
  (should (equal (dm-org-to-markdown "see [[https://x.example]] and /it/ ~c~ =v=")
                 "see <https://x.example> and *it* `c` `v`\n")))

(ert-deftest dm-org-markdown-heading ()
  (should (equal (dm-org-to-markdown "** Title") "## Title\n")))

(ert-deftest dm-org-markdown-link-abbreviations ()
  (let ((ab '(("jira" . "https://j.example/browse/")
              ("gh" . "https://g.example/%s/x"))))
    (should (equal (dm-org-to-markdown
                    "[[jira:API-1][API-1]] [[gh:a/b][pr]] [[nope:z][z]]" ab)
                   (concat "[API-1](https://j.example/browse/API-1) "
                           "[pr](https://g.example/a/b/x) [z](nope:z)\n")))))

(ert-deftest dm-org-markdown-region-reads-header-abbreviations ()
  (with-temp-buffer
    (insert "#+LINK: jira https://j.example/browse/\n- [[jira:A-1][A-1]]\n")
    (transient-mark-mode 1)
    (goto-char (point-min))
    (forward-line 1)
    (set-mark (point))
    (goto-char (point-max))
    (activate-mark)
    (let ((kill-ring nil))
      (dm-org-region-to-markdown (region-beginning) (region-end))
      (should (equal (car kill-ring)
                     "- [A-1](https://j.example/browse/A-1)\n\n")))))

(provide 'dm-org-markdown-tests)
;;; dm-org-markdown-tests.el ends here
