# What an activated workspace offers people, without and with a runtime.toml

Date: 2026-11-17. Measurements of an account server, and source checks of the
candidate. No binary of the candidate was built, so the write of
`masc auth bootstrap` itself did not run for this record.

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

## Source checks of the candidate

No Dune build ran. The checks below read the candidate's sources.

- Type check with `ocamlc.opt` 5.5.2, replaying the compiler arguments and
  the ppx action that a build of the base recorded, against the `.cmi` files
  of that build. 13 units passed: the two changed interfaces of `lib/server`
  and their implementations, the four interfaces that import
  `Server_runtime_setup_actions`, `bin/masc_cli_auth.mli` and its
  implementation, `bin/main_eio.ml`, the test support module and
  `test/test_config_root_embedded_seed.ml`.
  - Control: the three importing interfaces that the change does not reach
    compiled to the interface digests of that build.
  - Negative control: two broken copies failed for their own reason, a
    `match` on the placement without `Existing_kept` in
    `bin/masc_cli_auth.ml` and a misspelt constructor in the test.
- The reader and the writer share one path by construction:
  `Server_runtime_setup_actions.config` and `masc auth bootstrap` both take
  it from `Server_runtime_setup_actions.config_path`.
- The six files of the parser (`lib/runtime/runtime_toml*.ml`) name one read
  of the process: the home directory, for a path that starts with `~/`. They
  name no catalog. `Server_person_integrations.of_config` reads the provider
  catalog, which is the embedded one in a process that published none, and
  the `PATH` and `HOME` of the client lookup, which falls back to the
  configured command.

## Unverified

- `masc auth bootstrap` of the candidate from start to end: the line it
  prints for a written file, a kept file and a failed write, and the file on
  disk after it.
- A sign-in, a model verification and a Keeper turn with the ids of the
  shipped file. Earlier on the same day they ran with a hand-written
  runtime.toml of other ids, up to the model verification, which the limit of
  the connected account refused.
- Linux hosts.
- A workspace whose `config.json` was activated by an earlier build. The
  command refuses it as already active, so it gets the file by hand.
