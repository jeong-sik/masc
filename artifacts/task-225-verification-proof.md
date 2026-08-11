# task-225 verification proof

Base under review: PR #28181 head `acac7253a8faed28b356c36eca80cc953bd0d07c`.

## Current source

`lib/credential_observation/gh_auth_status.ml:42-49` defines `json_kind` with only the eight surviving `Yojson.Safe.t` constructors. There is no `| \`Tuple _ -> "tuple"` or `| \`Variant _ -> "variant"` arm in the current PR head.

## Verification

- `bash scripts/lint/no-yojson-3-dead-arms.sh` — exit 0; `OK: no yojson 3.0 dead arms found`.
- `dune exec --root . --build-dir _build-task225 test/test_gh_auth_status.exe` — exit 0; 15 tests passed.
- The focused test required the existing 2-line `Runtime_error` declaration from commit `c3d0246a6c` because the PR base otherwise fails before reaching `gh_auth_status`; no credential parser source change was needed.
