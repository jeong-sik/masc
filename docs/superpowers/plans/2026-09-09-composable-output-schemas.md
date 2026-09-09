# G1 — Typed `composable_output` for the top keeper tools — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give real `Json_output` schemas to the most-used keeper tools so `Keeper_tool_plan` nodes can chain them: node B's input references node A's output via RFC-6901 pointers, schema-checked at plan-create time (`keeper_tool_plan.ml:1046-1072`) and value-checked at execution time (`keeper_tool_plan_executor.ml:268-277`).

**Architecture:** `composable_output` is **not TOML-declared** — it is a field on the OCaml descriptor record (`keeper_tool_descriptor.ml:427` defaults it to `Opaque_output`; `with_composable_output` at line 562 applies a `Json_output { schema }`). The composition executor validates `Tool_result.data` of each `Completed` node against that schema. The data path is: producer → `Keeper_tool_execution.t` (`success_data` sets `data = Some json`, `success` sets `data = None`, `keeper_tool_execution.ml:39-62`) → `producer_payload` (`Some data -> data | None -> `String raw`, `keeper_tools_agent_core_handler_exec.ml:13-16`) → `Tool_result.output_payload.data` → `Keeper_tool_plan.validate_output`.

**Key design answer:** for Read/Grep/Write/Edit the runtime currently emits **no structured data** — they build a `Yojson.Safe.t` assoc, stringify it, and call `Keeper_tool_execution.success (Yojson.Safe.to_string x)`. The minimal, behavior-preserving change is `success_data x` instead: `success_data` sets `raw_output = Yojson.Safe.to_string data`, byte-identical to today, so the model-facing projection (`tool_bridge.ml:280` `project_result` renders `message`, i.e. `raw_output`; `structured_content` is only scanned for `_blob` artifact refs, which these payloads never contain) does not change. Execution change is therefore a mechanical `success`→`success_data` swap at each tool's single success-construction site, plus retyping two internal `payload : string` fields to `Yojson.Safe.t`. No TOML, no validator, no executor changes — the whole composition pipeline already exists and is already exercised by 13 tools (Execute, keeper_spawn, keeper_time_now, …).

**Tech stack:** OCaml 5.5, dune, yojson, alcotest-style test runners.

**Two tests force completeness for every newly declared tool:**
- `test_composable_output_registry_is_closed` (`test/test_keeper_tool_plan.ml:850`) — hardcoded sorted list of `Json_output` model names; fails until new names are added.
- `test_every_composable_tool_has_an_output_probe` (`test/test_keeper_tool_dispatch_runtime.ml:7317`) — every declared tool must have a runtime probe in `composable_output_probes` (line 7200) that runs the real producer through `KET.execute_keeper_tool_call_with_outcome` and validates the emitted `data` against the declared schema.

## Files map

| File | Responsibility |
|---|---|
| `lib/keeper/keeper_tool_descriptor.ml` | New `*_output_schema` values (next to existing ones, ~line 1300-1470); `\|> with_composable_output (Json_output { schema = … })` on the Grep/Read/Edit/Write descriptors (lines 683-791) |
| `lib/keeper/keeper_tool_filesystem_runtime.ml` | Read + Write/Edit producers: retype `Read_succeeded`/`Write_succeeded.payload` to `Yojson.Safe.t`, `success`→`success_data` (lines 315-318, 368-379, 447, 1470-1473, 1978-1979, 2446-2460, 2826-2847) |
| `lib/keeper/keeper_workspace_read_ops.ml` | Grep producer: two payload sites (sandbox lane 205-220, host lane 269-284) → `success_data` |
| `lib/keeper/keeper_tool_filesystem_remote_write.ml` | Remote (endpoint-owned) write lane: `success_payload` returns `Yojson.Safe.t`, `success`→`success_data` (lines 89-95, 161-166 and any sibling call sites) |
| `test/test_keeper_tool_plan.ml` | Registry-closed list (870-889); producer-shape samples in `test_new_declared_output_schemas_admit_producer_shapes` (909+); new typed-chain test |
| `test/test_keeper_tool_plan_executor.ml` | New end-to-end chain test through `Executor.execute` |
| `test/test_keeper_tool_dispatch_runtime.ml` | Four new `composable_output_probes` entries (7200-7315) |

## Tool selection

`~/.masc/tool_calls/` JSONL logs do not exist on this machine (only `~/.masc/tool-metrics.sqlite3`). Selection is inferred from the keeper toolset: the public LLM-native surface is exactly Execute, Grep, Read, Edit, Write, WebSearch, WebFetch, Browser* (`keeper_tool_descriptor.ml` `~public_name:` sites). Execute is already typed. The canonical keeper flow is **Grep → Read → Edit/Write**, so:

- **PR-1 (this plan, fully specified):** `Read`, `Grep`, `Write`, `Edit`. Write and Edit share one handler (`handle_file_write_with_outcome`, dispatched for both `Tool_edit_file | Tool_write_file`, `keeper_tool_runtime.ml:58-69`) and one success type, so one producer change covers both.
- **PR-2 (recipe only, shapes to be read at their construction sites):** `keeper_memory_search` (change site known: `keeper_tool_memory_runtime.ml:447` `success (Yojson.Safe.to_string result)` → `success_data result`; probe-able like `keeper_tasks_list`), `masc_board_post`, `keeper_context_status`. **WebFetch is deferred**: its data is already typed (`tool_misc_web_fetch.ml:868` `make_ok ~data`), but the forced runtime probe would need a hermetic fetch — see Risks.

Optional verification the implementing engineer may run (read-only, allowed): `sqlite3 ~/.masc/tool-metrics.sqlite3` frequency query to confirm the ranking.

---

## Task 1 — Output schemas in `lib/keeper/keeper_tool_descriptor.ml`

**Files:** Modify `lib/keeper/keeper_tool_descriptor.ml` (after line 1311, next to `time_now_output_schema`)

- [ ] **Step 1: Add the three schemas.** Follow the file's convention: a comment naming the single producer construction site with path (the producer-shape test comment at `test_keeper_tool_plan.ml:906-908` relies on this).

```ocaml
(* Producer: Keeper_tool_filesystem_runtime.handle_read_file_with_outcome
   [payload_of_slice] (lib/keeper/keeper_tool_filesystem_runtime.ml). [via]
   marks a backend-routed read and is absent on the host lane; [next_offset]
   appears only on a truncated window; [file_bytes] only on the host lane;
   [last_line_partial] only when the window ends mid-line. *)
let read_file_output_schema =
  object_output_schema
    ~properties:
      [ "ok", `Assoc [ "type", `String "boolean" ]
      ; "path", `Assoc [ "type", `String "string" ]
      ; "bytes", `Assoc [ "type", `String "integer" ]
      ; "truncated", `Assoc [ "type", `String "boolean" ]
      ; "offset", `Assoc [ "type", `String "integer" ]
      ; "returned_lines", `Assoc [ "type", `String "integer" ]
      ; "content", `Assoc [ "type", `String "string" ]
      ; "next_offset", `Assoc [ "type", `String "integer" ]
      ; "last_line_partial", `Assoc [ "type", `String "boolean" ]
      ; "file_bytes", `Assoc [ "type", `String "integer" ]
      ; "via", `Assoc [ "type", `String "string" ]
      ]
    ~required:
      [ "ok"; "path"; "bytes"; "truncated"; "offset"; "returned_lines"; "content" ]
