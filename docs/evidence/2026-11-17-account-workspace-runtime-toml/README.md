# What an activated workspace offers people, without and with a runtime.toml

Date: 2026-11-17. Measurements of an account server, source checks of the
candidate, and two test runs. No binary of the candidate was built on this
machine: `masc auth bootstrap` of the candidate ran in the second test run.

- Base: `8e78ac5f9e1039241d1e120ae47a6a360179f900`.
- Measured binary: a Dune build of `467cfe8e83736cdacc76b2871da966a7309ef80a`.
- Issue: #52692.
- macOS 27.2 (Darwin 27.2.0, arm64).

## What the account server answered

The workspace was a fresh directory with a `config.json` that asks for
Multi_account. `masc auth bootstrap` of the measured binary activated it and
`masc auth preview` served it on 127.0.0.1. The first Admin was signed in,
and [`integrations_probe.js`](integrations_probe.js) ran in a page of that
session.

| Capture | `<base>/.masc/config/runtime.toml` | `GET /api/v1/auth/integrations` |
| --- | --- | --- |
| [without](capture-without-runtime-toml.txt) | absent, as the bootstrap of the measured binary leaves it | 503, `The workspace configuration could not be read.` |
| [with](capture-with-shipped-runtime-toml.txt) | `config/runtime.toml` of the base, copied there by hand | 200: `claude_code` with calls allowed and 22 models, `codex_subscription` with calls refused (`native_tools_reach_other_homes`) and 50 models |

- The server ran through both captures without a restart: it reads the file
  at each request.
- With the file in place, the console of the same session named Claude Code
  as the subscription whose models run a Keeper on this server. That was seen
  with the file the measured binary embeds, which differs from the base's in
  comments only.
- The file answers with no other provider. Its HTTP providers and Antigravity
  are not connections a person signs in to
  (`Server_setup_account_login.person_target`).

## The file the candidate writes

The candidate writes `Embedded_config.read "runtime.toml"`. A build embeds the
repository's `config/` tree there: `masc init --config-only` of the measured
binary wrote a runtime.toml with the bytes of `config/runtime.toml` at the
commit of that binary.

`config/runtime.toml` of the base has SHA-256
`99034d9319adcd933ff6695f6637f54461c9248f48ed7624e71ece9ff10e2945`.

The file is staged beside the path, synced, and published by a rename that
replaces nothing (`Fs_compat.rename_noreplace`), with mode 0600.

- The directory of the path, and each directory the placement made, is
  synced before the command goes on, also when an entry was there and is
  kept. A run after one that could not sync syncs again.
- A placement that makes no file removes the directories it made.

## The order of the command

The candidate runs the checks of the activation, places the file, and writes
the records of the activation last.

- The checks are `Authz_activation.prepare`: whether a boot asks for the
  activation, and every check of the bootstrap (`Authz_bootstrap.prepare`),
  the path of the external store among them. A command that a check refuses
  makes no file and no directory for runtime.toml.
- A placement that fails refuses the command before a record is written.
- The writes are `Authz_activation.complete`. It takes what `prepare` gave,
  so no command writes the records without the checks.

- With the measured binary, which places nothing, `masc auth bootstrap` of a
  workspace whose `.masc/config` is a regular file ended with exit 0. No
  earlier step of the command touches that path, so in the candidate the
  placement is the step that refuses there.

## Source checks of the candidate

No Dune build ran on this machine. The checks below read the candidate's
sources.

- Type check with `ocamlc.opt` 5.5.2, replaying the compiler arguments and
  the ppx action that a build of the base recorded, against the `.cmi` files
  of that build. 17 units passed: `lib/auth/authz_activation` (interface and
  implementation) and the interface that imports it, the two changed
  interfaces of `lib/server` with their implementations, the four interfaces
  that import `Server_runtime_setup_actions`, `bin/masc_cli_auth.mli` and its
  implementation, `bin/main_eio.ml`, the test support module,
  `test/test_config_root_embedded_seed.ml` and `test/test_authz_activation.ml`.
  - Control: the three importing interfaces of `lib/server` that the change
    does not reach compiled to the interface digests of that build.
  - Negative control: a copy with two breaks failed for both, a
    `declare_connections` without the outcome `Not_synced` (the match is not
    exhaustive) and a `complete` that is given no prepared activation (the
    types differ).
- The reader and the writer share one path by construction:
  `Server_runtime_setup_actions.config` and `masc auth bootstrap` both take
  it from `Server_runtime_setup_actions.config_path`.
- The six files of the parser (`lib/runtime/runtime_toml*.ml`) name one read
  of the process: the home directory, for a path that starts with `~/`. They
  name no catalog. `Server_person_integrations.of_config` reads the provider
  catalog, which is the embedded one in a process that published none, and
  the `PATH` and `HOME` of the client lookup, which falls back to the
  configured command.

## Test runs

Each read once on 2026-11-17.

```sh
gh workflow run test.yml --ref feat/bootstrap-writes-runtime-toml \
  -f suite=test_config_root_embedded_seed,test_onboarding_journey -f minimal=true
```

- Workflow `Test`, run 44021898479, an earlier head of the candidate,
  `ca48ed19bbb0`, with `suite=test_config_root_embedded_seed`. Conclusion:
  success, 10 cases. In that head the command placed the file after the
  activation, with a write that replaced by rename.
- Run 44030305939, head `fde1ab45ae81`, with the command above. Conclusion:
  failure, for one case this change does not reach.
  - `test_config_root_embedded_seed`: 10 cases ran and passed, the three
    `place_embedded_runtime_toml` cases among them.
  - `test_onboarding_journey`: 243 cases ran and none was skipped. 242
    passed, the two that run `masc auth bootstrap` of the built binary among
    them: one reads the file the command leaves, the other refuses a
    workspace where the file cannot go and then runs the command again.
  - The one that ended in an error is
    `test_native_antigravity_account_import_keeps_original_and_lists_exact_models`,
    a case of `masc runtime-antigravity-account` (#52741).

## Unverified

- The placement on macOS. The test workflow builds and runs on Linux, and no
  build ran on this machine.
- The outcome `Not_synced`. No test makes the sync of a directory fail.
- A file system without a rename that replaces nothing. By the source, the
  placement stops there on every run with the reason of the operating
  system.
- The sentences the command prints. No test reads them.
- A sign-in, a model verification and a Keeper turn with the ids of the
  shipped file. Earlier on the same day they ran with a hand-written
  runtime.toml of other ids, up to the model verification, which the limit of
  the connected account refused.
- A workspace whose `config.json` was activated by an earlier build. The
  command refuses it as already active, so it gets the file by hand.
- A single-user boot of the base path after `masc auth off`. The config root
  exists by then, so that boot fills in what an existing root gets
  (`Refill_existing_root`) and not what a new one gets. The same holds today
  for a workspace whose runtime.toml was written by hand.
