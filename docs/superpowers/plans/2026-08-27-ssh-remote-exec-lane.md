# Phase 1: SSH Remote Execution Lane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `remote_ssh` sandbox profile that executes keeper tool commands on a remote machine over OpenSSH via a pinned remote shim binary, so that no keeper *payload* process ever runs on the masc host. Phase 1 targets any reachable sshd (including a localhost Docker fixture); Phase 2 (Firecracker microVM) reuses everything built here unchanged.

**Architecture:** Three layers, mirroring the Docker lane:

1. `lib/exec` gains `Sandbox_target.Ssh` — a data-carrying variant with injected `runner`/`pipeline_runner` closures (layering stays clean; `lib/exec` never depends on `lib/keeper`).
2. The keeper layer builds the runner in `keeper_sandbox_ssh.ml` on the existing `Process_eio` substrate, speaking a stdin-framed binary-safe protocol to a remote `masc-exec-shim` static Linux binary.
3. Endpoint configuration lives in runtime config under a new `[exec.ssh.endpoints.<name>]` namespace (parsed in `lib/runtime/runtime_toml.ml`); keeper TOML selects `sandbox_profile = "remote_ssh"` + `remote_endpoint = "<name>"`.

Fail-closed everywhere: unknown endpoint, unreachable host, shim version skew, `network_mode = "none"` — all named errors, never a silent downgrade to another lane.

**Tech Stack:** OCaml 5, dune, Alcotest, Eio, system OpenSSH client. The shim is OCaml built as a static musl binary inside an Alpine build container. Tests run via `scripts/dune-local.sh`.

**Spec:** `docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md` §4.2 (amended 2026-08-27 per spec review: stdin-framed shim protocol, result trailer, no-pty cancellation, network_mode fail-closed). Phase 0 (local playground gate) shipped in PR #31202. Phase 2 (microVM) gets its own plan.

---

## File Structure

- Modify: `lib/keeper_types_profile_sandbox/keeper_types_profile_sandbox.ml` — `Remote_ssh [@tla.symbol "Remote_ssh"]` variant, `all_sandbox_profiles`, `default_network_mode_for_profile`
- Modify: `specs/boundary/SandboxDispatch.tla` — `ProfileSet`, `ViaSet`, dispatch mapping, invariants
- Modify: `lib/config/keeper_sandbox_config.ml`, `lib/keeper/keeper_types_profile_toml_parser.ml`, `config/tools/masc_keeper_up.toml` — profile string `"remote_ssh"`, `remote_endpoint` key, `network_mode = "none"` rejection
- Create: `lib/runtime/exec_ssh_endpoint.ml` / `.mli` — typed endpoint record + defaults
- Modify: `lib/runtime/runtime_toml.ml` — `"exec"` top-level namespace, `parse_exec_endpoints`, `Runtime_schema.config` extension
- Modify: `lib/exec/sandbox_target.ml` / `.mli` — `ssh_endpoint` record, `Ssh` constructor, `ssh` builder
- Modify: `lib/exec/exec_dispatch.ml` — route `Ssh` via its runner (same as `Docker`)
- Create: `lib/exec_ssh_protocol/` — dune lib: frame codec, request/trailer/probe JSON, base64 fields (shared by runner and shim)
- Create: `lib/exec_shim/` — dune lib: shim implementation core (env synthesis/filter pure functions, spawn/supervise loop) + prctl C stub
- Create: `bin/masc_exec_shim.ml` — thin shim entrypoint
- Create: `scripts/build-shim-static.sh` + `test/fixtures/sshd/Dockerfile` — static musl build + integration fixture image
- Create: `lib/keeper/keeper_sandbox_ssh.ml` / `.mli` — SSH runner (flags, ControlMaster, framing, streaming, trailer, timeouts, cancellation)
- Create: `lib/keeper/keeper_remote_path.ml` / `.mli` — bidirectional path translation (single owner of both directions)
- Modify: `lib/keeper/keeper_sandbox_shell_ir_target.ml` — `ssh_target` mirroring `docker_target`
- Modify: `lib/keeper/keeper_tool_execute_runtime.ml` — `Remote_ssh` dispatch arms, secret-policy branch
- Modify: `lib/keeper/keeper_workspace_read_ops.ml`, `lib/keeper/keeper_sandbox_read_backend.ml` — read ops via `Keeper_sandbox_read_runner` SSH backend
- Modify: `lib/config/env_config_sandbox.ml` / `.mli` — `Preflight` remote-readiness extension + TTL cache
- Create: `bin/masc_exec_ssh_bootstrap.ml` — endpoint provisioning tool
- Modify: `lib/keeper/keeper_turn_up_args.ml`, `lib/keeper/keeper_runtime.ml`, `lib/keeper/keeper_sandbox_control.ml`, `lib/keeper/keeper_meta_contract.ml`, `lib/keeper/keeper_tool_shared_runtime.ml`, `lib/keeper/keeper_sandbox.ml`, `lib/keeper/keeper_sandbox_docker.ml`, `lib/keeper/keeper_sandbox_factory.mli`, `lib/keeper/keeper_runtime_contract.ml` — exhaustive `Remote_ssh` arms (compiler-driven)
- Create: tests `test/test_keeper_remote_ssh_profile.ml`, `test/test_exec_ssh_endpoints.ml`, `test/test_exec_dispatch_ssh.ml`, `test/test_exec_ssh_protocol.ml`, `test/test_exec_shim.ml`, `test/test_keeper_sandbox_ssh.ml`, `test/test_keeper_remote_path.ml`, `test/test_keeper_ssh_secret_policy.ml`, `test/test_keeper_ssh_preflight.ml`, `test/test_keeper_ssh_integration.ml` + stanzas in `test/dune`
- Create: `docs/rfc/RFC-0395-ssh-remote-exec-lane.md`, `docs/operations/ssh-endpoints-runbook.md`

## Conventions used below

- Test stanza, precedent `test/dune` Group 1 standalone style (see `test_keeper_local_playground_gate`):
  ```
  (test
   (name test_x)
   (modules test_x)
   (libraries masc_test_deps <extra-libs>))
  ```
  Default env from `test/dune:33-47` applies (`MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false` etc.). Tests that need the local-playground hatch add:
  ```
  (action (setenv MASC_EXEC_ALLOW_LOCAL_PLAYGROUND true (run %{test})))
  ```
  with the incidental-comment convention from Phase 0.
- Fast test loop: `scripts/dune-local.sh build test/<name>.exe && _build/default/test/<name>.exe`
- Full suite: `scripts/ci-run-tests.sh "scripts/dune-local.sh test"` (NOT `make test-unit` — repo-wide breakage, mk/test.mk:7)
- Substring helper (house copy):
  ```ocaml
  let contains needle haystack =
    let n = String.length needle and h = String.length haystack in
    let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
    scan 0
  ```
