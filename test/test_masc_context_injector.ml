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
    ];
    "iso8601", [
      test_case "format" `Quick test_iso8601_format;
    ];
  ]
