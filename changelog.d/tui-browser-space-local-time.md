### Changed

- The Browser lane's SDK Space row reads its observation moment in the
  local zone (`observed 14:05:06`, a date on another day) instead of a UTC
  ISO timestamp, and a client with no Space observation reads `SDK Space
  control: not reported` (RFC tui-one-screen-grammar 6.1 and 6.4).
