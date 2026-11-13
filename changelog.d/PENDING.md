### Fixed

- CI: a pull request that changes only a non-OCaml input of a build rule
  (`lib/exec/parser/bash_subset.mly`, `lib/auth/account_page.css`,
  `config/tools/*.toml`, `scripts/embed-setup.py`) now runs
  `dune build @check`. The decision listed source extensions, so such a pull
  request skipped the required type-check. Every path is now a source except
  under `changelog.d/`, `dashboard/` and `docs/`, and a test holds those three
  to what the tracked dune files read (#51595).
