# task-245 verification proof (fresh exact run)

Branch: sangsu/task-245-github-test-fscompat
Source revision before this proof refresh: eae3bf7b19

## Change under test

The isolated copied GitHub identity test boundary supplies the production
module's test-only dependencies:

- test/keeper_github_identity/dune declares fs_compat and the required Eio
  library modules.
- test/keeper_github_identity/fs_compat.ml provides recursive cleanup.
- test/keeper_github_identity/eio_context.ml provides the test clock/context
  boundary.
- test/keeper_github_identity/keeper_secret_redaction.ml provides streaming
  redaction.
- test/keeper_github_identity/process_eio.ml provides the streaming process
  boundary.

Production GitHub identity behavior is unchanged by this test-boundary fix.

## Acceptance verification

Command:

    dune build --root . --build-dir _build-task245-full4 @check @install

Result: exit status 0. The only output was the Dune warning that option
"-j-std" is deprecated.

Command:

    dune exec --root . --build-dir _build-task245-full4 test/keeper_github_identity/test_keeper_github_identity.exe

Result: exit status 0. Alcotest reported "Test Successful" with 9 tests,
covering environment isolation, fake-gh login/effective identity, symlink
rejection, nonblocking projection, observation, and malformed identity.

Command:

    git diff --check

Result: exit status 0.
