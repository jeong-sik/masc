### Fixed

- A Git read that stops part-way, a timeout included, no longer carries what it had read on standard output into its failure text: `Repo_git` failures quote only the exit status and standard error, the rule #52174 gave the search alone. When git's output cannot be read, the error says which field or byte offset was wrong instead of quoting the status row, worktree record, branch record or search row (#PENDING).
