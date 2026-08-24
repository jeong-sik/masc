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
    ?(current_task_id = None) () =
  let optional_field key = function
    | Some value -> [ (key, value) ]
    | None -> []
  in
  let fixture =
    `Assoc
      ([ ("name", `String "keeper-main")
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

let test_terminal_text_escapes_malformed_utf8_bytes () =
  [ ( "isolated illegal bytes"
    , "\128\160\192\193\194\245\255"
    , "\\x80\\xA0\\xC0\\xC1\\xC2\\xF5\\xFF" )
  ; ("overlong two-byte sequence", "\192\128", "\\xC0\\x80")
  ; ("overlong three-byte sequence", "\224\128\128", "\\xE0\\x80\\x80")
  ; ( "overlong four-byte sequence"
    , "\240\128\128\128"
    , "\\xF0\\x80\\x80\\x80" )
  ; ("UTF-16 surrogate", "\237\160\128", "\\xED\\xA0\\x80")
  ; ( "code point above U+10FFFF"
    , "\244\144\128\128"
    , "\\xF4\\x90\\x80\\x80" )
  ; ("truncated three-byte sequence", "\226\130", "\\xE2\\x82")
  ; ( "bad three-byte continuation"
    , "\226(\161"
    , "\\xE2(\\xA1" )
  ; ( "truncated four-byte sequence"
    , "\240\159\146"
    , "\\xF0\\x9F\\x92" )
  ]
  |> List.iter (fun (label, input, expected) ->
       Alcotest.(check string) label expected
         (Tui_decode.sanitize_terminal_text input))

let test_terminal_text_is_idempotent_and_single_line () =
  let once =
    Tui_decode.sanitize_terminal_text
      "safe\000\007\009\010\013\027\127\128\159\194\128done"
  in
  Alcotest.(check string)
    "all C0, DEL, raw C1, and encoded C1 controls are inert"
    "safe\\x00\\x07\\x09\\x0A\\x0D\\x1B\\x7F\\x80\\x9F\\u0080done"
    once;
  Alcotest.(check bool) "sanitized output is one logical row" false
    (String.contains once '\n');
  Alcotest.(check string) "sanitization is idempotent" once
    (Tui_decode.sanitize_terminal_text once)

let keeper_call_row ~keeper ~tool ?(success = true) ?duration_ms ?turn () =
  `Assoc
    ([ "ts", `Float 1787534998.4
     ; "keeper", `String keeper
     ; "tool", `String tool
     ; "input", `String "{\"file_path\": \"lib/a.ml\"}"
     ; "success", `Bool success
     ]
    @ (match duration_ms with None -> [] | Some d -> [ "duration_ms", `Float d ])
    @ (match turn with None -> [] | Some t -> [ "turn", `Int t ]))

let test_keeper_calls_reject_rows_naming_another_keeper () =
  let payload =
    `Assoc
      [ "keeper", `String "rondo"
      ; "count", `Int 3
      ; "health", `String "ok"
      ; "latest_age_s", `Float 8.2
      ; "stale_reason", `String "fresh"
      ; ( "entries"
        , `List
            [ keeper_call_row ~keeper:"rondo" ~tool:"Read" ~duration_ms:28.4
                ~turn:2143 ()
            ; keeper_call_row ~keeper:"analyst" ~tool:"Edit" ()
            ; keeper_call_row ~keeper:"rondo" ~tool:"tool_execute"
                ~success:false ()
            ] )
      ]
  in
  match
    Tui_decode.decode_keeper_calls_snapshot ~requested_keeper:"rondo" payload
  with
  | Error detail -> Alcotest.failf "expected a snapshot, got %s" detail
  | Ok snapshot ->
      Alcotest.(check int) "two rows kept in order" 2
        (List.length snapshot.Tui_decode.kcs_entries);
      Alcotest.(check int) "the foreign row is counted, not drawn" 1
        snapshot.Tui_decode.kcs_mismatched;
      (match snapshot.Tui_decode.kcs_entries with
       | [ first; second ] ->
           Alcotest.(check string) "order kept" "Read" first.Tui_decode.kc_tool;
           Alcotest.(check bool) "failure carried" false
             second.Tui_decode.kc_success;
           Alcotest.(check (option (Alcotest.float 0.01))) "duration optional"
             (Some 28.4) first.Tui_decode.kc_duration_ms;
           Alcotest.(check (option Alcotest.int)) "turn optional" (Some 2143)
             first.Tui_decode.kc_turn
       | _ -> Alcotest.fail "expected two rows");
      Alcotest.(check (option string)) "a fresh stale_reason is no reason" None
        snapshot.Tui_decode.kcs_stale_reason;
      Alcotest.(check string) "health verbatim" "ok"
        snapshot.Tui_decode.kcs_health

let test_keeper_calls_require_the_envelope () =
  Alcotest.(check bool) "no entries list is an error" true
    (Result.is_error
       (Tui_decode.decode_keeper_calls_snapshot ~requested_keeper:"rondo"
          (`Assoc
             [ "keeper", `String "rondo"
             ; "count", `Int 0
             ; "health", `String "ok"
             ])));
  Alcotest.(check bool) "a row without success is an error" true
    (Result.is_error
       (Tui_decode.decode_keeper_calls_snapshot ~requested_keeper:"rondo"
          (`Assoc
             [ "keeper", `String "rondo"
             ; "count", `Int 1
             ; "health", `String "ok"
             ; ( "entries"
               , `List
                   [ `Assoc
                       [ "ts", `Float 1.0
                       ; "keeper", `String "rondo"
                       ; "tool", `String "Read"
                       ]
                   ] )
             ])))

let test_timestamp_slices_are_sanitized_after_selection () =
  Alcotest.(check string) "normal clock timestamp" "04:05:06"
    (Tui_decode.clock_timestamp_for_terminal "2026-08-22T04:05:06Z");
  Alcotest.(check string) "empty short timestamp" "(never)"
    (Tui_decode.short_timestamp_for_terminal "");
  Alcotest.(check string)
    "clock slice cannot expose a UTF-8 continuation as raw C1"
    "\\x9B31mOWNE"
    (Tui_decode.clock_timestamp_for_terminal
       "0123456789Û31mOWNED!!");
  Alcotest.(check string)
    "short timestamp cannot leave a split UTF-8 lead byte"
    "123456789012345678\\xE2"
    (Tui_decode.short_timestamp_for_terminal
       "123456789012345678€");
  Alcotest.(check string)
    "clock slice escapes selected terminal controls"
    "0\\x1B]2;Xab"
    (Tui_decode.clock_timestamp_for_terminal
       "2026-08-22T0\027]2;Xabcd")

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

