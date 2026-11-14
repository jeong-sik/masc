### Fixed

- The server retires expired bearer credentials and orphaned redirect stubs
  from its daily maintenance pass, first at startup and then every 24h of
  uptime. Only `masc token prune` removed them, so every expired session
  credential stayed under `.masc/auth/agents` until an operator ran it
  (#45358, #PENDING).
