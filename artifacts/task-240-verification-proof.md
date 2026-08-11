# task-240 verification proof

## Scope

- Task: task-240 — key inline credentials by a secret-derived account scope.
- Producer branch: `sangsu/task-240-quota-scope`.
- Reviewed PR head: `10a74fe4686440db4863a8394928d5007e2d69fc` (`fix/quota-window-credential-scope`).
- Changed files:
  - `lib/runtime/dune`
  - `lib/runtime/runtime_quota_window.ml`
  - `lib/runtime/runtime_quota_window.mli`
  - `test/test_runtime_quota_window.ml`

## Contract evidence

1. `lib/runtime/runtime_quota_window.ml` adds the `Credential_inline` scope variant. For `Runtime_schema.Inline value`, it derives a stable SHA-256 hex key from a domain-separated value (`runtime-quota-inline\\000` plus the secret). The inline secret is never stored in the scope key, and two rows with the same inline secret therefore share one quota window.
2. `test/test_runtime_quota_window.ml` adds `test_shared_inline_credential_scope_demotes_siblings`. It maps `row_a` and `row_b` to the same inline credential but different provider row ids, records exhaustion through `row_a`, and asserts both rows move to the tail while a separate inline credential remains ahead.
3. `lib/runtime/runtime_schema.ml` retains the supported `Inline of string` credential variant; the change only updates its quota-scope projection.
4. `lib/runtime/dune` declares the `digestif` dependency required by the runtime quota library.

## Verification commands and observed output

```text
$ git diff --check
(exit 0, no output)

$ bash -n scripts/dune-local.sh
(exit 0, no output)

$ bash scripts/dune-local.sh build test/test_runtime_quota_window.exe
(exit 0)
[dune-local] command: dune build --root .../task-240-quota-scope test/test_runtime_quota_window.exe

$ bash scripts/dune-local.sh exec test/test_runtime_quota_window.exe
Test Successful in 0.013s. 11 tests run.
[OK] demote / shared inline credential demotes siblings
```

The focused build and test were run after adding the `digestif` dependency and the inline-scope regression. Full repository tests were not run.
