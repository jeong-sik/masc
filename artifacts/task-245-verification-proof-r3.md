# task-245 verification evidence (fresh run)

This is a fresh verification record for commit `15f87cba36` on
`sangsu/task-245-github-test-fscompat`. It supersedes any earlier proof
file with a different evidence path.

## Required isolated test boundary

The copied `lib/keeper/keeper_github_identity.ml` test has these explicit
test-only dependencies:

- `test/keeper_github_identity/dune` declares `fs_compat` and links Eio.
- `test/keeper_github_identity/fs_compat.ml` provides recursive cleanup.
- `test/keeper_github_identity/eio_context.ml`,
  `keeper_secret_redaction.ml`, and `process_eio.ml` provide the
  clockless, streaming-redaction, and streaming-process boundaries used by
  the copied module.

No production GitHub identity behavior was changed by this task.

## Fresh verification

Run on 2026-08-12 from the worktree root:

```
dune build --root . --build-dir _build-task245-full3 @check @install
```

Exit status: 0 (only the existing `-j-std` deprecation warning).

The focused fake-gh suite was then run with:

```
dune exec --root . --build-dir _build-task245-full3 \
  test/keeper_github_identity/test_keeper_github_identity.exe
```

Exit status: 0. Result: `Test Successful`, 9 tests run, including environment
isolation, fake-gh login/effective identity, symlink rejection, nonblocking
projection, observation, and malformed identity checks.

`git diff --check` is clean.
