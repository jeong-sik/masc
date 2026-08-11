# task-239 verification proof

Commit under review: `908a2e5c42e4b1eaac71aac2e7d41f931d413aa8` (`fix: validate GitHub identity hostnames`).

## Production path

- `lib/keeper/keeper_github_identity.ml:50` defines `validate_hostname`, allowing `github.com` and an exact configured Enterprise allowlist while rejecting malformed and unapproved hosts.
- `lib/keeper/keeper_github_identity.ml:409` validates before projecting the Keeper token environment or invoking `gh api`.
- `lib/keeper/keeper_github_identity.ml:513`, `:541`, and `:550` validate the CLI login, status, and logout paths before token-bearing subprocesses.
- `lib/server/server_dashboard_http_keeper_api.ml:1525` validates the GET hostname and returns a bad-request response before observation.
- `lib/server/server_dashboard_http_keeper_api_post.ml:60` validates the POST login hostname before `login_env` and process execution.

## Regression coverage

- `test/keeper_github_identity/test_keeper_github_identity.ml:94` covers public GitHub normalization, approved Enterprise normalization, arbitrary-host rejection, malformed-host rejection, and the pre-`gh api` observation guard.
- The approved Enterprise fake-`gh` path remains covered by the same test executable.

## Verification

- `dune exec --root . --build-dir _build-task239 test/keeper_github_identity/test_keeper_github_identity.exe` — exit 0; 9 tests passed.
- `dune build --root . --build-dir _build-task239 lib/masc.cmxa lib/server/masc_server.cmxa bin/main_eio.exe` — exit 0.
- `git diff --check` — exit 0.
