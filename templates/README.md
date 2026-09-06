# Tempel templates

Loaded via `tempel-path` (set in `modules/dm-snippets.el` to `templates/*.eld`).
These stack with the `tempel-collection` package, which registers itself into
`tempel-template-sources` separately.

## Provenance

The `.eld` files here are cherry-picked from
[gs-101/tempel-snippets](https://github.com/gs-101/tempel-snippets) (GPL-3.0),
a translation of [yasnippet-snippets](https://github.com/AndreaCrotti/yasnippet-snippets)
into Tempel format.

Only files filling gaps in `tempel-collection` were taken:

| File              | Why                                                  |
|-------------------|------------------------------------------------------|
| `css.eld`         | collection's `css-base.eld` is a header with no templates |
| `html.eld`        | collection's `html.eld` is a header with no templates     |
| `ruby.eld`        | collection's `ruby-base.eld` is a header with no templates |
| `elixir.eld`      | collection has no Elixir coverage                     |
| `dockerfile.eld`  | collection has no Dockerfile coverage                 |
| `makefile.eld`    | collection has no Makefile coverage                   |
| `git-commit.eld`  | collection has no git-commit coverage                 |
| `conf-unix.eld`   | collection has no conf-mode coverage                  |
| `latex.eld`       | 58 templates vs the collection's 27, near-disjoint    |

## Local modifications

`latex.eld` differs from upstream:

- Mode header widened from `latex-mode` to `latex-mode LaTeX-mode`. Belt and
  braces: AUCTeX already calls `derived-mode-add-parents` to put `latex-mode`
  in `LaTeX-mode`'s parents, so the bare header would match either way.
- `begin` and `frac` removed: the only two names that collided with
  `tempel-collection`'s `latex.eld`, which is otherwise disjoint.

Re-check both when syncing from upstream.

## Adding your own

Drop a `<mode>.eld` in here. First line is the mode(s) the templates apply to,
space-separated; `tempel-auto-reload` picks up edits without a restart.
Tempel matches via `derived-mode-p`, and also consults `major-mode-remap-alist`,
so a `python-base-mode` header covers `python-ts-mode`.
