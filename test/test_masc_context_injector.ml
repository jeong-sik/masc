(** Tests for MCI. *)

open Alcotest
module MCI = Masc.Masc_context_injector

(* ── Helpers ──────────────────────────────────────────── *)

let ok_output content : Agent_core.Types.tool_result =
  Ok { Agent_core.Types.content; _meta = None }

let err_output message : Agent_core.Types.tool_result =
  Error { Agent_core.Types.message; recoverable = true; error_class = None }

(* ── Unit tests: injector function ──────────────────── *)

let test_injector_returns_some_on_success () =
  let config = MCI.default_config () in
  let injector = MCI.make ~config () in
  match injector ~tool_name:"read_file" ~input:`Null ~output:(ok_output "data") with
  | Some inj ->
    check bool "has context_updates" true
      (List.length inj.Agent_core.Hooks.context_updates > 0);
    check bool "no extra_messages" true
      (inj.extra_messages = [])
  | None -> fail "expected Some injection"

let test_injector_returns_some_on_error () =
  let config = MCI.default_config () in
  let injector = MCI.make ~config () in
  match injector ~tool_name:"read_file" ~input:`Null ~output:(err_output "not found") with
  | Some inj ->
    let last_outcome =
      List.assoc MCI.key_last_tool_outcome
        inj.Agent_core.Hooks.context_updates
    in
    check (of_pp Yojson.Safe.pp) "outcome is error"
      (`String "error") last_outcome
  | None -> fail "expected Some injection"

let test_injector_increments_counts () =
  let config = MCI.default_config () in
  let injector = MCI.make ~config () in
  ignore (injector ~tool_name:"t1" ~input:`Null ~output:(ok_output "ok"));
  ignore (injector ~tool_name:"t2" ~input:`Null ~output:(ok_output "ok"));
  match injector ~tool_name:"t3" ~input:`Null ~output:(err_output "err") with
  | Some inj ->
    let updates = inj.Agent_core.Hooks.context_updates in
    let count = List.assoc MCI.key_tool_call_count updates in
    check (of_pp Yojson.Safe.pp) "3 total calls" (`Int 3) count;
    let success = List.assoc MCI.key_tool_success_count updates in
    check (of_pp Yojson.Safe.pp) "2 successes" (`Int 2) success;
    let errors = List.assoc MCI.key_tool_error_count updates in
    check (of_pp Yojson.Safe.pp) "1 error" (`Int 1) errors
  | None -> fail "expected Some injection"

(* ── Context.t integration ──────────────────────────── *)

let test_context_populated_after_injection () =
  let config = MCI.default_config () in
  let injector = MCI.make ~config () in
  let ctx = Agent_core.Context.create_sync () in
  match injector ~tool_name:"bash" ~input:`Null ~output:(ok_output "done") with
  | Some inj ->
    List.iter (fun (k, v) -> Agent_core.Context.set ctx k v)
      inj.Agent_core.Hooks.context_updates;
    (match Agent_core.Context.get ctx MCI.key_last_tool_name with
     | Some (`String "bash") -> ()
     | _ -> fail "last_tool_name not set");
    (match Agent_core.Context.get ctx MCI.key_wall_time with
     | Some (`String s) ->
       check bool "ends with Z" true (String.length s > 0 && s.[String.length s - 1] = 'Z')
     | _ -> fail "wall_time not set")
  | None -> fail "expected Some injection"

let test_context_updates_overwrite_bounded_keys () =
  let config = MCI.default_config () in
  let injector = MCI.make ~config () in
  let ctx = Agent_core.Context.create_sync () in
  let expected_keys =
    [
      MCI.key_wall_time;
      MCI.key_session_start;
      MCI.key_tool_call_count;
      MCI.key_last_tool_name;
      MCI.key_last_tool_outcome;
      MCI.key_tool_success_count;
      MCI.key_tool_error_count;
    ]
    |> List.sort String.compare
  in
  for idx = 1 to 200 do
    let tool_name = Printf.sprintf "tool_%03d" idx in
    match injector ~tool_name ~input:`Null ~output:(ok_output "done") with
    | Some inj ->
      List.iter
        (fun (key, value) -> Agent_core.Context.set ctx key value)
        inj.Agent_core.Hooks.context_updates
    | None -> fail "expected Some injection"
  done;
  check
    (list string)
    "context keys stay bounded"
    expected_keys
    (Agent_core.Context.keys ctx |> List.sort String.compare);
  (match Agent_core.Context.get ctx MCI.key_tool_call_count with
   | Some (`Int 200) -> ()
   | other ->
     fail
       (Printf.sprintf
          "expected 200 tool calls, got %s"
          (Yojson.Safe.to_string
             (Option.value ~default:`Null other))));
  match Agent_core.Context.get ctx MCI.key_last_tool_name with
  | Some (`String "tool_200") -> ()
  | other ->
    fail
      (Printf.sprintf
         "expected last tool to be tool_200, got %s"
         (Yojson.Safe.to_string (Option.value ~default:`Null other)))

(* ── Temporal summary rendering ─────────────────────── *)

(* #32199: a turn before any tool execution still gets the clock — and
   nothing else, since neither the session anchor nor tool metadata
   exists yet. *)
let test_render_temporal_summary_empty () =
  let ctx = Agent_core.Context.create_sync () in
  let now = 1_800_000_000.0 in
  check string "a fresh context renders the clock alone"
    ("[Temporal] time=" ^ MCI.iso8601_of_float now)
    (MCI.render_temporal_summary ~now ctx)

let test_render_temporal_summary_populated () =
  let ctx = Agent_core.Context.create_sync () in
  let now = 1_800_000_000.0 in
  Agent_core.Context.set ctx
    MCI.key_wall_time (`String "2026-04-06T12:00:00Z");
  Agent_core.Context.set ctx
    MCI.key_session_start (`Float (now -. 42.5));
  Agent_core.Context.set ctx
    MCI.key_tool_call_count (`Int 3);
  Agent_core.Context.set ctx
    MCI.key_last_tool_name (`String "tool_execute");
  Agent_core.Context.set ctx
    MCI.key_last_tool_outcome (`String "ok");
  let summary = MCI.render_temporal_summary ~now ctx in
  check bool "contains time" true
    (Astring.String.is_prefix ~affix:"[Temporal]" summary);
  check bool "contains tool name" true
    (Astring.String.is_infix ~affix:"tool_execute" summary);
  check bool "contains elapsed" true
    (Astring.String.is_infix ~affix:"elapsed=42s" summary)

(* Regression: turn N+1 must render the *fresh* current time, not the
   last tool call's timestamp frozen in [key_wall_time] from turn N
   (the idle-wake bug). Uses a fixed [~now] far in the future
   relative to the stored (stale) values. *)
let test_render_uses_fresh_now_not_stale () =
  let ctx = Agent_core.Context.create_sync () in
  let stale_now = 1_700_000_000.0 in
  (* 2023-11-14T22:13:20Z *)
  let session_start = stale_now -. 100.0 in
  Agent_core.Context.set ctx
    MCI.key_wall_time (`String (MCI.iso8601_of_float stale_now));
  Agent_core.Context.set ctx
    MCI.key_session_start (`Float session_start);
  Agent_core.Context.set ctx
    MCI.key_tool_call_count (`Int 2);
  Agent_core.Context.set ctx
    MCI.key_last_tool_name (`String "bash");
  Agent_core.Context.set ctx
    MCI.key_last_tool_outcome (`String "ok");
  let fresh_now = 1_800_000_000.0 in
  (* 2027-01-15T08:00:00Z — 100_000_000s after the stale snapshot *)
  let summary = MCI.render_temporal_summary ~now:fresh_now ctx in
  let fresh_iso = MCI.iso8601_of_float fresh_now in
  let stale_iso = MCI.iso8601_of_float stale_now in
  check bool "time= is the fresh render-time clock" true
    (Astring.String.is_infix ~affix:("time=" ^ fresh_iso) summary);
  check bool "time= is NOT the stale stored wall_time" false
    (Astring.String.is_infix ~affix:stale_iso summary);
  (* elapsed = fresh_now - session_start = 100_000_000 + 100 *)
  check bool "elapsed recomputed against session_start at render time" true
    (Astring.String.is_infix ~affix:"elapsed=100000100s" summary)

let test_render_rejects_retired_elapsed_without_session_start () =
  let ctx = Agent_core.Context.create_sync () in
  Agent_core.Context.set ctx
    MCI.key_wall_time (`String "2023-11-14T22:13:20Z");
  Agent_core.Context.set ctx
    "session:elapsed_seconds" (`Float 55.0);
  Agent_core.Context.set ctx
    MCI.key_tool_call_count (`Int 1);
  Agent_core.Context.set ctx
    MCI.key_last_tool_name (`String "legacy_tool");
  Agent_core.Context.set ctx
    MCI.key_last_tool_outcome (`String "ok");
  let summary = MCI.render_temporal_summary ~now:1_800_000_000.0 ctx in
  check bool "retired elapsed value is not repaired" false
    (Astring.String.is_infix ~affix:"elapsed=" summary);
  check bool "the retired seconds never surface" false
    (Astring.String.is_infix ~affix:"55" summary);
  check bool "the clock and tool trail still render" true
    (Astring.String.is_prefix ~affix:"[Temporal] time=" summary
     && Astring.String.is_infix ~affix:"last=legacy_tool(ok)" summary)

let test_render_omits_malformed_elapsed_context () =
  let ctx = Agent_core.Context.create_sync () in
  Agent_core.Context.set ctx
    MCI.key_wall_time (`String "2023-11-14T22:13:20Z");
  let now = 1_800_000_000.0 in
  check string "a context with only the sentinel renders the clock alone"
    ("[Temporal] time=" ^ MCI.iso8601_of_float now)
    (MCI.render_temporal_summary ~now ctx)

(* ── ISO 8601 formatting ────────────────────────────── *)

let test_iso8601_format () =
  let result = MCI.iso8601_of_float 1712404800.0 in
  check bool "ends with Z" true
    (String.length result > 0 && result.[String.length result - 1] = 'Z');
  check bool "contains T" true
    (Astring.String.is_infix ~affix:"T" result);
  check bool "length is 20" true (String.length result = 20)

(* ── Runner ─────────────────────────────────────────── *)

let () =
  run "Masc_context_injector" [
    "injector", [
      test_case "returns Some on success" `Quick
        test_injector_returns_some_on_success;
      test_case "returns Some on error" `Quick
        test_injector_returns_some_on_error;
      test_case "increments counts" `Quick
        test_injector_increments_counts;
    ];
    "context", [
      test_case "populated after injection" `Quick
        test_context_populated_after_injection;
      test_case "repeated injections overwrite bounded keys" `Quick
        test_context_updates_overwrite_bounded_keys;
    ];
    "temporal_summary", [
      test_case "empty context" `Quick
        test_render_temporal_summary_empty;
      test_case "populated context" `Quick
        test_render_temporal_summary_populated;
      test_case "fresh now, not stale wall_time" `Quick
        test_render_uses_fresh_now_not_stale;
      test_case "retired elapsed without session_start is rejected" `Quick
        test_render_rejects_retired_elapsed_without_session_start;
      test_case "malformed elapsed context omitted" `Quick
        test_render_omits_malformed_elapsed_context;
    ];
    "iso8601", [
      test_case "format" `Quick test_iso8601_format;
    ];
  ]
