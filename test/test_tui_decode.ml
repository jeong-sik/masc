open Masc

let test_decode_agent_success () =
  let json =
    `Assoc [
      ("name", `String "alice");
      ("status", `String "live");
      ("current_task", `String "task-1");
      ("last_seen", `String "2026-03-31T12:00:00Z");
    ]
  in
  match Tui_decode.decode_agent json with
  | Ok agent ->
      Alcotest.(check string) "name" "alice" agent.name;
      Alcotest.(check string) "status" "live" agent.status;
      Alcotest.(check (option string)) "task" (Some "task-1") agent.current_task
  | Error err -> Alcotest.fail err

let test_decode_agent_missing_status_fails () =
  let json =
    `Assoc [
      ("name", `String "alice");
      ("last_seen", `String "2026-03-31T12:00:00Z");
    ]
  in
  Alcotest.(check bool) "missing status rejected" true
    (Result.is_error (Tui_decode.decode_agent json))

let test_decode_task_missing_priority_defaults () =
  let json =
    `Assoc [
      ("id", `String "task-1");
      ("title", `String "Tighten parser");
      ("status", `String "todo");
    ]
  in
  match Tui_decode.decode_task json with
  | Ok task ->
      Alcotest.(check int) "default priority" 3 task.priority;
      Alcotest.(check string) "typed status" "todo"
        (Masc_domain.task_status_to_string task.status)
  | Error err -> Alcotest.fail err