(* The ledger rows as the server actually joins them, taken from a live
   workspace: an approval leaves [reason] null and carries its text in
   [evidence]; a refusal fills both with the same string. *)
let verification_json ?verdict state =
  `Assoc
    [ "goal_id", `String "goal-x"
    ; ( "completion"
      , `Assoc
          (("state", `String state)
           :: (match verdict with None -> [] | Some v -> [ "verdict", v ])) )
    ; "updated_at", `String "2026-08-23T13:15:16Z"
    ]
;;

let proven_verdict evidence =
  `Assoc
    [ "outcome", `String "proven"
    ; "reason", `Null
    ; "verification_run_id", `String "01a02ec2"
    ; "evidence", `String evidence
    ; "recorded_at", `String "2026-08-23T13:15:16Z"
    ]
;;

let refuted_verdict reason =
  `Assoc
    [ "outcome", `String "refuted"
    ; "reason", `String reason
    ; "verification_run_id", `String "01a028ce"
    ; "evidence", `String reason
    ; "recorded_at", `String "2026-08-22T09:30:53Z"
    ]
;;

let decoded_proof ?verification ?last_review_note () =
  let fields =
    [ "id", `String "goal-x"
    ; "title", `String "Goal x"
    ; "phase", `String "executing"
    ; "priority", `Int 1
    ]
    @ (match verification with None -> [] | Some v -> [ "verification", v ])
    @ (match last_review_note with
       | None -> []
       | Some note -> [ "last_review_note", `String note ])
  in
  match Tui_decode.decode_planning_snapshot
          (`Assoc
            [ "goals", `List [ `Assoc fields ]
            ; ( "rollup"
              , `Assoc
                  [ "active_count", `Int 1
                  ; "verifying_count", `Int 0
                  ; "done_count", `Int 0
                  ; "dropped_count", `Int 0
                  ] )
            ; ( "task_backlog"
              , `Assoc
                  [ "todo", `Int 0
                  ; "claimed", `Int 0
                  ; "in_progress", `Int 0
                  ; "done", `Int 0
                  ; "cancelled", `Int 0
                  ] )
            ; "generated_at", `String "2026-08-23T13:25:01Z"
            ])
  with
  | Error detail -> Alcotest.fail ("planning snapshot did not decode: " ^ detail)
  | Ok snapshot ->
    (match snapshot.Tui_decode.pl_goals with
     | [ goal ] -> goal
     | goals ->
       Alcotest.fail
         (Printf.sprintf "expected one goal, got %d" (List.length goals)))
;;

(* The phase says "executing" for a goal nobody asked about and for one the
   judge refused with a reason. Before this the pane could not tell them apart,
   and the reason — the whole product of the verification lane — stopped at the
   wire. *)
let test_planning_goal_carries_the_judge_verdict () =
  let proof goal = goal.Tui_decode.pg_proof in
  Alcotest.check Alcotest.bool "an approval carries what was measured" true
    (match
       proof
         (decoded_proof
            ~verification:
              (verification_json "proof_proven"
                 ~verdict:
                   (proven_verdict
                      "The file smoke-goal-tools/measurement.txt records \
                       smoke_tools_measured = 42, which matches the declared \
                       target value of 42."))
            ())
     with
     | Tui_decode.Proof_proven (Some evidence) ->
       Astring.String.is_infix ~affix:"smoke_tools_measured = 42" evidence
     | _ -> false);
  Alcotest.check Alcotest.bool "a refusal carries why" true
    (match
       proof
         (decoded_proof
            ~verification:
              (verification_json "proof_refuted"
                 ~verdict:(refuted_verdict "the rollup does not attempt the work"))
            ())
     with
     | Tui_decode.Proof_refuted (Some reason) ->
       Astring.String.is_infix ~affix:"does not attempt" reason
     | _ -> false);
  Alcotest.check Alcotest.bool "a pending request is neither" true
    (match proof (decoded_proof ~verification:(verification_json "proof_pending") ()) with
     | Tui_decode.Proof_pending -> true
     | _ -> false);
  Alcotest.check Alcotest.bool "an idle ledger is idle" true
    (match proof (decoded_proof ~verification:(verification_json "idle") ()) with
     | Tui_decode.Proof_idle -> true
     | _ -> false)
;;

(* An unreadable ledger is not an unreviewed goal. Rendering it as idle would
   disguise corruption as quiet, which is what the server's own projection note
   refuses to do. *)
let test_planning_goal_separates_unreadable_from_unreviewed () =
  Alcotest.check Alcotest.bool "a ledger error says so" true
    (match
       (decoded_proof
          ~verification:
            (`Assoc [ "state", `String "ledger_error"; "detail", `String "bad json" ])
          ())
         .Tui_decode.pg_proof
     with
     | Tui_decode.Proof_unreadable (Some detail) ->
       Astring.String.is_infix ~affix:"bad json" detail
     | _ -> false);
  Alcotest.check Alcotest.bool "a state this build does not know is not silently idle" true
    (match
       (decoded_proof ~verification:(verification_json "proof_teleported") ())
         .Tui_decode.pg_proof
     with
     | Tui_decode.Proof_unreadable _ -> true
     | _ -> false);
  (* The server attaches this block to every goal -- the default record when
     there is no ledger row, the ledger_error marker when the store will not
     decode. A goal that arrives without one is a wire this build cannot read,
     and reading it as "nobody asked" is the same disguise the server's own
     note refuses to put on. *)
  Alcotest.check Alcotest.bool "no verification block at all is not idle" true
    (match (decoded_proof ()).Tui_decode.pg_proof with
     | Tui_decode.Proof_unreadable _ -> true
     | _ -> false);
  Alcotest.check Alcotest.bool "and neither is a block with no completion state"
    true
    (match
       (decoded_proof ~verification:(`Assoc [ "completion", `Assoc [] ]) ())
         .Tui_decode.pg_proof
     with
     | Tui_decode.Proof_unreadable _ -> true
     | _ -> false)
;;

