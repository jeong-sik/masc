### Fixed

- When a signal ends the command that `masc-deployment-preflight-helper
  lease-run` runs, or the preparation command of `lease-handoff`, the helper
  now exits with 128 plus the host signal number, as a shell does: 143 for
  SIGTERM and 137 for SIGKILL. A SIGTERM or SIGINT that the helper forwards
  to the command is reported the same way. It added OCaml's negative signal number
  instead, so SIGTERM exited 117 and SIGKILL 121 (#52223, #PENDING).