let domain_task ~id ~priority status_fields =
  let json =
    `Assoc
      ([ "id", `String id
       ; "title", `String ("Task " ^ id)
       ; "priority", `Int priority
       ; "created_at", `String "2026-08-21T00:00:00Z"
       ]
      @ status_fields)
  in
  match Masc_domain.task_of_yojson json with
  | Ok task -> task
  | Error err -> Alcotest.fail err

let test_active_tasks_of_domain_filters_and_sorts () =
  let tasks =
    [ domain_task ~id:"done" ~priority:0
        [ "status", `String "done"
        ; "assignee", `String "alice"
        ; "completed_at", `String "2026-08-21T00:00:00Z"
        ]
    ; domain_task ~id:"todo" ~priority:3 [ "status", `String "todo" ]
    ; domain_task ~id:"running" ~priority:1
        [ "status", `String "in_progress"
        ; "assignee", `String "bob"
        ; "started_at", `String "2026-08-21T00:00:00Z"
        ]
    ; domain_task ~id:"cancelled" ~priority:2
        [ "status", `String "cancelled"
        ; "cancelled_by", `String "operator"
        ; "cancelled_at", `String "2026-08-21T00:00:00Z"
        ]
    ]
  in
  let active = Tui_decode.active_tasks_of_domain tasks in
  Alcotest.(check (list string)) "terminal tasks removed, priority preserved"
    [ "running"; "todo" ]
    (List.map (fun (task : Tui_decode.task) -> task.id) active)

let current_keeper_json ?(last_turn_ts = 0.0) ?(paused = false)
    ?(current_task_id = None) ?(blocker_detail = "queue full") () =
  let optional_field key = function
    | Some value -> [ (key, value) ]
    | None -> []
  in
  let fixture =
    `Assoc
      ([ ("name", `String "keeper-main")
       ; ("generation", `Int 2)
       ; ("paused", `Bool paused)
       ; ("total_turns", `Int 4)
       ; ("total_tokens", `Int 120)
       ; ("total_cost_usd", `Float 0.42)
       ; ("last_turn_ts", `Float last_turn_ts)
       ; ("compaction_count", `Int 1)
       ; ("autonomous_turn_count", `Int 7)
       ; ("autonomous_text_turn_count", `Int 5)
       ; ("autonomous_tool_turn_count", `Int 2)
       ; ("board_reactive_turn_count", `Int 3)
       ; ("mention_reactive_turn_count", `Int 1)
       ; ("noop_turn_count", `Int 4)
       ; ("last_proactive_outcome", `String "tool_use")
       ; ( "last_blocker"
         , Keeper_meta_contract.(
             blocker_info_of_class ~detail:blocker_detail Capacity_backpressure
             |> blocker_info_to_json) )
       ; ("created_at", `String "2026-08-20T01:02:03Z")
       ; ("updated_at", `String "2026-08-21T04:05:06Z")
       ]
      @ optional_field "current_task_id"
          (Option.map (fun id -> `String id) current_task_id))
  in
  match Masc_test_deps.meta_of_json_fixture fixture with
  | Ok meta -> Keeper_meta_json.meta_to_json meta
  | Error err -> Alcotest.fail err

let test_decode_keeper_projects_current_schema () =
  match
    Tui_decode.decode_keeper
      (current_keeper_json ~paused:true ~current_task_id:(Some "task-42") ())
  with
  | Ok keeper ->
      Alcotest.(check string) "name" "keeper-main" keeper.k_name;
      Alcotest.(check bool) "trace identity is projected" true
        (String.trim keeper.k_trace_id <> "");
      Alcotest.(check int) "generation" 2 keeper.k_generation;
      Alcotest.(check bool) "paused" true keeper.k_paused;
      Alcotest.(check (option string)) "current task" (Some "task-42")
        keeper.k_current_task_id;
      Alcotest.(check int) "autonomous turns" 7
        keeper.k_autonomous_turn_count;
      Alcotest.(check int) "total turns" 4 keeper.k_total_turns;
      Alcotest.(check int) "total tokens" 120 keeper.k_total_tokens;
      Alcotest.(check (float 0.0001)) "total cost" 0.42
        keeper.k_total_cost_usd;
      Alcotest.(check int) "compactions" 1 keeper.k_compaction_count;
      Alcotest.(check int) "autonomous text turns" 5
        keeper.k_autonomous_text_turn_count;
      Alcotest.(check int) "autonomous tool turns" 2
        keeper.k_autonomous_tool_turn_count;
      Alcotest.(check int) "board turns" 3
        keeper.k_board_reactive_turn_count;
      Alcotest.(check int) "mention turns" 1
        keeper.k_mention_reactive_turn_count;
      Alcotest.(check int) "no-op turns" 4 keeper.k_noop_turn_count;
      Alcotest.(check string) "last outcome" "tool_use"
        keeper.k_last_proactive_outcome;
      Alcotest.(check (option string)) "last blocker"
        (Some "capacity_backpressure: queue full")
        keeper.k_last_blocker;
      Alcotest.(check string) "created at" "2026-08-20T01:02:03Z"
        keeper.k_created_at;
      Alcotest.(check string) "updated at" "2026-08-21T04:05:06Z"
        keeper.k_updated_at
  | Error err -> Alcotest.fail err

let test_decode_keeper_formats_last_turn_timestamp () =
  let timestamp = 1700000000.9 in
  match
    Tui_decode.decode_keeper (current_keeper_json ~last_turn_ts:timestamp ())
  with
  | Ok keeper ->
      Alcotest.(check string) "timestamp uses canonical ISO formatter"
        (Masc_domain.iso8601_of_unix_seconds timestamp)
        keeper.k_last_turn_ts
  | Error err -> Alcotest.fail err

let test_decode_keeper_zero_last_turn_is_empty () =
  match Tui_decode.decode_keeper (current_keeper_json ()) with
  | Ok keeper ->
      Alcotest.(check string) "zero timestamp becomes empty" ""
        keeper.k_last_turn_ts
  | Error err -> Alcotest.fail err

let test_terminal_text_escapes_control_sequences () =
  let payload = "safe\027]0;owned\007\n\t\194\128done" in
  Alcotest.(check string)
    "C0, ESC, OSC terminator, and UTF-8 C1 are rendered inert"
    "safe\\x1B]0;owned\\x07\\x0A\\x09\\u0080done"
    (Tui_decode.sanitize_terminal_text payload)

let test_terminal_text_preserves_printable_utf8 () =
  Alcotest.(check string)
    "printable UTF-8 survives"
    "정상 blocker — café"
    (Tui_decode.sanitize_terminal_text "정상 blocker — café")

let test_keeper_blocker_terminal_boundary_keeps_raw_and_renders_safe () =
  let detail = "queue\027]8;;https://attacker.invalid\007owned\027]8;;\007" in
  match Tui_decode.decode_keeper (current_keeper_json ~blocker_detail:detail ()) with
  | Error error -> Alcotest.fail error
  | Ok keeper ->
    Alcotest.(check bool)
      "typed decode retains the raw diagnostic"
      true
      (Option.exists (fun raw -> String.contains raw '\027') keeper.k_last_blocker);
    let rendered = Tui_decode.keeper_blocker_for_terminal keeper in
    Alcotest.(check bool)
      "terminal projection contains no ESC byte"
      false
      (String.contains rendered '\027');
    Alcotest.(check bool)
      "terminal projection exposes escaped control evidence"
      true
      (String_util.contains_substring rendered "\\x1B]8;;")

let test_decode_keeper_rejects_retired_fields () =
  List.iter
    (fun field ->
      let json =
        match current_keeper_json () with
        | `Assoc fields -> `Assoc ((field, `Bool true) :: fields)
        | _ -> Alcotest.fail "current keeper fixture must be an object"
      in
      Alcotest.(check bool) ("retired field rejected: " ^ field) true
        (Result.is_error (Tui_decode.decode_keeper json)))
    [ "active_goal_ids"
    ; "active_model"
    ; "models"
    ; "proactive_enabled"
    ; "initiative_enabled"
    ; "trigger_mode"
    ; "context_budget"
    ; "drift_enabled"
    ; "verify"
    ]

let test_dotted_keeper_metadata_name_is_preserved () =
  Alcotest.(check (option string)) "portable dotted Keeper name"
    (Some "alpha.with.dot")
    (Keeper_runtime_root_entry.metadata_keeper_name "alpha.with.dot.json")

let test_decode_keeper_rejects_missing_current_field () =
  let json =
    match current_keeper_json () with
    | `Assoc fields ->
        `Assoc (List.filter (fun (key, _) -> key <> "paused") fields)
    | _ -> Alcotest.fail "current keeper fixture must be an object"
  in
  Alcotest.(check bool) "missing current field rejected" true
    (Result.is_error (Tui_decode.decode_keeper json))

let planning_goal_json id phase priority =
  `Assoc
    [ "id", `String id
    ; "title", `String ("Goal " ^ id)
    ; "phase", `String phase
    ; "priority", `Int priority
    ]

let planning_snapshot_json ?(running_key = "in_progress") () =
  `Assoc
    [ ( "goals"
      , `List
          (List.mapi
             (fun index phase ->
                planning_goal_json (Printf.sprintf "goal-%d" index) phase index)
             [ "executing"
             ; "blocked"
             ; "paused"
             ; "verifying"
             ; "completed"
             ; "dropped"
             ]) )
    ; ( "rollup"
      , `Assoc
          [ "active_count", `Int 1
          ; "paused_count", `Int 2
          ; "verifying_count", `Int 3
          ; "done_count", `Int 4
          ; "dropped_count", `Int 5
          ] )
    ; ( "task_backlog"
      , `Assoc
          [ "todo", `Int 6
          ; "claimed", `Int 7
          ; running_key, `Int 8
          ; "done", `Int 9
          ; "cancelled", `Int 10
          ] )
    ; "generated_at", `String "2026-08-21T05:06:07Z"
    ]

let test_decode_planning_snapshot_current_contract () =
  match Tui_decode.decode_planning_snapshot (planning_snapshot_json ()) with
  | Error err -> Alcotest.fail err
  | Ok snapshot ->
      Alcotest.(check (list string)) "all canonical phases"
        [ "executing"; "blocked"; "paused"; "verifying"; "completed"; "dropped" ]
        (List.map
           (fun (goal : Tui_decode.planning_goal) ->
              Goal_phase.to_string goal.pg_phase)
           snapshot.pl_goals);
      Alcotest.(check int) "active" 1 snapshot.pl_rollup.pr_active;
      Alcotest.(check int) "paused and blocked" 2 snapshot.pl_rollup.pr_paused;
      Alcotest.(check int) "verifying" 3 snapshot.pl_rollup.pr_verifying;
      Alcotest.(check int) "done" 4 snapshot.pl_rollup.pr_done;
      Alcotest.(check int) "dropped" 5 snapshot.pl_rollup.pr_dropped;
      Alcotest.(check int) "todo" 6 snapshot.pl_backlog.pb_todo;
      Alcotest.(check int) "claimed" 7 snapshot.pl_backlog.pb_claimed;
      Alcotest.(check int) "in progress" 8 snapshot.pl_backlog.pb_running;
      Alcotest.(check int) "backlog done" 9 snapshot.pl_backlog.pb_done;
      Alcotest.(check int) "cancelled" 10 snapshot.pl_backlog.pb_cancelled;
      Alcotest.(check string) "generated at" "2026-08-21T05:06:07Z"
        snapshot.pl_generated_at

let test_decode_planning_snapshot_rejects_running_alias () =
  Alcotest.(check bool) "retired running alias rejected" true
    (Result.is_error
       (Tui_decode.decode_planning_snapshot
          (planning_snapshot_json ~running_key:"running" ())))

let metrics_common_fields ~kind ~channel =
  [ "schema", `String Keeper_metrics_record.schema
  ; "record_kind", `String kind
  ; "ts", `String "2026-08-21T12:00:00Z"
  ; "ts_unix", `Float 1787313600.0
  ; "channel", `String channel
  ; "name", `String "keeper-main"
  ; "agent_name", `String "codex"
  ; "trace_id", `String "trace-current"
  ; "generation", `Int 4
  ]