(* With no verdict the keeper's own note is what the row has to say. *)
let test_planning_goal_keeps_the_last_review_note () =
  Alcotest.check (Alcotest.option Alcotest.string) "the note is decoded"
    (Some "blocked on the platform gap")
    (decoded_proof ~last_review_note:"blocked on the platform gap" ())
      .Tui_decode.pg_last_review_note
;;

let planning_snapshot_json ?(running_key = "in_progress") () =
  `Assoc
    [ ( "goals"
      , `List
          (List.mapi
             (fun index phase ->
                planning_goal_json (Printf.sprintf "goal-%d" index) phase index)
             [ "executing"; "verifying"; "completed"; "dropped" ]) )
    ; ( "rollup"
      , `Assoc
          [ "active_count", `Int 1
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
        [ "executing"; "verifying"; "completed"; "dropped" ]
        (List.map
           (fun (goal : Tui_decode.planning_goal) ->
              Goal_phase.to_string goal.pg_phase)
           snapshot.pl_goals);
      Alcotest.(check int) "active" 1 snapshot.pl_rollup.pr_active;
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

(* The shape the server actually sent while a keeper was failing to start,
   trimmed to the fields the TUI reads. *)
let fleet_safety_json ?(missing = true) () =
  `Assoc
    [ ( "keeper_fleet_safety"
      , `Assoc
          ([ "status", `String "degraded"
           ; "blocker", `String "reaction_capacity_below_target"
           ; "operator_action_required", `Bool true
           ; "bootable_keeper_count", `Int 10
           ; "running_keeper_fiber_count", `Int 9
           ; "executable_keeper_fiber_count", `Int 9
           ; "failing_keeper_fiber_count", `Int 0
           ; "recovering_keeper_fiber_count", `Int 0
           ; "paused_keeper_count", `Int 0
           ; "target_reaction_capacity_count", `Int 10
           ; "reaction_capacity_shortfall_count", `Int 1
           ; "active_task_owner_without_executable_fiber_count", `Int 1
           ; "completion_authority_pending_task_count", `Int 1
           ]
           @ [ ( "bootable_keeper_names"
               , `List
                   (List.map
                      (fun n -> `String n)
                      (if missing
                       then [ "analyst"; "kidsnote"; "sangsu" ]
                       else [ "analyst"; "kidsnote" ])) )
             ; ( "executable_keeper_names"
               , `List [ `String "analyst"; `String "kidsnote" ] )
             ]) )
    ]

let test_decode_fleet_safety_carries_both_name_lists () =
  match Tui_decode.decode_fleet_safety (fleet_safety_json ()) with
  | Error err -> Alcotest.fail err
  | Ok fleet ->
      Alcotest.(check string) "status" "degraded" fleet.fs_status;
      Alcotest.(check (option string)) "blocker"
        (Some "reaction_capacity_below_target") fleet.fs_blocker;
      Alcotest.(check bool) "operator must act" true
        fleet.fs_operator_action_required;
      Alcotest.(check int) "bootable" 10 fleet.fs_bootable_count;
      Alcotest.(check int) "running" 9 fleet.fs_running_count;
      Alcotest.(check int) "shortfall" 1 fleet.fs_reaction_capacity_shortfall;
      Alcotest.(check int) "task owner without fiber" 1
        fleet.fs_active_task_owner_without_fiber_count;
      (* The reader takes the difference; the server does not precompute it. *)
      Alcotest.(check (list string)) "keepers that should run"
        [ "analyst"; "kidsnote"; "sangsu" ] fleet.fs_bootable_names;
      Alcotest.(check (list string)) "keepers that do run"
        [ "analyst"; "kidsnote" ] fleet.fs_executable_names;
      Alcotest.(check (list string)) "the difference names the missing keeper"
        [ "sangsu" ]
        (List.filter
           (fun n -> not (List.mem n fleet.fs_executable_names))
           fleet.fs_bootable_names)

(* A fleet where every bootable keeper runs leaves the difference empty. *)
let test_decode_fleet_safety_with_nothing_missing () =
  match Tui_decode.decode_fleet_safety (fleet_safety_json ~missing:false ()) with
  | Error err -> Alcotest.fail err
  | Ok fleet ->
      Alcotest.(check (list string)) "nothing missing" []
        (List.filter
           (fun n -> not (List.mem n fleet.fs_executable_names))
           fleet.fs_bootable_names)

(* A body without the section is refused rather than read as a healthy fleet.
   Rendering "ok" for "the server did not say" is how a blocked keeper stays
   invisible, which is the state this reading exists to end. *)
let test_decode_fleet_safety_rejects_a_body_without_the_section () =
  Alcotest.(check bool) "missing section is an error" true
    (Result.is_error (Tui_decode.decode_fleet_safety (`Assoc [ "status", `String "ok" ])))

let metrics_common_fields ~kind ~channel =
  [ "schema", `String Keeper_metrics_record.schema
  ; "record_kind", `String kind
  ; "ts", `String "2026-08-21T12:00:00Z"
  ; "ts_unix", `Float 1787313600.0
  ; "channel", `String channel
  ; "name", `String "keeper-main"
  ; "agent_name", `String "codex"
  ; "trace_id", `String "trace-current"
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

(* The tools write envelope {ok, message}: the Board compose pane reports the
   server's own message either way, and a shape the endpoint never sends is
   an error rather than a guessed success. *)
let test_tool_envelope_outcome_ok_carries_message () =
  match Tui_decode.tool_envelope_outcome (`Assoc [ ("ok", `Bool true); ("message", `String "post created") ]) with
  | Ok "post created" -> ()
  | Ok other -> Alcotest.failf "expected server message, got %s" other
  | Error err -> Alcotest.fail err

let test_tool_envelope_outcome_ok_without_message_defaults () =
  match Tui_decode.tool_envelope_outcome (`Assoc [ ("ok", `Bool true) ]) with
  | Ok "posted" -> ()
  | Ok other -> Alcotest.failf "expected default ok note, got %s" other
  | Error err -> Alcotest.fail err

let test_tool_envelope_outcome_rejection_carries_message () =
  match
    Tui_decode.tool_envelope_outcome
      (`Assoc [ ("ok", `Bool false); ("message", `String "Title must not be empty") ])
  with
  | Error "Title must not be empty" -> ()
  | Error other -> Alcotest.failf "expected server rejection, got %s" other
  | Ok other -> Alcotest.failf "expected error, got %s" other

let test_tool_envelope_outcome_rejects_unexpected_shapes () =
  let cases = [ `String "nope"; `Assoc [ ("ok", `String "yes") ]; `Assoc [] ] in
  List.iter
    (fun json ->
       match Tui_decode.tool_envelope_outcome json with
       | Error "unexpected tool response envelope" -> ()
       | Error other -> Alcotest.failf "expected envelope error, got %s" other
       | Ok other -> Alcotest.failf "expected error, got %s" other)
    cases

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

let system_log_entry_json ?(level = "INFO") ?(keeper = `String "system") () =
  `Assoc
    [ ("seq", `Int 774272)
    ; ("ts", `String "2026-08-23T03:09:21Z")
    ; ("level", `String level)
    ; ("source", `String "structured")
    ; ("module", `String "Discord")
    ; ("keeper_name", keeper)
    ; ("turn_id", `Null)
    ; ("message", `String "presence update: idle")
    ; ("details", `Null)
    ; ("category", `Null)
    ]

let system_log_snapshot_json entries =
  `Assoc
    [ ("entries", `List entries)
    ; ("total", `Int 774273)
    ; ("latest_seq", `Int 774272)
    ; ("returned", `Int (List.length entries))
    ]

(* Verification requests. The shape is [Dashboard_verification.request_to_json]
   -- fields are asserted against what that writer emits, not against a shape
   invented here. *)
let verification_request_json ?(next_action = `Null)
    ?(evidence = [ "artifact:reports/proof.json" ])
    ?(evidence_error = `Null) () =
  `Assoc
    [ ("request_id", `String "vr-1")
    ; ("task_id", `String "task-470")
    ; ("task_title", `String "wire the approval gate")
    ; ("request_kind", `String "task_completion")
    ; ("request_summary", `String "tests green, gate installed")
    ; ("next_action", next_action)
    ; ("created_at", `String "2026-08-23T09:00:00Z")
    ; ("submitted_by", `String "keeper.one")
    ; ("completion_contract", `List [ `String "tests pass" ])
    ; ("required_artifacts", `List [ `String "artifact:reports/proof.json" ])
    ; ("submitted_evidence", `List (List.map (fun s -> `String s) evidence))
    ; ("evidence_projection_error", evidence_error)
    ]

let verification_snapshot_json ?(total = 3) requests =
  `Assoc
    [ ("updated_at", `String "2026-08-23T09:00:01Z")
    ; ("total", `Int total)
    ; ("requests", `List requests)
    ]