;;

(* Producer: Keeper_workspace_read_ops.try_handle_with_outcome, rg lane —
   the sandbox-routed and host argv branches build the same envelope
   (lib/keeper/keeper_workspace_read_ops.ml). [error_detail] is failure-side
   only; composition validation sees Completed nodes, where it is absent, but
   it is declared so a future ok-with-detail producer cannot drift silently. *)
let search_files_output_schema =
  object_output_schema
    ~properties:
      [ "ok", `Assoc [ "type", `String "boolean" ]
      ; "op", `Assoc [ "type", `String "string" ]
      ; "path", `Assoc [ "type", `String "string" ]
      ; "pattern", `Assoc [ "type", `String "string" ]
      ; "via", `Assoc [ "type", `String "string" ]
      ; ( "status"
        , `Assoc
            [ "type", `String "object"
            ; ( "properties"
              , `Assoc
                  [ "kind", `Assoc [ "type", `String "string" ]
                  ; "code", `Assoc [ "type", `String "integer" ]
                  ; "signal", `Assoc [ "type", `String "integer" ]
                  ] )
            ; "required", `List [ `String "kind" ]
            ; "additionalProperties", `Bool false
            ] )
      ; ( "matches"
        , `Assoc
            [ "type", `String "array"; "items", `Assoc [ "type", `String "string" ] ] )
      ; "error_detail", `Assoc [ "type", `String "string" ]
      ]
    ~required:[ "ok"; "op"; "path"; "pattern"; "via"; "status"; "matches" ]