type usage_fixture =
  | Usage_trusted
  | Usage_untrusted
  | Usage_missing
  | Usage_mixed
  | Usage_bad_total

let usage_fields = function
  | Usage_trusted ->
      ( `Assoc
          [ "input_tokens", `Int 10
          ; "output_tokens", `Int 12
          ; "cache_creation_tokens", `Int 3
          ; "cache_read_tokens", `Int 4
          ; "total_tokens", `Int 22
          ; "usage_trust", `String "trusted"
          ; "usage_anomaly", `Bool false
          ; "usage_anomaly_reasons", `List []
          ]
      , `Float 0.0
      , "trusted"
      , [] )
  | Usage_untrusted ->
      let reasons = [ `String "negative_input_tokens" ] in
      ( `Assoc
          [ "input_tokens", `Int (-10)
          ; "output_tokens", `Int 12
          ; "cache_creation_tokens", `Int 3
          ; "cache_read_tokens", `Int 4
          ; "total_tokens", `Int 2
          ; "usage_trust", `String "untrusted"
          ; "usage_anomaly", `Bool true
          ; "usage_anomaly_reasons", `List reasons
          ]
      , `Float 0.25
      , "untrusted"
      , reasons )
  | Usage_missing ->
      ( `Assoc
          [ "input_tokens", `Null
          ; "output_tokens", `Null
          ; "cache_creation_tokens", `Null
          ; "cache_read_tokens", `Null
          ; "total_tokens", `Null
          ; "usage_trust", `String "missing"
          ; "usage_anomaly", `Bool false
          ; "usage_anomaly_reasons", `List []
          ]
      , `Null
      , "missing"
      , [] )
  | Usage_mixed ->
      ( `Assoc
          [ "input_tokens", `Int 10
          ; "output_tokens", `Null
          ; "cache_creation_tokens", `Int 3
          ; "cache_read_tokens", `Int 4
          ; "total_tokens", `Int 17
          ; "usage_trust", `String "trusted"
          ; "usage_anomaly", `Bool false
          ; "usage_anomaly_reasons", `List []
          ]
      , `Float 0.25
      , "trusted"
      , [] )
  | Usage_bad_total ->
      ( `Assoc
          [ "input_tokens", `Int 10
          ; "output_tokens", `Int 12
          ; "cache_creation_tokens", `Int 3
          ; "cache_read_tokens", `Int 4
          ; "total_tokens", `Int 29
          ; "usage_trust", `String "trusted"
          ; "usage_anomaly", `Bool false
          ; "usage_anomaly_reasons", `List []
          ]
      , `Float 0.0
      , "trusted"
      , [] )

let current_turn_metrics ?(channel = "turn") ?(turn_mode = "tool_use")
    ?(usage = Usage_trusted) ?tools_used ?tool_call_count () =
  let usage_json, cost_json, usage_trust, usage_anomaly_reasons =
    usage_fields usage
  in
  let tools_used =
    Option.value tools_used
      ~default:
        (if String.equal turn_mode "tool_use" then [ "masc_task_claim" ]
         else [])
  in
  let tool_call_count =
    Option.value tool_call_count ~default:(List.length tools_used)
  in
  `Assoc
    (metrics_common_fields ~kind:"turn" ~channel
    @ [ "message_count", `Int 7
      ; "usage", usage_json
      ; "usage_trust", `String usage_trust
      ; "usage_anomaly_reasons", `List usage_anomaly_reasons
      ; "latency_ms", `Int 0
      ; "cost_usd", cost_json
      ; "turn_mode", `String turn_mode
      ; "tool_call_count", `Int tool_call_count
      ; "tools_used", `List (List.map (fun name -> `String name) tools_used)
      ])

