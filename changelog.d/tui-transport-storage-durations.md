### Changed

- Connection failures and the Storage cleanup pass spell their durations
  like the rest of the TUI (RFC tui-one-screen-grammar 6.2): `retry in 2m`
  instead of `retry in 120s`, `no answer within 1m30s` instead of `90s`,
  and the cleanup interval `간격 5m` / `every 5m` instead of `300초` /
  `300s`.