(* Tool inventory. The envelope is /dashboard/tools; the rows are
   [tool_inventory_json]. *)
let tool_entry_json ?(surfaces = [ "public_mcp" ]) ?(direct = `Bool true) () =
  `Assoc
    [ ("name", `String "masc_board_post")
    ; ("description", `String "Post to the board")
    ; ("registered_schema", `Bool true)
    ; ("direct_call_allowed", direct)
    ; ("doc_refs", `List [])
    ; ("prompt_hints", `List [])
    ; ("surfaces", `List (List.map (fun s -> `String s) surfaces))
    ]

let tool_snapshot_json tools =
  `Assoc
    [ ("generated_at", `String "2026-08-23T09:00:00Z")
    ; ("config_resolution", `Assoc [])
    ; ("runtime_resolution", `Assoc [])
    ; ( "tool_inventory"
      , `Assoc
          [ ("count", `Int (List.length tools))
          ; ("tools", `List tools)
          ; ("surface_summary", `Assoc [])
          ] )
    ; ("tool_usage", `Assoc [])
    ]

let test_decode_tool_snapshot_reads_the_live_shape () =
  match Tui_decode.decode_tool_snapshot (tool_snapshot_json [ tool_entry_json () ])
  with
  | Error err -> Alcotest.failf "decode failed: %s" err
  | Ok snapshot ->
      Alcotest.(check int) "count" 1 snapshot.Tui_decode.ts_count;
      (match snapshot.Tui_decode.ts_tools with
       | [ t ] ->
           Alcotest.(check string) "name" "masc_board_post"
             t.Tui_decode.tl_name;
           Alcotest.(check (list string)) "where it is visible"
             [ "public_mcp" ] t.Tui_decode.tl_surfaces;
           Alcotest.(check bool) "callable directly" true
             t.Tui_decode.tl_direct_call
       | ts -> Alcotest.failf "expected one tool, got %d" (List.length ts))

let test_decode_tool_projected_nowhere () =
  (* A registered tool on no surface is reachable by nothing. Kept as an empty
     list rather than dropped: that it exists and is projected nowhere is the
     reading. *)
  match
    Tui_decode.decode_tool_snapshot
      (tool_snapshot_json [ tool_entry_json ~surfaces:[] () ])
  with
  | Ok { Tui_decode.ts_tools = [ t ]; _ } ->
      Alcotest.(check (list string)) "nowhere" [] t.Tui_decode.tl_surfaces
  | Ok _ -> Alcotest.fail "expected one tool"
  | Error err -> Alcotest.failf "decode failed: %s" err

let test_decode_tool_absent_direct_call_is_off () =
  match
    Tui_decode.decode_tool_snapshot
      (tool_snapshot_json [ tool_entry_json ~direct:`Null () ])
  with
  | Ok { Tui_decode.ts_tools = [ t ]; _ } ->
      Alcotest.(check bool) "absent means not callable" false
        t.Tui_decode.tl_direct_call
  | Ok _ -> Alcotest.fail "expected one tool"
  | Error err -> Alcotest.failf "decode failed: %s" err

let test_decode_tool_snapshot_without_inventory_is_an_error () =
  (* The envelope without its inventory is not an empty inventory; reading it
     as one would draw a server that answered wrong as a server with no
     tools. *)
  match
    Tui_decode.decode_tool_snapshot (`Assoc [ ("generated_at", `String "x") ])
  with
  | Ok _ -> Alcotest.fail "an envelope with no inventory should not decode"
  | Error err -> Alcotest.(check bool) "says so" true (String.length err > 0)

(* Connectors. Shape is each connector's own connector_json; the fields below
   are the ones every connector emits. *)
let connector_json ?(available = `Bool true) ?(connected = `Bool true)
    ?(channel = `String "#release-deployment") () =
  `Assoc
    [ ("connector_id", `String "slack")
    ; ("display_name", `String "Slack")
    ; ("available", available)
    ; ("connected", connected)
    ; ("status", `String "ready")
    ; ("channel", channel)
    ; ("capabilities", `List [ `String "post" ])
    ]

let connector_snapshot_json ?(active = 1) connectors =
  `Assoc
    [ ("connectors", `List connectors)
    ; ("total", `Int (List.length connectors))
    ; ("active_count", `Int active)
    ; ("generated_at", `String "2026-08-23T09:00:00Z")
    ]

let test_decode_connector_snapshot_reads_the_live_shape () =
  match
    Tui_decode.decode_connector_snapshot
      (connector_snapshot_json [ connector_json () ])
  with
  | Error err -> Alcotest.failf "decode failed: %s" err
  | Ok snapshot ->
      Alcotest.(check int) "total" 1 snapshot.Tui_decode.cs_total;
      Alcotest.(check int) "active" 1 snapshot.Tui_decode.cs_active;
      (match snapshot.Tui_decode.cs_connectors with
       | [ c ] ->
           Alcotest.(check string) "name" "Slack"
             c.Tui_decode.cn_display_name;
           Alcotest.(check bool) "available" true c.Tui_decode.cn_available;
           Alcotest.(check bool) "connected" true c.Tui_decode.cn_connected;
           Alcotest.(check (option string)) "channel"
             (Some "#release-deployment") c.Tui_decode.cn_channel
       | cs -> Alcotest.failf "expected one connector, got %d" (List.length cs))

let test_decode_connector_configured_but_unreachable () =
  (* Available and connected are different questions. A connector that is set
     up but cannot be reached needs a different action than one that was never
     configured, so the two are not folded. *)
  match
    Tui_decode.decode_connector_snapshot
      (connector_snapshot_json ~active:1
         [ connector_json ~connected:(`Bool false) () ])
  with
  | Ok { Tui_decode.cs_connectors = [ c ]; _ } ->
      Alcotest.(check bool) "configured" true c.Tui_decode.cn_available;
      Alcotest.(check bool) "but not reachable" false c.Tui_decode.cn_connected
  | Ok _ -> Alcotest.fail "expected one connector"
  | Error err -> Alcotest.failf "decode failed: %s" err

let test_decode_connector_absent_flags_are_off () =
  (* Defaulting the other way would draw a dead connector as a working one. *)
  match
    Tui_decode.decode_connector_snapshot
      (connector_snapshot_json ~active:0
         [ connector_json ~available:`Null ~connected:`Null ~channel:`Null () ])
  with
  | Ok { Tui_decode.cs_connectors = [ c ]; _ } ->
      Alcotest.(check bool) "not available" false c.Tui_decode.cn_available;
      Alcotest.(check bool) "not connected" false c.Tui_decode.cn_connected;
      Alcotest.(check (option string)) "no channel" None
        c.Tui_decode.cn_channel
  | Ok _ -> Alcotest.fail "expected one connector"
  | Error err -> Alcotest.failf "decode failed: %s" err

(* Repositories. Shape is [repository_json] in the repositories route. *)
let repository_json ?(keepers = [ "keeper.one" ]) ?(auto_sync = `Bool true) () =
  `Assoc
    [ ("id", `String "repo-1")
    ; ("name", `String "masc")
    ; ("url", `String "https://github.com/jeong-sik/masc")
    ; ("local_path", `String "/Users/dancer/me/workspace/yousleepwhen/masc")
    ; ("aliases", `List [])
    ; ("default_branch", `String "main")
    ; ("keepers", `List (List.map (fun k -> `String k) keepers))
    ; ("status", `String "ready")
    ; ("auto_sync", auto_sync)
    ; ("sync_interval", `Int 300)
    ; ("created_at", `String "2026-08-01T00:00:00Z")
    ]

let repository_snapshot_json repos =
  `Assoc [ ("repositories", `List repos); ("total", `Int (List.length repos)) ]

let test_decode_repository_snapshot_reads_the_live_shape () =
  match
    Tui_decode.decode_repository_snapshot
      (repository_snapshot_json [ repository_json () ])
  with
  | Error err -> Alcotest.failf "decode failed: %s" err
  | Ok snapshot ->
      Alcotest.(check int) "total" 1 snapshot.Tui_decode.rs_total;
      (match snapshot.Tui_decode.rs_repositories with
       | [ r ] ->
           Alcotest.(check string) "name" "masc" r.Tui_decode.rp_name;
           Alcotest.(check string) "branch" "main"
             r.Tui_decode.rp_default_branch;
           Alcotest.(check (list string)) "who works in it" [ "keeper.one" ]
             r.Tui_decode.rp_keepers;
           Alcotest.(check bool) "auto sync" true r.Tui_decode.rp_auto_sync
       | rs -> Alcotest.failf "expected one repository, got %d" (List.length rs))

let test_decode_repository_absent_auto_sync_is_off () =
  (* A repository that does not declare auto-sync is not syncing. Reading a
     missing flag as true would tell an operator work is being pulled that is
     not. *)
  match
    Tui_decode.decode_repository_snapshot
      (repository_snapshot_json [ repository_json ~auto_sync:`Null () ])
  with
  | Ok { Tui_decode.rs_repositories = [ r ]; _ } ->
      Alcotest.(check bool) "absent means off" false r.Tui_decode.rp_auto_sync
  | Ok _ -> Alcotest.fail "expected one repository"
  | Error err -> Alcotest.failf "decode failed: %s" err

let test_decode_repository_with_no_keepers () =
  match
    Tui_decode.decode_repository_snapshot
      (repository_snapshot_json [ repository_json ~keepers:[] () ])
  with
  | Ok { Tui_decode.rs_repositories = [ r ]; _ } ->
      Alcotest.(check (list string)) "nobody assigned yet" []
        r.Tui_decode.rp_keepers
  | Ok _ -> Alcotest.fail "expected one repository"
  | Error err -> Alcotest.failf "decode failed: %s" err

(* Harness verdicts. Shape is [Dashboard_harness_health.verdict_item_json]. *)
let harness_verdict_json ?(fallback = `Null) () =
  `Assoc
    [ ("timestamp", `Float 1755950000.0)
    ; ("task_id", `String "task-470")
    ; ("task_title", `String "wire the approval gate")
    ; ("agent_name", `String "keeper.one")
    ; ("gate", `String "verify")
    ; ("verdict", `String "approve")
    ; ("evaluator_runtime", `String "glm-coding")
    ; ("fallback_reason", fallback)
    ]

let harness_snapshot_json verdicts =
  `Assoc
    [ ("generated_at", `Float 1755950001.0)
    ; ("recent_verdicts", `List verdicts)
    ; ("calibration", `Assoc [])
    ]

(* ── Autonomy feature-proof report ── *)

let feature_proof_json ?(id = "autonomous_tool_use") ?(status = "warn")
    ?(observed = [ "alice" ]) ?(missing = [ "bob" ]) ?(read_errors = []) () =
  `Assoc
    [ ("id", `String id)
    ; ("label", `String "autonomous tool use")
    ; ("status", `String status)
    ; ("summary", `String "1/2 keepers called a tool on an autonomous turn")
    ; ( "keeper_evidence"
      , `Assoc
          [ ("keeper_count", `Int 2)
          ; ("meta_count", `Int 2)
          ; ( "observed_keepers"
            , `List (List.map (fun k -> `String k) observed) )
          ; ("missing_keepers", `List (List.map (fun k -> `String k) missing))
          ; ( "read_errors"
            , `List
                (List.map
                   (fun k ->
                     `Assoc
                       [ ("keeper", `String k)
                       ; ("error", `String "meta.json is not readable")
                       ])
                   read_errors) )
          ] )
    ; ("evidence_refs", `List [])
    ; ("next_action", `String "Let the runtime run an autonomous cycle.")
    ]

let autonomy_json ?(status = "warn") ?(pass_count = 1) ?(gap_count = 1)
    ?(window_hours = `Null) features =
  `Assoc
    [ ("generated_at", `String "2026-08-24T00:00:00Z")
    ; ("status", `String status)
    ; ( "summary"
      , `Assoc
          [ ("status", `String status)
          ; ("feature_count", `Int (List.length features))
          ; ("pass_count", `Int pass_count)
          ; ("warn_count", `Int gap_count)
          ; ("fail_count", `Int 0)
          ; ("gap_count", `Int gap_count)
          ; ("keeper_count", `Int 2)
          ; ("window_hours", window_hours)
          ] )
    ; ("features", `List features)
    ; ("evidence_refs", `List [])
    ]

let test_decode_autonomy_reads_the_live_shape () =
  match
    Tui_decode.decode_autonomy_snapshot
      (autonomy_json [ feature_proof_json () ])
  with
  | Error err -> Alcotest.failf "decode failed: %s" err
  | Ok snapshot ->
      Alcotest.(check int) "features proven" 1
        snapshot.Tui_decode.au_pass_count;
      Alcotest.(check int) "features still open" 1
        snapshot.Tui_decode.au_gap_count;
      Alcotest.(check int) "keepers the report covered" 2
        snapshot.Tui_decode.au_keeper_count;
      Alcotest.(check (option (float 0.01)))
        "no window was asked for" None snapshot.Tui_decode.au_window_hours;
      (match snapshot.Tui_decode.au_features with
       | [ f ] ->
           Alcotest.(check (list string))
             "keepers with evidence" [ "alice" ] f.Tui_decode.fp_observed;
           Alcotest.(check (list string))
             "keepers without it" [ "bob" ] f.Tui_decode.fp_missing;
           Alcotest.(check string) "what would close the gap"
             "Let the runtime run an autonomous cycle."
             f.Tui_decode.fp_next_action
       | fs -> Alcotest.failf "expected one feature, got %d" (List.length fs))

let test_decode_autonomy_keeps_read_errors_apart_from_missing () =
  (* A keeper that never exercised the feature and a keeper whose record would
     not open are different problems. Folding the second into the first blames
     the keeper for a read failure and hides that the report is partly blind. *)
  match
    Tui_decode.decode_autonomy_snapshot
      (autonomy_json
         [ feature_proof_json ~missing:[ "bob" ] ~read_errors:[ "carol" ] () ])
  with
  | Ok { Tui_decode.au_features = [ f ]; _ } ->
      Alcotest.(check (list string))
        "missing stays missing" [ "bob" ] f.Tui_decode.fp_missing;
      Alcotest.(check (list string))
        "and the unreadable one is named separately" [ "carol" ]
        f.Tui_decode.fp_read_errors
  | Ok _ -> Alcotest.fail "expected one feature"
  | Error err -> Alcotest.failf "decode failed: %s" err

let test_decode_autonomy_unknown_status_is_a_gap () =
  (* The whole screen answers "is this proven". A status word this build was
     not taught means it cannot tell, and the safe reading of "I do not know"
     is not "yes" -- so it must not decode into the passing member. *)
  match
    Tui_decode.decode_autonomy_snapshot
      (autonomy_json [ feature_proof_json ~status:"degraded" () ])
  with
  | Ok { Tui_decode.au_features = [ f ]; _ } ->
      (match f.Tui_decode.fp_status with
       | Tui_decode.Fp_unreadable raw ->
           Alcotest.(check string) "the word is kept as written" "degraded" raw
       | Tui_decode.Fp_pass | Tui_decode.Fp_warn | Tui_decode.Fp_fail ->
           Alcotest.fail "an unknown status decoded into a known one");
      Alcotest.(check bool) "and it counts as a gap" true
        (Tui_decode.feature_proof_is_gap f.Tui_decode.fp_status)
  | Ok _ -> Alcotest.fail "expected one feature"
  | Error err -> Alcotest.failf "decode failed: %s" err

let test_decode_autonomy_missing_evidence_block_is_an_error () =
  (* A feature row with no keeper evidence is a malformed report, not a
     feature nobody has exercised. Defaulting it to an empty roster would draw
     "0/0" and read as a clean screen. *)
  let broken =
    `Assoc
      [ ("id", `String "runtime_liveness")
      ; ("label", `String "runtime liveness")
      ; ("status", `String "pass")
      ; ("summary", `String "all keepers up")
      ; ("next_action", `String "nothing")
      ]
  in
  match Tui_decode.decode_autonomy_snapshot (autonomy_json [ broken ]) with
  | Ok _ -> Alcotest.fail "a report with no keeper evidence decoded"
  | Error _ -> ()

let test_autonomy_window_hours_survives () =
  match
    Tui_decode.decode_autonomy_snapshot
      (autonomy_json ~window_hours:(`Float 24.0) [ feature_proof_json () ])
  with
  | Ok snapshot ->
      Alcotest.(check (option (float 0.01)))
        "the window the report used" (Some 24.0)
        snapshot.Tui_decode.au_window_hours
  | Error err -> Alcotest.failf "decode failed: %s" err

let test_decode_harness_snapshot_reads_the_live_shape () =
  match
    Tui_decode.decode_harness_snapshot
      (harness_snapshot_json [ harness_verdict_json () ])
  with
  | Error err -> Alcotest.failf "decode failed: %s" err
  | Ok snapshot ->
      (match snapshot.Tui_decode.hs_verdicts with
       | [ v ] ->
           Alcotest.(check string) "which gate ran" "verify" v.Tui_decode.hv_gate;
           Alcotest.(check string) "what it decided" "approve"
             v.Tui_decode.hv_verdict;
           Alcotest.(check string) "who decided it" "glm-coding"
             v.Tui_decode.hv_evaluator;
           Alcotest.(check (option string)) "and it was not a fallback" None
             v.Tui_decode.hv_fallback_reason
       | vs -> Alcotest.failf "expected one verdict, got %d" (List.length vs))

let test_decode_harness_keeps_the_fallback_reason () =
  (* A verdict reached by a fallback is not the verdict that was asked for.
     Dropping the reason would show the two alike. *)
  match
    Tui_decode.decode_harness_snapshot
      (harness_snapshot_json
         [ harness_verdict_json ~fallback:(`String "evaluator unreachable") () ])
  with
  | Ok { Tui_decode.hs_verdicts = [ v ] } ->
      Alcotest.(check (option string)) "the reason survives"
        (Some "evaluator unreachable") v.Tui_decode.hv_fallback_reason
  | Ok _ -> Alcotest.fail "expected one verdict"
  | Error err -> Alcotest.failf "decode failed: %s" err

let test_decode_harness_with_no_verdicts_is_not_an_error () =
  (* A quiet harness is a reading, not a failure. *)
  match Tui_decode.decode_harness_snapshot (harness_snapshot_json []) with
  | Ok snapshot ->
      Alcotest.(check int) "nothing recorded yet" 0
        (List.length snapshot.Tui_decode.hs_verdicts)
  | Error err -> Alcotest.failf "an empty harness should decode: %s" err

let test_decode_verification_snapshot_reads_the_live_shape () =
  match
    Tui_decode.decode_verification_snapshot
      (verification_snapshot_json [ verification_request_json () ])
  with
  | Error err -> Alcotest.failf "decode failed: %s" err
  | Ok snapshot ->
      Alcotest.(check int) "total is what the server holds, not what it sent" 3
        snapshot.Tui_decode.vs_total;
      (match snapshot.Tui_decode.vs_requests with
       | [ request ] ->
           Alcotest.(check string) "task" "task-470"
             request.Tui_decode.vr_task_id;
           Alcotest.(check string) "who submitted it" "keeper.one"
             request.Tui_decode.vr_submitted_by;
           Alcotest.(check (list string)) "what it must produce"
             [ "artifact:reports/proof.json" ]
             request.Tui_decode.vr_required_artifacts;
           Alcotest.(check (option string)) "no next action offered" None
             request.Tui_decode.vr_next_action
       | requests ->
           Alcotest.failf "expected one request, got %d" (List.length requests))

let test_decode_verification_keeps_no_evidence_apart_from_unreadable () =
  (* An empty list means nothing was submitted. Evidence that exists but could
     not be read is the error field, and folding the two together would show a
     broken submission as an absent one. *)
  let decode json =
    match Tui_decode.decode_verification_snapshot json with
    | Ok { Tui_decode.vs_requests = [ r ]; _ } -> r
    | Ok _ -> Alcotest.fail "expected one request"
    | Error err -> Alcotest.failf "decode failed: %s" err
  in
  let none_submitted =
    decode (verification_snapshot_json [ verification_request_json ~evidence:[] () ])
  in
  Alcotest.(check (list string)) "nothing submitted" []
    none_submitted.Tui_decode.vr_submitted_evidence;
  Alcotest.(check (option string)) "and nothing failed to read" None
    none_submitted.Tui_decode.vr_evidence_error;
  let unreadable =
    decode
      (verification_snapshot_json
         [ verification_request_json ~evidence:[]
             ~evidence_error:(`String "artifact path escapes the producer root")
             ()
         ])
  in
  Alcotest.(check (option string)) "the reason survives"
    (Some "artifact path escapes the producer root")
    unreadable.Tui_decode.vr_evidence_error

let test_decode_verification_carries_a_next_action () =
  match
    Tui_decode.decode_verification_snapshot
      (verification_snapshot_json
         [ verification_request_json
             ~next_action:(`String "attach the missing artifact") ()
         ])
  with
  | Ok { Tui_decode.vs_requests = [ r ]; _ } ->
      Alcotest.(check (option string)) "what would move it forward"
        (Some "attach the missing artifact") r.Tui_decode.vr_next_action
  | Ok _ -> Alcotest.fail "expected one request"
  | Error err -> Alcotest.failf "decode failed: %s" err

let test_decode_system_log_snapshot_reads_the_live_shape () =
  match
    Tui_decode.decode_system_log_snapshot
      (system_log_snapshot_json [ system_log_entry_json () ])
  with
  | Error err -> Alcotest.failf "decode failed: %s" err
  | Ok snapshot ->
      Alcotest.(check int) "total is the ring count, not the page" 774273
        snapshot.Tui_decode.sys_total;
      Alcotest.(check int) "latest seq" 774272 snapshot.Tui_decode.sys_latest_seq;
      (match snapshot.Tui_decode.sys_entries with
       | [ entry ] ->
           Alcotest.(check string) "module" "Discord"
             entry.Tui_decode.sl_module;
           Alcotest.(check (option string)) "keeper" (Some "system")
             entry.Tui_decode.sl_keeper;
           Alcotest.(check string) "level label" "INFO "
             (Tui_decode.system_log_level_label entry.Tui_decode.sl_level)
       | entries ->
           Alcotest.failf "expected one entry, got %d" (List.length entries))

let test_decode_system_log_accepts_both_warn_spellings () =
  let label spelling =
    match
      Tui_decode.decode_system_log_snapshot
        (system_log_snapshot_json [ system_log_entry_json ~level:spelling () ])
    with
    | Error err -> Alcotest.failf "decode failed for %s: %s" spelling err
    | Ok { Tui_decode.sys_entries = [ e ]; _ } ->
        Tui_decode.system_log_level_label e.Tui_decode.sl_level
    | Ok _ -> Alcotest.fail "expected one entry"
  in
  Alcotest.(check string) "warn" "WARN " (label "WARN");
  Alcotest.(check string) "warning" "WARN " (label "warning")

let test_decode_system_log_keeps_an_unnamed_level_as_itself () =
  (* Folding an unknown level into Info would render a level this build does
     not know as an ordinary line. *)
  match
    Tui_decode.decode_system_log_snapshot
      (system_log_snapshot_json [ system_log_entry_json ~level:"TRACE" () ])
  with
  | Error err -> Alcotest.failf "decode failed: %s" err
  | Ok { Tui_decode.sys_entries = [ e ]; _ } -> (
      match e.Tui_decode.sl_level with
      | Tui_decode.System_level_unknown raw ->
          Alcotest.(check string) "raw level survives" "TRACE" raw;
          Alcotest.(check string) "label is padded to the column width" "TRACE"
            (Tui_decode.system_log_level_label e.Tui_decode.sl_level)
      | _ -> Alcotest.fail "TRACE was folded into a named level")
  | Ok _ -> Alcotest.fail "expected one entry"

let test_decode_system_log_null_keeper_is_absent_not_empty () =
  match
    Tui_decode.decode_system_log_snapshot
      (system_log_snapshot_json [ system_log_entry_json ~keeper:`Null () ])
  with
  | Error err -> Alcotest.failf "decode failed: %s" err
  | Ok { Tui_decode.sys_entries = [ e ]; _ } ->
      Alcotest.(check (option string)) "absent keeper" None
        e.Tui_decode.sl_keeper
  | Ok _ -> Alcotest.fail "expected one entry"

let test_decode_system_log_requires_the_message () =
  let without_message =
    `Assoc
      [ ("seq", `Int 1)
      ; ("ts", `String "2026-08-23T03:09:21Z")
      ; ("level", `String "INFO")
      ; ("module", `String "Discord")
      ]
  in
  match
    Tui_decode.decode_system_log_snapshot
      (system_log_snapshot_json [ without_message ])
  with
  | Ok _ -> Alcotest.fail "a line with no message decoded"
  | Error _ -> ()

let () =
  Alcotest.run "tui_decode" [
    ( "decode_tools",
      [
        Alcotest.test_case "reads the live shape" `Quick
          test_decode_tool_snapshot_reads_the_live_shape;
        Alcotest.test_case "a tool projected nowhere" `Quick
          test_decode_tool_projected_nowhere;
        Alcotest.test_case "absent direct-call is off" `Quick
          test_decode_tool_absent_direct_call_is_off;
        Alcotest.test_case "no inventory is an error" `Quick
          test_decode_tool_snapshot_without_inventory_is_an_error;
      ] );
    ( "decode_connectors",
      [
        Alcotest.test_case "reads the live shape" `Quick
          test_decode_connector_snapshot_reads_the_live_shape;
        Alcotest.test_case "configured is not reachable" `Quick
          test_decode_connector_configured_but_unreachable;
        Alcotest.test_case "absent flags are off" `Quick
          test_decode_connector_absent_flags_are_off;
      ] );
    ( "decode_repositories",
      [
        Alcotest.test_case "reads the live shape" `Quick
          test_decode_repository_snapshot_reads_the_live_shape;
        Alcotest.test_case "absent auto-sync is off" `Quick
          test_decode_repository_absent_auto_sync_is_off;
        Alcotest.test_case "a repository with no keepers" `Quick
          test_decode_repository_with_no_keepers;
      ] );
    ( "decode_harness",
      [
        Alcotest.test_case "reads the live shape" `Quick
          test_decode_harness_snapshot_reads_the_live_shape;
        Alcotest.test_case "keeps the fallback reason" `Quick
          test_decode_harness_keeps_the_fallback_reason;
        Alcotest.test_case "an empty harness is a reading" `Quick
          test_decode_harness_with_no_verdicts_is_not_an_error;
      ] );
    ( "decode_autonomy",
      [
        Alcotest.test_case "reads the live shape" `Quick
          test_decode_autonomy_reads_the_live_shape;
        Alcotest.test_case "an unreadable record is not a missing keeper"
          `Quick test_decode_autonomy_keeps_read_errors_apart_from_missing;
        Alcotest.test_case "an unknown status counts as a gap" `Quick
          test_decode_autonomy_unknown_status_is_a_gap;
        Alcotest.test_case "a report with no keeper evidence is an error"
          `Quick test_decode_autonomy_missing_evidence_block_is_an_error;
        Alcotest.test_case "the window the report used survives" `Quick
          test_autonomy_window_hours_survives;
      ] );
    ( "decode_verification",
      [
        Alcotest.test_case "reads the live shape" `Quick
          test_decode_verification_snapshot_reads_the_live_shape;
        Alcotest.test_case "no evidence is not unreadable evidence" `Quick
          test_decode_verification_keeps_no_evidence_apart_from_unreadable;
        Alcotest.test_case "carries a next action" `Quick
          test_decode_verification_carries_a_next_action;
      ] );
    ( "decode_system_logs",
      [
        Alcotest.test_case "reads the live shape" `Quick
          test_decode_system_log_snapshot_reads_the_live_shape;
        Alcotest.test_case "warn and warning are one level" `Quick
          test_decode_system_log_accepts_both_warn_spellings;
        Alcotest.test_case "an unnamed level stays itself" `Quick
          test_decode_system_log_keeps_an_unnamed_level_as_itself;
        Alcotest.test_case "null keeper is absent" `Quick
          test_decode_system_log_null_keeper_is_absent_not_empty;
        Alcotest.test_case "message is required" `Quick
          test_decode_system_log_requires_the_message;
      ] );
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
        Alcotest.test_case "goal carries the judge verdict" `Quick
          test_planning_goal_carries_the_judge_verdict;
        Alcotest.test_case "unreadable is not unreviewed" `Quick
          test_planning_goal_separates_unreadable_from_unreviewed;
        Alcotest.test_case "keeps the last review note" `Quick
          test_planning_goal_keeps_the_last_review_note;
      ] );
    ( "decode_fleet_safety",
      [
        Alcotest.test_case "carries both name lists" `Quick
          test_decode_fleet_safety_carries_both_name_lists;
        Alcotest.test_case "a full fleet leaves the difference empty" `Quick
          test_decode_fleet_safety_with_nothing_missing;
        Alcotest.test_case "a body without the section is refused" `Quick
          test_decode_fleet_safety_rejects_a_body_without_the_section;
      ] );
    ( "terminal_text",
      [ Alcotest.test_case "escapes control sequences" `Quick
          test_terminal_text_escapes_control_sequences
      ; Alcotest.test_case "preserves printable UTF-8" `Quick
          test_terminal_text_preserves_printable_utf8
      ; Alcotest.test_case "escapes malformed UTF-8 bytes" `Quick
          test_terminal_text_escapes_malformed_utf8_bytes
      ; Alcotest.test_case "is idempotent and single-line" `Quick
          test_terminal_text_is_idempotent_and_single_line
      ; Alcotest.test_case "sanitizes timestamp slices after selection" `Quick
          test_timestamp_slices_are_sanitized_after_selection
      ] );
    ( "keeper_calls",
      [
        Alcotest.test_case "rejects rows naming another keeper" `Quick
          test_keeper_calls_reject_rows_naming_another_keeper
      ; Alcotest.test_case "requires the envelope" `Quick
          test_keeper_calls_require_the_envelope
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
        Alcotest.test_case "tool envelope ok carries the message" `Quick
          test_tool_envelope_outcome_ok_carries_message;
        Alcotest.test_case "tool envelope ok without message defaults" `Quick
          test_tool_envelope_outcome_ok_without_message_defaults;
        Alcotest.test_case "tool envelope rejection carries the message" `Quick
          test_tool_envelope_outcome_rejection_carries_message;
        Alcotest.test_case "tool envelope rejects unexpected shapes" `Quick
          test_tool_envelope_outcome_rejects_unexpected_shapes;
      ] );
    ( "bounded_parent_depth",
      [
        Alcotest.test_case "stops on cycle" `Quick
          test_bounded_parent_depth_stops_on_cycle;
      ] );
  ]