;;

(* Producer: Keeper_tool_filesystem_runtime content-write (overwrite/append)
   and patch-write [Write_succeeded] sites, and
   Keeper_tool_filesystem_remote_write.success_payload for endpoint-owned
   trees. [via] is absent on the host lane; the patch operation fields appear
   only under mode "patch". Shared by tool_write_file and tool_edit_file,
   which share one handler. *)
let file_write_output_schema =
  object_output_schema
    ~properties:
      [ "ok", `Assoc [ "type", `String "boolean" ]
      ; "path", `Assoc [ "type", `String "string" ]
      ; "mode", `Assoc [ "type", `String "string" ]
      ; "bytes_written", `Assoc [ "type", `String "integer" ]
      ; "via", `Assoc [ "type", `String "string" ]
      ; "occurrences", `Assoc [ "type", `String "integer" ]
      ; "replace_all", `Assoc [ "type", `String "boolean" ]
      ; "insert_before_line", `Assoc [ "type", `String "integer" ]
      ; "inserted", `Assoc [ "type", `String "string" ]
      ]
    ~required:[ "ok"; "path"; "mode"; "bytes_written" ]
;;
```

All three satisfy the closed schema contract (`validate_composable_schema`, enforced automatically by `test_declared_output_schemas_satisfy_the_contract`).

- [ ] **Step 2: Attach schemas to the four descriptors.** In `public_descriptors` (`keeper_tool_descriptor.ml`):

- Grep descriptor (lines 683-712): wrap the element in parentheses and append `|> with_composable_output (Json_output { schema = search_files_output_schema })`.
- Read descriptor (713-741): append `|> with_composable_output (Json_output { schema = read_file_output_schema })`.
- Edit descriptor (742-766): append `|> with_composable_output (Json_output { schema = file_write_output_schema })`.
- Write descriptor (767-791): append `|> with_composable_output (Json_output { schema = file_write_output_schema })`.

Exact idiom (mirrors line 682):

```ocaml
  ; (descriptor
       ~capability_identity:Internal_name_identity
       …  (* unchanged Grep fields *)
       ()
     |> with_composable_output (Json_output { schema = search_files_output_schema }))
```

## Task 2 — Producer: Read (`lib/keeper/keeper_tool_filesystem_runtime.ml`)

**Files:** Modify `lib/keeper/keeper_tool_filesystem_runtime.ml`

- [ ] **Step 1: Retype the attempt (lines 315-318):**

```ocaml
type read_file_attempt =
  | Read_succeeded of Yojson.Safe.t
  | Read_failed_payload of string
  | Read_failed_message of string
```

- [ ] **Step 2:** `payload_of_slice` (368-379): drop the `Yojson.Safe.to_string` wrapper — return the `` `Assoc `` directly.

- [ ] **Step 3:** Consumer (447): `| Ok (Read_succeeded json) -> Keeper_tool_execution.success_data json`.

- [ ] **Step 4:** `handle_owned_read_file_with_outcome` (655-667): same swap (`success (Yojson.Safe.to_string x)` → `success_data x`). This lane serves `verification_authority_tools.ml:300`, not composition, but it emits the identical envelope; keeping it stringly would re-create the drift this work removes. `raw_output` is byte-identical either way.

## Task 3 — Producer: Grep (`lib/keeper/keeper_workspace_read_ops.ml`)

**Files:** Modify `lib/keeper/keeper_workspace_read_ops.ml`

- [ ] **Step 1: Both lanes (sandbox 205-220, host 269-284).** Keep failure paths on strings (failures are never composition-validated); only the success branch becomes typed:

```ocaml
let payload =
  `Assoc
    ([ "ok", `Bool is_ok
     ; "op", `String op
     ; "path", `String target
     ; "pattern", `String pattern
     ; "via", `String Keeper_sandbox_read_runner.backend_via
     ; "status", Keeper_alerting_path.process_status_to_json st
     ; "matches", (if is_ok then lines_to_json ~limit out else `List [])
     ]
     @ error_detail)
in
if is_ok
then Keeper_tool_execution.success_data payload
else Keeper_tool_execution.failure (Yojson.Safe.to_string payload)
```

(host lane identical, with `"via", `String "host"` and `result.stdout`.)

## Task 4 — Producer: Write/Edit (`lib/keeper/keeper_tool_filesystem_runtime.ml` + remote lane)

