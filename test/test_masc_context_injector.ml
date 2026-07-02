(** Tests for MCI. *)

open Alcotest
module MCI = Masc.Masc_context_injector

(* ── Helpers ──────────────────────────────────────────── *)

let ok_output content : Agent_sdk.Types.tool_result =
  Ok { Agent_sdk.Types.content; _meta = None }

let err_output message : Agent_sdk.Types.tool_result =
  Error { Agent_sdk.Types.message; recoverable = true; error_class = None }

(* ── Unit tests: injector function ──────────────────── *)

let test_injector_returns_some_on_success () =
  let config = MCI.default_config () in
  let injector = MCI.make ~config () in
  match injector ~tool_name:"read_file" ~input:`Null ~output:(ok_output "data") with
  | Some inj ->
    check bool "has context_updates" true
      (List.length inj.Agent_sdk.Hooks.context_updates > 0);
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
        inj.Agent_sdk.Hooks.context_updates
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
    let updates = inj.Agent_sdk.Hooks.context_updates in
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
  let ctx = Agent_sdk.Context.create_sync () in
  match injector ~tool_name:"bash" ~input:`Null ~output:(ok_output "done") with
  | Some inj ->
    List.iter (fun (k, v) -> Agent_sdk.Context.set ctx k v)
      inj.Agent_sdk.Hooks.context_updates;
    (match Agent_sdk.Context.get ctx MCI.key_last_tool_name with
     | Some (`String "bash") -> ()
     | _ -> fail "last_tool_name not set");
    (match Agent_sdk.Context.get ctx MCI.key_wall_time with
     | Some (`String s) ->
       check bool "ends with Z" true (String.length s > 0 && s.[String.length s - 1] = 'Z')
     | _ -> fail "wall_time not set")
  | None -> fail "expected Some injection"

let test_context_updates_overwrite_bounded_keys () =
  let config = MCI.default_config () in
  let injector = MCI.make ~config () in
  let ctx = Agent_sdk.Context.create_sync () in
  let expected_keys =
    [
      MCI.key_wall_time;
      MCI.key_session_start;
      MCI.key_elapsed_seconds;
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
        (fun (key, value) -> Agent_sdk.Context.set ctx key value)
        inj.Agent_sdk.Hooks.context_updates
    | None -> fail "expected Some injection"
  done;
  check
    (list string)
    "context keys stay bounded"
    expected_keys
    (Agent_sdk.Context.keys ctx |> List.sort String.compare);
  (match Agent_sdk.Context.get ctx MCI.key_tool_call_count with
   | Some (`Int 200) -> ()
   | other ->
     fail
       (Printf.sprintf
          "expected 200 tool calls, got %s"
          (Yojson.Safe.to_string
             (Option.value ~default:`Null other))));
  match Agent_sdk.Context.get ctx MCI.key_last_tool_name with
  | Some (`String "tool_200") -> ()
  | other ->
    fail
      (Printf.sprintf
         "expected last tool to be tool_200, got %s"
         (Yojson.Safe.to_string (Option.value ~default:`Null other)))

(* ── Temporal summary rendering ─────────────────────── *)

let test_render_temporal_summary_empty () =
  let ctx = Agent_sdk.Context.create_sync () in
  check (option string) "no summary before any tool"
    None (MCI.render_temporal_summary ctx)

let test_render_temporal_summary_populated () =
  let ctx = Agent_sdk.Context.create_sync () in
  Agent_sdk.Context.set ctx
    MCI.key_wall_time (`String "2026-04-06T12:00:00Z");
  Agent_sdk.Context.set ctx
    MCI.key_elapsed_seconds (`Float 42.5);
  Agent_sdk.Context.set ctx
    MCI.key_tool_call_count (`Int 3);
  Agent_sdk.Context.set ctx
    MCI.key_last_tool_name (`String "tool_execute");
  Agent_sdk.Context.set ctx
    MCI.key_last_tool_outcome (`String "ok");
  match MCI.render_temporal_summary ctx with
  | Some summary ->
    check bool "contains time" true
      (Astring.String.is_prefix ~affix:"[Temporal]" summary);
    check bool "contains tool name" true
      (Astring.String.is_infix ~affix:"tool_execute" summary);
    check bool "contains elapsed" true
      (Astring.String.is_infix ~affix:"elapsed=42s" summary)
  | None -> fail "expected Some summary"

(* Regression: turn N+1 must render the *fresh* current time, not the
   last tool call's timestamp frozen in [key_wall_time]/[key_elapsed_seconds]
   from turn N (the idle-wake bug). Uses a fixed [~now] far in the future
   relative to the stored (stale) values. *)
let test_render_uses_fresh_now_not_stale () =
  let ctx = Agent_sdk.Context.create_sync () in
  let stale_now = 1_700_000_000.0 in
  (* 2023-11-14T22:13:20Z *)
  let session_start = stale_now -. 100.0 in
  Agent_sdk.Context.set ctx
    MCI.key_wall_time (`String (MCI.iso8601_of_float stale_now));
  Agent_sdk.Context.set ctx
    MCI.key_session_start (`Float session_start);
  Agent_sdk.Context.set ctx
    MCI.key_elapsed_seconds (`Float 100.0);
  Agent_sdk.Context.set ctx
    MCI.key_tool_call_count (`Int 2);
  Agent_sdk.Context.set ctx
    MCI.key_last_tool_name (`String "bash");
  Agent_sdk.Context.set ctx
    MCI.key_last_tool_outcome (`String "ok");
  let fresh_now = 1_800_000_000.0 in
  (* 2027-01-15T08:00:00Z — 100_000_000s after the stale snapshot *)
  match MCI.render_temporal_summary ~now:fresh_now ctx with
  | Some summary ->
    let fresh_iso = MCI.iso8601_of_float fresh_now in
    let stale_iso = MCI.iso8601_of_float stale_now in
    check bool "time= is the fresh render-time clock" true
      (Astring.String.is_infix ~affix:("time=" ^ fresh_iso) summary);
    check bool "time= is NOT the stale stored wall_time" false
      (Astring.String.is_infix ~affix:stale_iso summary);
    (* elapsed = fresh_now - session_start = 100_000_000 + 100 *)
    check bool "elapsed recomputed against session_start at render time" true
      (Astring.String.is_infix ~affix:"elapsed=100000100s" summary)
  | None -> fail "expected Some summary"

(* When [key_session_start] is absent (context written before the key
   existed), elapsed falls back to the stored value; time= is still fresh. *)
let test_render_elapsed_fallback_without_session_start () =
  let ctx = Agent_sdk.Context.create_sync () in
  Agent_sdk.Context.set ctx
    MCI.key_wall_time (`String "2023-11-14T22:13:20Z");
  Agent_sdk.Context.set ctx
    MCI.key_elapsed_seconds (`Float 55.0);
  match MCI.render_temporal_summary ~now:1_800_000_000.0 ctx with
  | Some summary ->
    check bool "time= is fresh" true
      (Astring.String.is_infix
         ~affix:("time=" ^ MCI.iso8601_of_float 1_800_000_000.0) summary);
    check bool "elapsed falls back to stored value" true
      (Astring.String.is_infix ~affix:"elapsed=55s" summary)
  | None -> fail "expected Some summary"

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
      test_case "elapsed fallback without session_start" `Quick
        test_render_elapsed_fallback_without_session_start;
    ];
    "iso8601", [
      test_case "format" `Quick test_iso8601_format;
    ];
  ]