let set_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> Alcotest.failf "cannot set field %s on a non-object" key

let remove_field key = function
  | `Assoc fields -> `Assoc (List.remove_assoc key fields)
  | _ -> Alcotest.failf "cannot remove field %s from a non-object" key

let update_field key update = function
  | `Assoc fields as json -> (
      match List.assoc_opt key fields with
      | Some value -> set_field key (update value) json
      | None -> Alcotest.failf "fixture has no field %s" key)
  | _ -> Alcotest.failf "cannot update field %s on a non-object" key

let update_usage update = update_field "usage" update

let current_heartbeat_metrics ?(channel = "heartbeat") ?(message_count = `Null)
    () =
  `Assoc
    (metrics_common_fields ~kind:"heartbeat" ~channel
    @ [ "message_count", message_count ])

let test_decode_current_turn_metrics () =
  match Tui_decode.decode_log_entry (current_turn_metrics ()) with
  | Ok entry ->
      Alcotest.(check bool) "turn kind" true
        (entry.le_kind = Tui_decode.Log_turn);
      Alcotest.(check bool) "canonical channel" true
        (entry.le_channel = Tui_decode.Log_channel_turn);
      Alcotest.(check (option int)) "message count" (Some 7)
        entry.le_message_count;
      Alcotest.(check (option int)) "input tokens" (Some 10)
        entry.le_input_tokens;
      Alcotest.(check (option int)) "output tokens" (Some 12)
        entry.le_output_tokens;
      Alcotest.(check (option int)) "zero latency remains observed" (Some 0)
        entry.le_latency_ms;
      Alcotest.(check (option (float 0.001))) "zero cost remains observed"
        (Some 0.0) entry.le_cost_usd;
      Alcotest.(check (option string)) "derived work kind" (Some "tool_use")
        entry.le_work_kind
  | Error err -> Alcotest.fail err

let test_decode_current_turn_variants () =
  List.iter
    (fun (channel, expected_channel) ->
      List.iter
        (fun (mode, expected_work_kind) ->
          match
            Tui_decode.decode_log_entry
              (current_turn_metrics ~channel ~turn_mode:mode ())
          with
          | Ok entry ->
              Alcotest.(check bool) (channel ^ " channel") true
                (entry.le_channel = expected_channel);
              Alcotest.(check (option string)) (mode ^ " work kind")
                (Some expected_work_kind) entry.le_work_kind
          | Error err -> Alcotest.failf "%s/%s: %s" channel mode err)
        [ "tool_use", "tool_use"
        ; "text_response", "text_turn"
        ; "skip_text", "text_turn"
        ; "noop", "noop"
        ])
    [ "turn", Tui_decode.Log_channel_turn
    ; ( "scheduled_autonomous"
      , Tui_decode.Log_channel_scheduled_autonomous )
    ];
  (match
     Tui_decode.decode_log_entry
       (current_turn_metrics ~usage:Usage_missing ())
   with
   | Ok entry ->
       Alcotest.(check (option int)) "missing input usage" None
         entry.le_input_tokens;
       Alcotest.(check (option int)) "missing output usage" None
         entry.le_output_tokens;
       Alcotest.(check (option (float 0.001))) "missing cost" None
         entry.le_cost_usd
   | Error err -> Alcotest.fail err);
  match
    Tui_decode.decode_log_entry
      (current_turn_metrics ~usage:Usage_untrusted ())
  with
  | Ok entry ->
      Alcotest.(check (option int)) "untrusted negative input remains observed"
        (Some (-10)) entry.le_input_tokens;
      Alcotest.(check (option int)) "untrusted output remains observed"
        (Some 12) entry.le_output_tokens
  | Error err -> Alcotest.fail err

let test_decode_current_heartbeat_metrics () =
  match Tui_decode.decode_log_entry (current_heartbeat_metrics ()) with
  | Ok entry ->
      Alcotest.(check bool) "heartbeat kind" true
        (entry.le_kind = Tui_decode.Log_heartbeat);
      Alcotest.(check bool) "heartbeat channel" true
        (entry.le_channel = Tui_decode.Log_channel_heartbeat);
      Alcotest.(check (option int)) "unknown message count" None
        entry.le_message_count;
      Alcotest.(check (option int)) "heartbeat has no turn usage" None
        entry.le_input_tokens;
      (match
         Tui_decode.decode_log_entry
           (current_heartbeat_metrics ~message_count:(`Int 9) ())
       with
       | Ok counted ->
           Alcotest.(check (option int)) "observed message count" (Some 9)
             counted.le_message_count
       | Error err -> Alcotest.fail err)
  | Error err -> Alcotest.fail err

