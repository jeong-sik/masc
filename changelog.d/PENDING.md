### Fixed

- CI: the type-check script test now lists
  `docs/examples/lane-addons/operator-lesson.toml` among the files a dune
  rule reads only to run tests. `test/dune` reads that example declaration
  since #51897, so `test_dune_files_read_them_only_to_run_tests` failed on
  main and on every pull request whose `type-check` ran after the merge
  (#51897, #PENDING).
