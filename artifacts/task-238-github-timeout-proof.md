# task-238 GitHub identity subprocess timeout proof

Base: PR #28215 head 06b6117cba, worktree branch sangsu/task-238-github-timeout.

Implementation:
- keeper_github_identity.ml keeps the 15-second bounded probe used by stored/effective status observation.
- CLI inherited login/logout execution now validates a positive timeout, polls waitpid(WNOHANG), sends SIGKILL at the deadline, and always waits for the child before returning exit 124.
- Streaming server login accepts and validates the 600-second bound; both the dashboard POST and H2 gateway pass the named bound explicitly, and Process_eio cancellation/timeout cleanup reaps the child.
- Test-only process and dependency shims make the isolated GitHub identity suite exercise the current production source.

Verification:
- ocamlformat --check passed for the touched OCaml source, interface, test helpers, and regression test.
- git diff --check passed.
- bash scripts/dune-local.sh build test/keeper_github_identity/test_keeper_github_identity.exe exited 0.
- bash scripts/dune-local.sh exec test/keeper_github_identity/test_keeper_github_identity.exe: 11 tests passed in 0.525s, including bounded capture/status and inherited logout timeout regressions.
- bash scripts/dune-local.sh build lib/masc.cmxa exited 0.

Bounded verifier snapshots (each kept below the artifact read limit):
- `artifacts/task-238-identity-timeout-excerpt.md` contains bounded capture/inherited wait and kill/reap behavior.
- `artifacts/task-238-dashboard-login-excerpt.md` contains the dashboard POST's explicit timeout call.
- `artifacts/task-238-timeout-regression-excerpt.md` contains the hanging status/logout regression tests.