- Named errors use the `snake_case` code-in-message convention from Phase 0 (e.g. `remote_ssh_no_network_mode`).
- The ssh client binary path is a runner parameter `~ssh_bin` (default `"ssh"`) — this is the unit-test seam (tests point it at a stub script).

---

### Task 1: `Remote_ssh` profile variant (compiler-driven exhaustiveness)

The variant SSOT comment at `keeper_types_profile_sandbox.ml:13-23` means adding the constructor turns every missing match arm into a compile error — that is the intended discovery mechanism for this task.

**Files:**
- Create: `test/test_keeper_remote_ssh_profile.ml`
- Modify: `test/dune` (append stanza)
- Modify: `lib/keeper_types_profile_sandbox/keeper_types_profile_sandbox.ml` (variant after `Docker`, `all_sandbox_profiles` at :56, `default_network_mode_for_profile` at :76-79)
- Modify: `specs/boundary/SandboxDispatch.tla` (`ProfileSet` :51, `ViaSet` :52, dispatch mapping :92-95, invariants :109-118)
- Modify: `lib/keeper_types_profile_sandbox/keeper_types_profile_toml_parser.ml` (:202-211, :280-281) — parse `"remote_ssh"` + optional `remote_endpoint = "<name>"`
- Modify: `lib/config/keeper_sandbox_config.ml` (:13-24, :67-73) — string mapping
- Modify: `config/tools/masc_keeper_up.toml` (:28-36) — enum gains `remote_ssh`
- Modify: every remaining match site the compiler flags (expected: `lib/keeper/keeper_sandbox.ml:72-78,98-103,130-152,154-158,160-172,199-205`, `lib/keeper/keeper_sandbox_docker.ml:112-116`, `lib/keeper/keeper_sandbox_read_backend.ml:15-16`, `lib/keeper/keeper_runtime_contract.ml:10-11`, `lib/keeper/keeper_tool_execute_runtime.ml:43-47,337-384,402-411,420-428`, `lib/keeper/keeper_tool_shared_runtime.ml:107`, `lib/keeper/keeper_sandbox_control.ml:89,602,608`, `lib/keeper/keeper_turn_up_args.ml:377-391,430-433`, `lib/keeper/keeper_runtime.ml:212-223,332-361,497-501`, `lib/keeper/keeper_meta_contract.ml:290,349-415`, `lib/keeper/keeper_sandbox_factory.mli:26-29,50-63`)

- [ ] **Step 1: Write the failing test + dune stanza**

`test/test_keeper_remote_ssh_profile.ml`:
```ocaml
open Alcotest

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

let test_profile_roundtrip () =
  check string "to_string" "remote_ssh"
    (Keeper_types_profile_sandbox.sandbox_profile_to_string
       Keeper_types_profile_sandbox.Remote_ssh);
  check (option string) "of_string"
    (Some "remote_ssh")
    (Option.map Keeper_types_profile_sandbox.sandbox_profile_to_string
       (Keeper_types_profile_sandbox.sandbox_profile_of_string "remote_ssh"))

let test_all_profiles_includes_remote_ssh () =
  check bool "listed" true
    (List.exists
       (fun p -> Keeper_types_profile_sandbox.sandbox_profile_to_string p = "remote_ssh")
       Keeper_types_profile_sandbox.all_sandbox_profiles)

let test_default_network_mode_is_inherit () =
  check string "network inherit" "inherit"
    (match Keeper_types_profile_sandbox.default_network_mode_for_profile
             Keeper_types_profile_sandbox.Remote_ssh with
     | Keeper_types_profile_sandbox.Network_inherit -> "inherit"
     | Keeper_types_profile_sandbox.Network_none -> "none")

let test_network_mode_none_rejected () =
  (* config-load rejection: remote_ssh + network_mode = "none" must fail
     with remote_ssh_no_network_mode *)
  match Keeper_types_profile_toml_parser.parse_sandbox_settings
          ~profile:"remote_ssh" ~network_mode:(Some "none") with
  | Ok _ -> fail "expected rejection"
  | Error msg -> check bool "named error" true (contains "remote_ssh_no_network_mode" msg)

let () =
  run "remote_ssh profile"
    [ "profile", [ test_case "roundtrip" `Quick test_profile_roundtrip
                 ; test_case "all_profiles" `Quick test_all_profiles_includes_remote_ssh ]
    ; "network", [ test_case "default inherit" `Quick test_default_network_mode_is_inherit
                 ; test_case "none rejected" `Quick test_network_mode_none_rejected ] ]
```
(Exact parser entrypoint signature is whatever `keeper_types_profile_toml_parser.ml` exposes today — adapt the call, keep the assertions.)

- [ ] **Step 2: Run to confirm RED** — `scripts/dune-local.sh build test/test_keeper_remote_ssh_profile.exe` must fail (unbound constructor `Remote_ssh`).

- [ ] **Step 3: Add the variant + SSOT updates**

In `keeper_types_profile_sandbox.ml`:
```ocaml
| Remote_ssh [@tla.symbol "Remote_ssh"]
```
after `Docker`; add `Remote_ssh` to `all_sandbox_profiles`; extend `default_network_mode_for_profile` with `Remote_ssh -> Network_inherit`; extend the string converters. Regenerate the TLA symbols (ppx_tla derives `to_tla_symbol`/`all_symbols`).

