### Fixed

- A Git read that stops part-way, a timeout included, no longer carries what it had read on standard output into its failure text. `Repo_git.run_git` takes whether a command reads data or reports on standard output; only a reporting command such as `merge` or `commit` has its standard output quoted, and the search's own exception from #52174 is the same rule (#PENDING).
