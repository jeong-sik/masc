# Installed Lazygit: parent, detail and full view

Manual terminal observation on 2026-10-29 KST of Homebrew Lazygit **0.59.0**,
darwin/arm64, with Git 2.50.1. The [manifest](manifest.json) records executable
and retained-file digests. A private HOME and [config](config.yml) disabled
fetching, refreshing, updates, tips and the command log. The repository had
18 fabricated commits, no remote and no private project content.
[Its exported history](synthetic-history.export) preserves the synthetic objects.

The `lazygit --path <repo> --use-config-file <config> log` entry was observed
at [80×24](commits-80x24.txt), [120×36](commits-120x36.txt) and
[160×40](commits-160x40.txt). All 18 commit rows fit beside Patch. At 80
columns, hash/time/author/graph fields consumed most of the left pane and
subjects truncated to their first characters. Wider samples exposed subjects.
A separate invocation with `--screen-mode full` and the same initially selected
commit exposed subjects at [80×24](commits-full-80x24.txt), while covering Patch.
This is a structural observation, not a performance comparison with a queue;
author and hash fields have a different purpose in Git history.

| Input | Observation |
| --- | --- |
| `j` | Selected commit 17 and [updated Patch](selected-17-80x24.txt) without Enter. |
| Enter, Esc | [Commit files](commit-files-80x24.txt) opened; [return](return-from-files-80x24.txt) retained commit 17 and position 2/18. |
| `?`, Esc | [Keybinding popup](help-80x24.txt) covered part of its parent; [return](return-from-help-80x24.txt) retained the same commit. |
| Tab | Moved to [Stash](after-tab-80x24.txt), not Patch. |

These observations support familiar selection/detail/return keys and retained
parent identity. They do not justify copying every shortcut or adding a second
focusable MASC Queue pane: its preview has no editing task. No mutation binding
was invoked. Lazygit's `f` is Fixup; MASC's preference command must remain
explicitly disclosed rather than described as universally familiar.

These are actual terminal text captures and [manual notes](actions.jsonl), not
pixel-readability, task-time, error-rate or physical-IME measurements. To
reproduce, import the export into a new scratch Git repository, check out
`main`, and run the recorded Lazygit version with the retained config.

