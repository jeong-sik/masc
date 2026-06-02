# RFC-0209 Evidence Appendix — diagnosis trace

Companion to `RFC-0209-local-sandbox-credential-boundary.md` (originally drafted as RFC-0207). Records the
verification trace so a reviewer can reproduce the CRITICAL finding without
re-running the investigation.

## Verified facts (all via Read / `git config`, not grep-stdout)

1. `lib/exec/exec_dispatch.ml:122-133` — `resolve_host_env`:
   ```ocaml
   let resolve_host_env = function
     | [] -> None
     | env_bindings ->
         let overrides = resolve_env env_bindings |> Array.to_list in
         let override_keys = List.map env_key overrides in
         let inherited =
           Unix.environment () |> Array.to_list
           |> List.filter (fun e -> not (List.mem (env_key e) override_keys))
         in
         Some (Array.of_list (inherited @ overrides))
   ```
   No `Env_keeper_scrub`. `[]` → `None` (ambient inherit); non-empty → full
   `Unix.environment ()` merged. `lib/exec/` has zero `Env_keeper_scrub` refs.

2. `lib/process/process_eio.ml:116-118` — `default_env None = Unix.environment ()`;
   `:485-495` — `Eio.Process.spawn ~cwd ?env` (None ⇒ inherit parent).

3. `lib/keeper/agent_tool_execute_runtime.ml:~120` — Local branch:
   `Local -> Ok (Masc_exec.Sandbox_target.host (), [])` (no env, no scope).

4. `lib/keeper/repo_cli_credentials.ml:259-266` — `process_env` /
   `keeper_process_env` defined; `grep` over `lib bin test` (excluding the
   definition file) → only the `.mli` declaration. Zero production callers.
   `compose_base_with_repo_cli_config` → one test caller
   (`test/test_env_git_noninteractive.ml:178`).

5. `lib/keeper/dev_exec_allowlist.ml:16-17` — `Gh` and `Git` both in
   `dev_programs`. `Ssh` NOT in the list (line 13 is `Env`) → ssh vector
   blocked. `lib/exec_policy.ml:60-62` gh-rejection is a hint string;
   real gate is `shell_command_gate.bin_allowed` membership.

6. `lib/keeper/keeper_sandbox_docker.ml:311-327,384-385` — Docker resolves
   creds via `Keeper_host_config_provider.resolve` → scrubbed bundle →
   explicit `docker run -e`. Docker path SAFE.

7. Operator config on primary deployment (`git config --show-origin`):
   - `~/.gitconfig` → `credential.helper = !/opt/homebrew/bin/gh auth git-credential`
   - Xcode gitconfig → `osxkeychain`
   - `~/.config/gh/hosts.yml` exists (PAT store)
   Current shell carries 0 `GH_TOKEN`/`GITHUB_TOKEN` env vars → dominant leak
   is via inherited `HOME` → gitconfig helper → gh PAT, not an env-var token.

8. Live fleet: `~/.masc/config/keepers/` — 16 keepers, 14 `local`, `analyst`
   `docker`, `base` docker+`autoboot_enabled=false`. All carry placeholder
   `repo_cli_identity = "repo_cli_identity"` (no bundle on disk).

## Exploit chain (CRITICAL, CERTAIN)

A write-enabled Local keeper runs `git push https://github.com/owner/repo.git`
or `gh pr create` → subprocess inherits operator `HOME` (unscrubbed) → git
invokes `credential.helper` from operator `~/.gitconfig` → `gh auth
git-credential` reads `~/.config/gh/hosts.yml` PAT → authenticates and pushes
as the operator. Audit logs show the command, not the identity.

ssh vector: BLOCKED (`ssh` not allowlisted). HTTPS vector: LIVE.

## Evidence provenance

Transient session task outputs and operator-local notes are not cited because
they are not reproducible for repository readers. The durable facts from those
runs are transcribed in the sections above and in
`RFC-0209-local-sandbox-credential-boundary.md`.

## Diagnosis confidence

CRITICAL / CERTAIN on code structure. The single non-code precondition
(server process carries operator GH credentials, or HOME has a credential
helper) is satisfied on the primary single-user deployment (verified §7) and
documented; degrades to LATENT only on a scrubbed-launch deployment.