In `specs/boundary/SandboxDispatch.tla`: add `"Remote_ssh"` to `ProfileSet`, add the `ViaSet` atom for the SSH lane (e.g. `"ViaSsh"`), extend the dispatch mapping (:92-95) so `Remote_ssh` maps to it, and extend the invariants (:109-118) to assert a `Remote_ssh` dispatch never resolves to `ViaHost` or `ViaLocalPlayground`. Run the existing TLA check harness (`scripts/check-tla.sh` if present, else the dune alias used in Phase 0 — confirm the command from the Phase 0 plan before writing this step's run command).

- [ ] **Step 4: Compile-driven sweep** — `scripts/dune-local.sh build` and fix every exhaustiveness error. Arms whose functionality arrives in later tasks fail closed with a named error, e.g.:
```ocaml
| Remote_ssh -> Error "remote_ssh_dispatch_unavailable: runner not wired yet (Phase 1 task 6)"
```
Never silently fall through to a Docker or host path (RFC-0001). `keeper_sandbox_factory.mli:26-29,50-63` gains the `Remote` branch shape per the existing `Docker` precedent.

- [ ] **Step 5: network_mode fail-closed** — in the sandbox-settings validation path (`keeper_types_profile_toml_parser.ml` or `keeper_sandbox_config.ml`, wherever `network_mode` is validated for Docker today), `Remote_ssh` + anything other than `Network_inherit` → `Error "remote_ssh_no_network_mode: ..."`.

- [ ] **Step 6: GREEN + full-suite no-regression** — `scripts/dune-local.sh build test/test_keeper_remote_ssh_profile.exe && _build/default/test/test_keeper_remote_ssh_profile.exe`, then `scripts/ci-run-tests.sh "scripts/dune-local.sh test"` compared against `/tmp/masc-gate-suite-final.log` baseline.

- [ ] **Step 7: Commit** — `feat(keeper): add Remote_ssh sandbox profile (fail-closed arms, network_mode fail-closed)`

### Task 2: Endpoint registry — `[exec.ssh.endpoints.<name>]` in runtime config

**Files:**
- Create: `test/test_exec_ssh_endpoints.ml`
- Modify: `test/dune` (append stanza)
- Create: `lib/runtime/exec_ssh_endpoint.ml` / `.mli`
- Modify: `lib/runtime/runtime_toml.ml` (`active_top_level_namespaces` :247-254 gains `"exec"`; `parse_exec_endpoints` modeled on `parse_providers` :617; wire into the config assembly at :1678-1701 alongside `providers_result`; `Runtime_schema.config` :1728-1735 extension)
- Modify: `lib/runtime/runtime_toml.mli` / `runtime_schema.mli` (expose endpoint registry on the parsed config)
- Modify: `config/runtime.toml` (commented example endpoint)

- [ ] **Step 1: Write the failing test + dune stanza**

`test/test_exec_ssh_endpoints.ml`:
```ocaml
open Alcotest

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

let endpoint_toml name extra =
  Printf.sprintf {|
[exec.ssh.endpoints.%s]
host = "builder.local"
user = "masc-exec"
remote_root = "/srv/masc/playground"
%s
|} name extra

let parse s = Runtime_toml.parse_string s (* adapt to the actual entrypoint *)

let test_parse_minimal_endpoint () =
  match parse (endpoint_toml "dev" "") with
  | Error e -> fail e
  | Ok cfg ->
    let ep = Runtime_schema.exec_ssh_endpoint_exn cfg "dev" in
    check string "host" "builder.local" ep.Exec_ssh_endpoint.host;
    check int "port default" 22 ep.Exec_ssh_endpoint.port;
    check int "connect_timeout default" 10 ep.Exec_ssh_endpoint.connect_timeout_sec;
    check int "max_sessions default" 8 ep.Exec_ssh_endpoint.max_concurrent_sessions;
    check (list string) "env_allowlist default" [] ep.Exec_ssh_endpoint.env_allowlist

let test_unknown_key_rejected () =
  match parse (endpoint_toml "dev" "bogus_key = 1") with
  | Ok _ -> fail "expected rejection"
  | Error msg -> check bool "names the key" true (contains "bogus_key" msg)

let test_missing_required_rejected () =
  match parse {|
[exec.ssh.endpoints.dev]
host = "builder.local"
|} with
  | Ok _ -> fail "expected rejection"
  | Error msg -> check bool "names missing key" true (contains "user" msg)

let test_endpoint_name_validation () =
  match parse (endpoint_toml "bad name!" "") with
  | Ok _ -> fail "expected rejection"
  | Error msg -> check bool "validation error" true (contains "bad name" msg)

let () =
  run "exec ssh endpoints"
    [ "parse", [ test_case "minimal" `Quick test_parse_minimal_endpoint
               ; test_case "unknown key" `Quick test_unknown_key_rejected
               ; test_case "missing required" `Quick test_missing_required_rejected
               ; test_case "name validation" `Quick test_endpoint_name_validation ] ]
```

- [ ] **Step 2: RED** — build fails (`Runtime_schema.exec_ssh_endpoint_exn` unbound).

- [ ] **Step 3: `Exec_ssh_endpoint` module** — record with exactly the spec table fields: `host`, `user`, `port` (default 22), `identity_file` (default `<base>/.masc/ssh/<name>.key`), `known_hosts_file` (default `<base>/.masc/ssh/known_hosts.d/<name>`), `remote_root` (required), `connect_timeout_sec` (default 10), `max_concurrent_sessions` (default 8), `env_allowlist` (default `[]`), `capabilities` (default `[]`; unknown capability values warn-and-ignore, per spec). The two `<name>`-dependent defaults are resolved at parse time, where the endpoint name and `<base>` are both in scope.

- [ ] **Step 4: Parser** — `parse_exec_endpoints` walks `[exec.ssh.endpoints.*]` tables; each name passes `validate_runtime_id_component ~allow_dot:false ~kind:"exec ssh endpoint"` (:284-301); unknown keys and missing required keys are parse errors naming the key; wire the result into the config record assembly at :1678-1701 with the same `extract_after_all_errors_guard` pattern as `providers_result`; add `"exec"` to `active_top_level_namespaces` so a stray `[exec]` table is not silently ignored. Keep the mli signatures in sync.

- [ ] **Step 5: Seed** — `config/runtime.toml` gains a fully commented-out example endpoint block (no live endpoint ships in the repo).

- [ ] **Step 6: GREEN + no-regression** (same commands as Task 1 Step 6).

- [ ] **Step 7: Commit** — `feat(runtime): [exec.ssh.endpoints] registry — typed, fail-closed parse`

### Task 3: `Sandbox_target.Ssh` variant + dispatch routing

**Files:**
- Create: `test/test_exec_dispatch_ssh.ml`
- Modify: `test/dune` (append stanza)
- Modify: `lib/exec/sandbox_target.ml` / `.mli` (after the `Docker` constructor, :51-54 area)
- Modify: `lib/exec/exec_dispatch.ml` (route `Ssh` exactly like `Docker`)
- Modify: `lib/keeper/keeper_tool_execute_runtime.ml:55` (`target_label` arm: `"ssh:" ^ endpoint.host`)

- [ ] **Step 1: Write the failing test + dune stanza**

`test/test_exec_dispatch_ssh.ml` mirrors the Docker mock-runner case in `test/test_exec_dispatch.ml`: build an `Ssh` target whose `runner` records `(argv, env, cwd, stdin_content)` and returns `(Unix.WEXITED 0, "out", "err")`, dispatch a simple command, assert the runner saw the command and the dispatch result carries the mocked stdout/stderr. Include the `pipeline_runner = None` pipeline case asserting Docker parity: with no pipeline runner injected, the pipeline decomposes to per-stage `dispatch_simple` through the plain runner (pinned by `test_exec_dispatch.ml:384-416` — no named error exists for this case), and a `pipeline_runner = Some` case asserting the streaming pipeline runner is preferred.

- [ ] **Step 2: RED** — build fails (unbound `Sandbox_target.ssh`).

- [ ] **Step 3: Variant + builder**

In `sandbox_target.ml`:
```ocaml
type ssh_endpoint = {
  name : string;
  host : string;
  user : string;
  port : int;
  identity_file : string;
  known_hosts_file : string;
  remote_root : string;
  connect_timeout_sec : int;
  env_allowlist : string list;
}

type t =
  | Host
  | Docker of { image : string; runner : runner; pipeline_runner : pipeline_runner option }
  | Ssh of { endpoint : ssh_endpoint; runner : runner; pipeline_runner : pipeline_runner option }

let ssh ~endpoint ~runner ?pipeline_runner () : t =
  Ssh { endpoint; runner; pipeline_runner }
```
(`max_concurrent_sessions` and `capabilities` are consumed by the keeper-side runner/preflight, not by `lib/exec`, so they stay out of this record.) Update the mli doc comment — the "variant rather than a record" rationale now covers three constructors.

- [ ] **Step 4: Routing** — in `exec_dispatch.ml`, the `Ssh { runner; _ }` arm calls `runner` identically to the `Docker` arm (same `on_stdout_chunk`/`on_stderr_chunk`/`stdin_content` plumbing). `keeper_tool_execute_runtime.ml:55` `target_label` gains `| Masc_exec.Sandbox_target.Ssh { endpoint; _ } -> "ssh:" ^ endpoint.host`.

- [ ] **Step 5: GREEN + no-regression.**

- [ ] **Step 6: Commit** — `feat(exec): Sandbox_target.Ssh — injected-runner SSH lane, dispatch routing`

---

### Task 4: Shim protocol codec (`exec_ssh_protocol` lib)

Pure OCaml, no I/O — shared by the keeper-side runner (encode request, parse trailer/probe) and the shim binary (parse request, emit trailer/probe). One library is the protocol SSOT; the runner and the shim can never drift.

**Files:**
- Create: `test/test_exec_ssh_protocol.ml`
- Modify: `test/dune` (append stanza with `libraries masc_test_deps exec_ssh_protocol`)
- Create: `lib/exec_ssh_protocol/dune`, `lib/exec_ssh_protocol/exec_ssh_protocol.ml` / `.mli`

- [ ] **Step 1: Write the failing test + dune stanza**

`test/test_exec_ssh_protocol.ml`:
```ocaml
open Alcotest

let req = Exec_ssh_protocol.{ v = 1
                            ; argv = ["/bin/echo"; "hello"]
                            ; env = [("FOO", "bar")]
                            ; cwd = "/srv/masc/playground/keeper-a"
                            ; timeout_sec = 300.0
                            ; stdin_len = 0L }

let test_frame_roundtrip () =
  let framed = Exec_ssh_protocol.encode_request req ~stdin:"" in
  match Exec_ssh_protocol.decode_request framed with
  | Error e -> fail e
  | Ok (req', stdin) ->
    check (list string) "argv" req.argv req'.argv;
    check (list (pair string string)) "env" req.env req'.env;
    check string "cwd" req.cwd req'.cwd;
    check (float 0.0) "timeout" req.timeout_sec req'.timeout_sec;
    check string "stdin" "" stdin

let test_hostile_bytes_roundtrip () =
  (* invalid UTF-8 in argv; NULs, 0x1e and 0xff inside a 10 MiB stdin payload *)
  let big = Bytes.make (10 * 1024 * 1024) '\x00' in
  Bytes.blit_string "\x1e record sep \x1e \x00 \xff" 0 big 42 22;
  let stdin = Bytes.unsafe_to_string big in
  let r = { req with argv = ["\xff\xfe invalid utf8"]
                   ; stdin_len = Int64.of_int (String.length stdin) } in
  let framed = Exec_ssh_protocol.encode_request r ~stdin in
  match Exec_ssh_protocol.decode_request framed with
  | Error e -> fail e
  | Ok (r', stdin') ->
    check (list string) "hostile argv" r.argv r'.argv;
    check string "stdin bytes" stdin stdin'

let test_trailer_roundtrip () =
  let t = Exec_ssh_protocol.{ v = 1; exit = Some 3; signal = None
                            ; timed_out = false; shim_error = None } in
  let rendered = Exec_ssh_protocol.render_trailer t in
  check bool "starts with RS" true (String.length rendered > 2 && rendered.[0] = '\x1e');
  check bool "ends with RS" true
    (String.length rendered > 2 && rendered.[String.length rendered - 1] = '\x1e');
  match Exec_ssh_protocol.parse_trailer rendered with
  | Error e -> fail e
  | Ok t' -> check (option int) "exit" t.exit t'.exit

let test_trailer_malformed_is_transport_error () =
  match Exec_ssh_protocol.parse_trailer "\x1e not json \x1e" with
  | Ok _ -> fail "expected transport error"
  | Error msg -> check bool "transport, not exit0" true (contains "transport" msg)

let test_trailer_absent_is_transport_error () =
  match Exec_ssh_protocol.parse_trailer "plain stderr with no trailer" with
  | Ok _ -> fail "expected transport error"
  | Error _ -> ()

let test_signal_vs_exit () =
  let t = Exec_ssh_protocol.{ v = 1; exit = None; signal = Some 9
                            ; timed_out = false; shim_error = None } in
  match Exec_ssh_protocol.parse_trailer (Exec_ssh_protocol.render_trailer t) with
  | Error e -> fail e
  | Ok t' -> check (option int) "signal" (Some 9) t'.signal

let test_probe_roundtrip () =
  let p = Exec_ssh_protocol.{ name = "masc-exec-shim"; version = "1.0.0"
                            ; capabilities = [] } in
  match Exec_ssh_protocol.parse_probe (Exec_ssh_protocol.render_probe p) with
  | Error e -> fail e
  | Ok p' ->
    check string "version" p.version p'.version;
    check bool "major compatible" true
      (Exec_ssh_protocol.probe_major_compatible ~want:"1" p'.version)

let test_probe_version_skew () =
  check bool "major mismatch" false
    (Exec_ssh_protocol.probe_major_compatible ~want:"2" "1.4.2")

let () =
  run "exec ssh protocol"
    [ "frame", [ test_case "roundtrip" `Quick test_frame_roundtrip
               ; test_case "hostile bytes" `Quick test_hostile_bytes_roundtrip ]
    ; "trailer", [ test_case "roundtrip" `Quick test_trailer_roundtrip
                 ; test_case "malformed is transport error" `Quick test_trailer_malformed_is_transport_error
                 ; test_case "absent is transport error" `Quick test_trailer_absent_is_transport_error
                 ; test_case "signal vs exit" `Quick test_signal_vs_exit ]
    ; "probe", [ test_case "roundtrip" `Quick test_probe_roundtrip
               ; test_case "version skew" `Quick test_probe_version_skew ] ]
```

- [ ] **Step 2: RED.**

- [ ] **Step 3: Implement the codec**

`lib/exec_ssh_protocol/dune`:
```
(library
 (name exec_ssh_protocol)
 (modules exec_ssh_protocol)
 (libraries yojson base64))
```
(Confirm `yojson`/`base64` are already used elsewhere in the repo before writing the dune file — `grep -r "yojson" lib/*/dune | head -3`. If `base64` is not a repo dependency, implement the RFC 4648 codec inline in this module — it is ~40 lines and avoids a new dependency.)

Frame format (exactly per spec §4.2): `[8-byte big-endian length][request JSON][stdin_len raw bytes]`, where length covers JSON + raw bytes. Binary-suspect fields are base64 inside the JSON. Trailer: `\x1e{"masc_exec_result":{"v":1,"exit":...,"signal":...,"timed_out":...,"shim_error":...}}\x1e` appended after the child's stderr. `parse_trailer` takes the *tail* of the stderr stream (the runner passes the trailing bytes), so it must locate the LAST `\x1e...\x1e` pair, not the first — a payload may legally emit `\x1e` only inside valid UTF-8 (it cannot), but defensive last-match is required regardless. Malformed/absent trailer → `Error` whose message contains `remote_ssh_transport_error` (never a fabricated exit 0). `probe_major_compatible ~want version` compares the numeric major prefix.

- [ ] **Step 4: GREEN + no-regression.**

- [ ] **Step 5: Commit** — `feat(exec-ssh-protocol): framed request/trailer/probe codec — binary-safe, version-gated`

### Task 5: `masc-exec-shim` static Linux binary

**Files:**
- Create: `test/test_exec_shim.ml` (unit tests for the pure cores)
- Modify: `test/dune` (append stanza with `libraries masc_test_deps exec_shim`)
- Create: `lib/exec_shim/dune` (with `(foreign_stubs (language c) (names prctl_stub))`), `lib/exec_shim/exec_shim.ml` / `.mli`, `lib/exec_shim/prctl_stub.c`
- Create: `bin/masc_exec_shim.ml`, plus its `bin/dune` entry
- Create: `scripts/build-shim-static.sh`

- [ ] **Step 1: Write the failing test + dune stanza**

`test/test_exec_shim.ml` covers the pure cores:
```ocaml
(* env synthesis: minimal base env is exactly PATH/HOME/USER/TMPDIR *)
(* allowlist overlay: request env entry whose name is in endpoint allowlist survives *)
(* denylist: PATH/HOME/LD_PRELOAD/LD_LIBRARY_PATH/DYLD_*/BASH_ENV/ENV from the wire
   are dropped even when allowlisted *)
(* timeout policy: timer value comes from request timeout_sec, kill sequence is
   SIGTERM(pgid) -> grace -> SIGKILL(pgid) — assert the *decision function*,
   not real signals *)
```
Concrete cases:
```ocaml
let test_denylist_beats_allowlist () =
  let env = Exec_shim.synthesize_env
      ~allowlist:["PATH"; "FOO"]
      ~request_env:[("PATH", "/evil/bin"); ("FOO", "ok")] in
  check bool "wire PATH dropped" true (List.assoc_opt "PATH" env <> Some "/evil/bin");
  check (option string) "FOO kept" (Some "ok") (List.assoc_opt "FOO" env)
```

- [ ] **Step 2: RED.**

- [ ] **Step 3: Shim core (`lib/exec_shim`)**

- `synthesize_env ~allowlist ~request_env` — minimal base env (`PATH`=/usr/local/bin:/usr/bin:/bin, `HOME`/`USER`/`TMPDIR` from the shim's own environment), overlay only allowlisted request entries, minus the reserved-name denylist (`PATH`, `HOME`, `LD_PRELOAD`, `LD_LIBRARY_PATH`, `DYLD_*` prefix, `BASH_ENV`, `ENV`) which is never accepted from the wire. Pure and fully unit-tested.
- `kill_policy` — pure decision function: `on_eof | on_timeout | on_child_exit` → ordered action list `[SIGTERM pgid; wait grace; SIGKILL pgid]`, so the sequence is asserted without real signals.
- `prctl_stub.c` — ~20 lines exposing `PR_SET_PDEATHSIG` (`ocaml_prctl_set_pdeathsig`); called pre-exec in the child. The dune `foreign_stubs` stanza links it.
- `run` — decode the stdin frame (`Exec_ssh_protocol.decode_request`), `setsid()`, fork; child: pdeathsig=SIGKILL, dup pipes, `execvp`; parent: `select` on child stdout/stderr pipes + shim stdin (EOF/HUP detection) + `timeout_sec` timer; stream child output through verbatim; on EOF/timeout apply `kill_policy`; on child exit append the result trailer to the stderr stream per the codec; `--probe` prints `Exec_ssh_protocol.render_probe` and exits 0.

- [ ] **Step 4: Thin entrypoint** — `bin/masc_exec_shim.ml` is `let () = Exec_shim.main ()`; add the executable to `bin/dune` following the neighboring entry pattern.

- [ ] **Step 5: Static build script** — `scripts/build-shim-static.sh` runs an `ocaml/opam:alpine` container, installs the pinned deps, builds with `-ccopt -static`, copies out `masc-exec-shim`, and asserts `file` reports a statically linked ELF (fails the script otherwise). macOS host builds stay dynamic — the static artifact is produced on demand for fixture/provisioning use. Document the invocation in the script header comment.

- [ ] **Step 6: GREEN + no-regression** (unit tests run on macOS against the dynamic build; the static artifact is exercised in Task 10's fixture).

- [ ] **Step 7: Commit** — `feat(shim): masc-exec-shim — setsid+pdeathsig supervision, framed protocol, --probe`

### Task 6: SSH runner (`keeper_sandbox_ssh.ml`) + dispatch wiring

**Files:**
- Create: `test/test_keeper_sandbox_ssh.ml`
- Modify: `test/dune` (append stanza)
- Create: `lib/keeper/keeper_sandbox_ssh.ml` / `.mli`
- Modify: `lib/keeper/keeper_sandbox_shell_ir_target.ml` — `ssh_target` mirroring `docker_target` (:59-136)
- Modify: `lib/keeper/keeper_tool_execute_runtime.ml` — `Remote_ssh` arms at :337-384 (dispatch), :402-411, :420-428 (redirect-path translation note), :699 area
- Modify: `lib/keeper/dune` (add `exec_ssh_protocol` to libraries if not already transitively present)

- [ ] **Step 1: Write the failing test + dune stanza**

`test/test_keeper_sandbox_ssh.ml` uses the `~ssh_bin` seam: a stub shell script (created in `Unix.mkstemp`-style temp dir, chmod 0755) that records its argv to a file, cats a canned stdout, emits a canned stderr + valid trailer, and exits 0. Cases:
```ocaml
(* argv contains exactly: -T -F none -o BatchMode=yes -o IdentitiesOnly=yes
     -i <identity> -o ForwardAgent=no -o ClearAllForwardings=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<kh>
     -o ConnectTimeout=<n> -o ControlMaster=auto -o ControlPersist=120
     -o ControlPath=<base>/.masc/run/ssh/%C -o ServerAliveInterval=15
     -o ServerAliveCountMax=2 -p <port> <user>@<host> masc-exec-shim *)
(* the remote command token is the fixed literal "masc-exec-shim", never request data *)
(* request JSON reached the stub's stdin (framed), argv/env/cwd round-trip *)
(* trailer stripped from stderr; exit code taken from trailer, not ssh status *)
(* malformed trailer -> remote_ssh_transport_error, never exit 0 *)
(* ssh exit 255 + no trailer -> remote_ssh_transport_error naming the endpoint *)
(* trailer signal=Some 9 -> WSIGNALED 9 surfaces *)
(* timed_out=true in trailer -> remote timeout named distinctly from local budget timeout *)
(* env: allowlisted entry present in frame; PATH in request env absent from frame *)
(* cancellation: killing the local stub while blocked on read terminates dispatch *)
```

- [ ] **Step 2: RED.**

- [ ] **Step 3: Runner implementation** in `keeper_sandbox_ssh.ml`:

- `build_ssh_argv ~endpoint ~control_path_dir` produces exactly the flag set above (order fixed for testability); `ControlPath` dir is created 0700 at runner construction; `max_concurrent_sessions` bounds concurrent dispatches per endpoint with a semaphore (sshd `MaxSessions` default 10 — the ceiling is explicit).
- `runner ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env ~cwd` — spawn via `Process_eio.run_argv_with_stdin_and_status_split` (mli:133-146) or the streaming variant (:206-217) so chunk callbacks fire as the ssh channel delivers; encode the request via `Exec_ssh_protocol.encode_request`; write frame to ssh stdin, then `stdin_content` raw bytes are part of the frame (`stdin_len`), then close stdin for no-stdin commands so the shim sees EOF semantics correctly.
- Stream tail buffering: keep only the trailing bytes needed to detect the `\x1e...\x1e` trailer; deliver preceding stderr chunks immediately; on process exit, strip the trailer from the stderr bucket and map trailer fields → `Unix.process_status` (`exit` → `WEXITED n`, `signal` → `WSIGNALED n`); `timed_out=true` → named remote-timeout error; absent/malformed trailer or ssh's own exit 255 → `remote_ssh_transport_error` naming the endpoint.
- Wall-clock budget = `connect_timeout_sec + timeout_sec + drain grace` (constant, documented); per-bucket timeouts come from `Env_config_sandbox.Shell_timeout` exactly like the Docker lane.
- Cancellation = kill the local ssh client process (`Process_eio.tree_kill` :275-316 precedent); channel EOF lets the shim's watchdog reap the remote process group (asserted end-to-end in Task 10).
- First-SSH-dispatch-per-endpoint info log line (observability parity with the Phase 0 hatch warning); a per-endpoint preflight TTL cache re-check (`--probe` over the ControlMaster) fails the dispatch with a named error when the endpoint degrades mid-session.

- [ ] **Step 4: `ssh_target` + dispatch arms** — in `keeper_sandbox_shell_ir_target.ml`, `ssh_target ~endpoint ~runner ...` mirrors `docker_target` including the env-unsupported guard shape (SSH *does* support env — via the allowlist — so the guard differs: typed Shell IR env entries not in the endpoint allowlist fail with `remote_ssh_env_not_allowlisted`). In `keeper_tool_execute_runtime.ml`, the `Remote_ssh` profile arm (:337-384) constructs the SSH target via the runner and dispatches; redirect-path arms (:402-428) translate via `Keeper_remote_path` (Task 7 — if Task 7 lands after, these arms fail closed with a named error until then).

- [ ] **Step 5: GREEN + no-regression.**

- [ ] **Step 6: Commit** — `feat(keeper): SSH exec runner — pinned flags, framed stdin protocol, trailer-verified results, no-pty cancellation`

---

### Task 7: Bidirectional path translation + workspace read ops SSH backend

**Files:**
- Create: `test/test_keeper_remote_path.ml`
- Modify: `test/dune` (append stanza)
- Create: `lib/keeper/keeper_remote_path.ml` / `.mli`
- Modify: `lib/keeper/keeper_workspace_read_ops.ml` (:123 `Sys.file_exists` host check)
- Modify: `lib/keeper/keeper_sandbox_read_backend.ml` (:15-16) / its mli — `Ssh` backend
- Modify: `lib/keeper/keeper_tool_execute_runtime.ml` :402-428 (redirect-path arms now translate instead of failing closed)

- [ ] **Step 1: Write the failing test + dune stanza**

`test/test_keeper_remote_path.ml`:
```ocaml
(* host_to_remote: <base>/.masc/playground/keeper-a/src/main.ml
   -> <remote_root>/keeper-a/src/main.ml *)
(* remote_to_logical: <remote_root>/keeper-a/src/main.ml
   -> keeper-logical path a model would have written *)
(* round-trip both directions is the identity on keeper-relative paths *)
(* path outside the jail (host side) -> Error naming the gate (defense layer 1) *)
(* remote path outside remote_root (in tool output) -> left untouched, no crash *)
(* identical keeper names with different remote_root never cross-map *)
```

- [ ] **Step 2: RED.**

- [ ] **Step 3: `Keeper_remote_path`** — the ONE module owning both directions: `host_to_remote ~endpoint ~keeper host_path` and `remote_to_logical ~endpoint ~keeper remote_path`, plus `rewrite_output ~endpoint ~keeper text` applied to streamed stdout/stderr and error text (compiler errors and `rg` hits contain absolute remote paths; a keeper that sees them feeds them back into the next call). Jail violations host-side return the same named error the existing path gate uses today (`keeper_sandbox_config.ml:75`, `playground_paths.ml`).

- [ ] **Step 4: Read ops SSH backend** — `keeper_sandbox_read_backend.ml` gains the `Ssh` backend; `keeper_workspace_read_ops.ml:123`'s host-side `Sys.file_exists` is skipped for remote targets and routed through `Keeper_sandbox_read_runner` (:132-137 precedent: `container_path_of_host`, `run_command_with_status`) using `test -e` over the shim. `should_route_read` (:172) gains the `Remote_ssh` arm. Enumerate `host_root_abs_of_meta` call sites (~27: telemetry, filesystem-runtime normalization, dashboard workspace views) and classify each in a comment at the top of `keeper_remote_path.ml` as logical-path (unchanged), remote-proxied (routed through the runner), or explicitly-divergent (documented) — this enumeration comment is a deliverable of this task, reviewable in the PR.

- [ ] **Step 5: Redirect-path arms** — `keeper_tool_execute_runtime.ml:402-428` `Remote_ssh` arms translate redirect paths via `Keeper_remote_path` (replacing any fail-closed stub from Task 6).

- [ ] **Step 6: GREEN + no-regression.**

- [ ] **Step 7: Commit** — `feat(keeper): bidirectional remote path translation + SSH read-ops backend`

### Task 8: Secret policy — nothing crosses the wire by default

**Files:**
- Create: `test/test_keeper_ssh_secret_policy.ml`
- Modify: `test/dune` (append stanza)
- Modify: `lib/keeper/keeper_tool_execute_runtime.ml` (:268-330 projection branch)

- [ ] **Step 1: Write the failing test + dune stanza**

`test/test_keeper_ssh_secret_policy.ml`:
```ocaml
(* SSH dispatch: host env (GH_TOKEN set in the test process env) does NOT appear
   in the framed request env captured by the ssh stub *)
(* validate_local_tool_env STILL runs on typed env: typed env containing
   GH_TOKEN fails exactly as it does for the Docker arm *)
(* typed env entry not in endpoint env_allowlist -> remote_ssh_env_not_allowlisted *)
(* allowlisted non-secret typed env entry crosses *)
```

- [ ] **Step 2: RED.**

- [ ] **Step 3: Branch the projection** — in the dispatch path, the `Remote_ssh` arm skips the local identity/env projection (`Keeper_secret_projection` call at :268-330) entirely, then runs `Keeper_github_identity.validate_local_tool_env` on typed env unchanged (or rejects typed env exactly like the Docker arm if that is what the Docker arm does today — match it). The only env that may cross is the endpoint allowlist, enforced by the runner (Task 6) and re-asserted here.

- [ ] **Step 4: GREEN + no-regression.**

- [ ] **Step 5: Commit** — `feat(keeper): SSH secret policy — no host secrets cross the wire, typed env still validated`

### Task 9: Preflight extension + provisioning bootstrap

**Files:**
- Create: `test/test_keeper_ssh_preflight.ml`
- Modify: `test/dune` (append stanza)
- Modify: `lib/config/env_config_sandbox.ml` / `.mli` (`Preflight` remote-readiness extension + TTL cache)
- Modify: `lib/keeper/keeper_turn_up_args.ml` (:377-391, :430-433) — `remote_endpoint` required for `remote_ssh`, must exist in the registry (else config-load error naming the endpoint), preflight invocation
- Create: `bin/masc_exec_ssh_bootstrap.ml` + `bin/dune` entry

- [ ] **Step 1: Write the failing test + dune stanza**

`test/test_keeper_ssh_preflight.ml` (stub `~ssh_bin` again):
```ocaml
(* probe ok + version match -> ready *)
(* probe major mismatch -> remote_shim_version_skew naming endpoint + versions *)
(* ssh unreachable -> remote_ssh_endpoint_unreachable naming host *)
(* missing remote gh identity -> remote_github_identity_missing naming keeper *)
(* TTL cache: second check within TTL does not respawn ssh (stub invocation count) *)
(* TTL expiry rechecks; a degraded endpoint fails dispatch with the named error *)
(* keeper_up with remote_endpoint = "ghost" not in registry -> config-load error *)
```

- [ ] **Step 2: RED.**

- [ ] **Step 3: Preflight extension** — `Env_config_sandbox.Preflight` gains `check_ssh_endpoint ~endpoint ~keeper` running, over the pinned ssh flags: (1) connect, (2) `masc-exec-shim --probe` + `probe_major_compatible`, (3) remote `git --version`, (4) `remote_root` exists + disk-free floor, (5) remote `gh auth status` with `GH_CONFIG_DIR=<remote_root>/<keeper>/.config/gh`, (6) local ControlPath dir creatable. TTL cache (per endpoint, default 60s, overridable via env for tests) consulted at dispatch; keeper_up always forces a fresh check. Every failure is a named error; there is NO fallback to another lane.

- [ ] **Step 4: Bootstrap tool** — `bin/masc_exec_ssh_bootstrap.ml --endpoint <name>`: generates the dedicated keypair under `<base>/.masc/ssh/` (0600, never committed); `ssh-keyscan`s the host and writes the pinned `known_hosts` only after the operator confirms the fingerprint out-of-band (the tool prints the fingerprint and requires retyping it — runbook step); installs/upgrades `masc-exec-shim` (built by `scripts/build-shim-static.sh`) and records its version; creates `remote_root`; provisions `<remote_root>/<keeper>/.config/gh` per keeper (never per-call over the wire); registers the remote token *value* in the host redaction set so a leak into output is still scrubbed.

- [ ] **Step 5: keeper_up wiring** — `keeper_turn_up_args.ml` validation: `sandbox_profile = "remote_ssh"` requires `remote_endpoint`; unknown endpoint name → config-load error naming it. The profile TOML parser arm (Task 1) already carries the key through.

- [ ] **Step 6: GREEN + no-regression.**

- [ ] **Step 7: Commit** — `feat(keeper): SSH endpoint preflight + provisioning bootstrap`

### Task 10: Integration fixture + end-to-end tests

**Files:**
- Create: `test/test_keeper_ssh_integration.ml`
- Modify: `test/dune` (standalone stanza, gated)
- Create: `test/fixtures/sshd/Dockerfile` (alpine + openssh + git + gh + the statically built shim installed at `/usr/local/bin/masc-exec-shim`; a dedicated fixture keypair baked with 0600; `MaxSessions 10`)
- Create: `test/fixtures/sshd/entrypoint.sh`, `scripts/test-ssh-fixture.sh` (build image, run container on an ephemeral port, export `MASC_TEST_SSH_FIXTURE=host:port:keydir`)

- [ ] **Step 1: Fixture scripts first** — `scripts/test-ssh-fixture.sh` builds the image (running `scripts/build-shim-static.sh` if the artifact is stale), starts the container, waits for sshd readiness, prints the fixture coordinates. It must clean up the container on exit (trap).

- [ ] **Step 2: Write the integration test** — `test/test_keeper_ssh_integration.ml` skips loudly unless `MASC_TEST_SSH_FIXTURE` is set (Alcotest `skip` pattern used elsewhere in the suite — find the precedent with `grep -rn "Skip\|skip" test/*.ml | grep -i env | head -5`). Cases against the live fixture:

```ocaml
(* echo round-trip: stdout/stderr split preserved, exit 0 *)
(* hostile bytes: invalid-UTF-8 argv, NUL stdin, 1 MiB payload round-trip losslessly *)
(* trailer integrity: remote `exit 3` surfaces WEXITED 3; `kill -9 $$` surfaces WSIGNALED 9 *)
(* cancel quiet payload: start `sleep 600`, cancel after 1s, then ssh into the
   fixture and assert `pgrep -f "sleep 600"` finds nothing (no remote orphans) *)
(* host-side invariant: after all cases, run `ps -Ao args` on the masc host and
   assert the payload argv markers appear nowhere except inside ssh client
   transports (this is the automated form of the §8 success criterion) *)
(* env policy: wire PATH attempt is dropped (remote `env` output proves it);
   allowlisted FOO crosses *)
(* preflight against the fixture: ready; then point at a stopped port:
   remote_ssh_endpoint_unreachable *)
```

- [ ] **Step 3: Run gated locally** — `scripts/test-ssh-fixture.sh` in one shell, then `MASC_TEST_SSH_FIXTURE=... scripts/dune-local.sh build test/test_keeper_ssh_integration.exe && _build/default/test/test_keeper_ssh_integration.exe`. Record the outcome in the PR description (CI without Docker skips the fixture — same posture as other Docker-dependent tests).

- [ ] **Step 4: Commit** — `test(keeper): SSH lane end-to-end fixture — cancel reaps remote pgid, host ps invariant`

### Task 11: Docs — RFC-0395, runbook, AGENTS.md sweep

**Files:**
- Create: `docs/rfc/RFC-0395-ssh-remote-exec-lane.md` (strategy RFC; number follows RFC-0394 from Phase 0 — verify the next free number with `ls docs/rfc/ | tail -5`)
- Create: `docs/operations/ssh-endpoints-runbook.md` — endpoint provisioning (bootstrap tool), fingerprint confirmation ritual, shim upgrade procedure, keeper migration steps (`sandbox_profile = "remote_ssh"` + `remote_endpoint`), failure-mode table (every named error → meaning → operator action)
- Modify: `AGENTS.md` + any nested `AGENTS.md` whose sandbox/exec conventions changed; `config/runtime.toml` example cross-reference

- [ ] **Step 1: Write the RFC** — context (Phase 0 gate shipped), decision (SSH lane as the universal remote transport; microVM = config change in Phase 2), alternatives (mTLS+HTTP executor, gRPC stream — why pinned OpenSSH wins: battle-tested auth/encryption, zero new listening service), consequences.

- [ ] **Step 2: Write the runbook** — every named error string from Tasks 1-9 appears in the failure-mode table (grep the diff for `remote_ssh_` to enumerate them; the table must be complete).

- [ ] **Step 3: AGENTS.md sweep** — update sandbox profile conventions; document the fixture-gated test (`MASC_TEST_SSH_FIXTURE`) and the static shim build.

- [ ] **Step 4: Commit** — `docs: RFC-0395 SSH remote exec lane + operator runbook`

### Task 12: Final review + PR

- [ ] **Step 1: Full suite** — `scripts/ci-run-tests.sh "scripts/dune-local.sh test"`; diff failures against `/tmp/masc-gate-suite-final.log` baseline (only pre-existing failures may remain, same set as Phase 0).
- [ ] **Step 2: Contract/TLA harness** — run whatever Phase 0 used (`scripts/check-tla.sh` or the dune alias recorded in the Phase 0 plan) plus the structural lint that Phase 0 touched (`test_keeper_local_playground_gate` overlay site precedent).
- [ ] **Step 3: Reviewer subagent** — requesting-code-review flow against the spec §4.2/§5/§6 (fresh reviewer, not an implementer); resolve or explicitly defer every finding.
- [ ] **Step 4: PR** — `gh pr create` on branch `feat/ssh-remote-exec-lane-20260827`, body per Phase 0's format (goal, design summary, test evidence incl. the gated integration run output, named-error catalog, follow-ups: Phase 2 microVM, keeper-by-keeper migration). Reference spec file and RFC-0395. Note the stacked-base relationship to PR #31202 in the body.

---

## Self-review (author, 2026-08-27)

**Spec coverage** — every §4.2 subsection maps to a task: Target type → T3; Profile → T1; Runner → T6; Remote shim → T4+T5; Path mapping → T7; Provisioning → T9; Preflight → T9; Config surface → T2; Secret policy → T8; Docker-parity hardening (network_mode) → T1. §5 (security model): `-F none`/pinning/`IdentitiesOnly` → T6 argv test; secrets → T8; fail-closed → T1/T2/T9; shim-side path re-validation → T5 (shim core) + T10 (e2e). §6 (testing): every listed Phase 1 test item appears in T4/T6/T10 test code. §8: host `ps` invariant is an automated assertion in T10, not a manual check.

**Placeholder scan** — no `TODO`/`...`/`implement me` in code blocks; every "adapt to actual entrypoint" note names the file where the real signature lives.

**Type consistency** — `Sandbox_target.ssh_endpoint` (T3) is the `lib/exec` projection; `Exec_ssh_endpoint.t` (T2) is the config-layer record; the keeper layer converts one to the other at target construction (T6). The two records are deliberately separate: `lib/exec` stays dependency-clean. `runner`/`pipeline_runner` closure shapes are copied verbatim from the `Docker` arm so `Exec_dispatch` routing needs no new plumbing.

**Known risks carried into implementation** — (1) static OCaml+musl build with a C stub inside `ocaml/opam:alpine` is the plan's least-verified claim; T5 Step 5 fails loudly if `file` disagrees, and the fallback is a two-stage Dockerfile that compiles in one stage and ships the artifact in the fixture stage. (2) The stderr-tail trailer detection must keep exactly enough trailing bytes; T4's hostile-byte cases pin the boundary. (3) `parse_string` entrypoint names in T2 tests are illustrative; the real `runtime_toml` parse entrypoint is used.