**Files:** Modify `lib/keeper/keeper_tool_filesystem_runtime.ml`, `lib/keeper/keeper_tool_filesystem_remote_write.ml`

- [ ] **Step 1: Retype the success payload (1470-1473):**

```ocaml
  | Write_succeeded of
      { payload : Yojson.Safe.t
      ; file_change_evidence : Keeper_file_change_evidence.t option
      }
```

(`Write_failed.payload` stays `string`.)

- [ ] **Step 2:** Consumer (1978-1979): `let execution = Keeper_tool_execution.success_data payload in`.

- [ ] **Step 3:** Content-write success site (2446-2455) and patch-write success site (2826-2838): drop the `Yojson.Safe.to_string` around the `` `Assoc ``.

- [ ] **Step 4:** Remote lane (`keeper_tool_filesystem_remote_write.ml`): change `success_payload` (89-95) to return the `` `Assoc `` without `Yojson.Safe.to_string`; change its success call site(s) (162-166, and any sibling `Keeper_tool_execution.success (success_payload …)` occurrences for mkdir/append in the same file — verify by grep) to `success_data`.

## Task 5 — Tests

**Files:** Modify `test/test_keeper_tool_plan.ml`, `test/test_keeper_tool_plan_executor.ml`, `test/test_keeper_tool_dispatch_runtime.ml`

- [ ] **Step 1: `test/test_keeper_tool_plan.ml`** — `test_composable_output_registry_is_closed` (870-889), new sorted list:

```ocaml
    [ "Edit"
    ; "Execute"
    ; "Grep"
    ; "Read"
    ; "Write"
    ; "keeper_artifact_read"
    ; "keeper_lane_status"
    ; "keeper_spawn"
    ; "keeper_tasks_list"
    ; "keeper_time_now"
    ; "masc_agent_fitness"
    ; "masc_board_list"
    ; "masc_board_stats"
    ; "masc_get_metrics"
    ; "masc_goal_list"
    ; "masc_msx_screen"
    ; "masc_run_list"
    ]
```

- [ ] **Step 2: `test/test_keeper_tool_plan.ml`** — extend `test_new_declared_output_schemas_admit_producer_shapes` (909+) with producer-shaped samples:

```ocaml
  accepts
    "Read"
    (`Assoc
       [ "ok", `Bool true
       ; "path", `String "/keeper/probe/a.ml"
       ; "bytes", `Int 12
       ; "truncated", `Bool false
       ; "offset", `Int 0
       ; "returned_lines", `Int 3
       ; "content", `String "let a = 1\n"
       ; "file_bytes", `Int 4096
       ; "next_offset", `Int 4
       ; "last_line_partial", `Bool true
       ; "via", `String "backend"
       ]);
  rejects "Read" (`Assoc [ "ok", `Bool true; "path", `String "/x" ]);
  accepts
    "Grep"
    (`Assoc
       [ "ok", `Bool true
       ; "op", `String "rg"
       ; "path", `String "/keeper/probe"
       ; "pattern", `String "probe"
       ; "via", `String "host"
       ; "status", `Assoc [ "kind", `String "exit"; "code", `Int 0 ]
       ; "matches", `List [ `String "a.ml:1:probe" ]
       ]);
  rejects
    "Grep"
    (`Assoc
       [ "ok", `Bool true; "op", `String "rg"; "path", `String "/p"
       ; "pattern", `String "p"; "via", `String "host"
       ; "status", `Assoc [ "kind", `String "exit"; "code", `Int 0 ]
       ; "matches", `List [ `Int 1 ] ]);
  accepts
    "Write"
    (`Assoc
       [ "ok", `Bool true; "path", `String "/keeper/probe/out.txt"
       ; "mode", `String "overwrite"; "bytes_written", `Int 5 ]);
  accepts
    "Edit"
    (`Assoc
       [ "ok", `Bool true; "path", `String "/keeper/probe/out.txt"
       ; "mode", `String "patch"; "replace_all", `Bool false
       ; "occurrences", `Int 1; "bytes_written", `Int 9
       ; "via", `String "remote-ssh" ]);
  rejects
    "Edit"
    (`Assoc [ "ok", `Bool true; "path", `String "/x"; "mode", `String "patch" ])
```

- [ ] **Step 3: `test/test_keeper_tool_plan.ml`** — new test (register it in the `run` block next to `"composable output drift"` at 2297), proving a typed reference from a new tool resolves into a consumer's validated input — mirrors `test_output_schema_and_consumer_input_are_enforced` (485-585) but exercises the real Read producer:

```ocaml
let test_read_output_feeds_grep_path_input () =
  let read_id = node_id "read" in
  let read_node =
    node ~id:"read" ~tool_name:"Read"
      (object_template [ "path", Plan.Json_template.literal (`String "a.ml") ])
  in
  let grep_node =
    node ~id:"grep" ~tool_name:"Grep"
      (object_template
         [ "pattern", Plan.Json_template.literal (`String "probe")
         ; "path", Plan.Json_template.output ~node_id:read_id ~pointer:(pointer "/path")
         ])
  in
  let plan =
    match Plan.create ~descriptors:(descriptors ()) [ read_node; grep_node ] with
    | Ok plan -> plan
    | Error _ -> fail "Read -> Grep typed chain was rejected"
  in
  let run_id = Plan.Run_id.fresh () in
  let read_output =
    match Plan.validate_output plan ~run_id ~node_id:read_id
            (`Assoc
               [ "ok", `Bool true; "path", `String "/keeper/probe/a.ml"
               ; "bytes", `Int 4; "truncated", `Bool false; "offset", `Int 0
               ; "returned_lines", `Int 1; "content", `String "probe" ])
    with
    | Ok output -> output
    | Error _ -> fail "producer-shaped Read output violated its declared schema"
  in
  let lookup id = if Plan.Node_id.equal id read_id then Some read_output else None in
  match Plan.resolve_input plan ~run_id ~node_id:(node_id "grep") ~lookup with
  | Ok (`Assoc fields) ->
    check string "Grep path came from Read output" "/keeper/probe/a.ml"
      Yojson.Safe.Util.(List.assoc "path" fields |> to_string)
  | Ok _ | Error _ -> fail "resolved Grep input lost the referenced path"
```

Also assert the invalid-pointer direction still fails closed for the new tools: a `Output { node_id: read; pointer: "/nonexistent" }` reference must give `Error (Plan.Invalid_output_pointer _)` at `Plan.create`.

- [ ] **Step 4: `test/test_keeper_tool_plan_executor.ml`** — new test `test_typed_output_flows_to_consumer_dispatch_input`: two-node plan (Read → Grep as above), `Executor.execute` with a stub `dispatch` that returns `completed ~tool_name:"Read" ~data:<producer-shaped assoc>` for node "read" and captures `input` for node "grep"; assert the captured grep input's `"path"` equals the read path. Mirrors `test_schedule_and_parallel_dataflow` (87-150).

- [ ] **Step 5: `test/test_keeper_tool_dispatch_runtime.ml`** — add four entries to `composable_output_probes` (after 7314), with `prepare` creating real fixture state (pattern: `keeper_tasks_list` probe at 7226-7253; the exec fixture already runs `Workspace.init`, `bind_session`, and `~always_allow:true`, so Gate admits the writes):

```ocaml
  ; { tool_name = "Write"
    ; needs_sandbox = false
    ; prepare =
        (fun ~config:_ ~meta:_ ->
           `Assoc
             [ "path", `String "composable-output-probe.txt"
             ; "content", `String "composable output probe\n"
             ; "mode", `String "overwrite"
             ])
    }
  ; { tool_name = "Read"
    ; needs_sandbox = false
    ; prepare =
        (fun ~config:_ ~meta:_ ->
           `Assoc [ "path", `String "composable-output-probe.txt" ])
    }
  ; { tool_name = "Grep"
    ; needs_sandbox = false
    ; prepare =
        (fun ~config:_ ~meta:_ ->
           `Assoc
             [ "pattern", `String "composable output probe"
             ; "path", `String "composable-output-probe.txt"
             ])
    }
  ; { tool_name = "Edit"
    ; needs_sandbox = false
    ; prepare =
        (fun ~config:_ ~meta:_ ->
           `Assoc
             [ "path", `String "composable-output-probe.txt"
             ; "mode", `String "append"
             ; "content", `String "second line\n"
             ])
    }
```

Probe-order note: the list is executed in order (7478-7522), so Write must precede Read/Grep/Edit. The exact `path` spellings the fixture's sandbox root accepts must be confirmed by reading `with_exec_fixture` + `test_keeper_tool_read_window.ml` during implementation (that test already constructs a readable fixture file through the same handler — copy its path setup). `Keeper_tool_write_mode.of_args` rejects an absent mode (filesystem_runtime.ml:2250-2252), so `mode` is required in Write/Edit probe args; confirm "append" is a valid mode spelling there.

## Task 6 — Commit and workflow (constitution: no local build loops)

- [ ] **Step 1:** Self-review by re-reading each changed hunk against this plan; specifically re-check that every remaining `Keeper_tool_execution.success (Yojson.Safe.to_string …)` site inside the four producers is a **failure** path (those stay stringly).
- [ ] **Step 2:** Single commit on this worktree branch: `feat(keeper): typed composable_output for Read/Grep/Write/Edit`, containing descriptor schemas, producer changes, and all test updates together (tests and implementation land atomically — the registry-closed and probe-coverage tests fail on any half-applied state).
- [ ] **Step 3:** Push; CI runs `test_keeper_tool_plan`, `test_keeper_tool_plan_executor`, `test_keeper_tool_dispatch_runtime` (stanzas exist: `test/dune:396`, `test/dune:2414-2416`) plus the full suite, which catches any unspotted golden/route-evidence pinning.

## PR-2 (stacked on PR-1, same recipe — smaller spec, follow-up)

Per tool: read the single success-construction site, swap `success (Yojson.Safe.to_string x)` → `success_data x`, add a schema next to PR-1's, extend the registry list + probes + producer-shape samples.

- `keeper_memory_search` — change site: `lib/keeper/keeper_tool_memory_runtime.ml:447`. Probe pattern: seed a memory entry in `prepare`, like the `keeper_tasks_list` probe seeds tasks. Schema fields: read the `result` assoc built above line 402-447 (`match_count`, results list, …).
- `masc_board_post` / keeper message — discover the dispatch output in the board dispatch cluster before writing the schema.
- **Do not** include `WebFetch` unless the probe problem is solved (Risks).

Size check: PR-1 touches 4 source files + 3 test files, ~250 new/changed lines — within one ≤20k-token work unit.

---

## Risks / open questions

1. **Probe path vocabulary (unverified).** Whether `composable-output-probe.txt` (relative) resolves under the dispatch fixture's sandbox roots for Read/Grep/Write was not fully traced (`resolve_read_file_target`, `resolve_keeper_confined_write_path`). Mitigation: `test/test_keeper_tool_read_window.ml` and `test_keeper_fs_edit_patch.ml` already drive these exact handlers in fixtures — copy their path setup. Worst case, probe `prepare` writes via `Workspace`-anchored absolute paths from `config.base_path` (but note Grep's path goes through `Keeper_sandbox_read_runner.container_path_of_host` on sandbox-routed metas; the fixture profile determines which lane runs).
2. **Write/Edit mode spellings.** `"overwrite"` / `"append"` assumed from `Keeper_tool_write_mode.of_args` (not read). If the enum differs, probe args and the schema's `mode` field stay `type: string` regardless — only the probe args change.
3. **WebFetch probe hermeticity.** `test_every_composable_tool_has_an_output_probe` forces a live producer run for every declared tool. WebFetch performs a real HTTP fetch (`tool_misc_web_fetch.ml`); unless `fetch_impl` is injectable or a loopback fixture exists, declaring its schema would introduce a network-dependent test. Left out of PR-1/PR-2 pending an explore pass on `fetch_impl` injection seams.
4. **Other `success_payload` call sites in `keeper_tool_filesystem_remote_write.ml`.** Only lines 89-95/161-166 were read; mkdir/append remote successes may exist. Engineer greps the file before editing.
5. **Route evidence / golden fixtures.** Descriptor receipt labels include `"composable_output", "opaque"→"json"` (`keeper_tool_descriptor.ml:522`). I checked `test/fixtures/tool_call_quality_benchmark/evidence_runs.json` (no `composable_output` key) and found no test pinning the label for these four descriptors, but a repo-wide golden could exist that grep didn't surface; CI is the backstop.
6. **Tool ranking is inferred, not measured** — `~/.masc/tool_calls/` JSONL does not exist on this host; `tool-metrics.sqlite3` does. If measured usage contradicts the Read/Grep/Write/Edit choice, the plan's per-tool recipe is unchanged; only the tool set moves.
7. **`handle_owned_read_file_with_outcome` swap (Task 2 step 4)** is optional for composition but recommended for drift avoidance; it is consumed by `lib/verification_authority_tools.ml:300`, whose tests (`test_owned_read_cwd.ml`) assert on `raw_output` — byte-identical after the change, so expected green, but flag if CI disagrees.