let test_metrics_contract_rejects_retired_or_unknown_rows () =
  let versionless =
    match current_turn_metrics () with
    | `Assoc fields -> `Assoc (List.remove_assoc "schema" fields)
    | _ -> Alcotest.fail "turn fixture must be an object"
  in
  let missing_usage_field =
    current_turn_metrics ~usage:Usage_missing ()
    |> update_usage (remove_field "input_tokens")
  in
  let anomaly_flag_mismatch =
    current_turn_metrics ~usage:Usage_untrusted ()
    |> update_usage (set_field "usage_anomaly" (`Bool false))
  in
  let anomaly_reasons_mismatch =
    current_turn_metrics ~usage:Usage_untrusted ()
    |> set_field "usage_anomaly_reasons" (`List [])
  in
  let cases =
    [ "versionless", versionless
    ; "mixed usage observation", current_turn_metrics ~usage:Usage_mixed ()
    ; "incorrect usage total", current_turn_metrics ~usage:Usage_bad_total ()
    ; "missing explicit-null usage field", missing_usage_field
    ; "usage anomaly flag mismatch", anomaly_flag_mismatch
    ; "usage anomaly reasons mismatch", anomaly_reasons_mismatch
    ; "unknown turn channel", current_turn_metrics ~channel:"reactive" ()
    ; "unknown turn mode", current_turn_metrics ~turn_mode:"text" ()
    ; ( "non-tool mode with tool calls"
      , current_turn_metrics ~turn_mode:"noop"
          ~tools_used:[ "masc_task_claim" ] ~tool_call_count:1 () )
    ; ( "tool call count mismatch"
      , current_turn_metrics ~tool_call_count:2 () )
    ; ( "missing tool call count"
      , current_turn_metrics () |> remove_field "tool_call_count" )
    ; ( "negative turn message count"
      , current_turn_metrics () |> set_field "message_count" (`Int (-1)) )
    ; ( "negative turn latency"
      , current_turn_metrics () |> set_field "latency_ms" (`Int (-1)) )
    ; "heartbeat channel mismatch", current_heartbeat_metrics ~channel:"hb" ()
    ; ( "negative heartbeat message count"
      , current_heartbeat_metrics ~message_count:(`Int (-1)) () )
    ; ( "heartbeat missing nullable message count"
      , current_heartbeat_metrics () |> remove_field "message_count" )
    ]
  in
  List.iter
    (fun (label, json) ->
      Alcotest.(check bool) label true
        (Result.is_error (Tui_decode.decode_log_entry json)))
    cases

let observed_context ?(ratio = `Float 0.5) ?(maximum = `Int 200)
    ?(absolute_turn = 4) ?(request_body_bytes = `Int 4096) () =
  `Assoc
    [ "context_ratio", ratio
    ; "context_tokens", `Int 100
    ; "context_max", maximum
    ; "context_source", `String "turn_record"
    ; "context_metrics_unavailable", `Null
    ; ( "context"
      , `Assoc
          [ "source", `String "turn_record"
          ; "context_ratio", ratio
          ; "context_tokens", `Int 100
          ; "context_max", maximum
          ; "observed_at", `String "2026-08-21T12:00:00Z"
          ; "turn_ref", `String "trace-current#4"
          ; "absolute_turn", `Int absolute_turn
          ; "request_body_bytes", request_body_bytes
          ; "metrics_unavailable", `Null
          ] )
    ]

let unavailable_context ?(reverse_nested_payload = false) reason =
  let unavailable_fields =
    [ "kind", `String "not_observed"; "reason", `String reason ]
  in
  let unavailable = `Assoc unavailable_fields in
  let nested_unavailable =
    `Assoc
      (if reverse_nested_payload then List.rev unavailable_fields
       else unavailable_fields)
  in
  `Assoc
    [ "context_ratio", `Null
    ; "context_tokens", `Null
    ; "context_max", `Null
    ; "context_source", `Null
    ; "context_metrics_unavailable", unavailable
    ; ( "context"
      , `Assoc
          [ "source", `Null
          ; "context_ratio", `Null
          ; "context_tokens", `Null
          ; "context_max", `Null
          ; "metrics_unavailable", nested_unavailable
          ] )
    ]

let test_decode_context_observation () =
  (match
     Tui_decode.decode_context_observation ~expected_trace_id:"trace-current"
       (observed_context ())
   with
   | Ok (Tui_decode.Context_observed observation) ->
       Alcotest.(check (option (float 0.001))) "ratio" (Some 0.5)
         observation.ratio;
       Alcotest.(check int) "tokens" 100 observation.tokens;
       Alcotest.(check (option int)) "maximum" (Some 200)
         observation.maximum;
       Alcotest.(check string) "turn ref" "trace-current#4"
         observation.turn_ref
   | Ok (Tui_decode.Context_unavailable _) ->
       Alcotest.fail "observed context decoded as unavailable"
   | Error err -> Alcotest.fail err);
  match
    Tui_decode.decode_context_observation ~expected_trace_id:"trace-current"
      (observed_context ~ratio:`Null ~maximum:`Null ())
  with
  | Ok (Tui_decode.Context_observed observation) ->
      Alcotest.(check (option (float 0.001))) "missing ratio is preserved" None
        observation.ratio;
      Alcotest.(check (option int)) "missing window is preserved" None
        observation.maximum
  | Ok (Tui_decode.Context_unavailable _) ->
      Alcotest.fail "partial observation decoded as unavailable"
  | Error err -> Alcotest.fail err

let test_decode_context_unavailable_reasons () =
  let reasons =
    [ "context_measurement_missing"
    ; "turn_record_undecodable"
    ; "turn_record_read_failed"
    ; "turn_record_without_usage"
    ; "turn_record_trace_mismatch"
    ]
  in
  List.iter
    (fun reason ->
      let json =
        unavailable_context
          ~reverse_nested_payload:
            (String.equal reason "context_measurement_missing")
          reason
      in
      match
        Tui_decode.decode_context_observation
          ~expected_trace_id:"trace-current" json
      with
      | Ok (Tui_decode.Context_unavailable _) -> ()
      | Ok (Tui_decode.Context_observed _) ->
          Alcotest.failf "%s decoded as observed" reason
      | Error err -> Alcotest.failf "%s: %s" reason err)
    reasons;
  let unknown =
    `Assoc
      [ ( "context_metrics_unavailable"
        , `Assoc
            [ "kind", `String "not_observed"; "reason", `String "unknown" ] )
      ]
  in
  Alcotest.(check bool) "unknown unavailable reason rejected" true
    (Result.is_error
       (Tui_decode.decode_context_observation
          ~expected_trace_id:"trace-current" unknown))

let test_context_observation_rejects_hybrids_and_prior_trace () =
  let prior_trace =
    match observed_context () with
    | `Assoc fields ->
        let context =
          match List.assoc "context" fields with
          | `Assoc nested ->
              `Assoc
                (("turn_ref", `String "trace-prior#4")
                :: List.remove_assoc "turn_ref" nested)
          | _ -> Alcotest.fail "observed context fixture must be an object"
        in
        `Assoc (("context", context) :: List.remove_assoc "context" fields)
    | _ -> Alcotest.fail "observed context fixture must be an object"
  in
  let hybrid =
    `Assoc
      [ "context_ratio", `Float 0.5
      ; "context_tokens", `Int 100
      ; "context_max", `Int 200
      ; "context_source", `String "turn_record"
      ; ( "context_metrics_unavailable"
        , `Assoc
            [ "kind", `String "not_observed"
            ; "reason", `String "context_measurement_missing"
            ] )
      ]
  in
  let missing_observed_nullable =
    observed_context () |> remove_field "context_ratio"
  in
  let missing_observed_provenance =
    observed_context ()
    |> update_field "context" (remove_field "request_body_bytes")
  in
  let missing_unavailable_nullable =
    unavailable_context "context_measurement_missing"
    |> remove_field "context_tokens"
  in
  let absolute_turn_mismatch = observed_context ~absolute_turn:5 () in
  let negative_request_bytes =
    observed_context ~request_body_bytes:(`Int (-1)) ()
  in
  let ratio_mismatch = observed_context ~ratio:(`Float 0.75) () in
  List.iter
    (fun (label, json) ->
      Alcotest.(check bool) label true
        (Result.is_error
           (Tui_decode.decode_context_observation
              ~expected_trace_id:"trace-current" json)))
    [ "prior trace rejected", prior_trace
    ; "hybrid rejected", hybrid
    ; "missing observed nullable field rejected", missing_observed_nullable
    ; "missing observed provenance rejected", missing_observed_provenance
    ; "missing unavailable nullable field rejected", missing_unavailable_nullable
    ; "absolute turn mismatch rejected", absolute_turn_mismatch
    ; "negative request bytes rejected", negative_request_bytes
    ; "ratio mismatch rejected", ratio_mismatch
    ]

let test_parse_keeper_chat_response_sse_delta () =
  let response =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n\
     data: {\"type\":\"content_delta\",\"delta\":\"hello\"}\n\
     data: {\"type\":\"delta\",\"delta\":\" world\"}\n"
  in
  match Tui_decode.parse_keeper_chat_response response with
  | Ok text -> Alcotest.(check string) "delta text" "hello world" text
  | Error err -> Alcotest.fail err

let test_parse_keeper_chat_response_ag_ui_sse () =
  let response =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n\
     data: {\"type\":\"RUN_STARTED\",\"threadId\":\"default\",\"runId\":\"run-1\"}\n\n\
     data: {\"type\":\"TEXT_MESSAGE_CONTENT\",\"threadId\":\"default\",\"runId\":\"run-1\",\"delta\":\"hello\"}\n\n\
     data: {\"type\":\"TEXT_MESSAGE_CONTENT\",\"threadId\":\"default\",\"runId\":\"run-1\",\"delta\":\" world\"}\n\n\
     data: {\"type\":\"RUN_FINISHED\",\"threadId\":\"default\",\"runId\":\"run-1\"}\n\n"
  in
  match Tui_decode.parse_keeper_chat_response response with
  | Ok text -> Alcotest.(check string) "AG-UI delta text" "hello world" text
  | Error err -> Alcotest.fail err

let test_parse_keeper_chat_response_ag_ui_error () =
  let response =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n\
     data: {\"type\":\"RUN_ERROR\",\"threadId\":\"default\",\"runId\":\"run-1\",\"message\":\"boom\"}\n\n"
  in
  match Tui_decode.parse_keeper_chat_response response with
  | Ok text -> Alcotest.failf "expected RUN_ERROR failure, got %S" text
  | Error err -> Alcotest.(check string) "AG-UI error message" "boom" err

let test_parse_keeper_chat_response_ag_ui_empty_terminal () =
  let response =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n\
     data: {\"type\":\"RUN_FINISHED\",\"threadId\":\"default\",\"runId\":\"run-1\"}\n\n"
  in
  match Tui_decode.parse_keeper_chat_response response with
  | Ok text -> Alcotest.(check string) "empty terminal response" "" text
  | Error err -> Alcotest.fail err

let test_parse_keeper_chat_response_body_json () =
  let response = "{\"result\":{\"text\":\"hello body\"}}" in
  match Tui_decode.parse_keeper_chat_response response with
  | Ok text -> Alcotest.(check string) "body text" "hello body" text
  | Error err -> Alcotest.fail err

let test_parse_keeper_chat_response_json_error () =
  let response =
    "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n\r\n\
     {\"error\":{\"message\":\"boom\"}}"
  in
  match Tui_decode.parse_keeper_chat_response response with
  | Ok _ -> Alcotest.fail "expected parse failure"
  | Error err -> Alcotest.(check string) "error message" "boom" err

let test_decode_json_response_body_rejects_error_status () =
  match
    Tui_decode.decode_json_response_body ~allow_empty:true ~status_code:400
      ~body:"{\"error\":\"bad confirm\"}"
  with
  | Ok _ -> Alcotest.fail "expected HTTP 400 to fail"
  | Error err ->
      Alcotest.(check string)
        "http error" "HTTP 400: {\"error\":\"bad confirm\"}" err

let test_decode_json_response_body_allows_empty_success () =
  match
    Tui_decode.decode_json_response_body ~allow_empty:true ~status_code:204
      ~body:""
  with
  | Ok (`Assoc []) -> ()
  | Ok json ->
      Alcotest.failf "expected empty object, got %s" (Yojson.Safe.to_string json)
  | Error err -> Alcotest.fail err

type parent_node = {
  node_id : string;
  parent_id : string option;
}

let test_bounded_parent_depth_stops_on_cycle () =
  let a = { node_id = "a"; parent_id = Some "b" } in
  let b = { node_id = "b"; parent_id = Some "a" } in
  let depth =
    Tui_decode.bounded_parent_depth
      ~id_of:(fun n -> n.node_id)
      ~parent_id_of:(fun n -> n.parent_id)
      [ a; b ] a
  in
  Alcotest.(check int) "cycle stops at first repeated parent" 1 depth

let () =
  Alcotest.run "tui_decode" [
    ( "decode_agent",
      [
        Alcotest.test_case "success" `Quick test_decode_agent_success;
        Alcotest.test_case "missing status fails" `Quick
          test_decode_agent_missing_status_fails;
      ] );
    ( "decode_task",
      [
        Alcotest.test_case "missing priority defaults" `Quick
          test_decode_task_missing_priority_defaults;
        Alcotest.test_case "active projection filters and sorts" `Quick
          test_active_tasks_of_domain_filters_and_sorts;
      ] );
    ( "decode_keeper",
      [
        Alcotest.test_case "projects current schema" `Quick
          test_decode_keeper_projects_current_schema;
        Alcotest.test_case "formats last turn timestamp" `Quick
          test_decode_keeper_formats_last_turn_timestamp;
        Alcotest.test_case "zero last turn is empty" `Quick
          test_decode_keeper_zero_last_turn_is_empty;
        Alcotest.test_case "rejects retired fields" `Quick
          test_decode_keeper_rejects_retired_fields;
        Alcotest.test_case "preserves dotted metadata name" `Quick
          test_dotted_keeper_metadata_name_is_preserved;
        Alcotest.test_case "rejects missing current field" `Quick
          test_decode_keeper_rejects_missing_current_field;
      ] );
    ( "decode_planning",
      [
        Alcotest.test_case "current contract" `Quick
          test_decode_planning_snapshot_current_contract;
        Alcotest.test_case "rejects running alias" `Quick
          test_decode_planning_snapshot_rejects_running_alias;
      ] );
    ( "terminal_text",
      [ Alcotest.test_case "escapes control sequences" `Quick
          test_terminal_text_escapes_control_sequences
      ; Alcotest.test_case "preserves printable UTF-8" `Quick
          test_terminal_text_preserves_printable_utf8
      ; Alcotest.test_case "keeper blocker keeps raw and renders safe" `Quick
          test_keeper_blocker_terminal_boundary_keeps_raw_and_renders_safe
      ] );
    ( "parse_log_entry",
      [
        Alcotest.test_case "current turn contract" `Quick
          test_decode_current_turn_metrics;
        Alcotest.test_case "all current turn variants" `Quick
          test_decode_current_turn_variants;
        Alcotest.test_case "current heartbeat contract" `Quick
          test_decode_current_heartbeat_metrics;
        Alcotest.test_case "retired and unknown rows fail closed" `Quick
          test_metrics_contract_rejects_retired_or_unknown_rows;
      ] );
    ( "context_observation",
      [
        Alcotest.test_case "observed and partial current context" `Quick
          test_decode_context_observation;
        Alcotest.test_case "closed unavailable reasons" `Quick
          test_decode_context_unavailable_reasons;
        Alcotest.test_case "hybrid and prior trace fail closed" `Quick
          test_context_observation_rejects_hybrids_and_prior_trace;
      ] );
    ( "parse_keeper_chat_response",
      [
        Alcotest.test_case "sse delta" `Quick
          test_parse_keeper_chat_response_sse_delta;
        Alcotest.test_case "AG-UI SSE" `Quick
          test_parse_keeper_chat_response_ag_ui_sse;
        Alcotest.test_case "AG-UI error" `Quick
          test_parse_keeper_chat_response_ag_ui_error;
        Alcotest.test_case "AG-UI empty terminal" `Quick
          test_parse_keeper_chat_response_ag_ui_empty_terminal;
        Alcotest.test_case "body json" `Quick
          test_parse_keeper_chat_response_body_json;
        Alcotest.test_case "json error" `Quick
          test_parse_keeper_chat_response_json_error;
      ] );
    ( "structured_http_response",
      [
        Alcotest.test_case "body rejects error status" `Quick
          test_decode_json_response_body_rejects_error_status;
        Alcotest.test_case "body allows empty success" `Quick
          test_decode_json_response_body_allows_empty_success;
      ] );
    ( "bounded_parent_depth",
      [
        Alcotest.test_case "stops on cycle" `Quick
          test_bounded_parent_depth_stops_on_cycle;
      ] );
  ]
