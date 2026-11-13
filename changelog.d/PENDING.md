### Fixed

- `masc setup-stop-previous-owner` and `masc restart` no longer send the
  operator bearer to a port because it answered `/health` as this workspace.
  They first ask the kernel whether the process that holds the workspace
  lease is the one that announces that port as its single-user server, and
  ask again right before each request that carries the bearer. Without that
  answer no sign-in happens and no bearer leaves; the refusal says why
  (#51321, #PENDING).

### Upgrade notes

- A single-user server built before it announced its port (#51807), or one
  bound outside 127.0.0.1, cannot be confirmed by the kernel, so
  `masc restart` and the graceful stop of `masc setup` refuse it once and
  name its pid. Stop that server yourself (SIGTERM, then wait for it to
  exit) and run `masc start`; servers started from this version on are
  stopped as before (#51321, #PENDING).
