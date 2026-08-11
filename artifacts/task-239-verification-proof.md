# task-239 verification proof

Commit under review: `908a2e5c42e4b1eaac71aac2e7d41f931d413aa8` (`fix: validate GitHub identity hostnames`). The proof is intentionally self-contained because the large production source files exceed the verifier's artifact page limit.

## Required production evidence

`lib/keeper/keeper_github_identity.ml` validates before the token-bearing observation path:

```ocaml
let observe ~base_path ~keeper_name ~hostname =
  match validate_hostname hostname with
  | Error _ as error -> error
  | Ok hostname ->
    match projected_env ~base_path ~keeper_name with
    | Error _ as error -> error
    | Ok effective_env ->
      ...
      auth_result_of_command ~redact ~env:effective_env ~hostname
```

The validator allows `github.com` and an exact configured Enterprise allowlist, while rejecting malformed and unapproved hosts. The same guard is applied to CLI login, status, and logout before their token-bearing subprocesses.

`lib/server/server_dashboard_http_keeper_api.ml` rejects an invalid GET hostname before observation:

```ocaml
match Keeper_github_identity.validate_hostname hostname with
| Error message ->
  Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
    (error_json message)
| Ok hostname ->
  Keeper_github_identity.observe ~base_path:config.base_path
    ~keeper_name:name ~hostname
```

`lib/server/server_dashboard_http_keeper_api_post.ml` applies the same validation before `login_env` and the streaming login process.

## Regression coverage

`test/keeper_github_identity/test_keeper_github_identity.ml:94` covers public GitHub normalization, approved Enterprise normalization, arbitrary-host rejection, malformed URL/port/path rejection, and observation rejection before `gh api`. The approved Enterprise fake-`gh` login/status path remains covered.

## Verification

- `dune exec --root . --build-dir _build-task239 test/keeper_github_identity/test_keeper_github_identity.exe` — exit 0; 9 tests passed.
- `dune build --root . --build-dir _build-task239 lib/masc.cmxa lib/server/masc_server.cmxa bin/main_eio.exe` — exit 0.
- `git diff --check` — exit 0.
