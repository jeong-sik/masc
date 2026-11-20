### Changed

- The Providers header's `Exhausted (observed)` count draws `◌` while the
  quota catalogue is not read yet and `✕` when reading it failed, instead of
  `unknown` for both; only the failure keeps the warning colour. A change's
  PR with no repository reads `(repository not reported)` (RFC
  tui-one-screen-grammar 6.4).
