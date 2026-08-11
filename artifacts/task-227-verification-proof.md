# task-227 verification proof

PR #28181 head: `acac7253a8faed28b356c36eca80cc953bd0d07c`.

## Fail-closed parser path

`lib/credential_observation/gh_auth_status.ml:225-230` derives `account` from `login` and rejects a successful row with no non-empty account before it can become an entry:

```ocaml
let* login = string_field context "login" fields in
let account = account_of_login login in
let* () =
  match outcome, account with
  | Logged_in, None -> Error (context ^ " success is missing a non-empty login")
  | Logged_in, Some _ | (Login_failed | Timed_out), _ -> Ok ()
```

## Regression input

`test/test_gh_auth_status.ml:294-298` includes the exact malformed shape (`state = success`, `login = ""`) in the schema-decline cases. `check_schema_declines` asserts a typed schema error, no partial entries, and an `unknown` verdict.

## Verification

- `dune exec --root . --build-dir _build-task227 test/test_gh_auth_status.exe` — exit 0; 15 tests passed.
- `git log -S 'success is missing a non-empty login' --oneline` — `acac7253a8 fix(credential): close gh auth schema edges`.
- Existing stale-base compile prerequisite `eaba05e1e8` declares `Runtime_error`; it is unrelated to the parser change.
