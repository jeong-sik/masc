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
      Alcotest.(check int) "total turns" 4 keeper.k_total_turns;
      Alcotest.(check int) "total tokens" 120 keeper.k_total_tokens;
      Alcotest.(check (float 0.0001)) "total cost" 0.42
        keeper.k_total_cost_usd;
      Alcotest.(check int) "compactions" 1 keeper.k_compaction_count;
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
      [ "keeper", `String "largo"
      ; "count", `Int 3
      ; "health", `String "ok"
      ; "latest_age_s", `Float 8.2
      ; "stale_reason", `String "fresh"
      ; ( "entries"
        , `List
            [ keeper_call_row ~keeper:"largo" ~tool:"Read" ~duration_ms:28.4
                ~turn:2143 ()
            ; keeper_call_row ~keeper:"analyst" ~tool:"Edit" ()
            ; keeper_call_row ~keeper:"largo" ~tool:"tool_execute"
                ~success:false ()
            ] )
      ]
  in
  match
    Tui_decode.decode_keeper_calls_snapshot ~requested_keeper:"largo" payload
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

(* The envelope has always carried what a call answered; the row did not read
   it, so a call that failed said so without saying why. Absent and empty stay
   absent: a row that carried no result is not a call that answered "". *)
let test_keeper_calls_carry_what_the_call_answered () =
  let row ~output =
    `Assoc
      [ "ts", `Float 1787534998.4
      ; "keeper", `String "largo"
      ; "tool", `String "Execute"
      ; "input", `String {|{"argv": ["ls"]}|}
      ; "success", `Bool true
      ; "output", output
      ]
  in
  let payload entries =
    `Assoc
      [ "keeper", `String "largo"
      ; "count", `Int (List.length entries)
      ; "health", `String "ok"
      ; "entries", `List entries
      ]
  in
  let outputs entries =
    match
      Tui_decode.decode_keeper_calls_snapshot ~requested_keeper:"largo"
        (payload entries)
    with
    | Error detail -> Alcotest.failf "expected a snapshot, got %s" detail
    | Ok snapshot ->
        List.map
          (fun (call : Tui_decode.keeper_call) -> call.Tui_decode.kc_output)
          snapshot.Tui_decode.kcs_entries
  in
  Alcotest.(check (list (option string)))
    "text kept, absent and blank stay absent, a non-string is serialised"
    [ Some "a.ml  b.ml"; None; None; Some {|{"code":0}|} ]
    (outputs
       [ row ~output:(`String "a.ml  b.ml")
       ; row ~output:`Null
       ; row ~output:(`String "   ")
       ; row ~output:(`Assoc [ "code", `Int 0 ])
       ])

let test_keeper_calls_require_the_envelope () =
  Alcotest.(check bool) "no entries list is an error" true
    (Result.is_error
       (Tui_decode.decode_keeper_calls_snapshot ~requested_keeper:"largo"
          (`Assoc
             [ "keeper", `String "largo"
             ; "count", `Int 0
             ; "health", `String "ok"
             ])));
  Alcotest.(check bool) "a row without success is an error" true
    (Result.is_error
       (Tui_decode.decode_keeper_calls_snapshot ~requested_keeper:"largo"
          (`Assoc
             [ "keeper", `String "largo"
             ; "count", `Int 1
             ; "health", `String "ok"
             ; ( "entries"
               , `List
                   [ `Assoc
                       [ "ts", `Float 1.0
                       ; "keeper", `String "largo"
                       ; "tool", `String "Read"
                       ]
                   ] )
             ])))

let test_timestamp_slices_are_sanitized_after_selection () =
  Alcotest.(check string) "normal clock timestamp, in the zone asked for"
    "04:05:06"
    (Tui_decode.clock_timestamp_for_terminal ~localtime:Unix.gmtime
       "2026-08-22T04:05:06Z");
  Alcotest.(check string) "the row clock follows the terminal's zone"
    "13:05:06"
    (Tui_decode.clock_timestamp_for_terminal
       ~localtime:(fun seconds -> Unix.gmtime (seconds +. 32400.))
       "2026-08-22T04:05:06Z");
  Alcotest.(check string) "fractional seconds and offsets read the same clock"
    "04:05:06"
    (Tui_decode.clock_timestamp_for_terminal ~localtime:Unix.gmtime
       "2026-08-22T13:05:06.250+09:00");
  Alcotest.(check string) "empty short timestamp" "(never)"
    (Tui_decode.short_timestamp_for_terminal "");
  Alcotest.(check string)
    "clock slice cannot expose a UTF-8 continuation as raw C1"
    "\\x9B31mOWNE"
    (Tui_decode.clock_timestamp_for_terminal ~localtime:Unix.gmtime
       "0123456789Û31mOWNED!!");
  Alcotest.(check string)
    "short timestamp cannot leave a split UTF-8 lead byte"
    "123456789012345678\\xE2"
    (Tui_decode.short_timestamp_for_terminal
       "123456789012345678€");
  Alcotest.(check string)
    "clock slice escapes selected terminal controls"
    "0\\x1B]2;Xab"
    (Tui_decode.clock_timestamp_for_terminal ~localtime:Unix.gmtime
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

let decoded_proof ?verification ?last_review_note ?(extra = []) () =
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
    @ extra
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

let test_planning_goal_keeps_the_server_timestamps () =
  let goal =
    decoded_proof
      ~extra:[ "created_at", `String "2026-08-01T09:00:00Z"
             ; "updated_at", `String "2026-08-23T13:15:16Z"
             ; "last_review_at", `String "2026-08-22T10:00:00Z" ]
      ()
  in
  Alcotest.(check (option string)) "created_at is decoded"
    (Some "2026-08-01T09:00:00Z") goal.Tui_decode.pg_created_at;
  Alcotest.(check (option string)) "updated_at is decoded"
    (Some "2026-08-23T13:15:16Z") goal.Tui_decode.pg_updated_at;
  Alcotest.(check (option string)) "last_review_at is decoded"
    (Some "2026-08-22T10:00:00Z") goal.Tui_decode.pg_last_review_at
;;

(* A server build that predates the timestamp fields still decodes; the TUI
   renders what is there rather than refusing the goal. *)
let test_planning_goal_tolerates_missing_timestamps () =
  let goal = decoded_proof () in
  Alcotest.(check (option string)) "created_at absent" None
    goal.Tui_decode.pg_created_at;
  Alcotest.(check (option string)) "updated_at absent" None
    goal.Tui_decode.pg_updated_at;
  Alcotest.(check (option string)) "last_review_at absent" None
    goal.Tui_decode.pg_last_review_at
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
                       then [ "analyst"; "bluebird"; "haneul" ]
                       else [ "analyst"; "bluebird" ])) )
             ; ( "executable_keeper_names"
               , `List [ `String "analyst"; `String "bluebird" ] )
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
        [ "analyst"; "bluebird"; "haneul" ] fleet.fs_bootable_names;
      Alcotest.(check (list string)) "keepers that do run"
        [ "analyst"; "bluebird" ] fleet.fs_executable_names;
      Alcotest.(check (list string)) "the difference names the missing keeper"
        [ "haneul" ]
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

(* A wheel report must claim a key of its own -- not the arrow's. The wheel
   moves further than one row per notch, and the chat composer answers the
   arrows with its history, so a shared key made one of the two wrong. Clicks
   and releases arriving on the same encoding must still not leak into the key
   stream. *)
let test_sgr_wheel_up_is_its_own_key () =
  match Tui_decode.sgr_wheel_key "<64;10;5" 'M' with
  | Some "wheel-up" -> ()
  | Some other -> Alcotest.failf "expected wheel-up, got %s" other
  | None -> Alcotest.fail "wheel up should claim a key"

let test_sgr_wheel_down_is_its_own_key () =
  match Tui_decode.sgr_wheel_key "<65;10;5" 'M' with
  | Some "wheel-down" -> ()
  | Some other -> Alcotest.failf "expected wheel-down, got %s" other
  | None -> Alcotest.fail "wheel down should claim a key"

let test_sgr_click_and_horizontal_wheel_stay_unclaimed () =
  let cases = [ ("<0;10;5", 'M'); ("<32;10;5", 'M'); ("<66;10;5", 'M'); ("<0;10;5", 'm') ] in
  List.iter
    (fun (params, final) ->
       match Tui_decode.sgr_wheel_key params final with
       | None -> ()
       | Some other ->
           Alcotest.failf "report %S should stay unclaimed, got %s" params other)
    cases

(* Apple Terminal, the macOS default, answers [?1006;1000h] with the legacy X10
   shape instead of SGR. The button byte carries the same numbers offset by 32,
   so the wheel has to be readable from it or the notch is lost -- and the three
   bytes after [CSI M] have to be consumed by the caller either way, which is
   what stopped them being typed into the composer. *)
let test_x10_wheel_up_is_its_own_key () =
  match Tui_decode.x10_wheel_key (Char.chr (32 + 64)) with
  | Some "wheel-up" -> ()
  | Some other -> Alcotest.failf "expected wheel-up, got %s" other
  | None -> Alcotest.fail "wheel up should claim a key"

let test_x10_wheel_down_is_its_own_key () =
  match Tui_decode.x10_wheel_key (Char.chr (32 + 65)) with
  | Some "wheel-down" -> ()
  | Some other -> Alcotest.failf "expected wheel-down, got %s" other
  | None -> Alcotest.fail "wheel down should claim a key"

let test_x10_clicks_and_drags_stay_unclaimed () =
  List.iter
    (fun button ->
       match Tui_decode.x10_wheel_key (Char.chr (32 + button)) with
       | None -> ()
       | Some other ->
           Alcotest.failf "button %d should stay unclaimed, got %s" button other)
    [ 0; 1; 2; 3; 32; 35; 66; 67 ]

(* The two decoders answer the same physical notch, so they must agree. A
   terminal that switches encodings between sessions must not change what the
   wheel does. *)
let test_x10_and_sgr_agree_on_the_wheel () =
  List.iter
    (fun (button, params) ->
       let x10 = Tui_decode.x10_wheel_key (Char.chr (32 + button)) in
       let sgr = Tui_decode.sgr_wheel_key params 'M' in
       Alcotest.(check (option string))
         (Printf.sprintf "button %d" button) sgr x10)
    [ (64, "<64;10;5"); (65, "<65;10;5"); (0, "<0;10;5"); (66, "<66;10;5") ]

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

let tool_snapshot_json ?effective ?activations tools =
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
    ; ( "effective_keeper_surface"
      , Option.value ~default:`Null effective )
    ; ( "skill_activations"
      , Option.value ~default:`Null activations )
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

(* The server answers a cold cache with its warming placeholder: the same
   envelope, an empty inventory, and a flag saying so. Reading only the list
   made that identical to a workspace with no tools, and the pane said "no
   tools registered" to an operator who has a hundred. *)
let test_decode_tool_snapshot_keeps_the_warming_flag () =
  let warming =
    match tool_snapshot_json [] with
    | `Assoc fields -> `Assoc (("is_warming", `Bool true) :: fields)
    | other -> other
  in
  (match Tui_decode.decode_tool_snapshot warming with
   | Error err -> Alcotest.failf "decode failed: %s" err
   | Ok snapshot ->
       Alcotest.(check bool) "an empty warming inventory is not an answer" true
         (snapshot.Tui_decode.ts_freshness = Tui_decode.Warming));
  (* A built inventory does not mention the flag at all. *)
  match Tui_decode.decode_tool_snapshot (tool_snapshot_json []) with
  | Error err -> Alcotest.failf "decode failed: %s" err
  | Ok snapshot ->
      Alcotest.(check bool) "an empty built inventory does mean none" true
        (snapshot.Tui_decode.ts_freshness = Tui_decode.Settled)

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

let test_decode_effective_keeper_surface_keeps_provenance () =
  let exact_reference name revision =
    `Assoc
      [ ( "identity"
        , `Assoc
            [ "source_id", `String "project-masc"
            ; "package_id", `String name
            ; "name", `String name
            ] )
      ; "content_revision", `String (String.make 64 revision)
      ]
  in
  let effective =
    `Assoc
      [ "status", `String "available"
      ; "keeper_name", `String "codex-mcp-client"
      ; "runtime_id", `String "openai.codex"
      ; "official_client_kind", `String "codex"
      ; "tool_delivery", `Assoc [ "status", `String "delivered" ]
      ; "native_posture", `String "read"
      ; "tool_groups", `List [ `String "filesystem" ]
      ; "skill_snapshot_revision", `String (String.make 64 'c')
      ; "instruction_skills", `List [ exact_reference "ocaml-coding" 'a' ]
      ; "composition_skills", `List [ exact_reference "mission-snapshot" 'b' ]
      ; ( "skill_profiles"
        , `List
            [ `Assoc
                [ "reference", exact_reference "mission-snapshot" 'b'
                ; "kind", `String "composition"
                ; "execution", `String "async"
                ; ( "context"
                  , `Assoc
                      [ "body_bytes", `Int 1242
                      ; "discovery_bytes", `Int 369
                      ] )
                ; ( "plan"
                  , `Assoc
                      [ "node_count", `Int 4
                      ; "batch_count", `Int 2
                      ; "max_parallelism", `Int 3
                      ] )
                ; ( "flow"
                  , `Assoc
                      [ ( "nodes"
                        , `List
                            [ `Assoc
                                [ "id", `String "clock"
                                ; "tool_name", `String "keeper_time_now"
                                ; "dependencies", `List []
                                ; "batch_index", `Int 0
                                ; "batch_size", `Int 1
                                ; "execution_mode", `String "concurrent"
                                ; "statically_read_only", `Bool true
                                ] ] )
                      ; ( "batches"
                        , `List
                            [ `Assoc
                                [ "index", `Int 0
                                ; "execution_mode", `String "concurrent"
                                ; "node_ids", `List [ `String "clock" ]
                                ] ] )
                      ] )
                ] ] )
      ; "tool_surface_bytes", `Int 79984
      ; "skill_tool_surface_bytes", `Int 2360
      ; "skill_body_bytes", `Int 4981
      ; "skills_left_out", `List []
      ; "skill_resource_read_max_bytes", `Int 65536
      ; "count", `Int 1
      ; ( "tools"
        , `List
            [ `Assoc
                [ "name", `String "keeper_compose_mission-snapshot"
                ; ( "origin"
                  , `Assoc
                      [ "kind", `String "composition_skill"
                      ; "skill_source"
                        , `String "skills/mission-snapshot/SKILL.md"
                      ] )
                ] ] )
      ; "tool_surface_sha256", `String (String.make 64 'a')
      ]
  in
  match Tui_decode.decode_tool_snapshot (tool_snapshot_json ~effective []) with
  | Error err -> Alcotest.failf "decode failed: %s" err
  | Ok
      { Tui_decode.ts_effective =
          Some
            (Tui_decode.Effective_surface_available
               { ets_keeper_name;
                 ets_native_posture = Some native;
                 ets_skill_resource_read_max_bytes = Some resource_bound;
                 ets_instruction_skills;
                 ets_skill_profiles = [ profile ];
                 ets_tool_surface_bytes;
                 ets_skill_tool_surface_bytes;
                 ets_skill_body_bytes;
                 ets_tools = [ tool ];
                 ets_tool_surface_sha256 = Some digest;
                 _
               });
        _ } ->
      Alcotest.(check string) "Keeper" "codex-mcp-client" ets_keeper_name;
      Alcotest.(check string) "native posture" "read" native;
      Alcotest.(check int) "resource read bound" 65536 resource_bound;
      Alcotest.(check string)
        "declared instruction skill"
        (Yojson.Safe.to_string (`List [ exact_reference "ocaml-coding" 'a' ]))
        (Skill_reference.list_to_yojson ets_instruction_skills
         |> Yojson.Safe.to_string);
      Alcotest.(check string) "tool origin" "composition_skill" tool.et_origin;
      Alcotest.(check string) "profile name" "mission-snapshot" profile.esp_name;
      Alcotest.(check string)
        "profile keeps the exact editable reference"
        (Yojson.Safe.to_string (exact_reference "mission-snapshot" 'b'))
        (Skill_reference.to_yojson profile.esp_reference |> Yojson.Safe.to_string);
      Alcotest.(check string) "profile execution" "async" profile.esp_execution;
      Alcotest.(check int) "profile nodes" 4 profile.esp_node_count;
      Alcotest.(check int) "profile parallel width" 3 profile.esp_max_parallelism;
      (match profile.esp_flow with
       | Some { sf_nodes = [ node ]; sf_batches = [ batch ] } ->
         Alcotest.(check string) "flow node tool" "keeper_time_now" node.sfn_tool_name;
         Alcotest.(check string) "flow batch mode" "concurrent" batch.sfb_execution_mode
       | _ -> Alcotest.fail "expected one decoded flow node and batch");
      Alcotest.(check int) "whole surface bytes" 79984 ets_tool_surface_bytes;
      Alcotest.(check int) "Skill surface bytes" 2360 ets_skill_tool_surface_bytes;
      Alcotest.(check int) "Skill body bytes" 4981 ets_skill_body_bytes;
      Alcotest.(check (option string)) "SKILL.md source"
        (Some "skills/mission-snapshot/SKILL.md") tool.et_skill_source;
      Alcotest.(check int) "digest length" 64 (String.length digest)
  | Ok _ -> Alcotest.fail "expected an available effective Keeper surface"

let test_decode_effective_keeper_surface_rejects_legacy_skill_names () =
  let effective =
    `Assoc
      [ "status", `String "available"
      ; "keeper_name", `String "fixture"
      ; "runtime_id", `String "runtime"
      ; "official_client_kind", `String "codex"
      ; "tool_delivery", `Assoc [ "status", `String "delivered" ]
      ; "native_posture", `Null
      ; "tool_groups", `List []
      ; "skill_snapshot_revision", `String (String.make 64 'c')
      ; "instruction_skills", `List [ `String "legacy-name" ]
      ; "composition_skills", `List []
      ; "skills_left_out", `List []
      ; "count", `Int 0
      ; "tools", `List []
      ; "tool_surface_sha256", `Null
      ]
  in
  match Tui_decode.decode_tool_snapshot (tool_snapshot_json ~effective []) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "legacy Skill name list was accepted"

let test_decode_effective_keeper_surface_does_not_hide_unavailable () =
  let effective =
    `Assoc
      [ "status", `String "unavailable"
      ; "keeper_name", `String "analyst"
      ; "reason", `String "declared_skill_missing"
      ; "detail", `String "current task declares missing skill"
      ]
  in
  match Tui_decode.decode_tool_snapshot (tool_snapshot_json ~effective []) with
  | Ok
      { Tui_decode.ts_effective =
          Some
            (Tui_decode.Effective_surface_unavailable
               { ets_reason; ets_detail; _ });
        _ } ->
      Alcotest.(check string) "typed reason" "declared_skill_missing" ets_reason;
      Alcotest.(check bool) "diagnostic preserved" true
        (String.length ets_detail > 0)
  | Ok _ -> Alcotest.fail "expected an unavailable effective Keeper surface"
  | Error err -> Alcotest.failf "decode failed: %s" err

let test_decode_effective_keeper_surface_keeps_tool_suppression () =
  let effective =
    `Assoc
      [ "status", `String "available"
      ; "keeper_name", `String "text-only"
      ; "runtime_id", `String "agent-core.text"
      ; "official_client_kind", `String "agent_core"
      ; ( "tool_delivery"
        , `Assoc
            [ "status", `String "suppressed"
            ; "reason", `String "runtime_tools_unsupported"
            ] )
      ; "native_posture", `Null
      ; "tool_groups", `List []
      ; "skill_snapshot_revision", `String (String.make 64 'c')
      ; "instruction_skills", `List []
      ; "composition_skills", `List []
      ; "skills_left_out", `List []
      ; "count", `Int 0
      ; "tools", `List []
      ; "tool_surface_sha256", `Null
      ]
  in
  match Tui_decode.decode_tool_snapshot (tool_snapshot_json ~effective []) with
  | Ok
      { Tui_decode.ts_effective =
          Some
            (Tui_decode.Effective_surface_available
               { ets_tool_delivery =
                   Tui_decode.Effective_tools_suppressed_runtime_unsupported;
                 ets_skill_profiles = [];
                 ets_tool_surface_bytes = 0;
                 ets_skill_tool_surface_bytes = 0;
                 ets_skill_body_bytes = 0;
                 ets_tools = [];
                 _
               });
        _ } -> ()
  | Ok _ -> Alcotest.fail "runtime tool suppression was not kept distinct"
  | Error err -> Alcotest.failf "decode failed: %s" err

let skill_activation_reference_json name revision =
  `Assoc
    [ ( "identity"
      , `Assoc
          [ "source_id", `String "project-masc"
          ; "package_id", `String name
          ; "name", `String name
          ] )
    ; "content_revision", `String (String.make 64 revision)
    ]

let skill_activation_json
    ?(invocation =
      `Assoc
        [ "kind", `String "instruction"
        ; "origin", `Assoc [ "kind", `String "session_instruction" ]
        ; ( "served_content"
          , `Assoc
              [ "kind", `String "skill_body"
              ; "bytes", `Int 12
              ; "sha256", `String (String.make 64 'c')
              ] )
        ])
    ?(delivery = `Null)
    ?(actions = `List [])
    ?(revision = 'a') () =
  match skill_activation_reference_json "ocaml-coding" revision with
  | `Assoc reference_fields ->
      `Assoc
        (reference_fields
         @ [ "snapshot_revision", `String (String.make 64 'f')
           ; "turn_ref", `String "trace-activation#7"
           ; "runtime_id", `String "test.runtime"
           ; "skill_tool_use_id", `String (Printf.sprintf "call-%c" revision)
           ; "agent_core_turn", `Int 0
           ; "invocation", invocation
           ; "delivery", delivery
           ; "actions", actions
           ; "activated_at", `String "2026-08-26T10:30:00Z"
           ])
  | _ -> assert false

let skill_activation_projection_json activations =
  let workspace_key = String.make 64 '1' in
  let session_id = "trace-activation" in
  let revision =
    `Assoc
      [ "workspace_key", `String workspace_key
      ; "session_id", `String session_id
      ; "activations", `List activations
      ; "transition_rejections", `List []
      ]
    |> Yojson.Safe.to_string
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  in
  `Assoc
    [ "status", `String "available"
    ; "keeper_name", `String "codex-mcp-client"
    ; ( "ledger"
      , `Assoc
          [ "schema", `String "masc.skill-activations/v5"
          ; "workspace_key", `String workspace_key
          ; "session_id", `String session_id
          ; "revision", `String revision
          ; "activations", `List activations
          ; "transition_rejections", `List []
          ] )
    ]

let test_decode_skill_activations_keeps_exact_receipt_and_origin () =
  let task_invocation =
    `Assoc
      [ "kind", `String "composition"
      ; ( "origin"
        , `Assoc
            [ "kind", `String "task_composition"
            ; "task_ids", `List [ `String "task-470"; `String "task-held" ]
            ] )
      ; "tool_name", `String "run-checks"
      ]
  in
  let activations =
    skill_activation_projection_json
      [ skill_activation_json
          ~invocation:task_invocation
          ~delivery:
            (`Assoc
               [ ( "boundary"
                 , `Assoc
                     [ "kind", `String "official_client_result_handoff"
                     ; "agent_core_turn", `Int 0
                     ] )
               ; "runtime_id", `String "codex.runtime"
               ; "delivered_at", `String "2026-08-26T10:30:01Z"
               ; "content_bytes", `Int 12
               ; "content_sha256", `String (String.make 64 'c')
               ])
          ~actions:
            (`List
               [ `Assoc
                   [ ( "identity"
                     , `Assoc
                         [ "kind", `String "provider_step"
                         ; "conversation_id", `String "conversation-antigravity"
                         ; "step_index", `Int 7
                         ] )
                   ; "tool_name", `String "keeper_time_now"
                   ; "runtime_id", `String "claude.runtime"
                   ; "agent_core_turn", `Int 0
                   ; "observed_at", `String "2026-08-26T10:30:02Z"
                   ]
               ])
          ()
      ; skill_activation_json ~revision:'b'
          ~invocation:
            (`Assoc
               [ "kind", `String "composition"
               ; "origin", `Assoc [ "kind", `String "session_composition" ]
               ; "tool_name", `String "summarize"
               ])
          ()
      ]
  in
  match
    Tui_decode.decode_tool_snapshot
      (tool_snapshot_json ~activations [])
  with
  | Error err -> Alcotest.failf "decode failed: %s" err
  | Ok
      { Tui_decode.ts_skill_activations =
          Some
            (Tui_decode.Skill_activations_available
               { sap_keeper_name
               ; sap_ledger
               ; _
               });
        _ } ->
      let activations =
        Keeper_skill_activation_ledger.activations sap_ledger
      in
      let first, second =
        match activations with
        | [ first; second ] -> first, second
        | _ -> Alcotest.fail "expected two canonical activation rows"
      in
      let sao_task_ids, sao_tool_name =
        match first.invocation with
        | Keeper_skill_activation_ledger.Composition_invocation
            { origin = Task_composition { task_ids }; tool_name } ->
          ( Keeper_skill_activation_ledger.task_id_set_to_list task_ids
          , tool_name )
        | _ -> Alcotest.fail "expected task composition origin"
      in
      let session_tool =
        match second.invocation with
        | Keeper_skill_activation_ledger.Composition_invocation
            { origin = Session_composition; tool_name } ->
          tool_name
        | _ -> Alcotest.fail "expected session composition origin"
      in
      let sa_reference =
        Skill_reference.make
          ~identity:first.identity
          ~content_revision:first.content_revision
      in
      Alcotest.(check string) "Keeper" "codex-mcp-client" sap_keeper_name;
      Alcotest.(check string) "session" "trace-activation"
        (Keeper_skill_activation_ledger.session_id sap_ledger
         |> Keeper_id.Trace_id.to_string);
      Alcotest.(check string) "exact reference"
        (Yojson.Safe.to_string (skill_activation_reference_json "ocaml-coding" 'a'))
        (Skill_reference.to_yojson sa_reference |> Yojson.Safe.to_string);
      Alcotest.(check string) "snapshot revision" (String.make 64 'f')
        (Skill_catalog_snapshot.snapshot_revision_to_string
           first.snapshot_revision);
      Alcotest.(check string) "turn" "trace-activation#7"
        (Ids.Turn_ref.to_string first.turn_ref);
      Alcotest.(check (list string)) "tasks" [ "task-470"; "task-held" ]
        (List.map Keeper_id.Task_id.to_string sao_task_ids);
      Alcotest.(check string) "task tool" "run-checks" sao_tool_name;
      Alcotest.(check string) "session tool" "summarize" session_tool;
      (match first.delivery, first.actions with
       | ( Some
             { boundary = Official_client_result_handoff { agent_core_turn }
             ; runtime_id
             ; content_bytes
             ; _
             }
         , [ action ] ) ->
         Alcotest.(check int) "handoff turn" 0 agent_core_turn;
         Alcotest.(check string) "delivery runtime" "codex.runtime" runtime_id;
         Alcotest.(check int) "delivery bytes" 12 content_bytes;
         Alcotest.(check string) "action runtime" "claude.runtime"
           action.runtime_id;
         Alcotest.(check bool) "action provider step" true
           (action.identity
            = Runtime_native_tools.Provider_step
                { conversation_id = "conversation-antigravity"; step_index = 7 })
       | _ -> Alcotest.fail "v5 delivery/action provenance was not decoded")
  | Ok _ -> Alcotest.fail "expected two typed Skill activation receipts"

let test_decode_skill_activations_keeps_no_session_distinct () =
  let activations =
    `Assoc
      [ "status", `String "no_session"
      ; "keeper_name", `String "idle-keeper"
      ]
  in
  match Tui_decode.decode_tool_snapshot (tool_snapshot_json ~activations []) with
  | Ok
      { Tui_decode.ts_skill_activations =
          Some (Tui_decode.Skill_activations_no_session { sap_keeper_name });
        _ } ->
      Alcotest.(check string) "Keeper" "idle-keeper" sap_keeper_name
  | Ok _ -> Alcotest.fail "no_session was not kept distinct"
  | Error err -> Alcotest.failf "decode failed: %s" err

let test_decode_skill_activations_does_not_hide_unavailable () =
  let activations =
    `Assoc
      [ "status", `String "unavailable"
      ; "keeper_name", `String "broken-keeper"
      ; "reason", `String "activation_ledger_unreadable"
      ; "detail", `String "decode failed"
      ]
  in
  match Tui_decode.decode_tool_snapshot (tool_snapshot_json ~activations []) with
  | Ok
      { Tui_decode.ts_skill_activations =
          Some
            (Tui_decode.Skill_activations_unavailable
               { sap_reason; sap_detail; _ });
        _ } ->
      Alcotest.(check string) "reason" "activation_ledger_unreadable" sap_reason;
      Alcotest.(check string) "detail" "decode failed" sap_detail
  | Ok _ -> Alcotest.fail "unavailable activation ledger was hidden"
  | Error err -> Alcotest.failf "decode failed: %s" err

let test_decode_skill_activations_rejects_cross_session_turn () =
  let activation =
    match skill_activation_json () with
    | `Assoc fields ->
        `Assoc
          (("turn_ref", `String "different-trace#7")
           :: List.remove_assoc "turn_ref" fields)
    | other -> other
  in
  let activations = skill_activation_projection_json [ activation ] in
  match Tui_decode.decode_tool_snapshot (tool_snapshot_json ~activations []) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "cross-session activation turn_ref was accepted"

let test_decode_tool_snapshot_requires_both_keeper_projection_fields () =
  let missing_activations =
    match tool_snapshot_json [] with
    | `Assoc fields -> `Assoc (List.remove_assoc "skill_activations" fields)
    | other -> other
  in
  match Tui_decode.decode_tool_snapshot missing_activations with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "missing skill_activations field was accepted"

let test_decode_skill_activations_reuses_canonical_ledger_decoder () =
  let activation = skill_activation_json () in
  let invalid_time =
    match activation with
    | `Assoc fields ->
      `Assoc
        (("activated_at", `String "not-a-time")
         :: List.remove_assoc "activated_at" fields)
    | other -> other
  in
  let duplicate = skill_activation_projection_json [ activation; activation ] in
  let invalid_time = skill_activation_projection_json [ invalid_time ] in
  let invalid_revision =
    match skill_activation_projection_json [ activation ] with
    | `Assoc fields ->
      let ledger =
        match List.assoc "ledger" fields with
        | `Assoc ledger_fields ->
          `Assoc
            (("revision", `String (String.make 64 '0'))
             :: List.remove_assoc "revision" ledger_fields)
        | other -> other
      in
      `Assoc (("ledger", ledger) :: List.remove_assoc "ledger" fields)
    | other -> other
  in
  List.iter
    (fun projection ->
       match
         Tui_decode.decode_tool_snapshot
           (tool_snapshot_json ~activations:projection [])
       with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "canonical activation invariant was bypassed")
    [ invalid_time; duplicate; invalid_revision ]

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

(* Keeper lane rows. Shape is the light projection the TUI reads from
   [GET /api/v1/keepers/composite]. *)
let keeper_lane_json ?(phase = "running") ?(turn_phase = "executing")
    ?(idle_seconds = 75) ?(last_outcome = `Null)
    ?(diagnosis = `String "running_fiber_alive") keeper =
  `Assoc
    [ "keeper", `String keeper
    ; "phase", `String phase
    ; "turn_phase", `String turn_phase
    ; "idle_seconds", `Int idle_seconds
    ; "last_outcome", last_outcome
    ; ( "phase_diagnosis"
      , `Assoc [ "determining_condition", diagnosis ] )
    ]

let keeper_lanes_json lanes =
  `Assoc
    [ "generated_at", `Float 1787557669.715736
    ; "count", `Int (List.length lanes)
    ; "snapshots", `List lanes
    ]

let test_decode_keeper_lanes_reads_current_shape_and_keeps_unknown_values () =
  let last_outcome =
    `Assoc
      [ "runtime_state", `String "done"
      ; "selected_model", `String "claude-opus-5"
      ]
  in
  match
    Tui_decode.decode_keeper_lanes_snapshot
      (keeper_lanes_json
         [ keeper_lane_json ~last_outcome "alpha"
         ; keeper_lane_json ~phase:"future_phase" ~turn_phase:"future_turn"
             ~diagnosis:`Null "beta"
         ])
  with
  | Error err -> Alcotest.failf "decode failed: %s" err
  | Ok snapshot ->
      Alcotest.(check int) "envelope count" 2 snapshot.Tui_decode.kls_count;
      (match snapshot.Tui_decode.kls_lanes with
       | [ alpha; beta ] ->
           Alcotest.(check string) "first keeper" "alpha" alpha.kl_keeper;
           Alcotest.(check string) "known phase" "running"
             (Tui_decode.keeper_lane_phase_to_string alpha.kl_phase);
           Alcotest.(check string) "known turn" "executing"
             (Tui_decode.keeper_lane_turn_phase_to_string alpha.kl_turn_phase);
           Alcotest.(check int) "idle seconds" 75 alpha.kl_idle_seconds;
           (match alpha.kl_last_outcome with
            | Some outcome ->
                Alcotest.(check string) "outcome" "done"
                  outcome.klo_runtime_state;
                Alcotest.(check (option string)) "model"
                  (Some "claude-opus-5") outcome.klo_selected_model
            | None -> Alcotest.fail "alpha lost its last outcome");
           (match beta.kl_phase with
            | Tui_decode.Lane_phase_unknown raw ->
                Alcotest.(check string) "unknown phase" "future_phase" raw
            | _ -> Alcotest.fail "future phase was folded into a known phase");
           (match beta.kl_turn_phase with
            | Tui_decode.Lane_turn_unknown raw ->
                Alcotest.(check string) "unknown turn" "future_turn" raw
            | _ -> Alcotest.fail "future turn was folded into a known turn");
           Alcotest.(check (option string)) "no determining condition" None
             beta.kl_diagnosis
       | lanes ->
           Alcotest.failf "expected two lane rows, got %d" (List.length lanes))

let test_decode_keeper_lanes_requires_the_table_fields () =
  let incomplete =
    `Assoc
      [ "keeper", `String "alpha"
      ; "phase", `String "running"
      ; "turn_phase", `String "idle"
      ; "last_outcome", `Null
      ; "phase_diagnosis", `Assoc [ "determining_condition", `Null ]
      ]
  in
  match
    Tui_decode.decode_keeper_lanes_snapshot (keeper_lanes_json [ incomplete ])
  with
  | Ok _ -> Alcotest.fail "a lane without idle_seconds decoded"
  | Error detail ->
      Alcotest.(check bool) "error names the missing field" true
        (String.starts_with ~prefix:"snapshots[0]: missing required field 'idle_seconds'" detail)

let standalone_lane_json ?(status = "idle") ?(retained = 3)
    ?(running = 0) ?(selected_slots = []) lane_id label =
  `Assoc
    [ "lane_id", `String lane_id
    ; "label", `String label
    ; "required", `Bool true
    ; "observation_only", `Bool true
    ; "configured", `Bool true
    ; "configuration_state", `String "ready"
    ; "admitted_slots", `List [ `String "qwen-primary" ]
    ; "admission_error", `Null
    ; "status", `String status
    ; "retained_run_count", `Int retained
    ; "running_count", `Int running
    ; "succeeded_count", `Int retained
    ; "failed_count", `Int 0
    ; "cancelled_count", `Int 0
    ; "last_started_at", (if retained = 0 then `Null else `Float 10.)
    ; "last_terminal_at", (if retained = 0 then `Null else `Float 11.)
    ; "last_outcome", (if retained = 0 then `Null else `String "succeeded")
    ; "p50_elapsed_s", (if retained = 0 then `Null else `Float 1.)
    ; "selected_slots", `List selected_slots
    ]

let test_decode_standalone_lanes_keeps_running_and_no_retained_observation () =
  let lanes =
    [ standalone_lane_json ~status:"running" ~running:1
        "board_attention_exact" "Board Attention"
    ; standalone_lane_json "hitl_auto_judge" "HITL Auto Judge"
    ; standalone_lane_json
        ~selected_slots:
          [ `Assoc [ "slot_id", `String "qwen-primary"; "count", `Int 3 ] ]
        "librarian_exact" "Librarian"
    ; standalone_lane_json ~status:"no_retained_observation" ~retained:0
        "compaction_exact" "Compaction"
    ; standalone_lane_json "verifier_exact" "Verifier"
    ]
  in
  let json =
    `Assoc
      [ "schema", `String "masc.standalone_llm_lanes.v1"
      ; "generated_at", `String "2026-08-27T00:00:00Z"
      ; "observed_at_unix", `Float 20.
      ; "observation_only", `Bool true
      ; "exact_run_projection_count", `Int 4
      ; "exact_run_source_total", `Int 4
      ; "exact_run_projection_truncated", `Bool false
      ; "lanes", `List lanes
      ]
  in
  match Tui_decode.decode_standalone_lanes_snapshot json with
  | Error detail -> Alcotest.failf "decode failed: %s" detail
  | Ok snapshot ->
      Alcotest.(check int) "all five lanes" 5 (List.length snapshot.sls_lanes);
      let first = List.hd snapshot.sls_lanes in
      Alcotest.(check string) "running status" "running"
        (Tui_decode.standalone_lane_status_to_string first.sl_status);
      let compaction = List.nth snapshot.sls_lanes 3 in
      Alcotest.(check string)
        "no retained observation"
        "no retained observation"
        (Tui_decode.standalone_lane_status_to_string compaction.sl_status)

let test_decode_standalone_lanes_rejects_duplicate_ids () =
  let duplicate = standalone_lane_json "board_attention_exact" "Board" in
  let json =
    `Assoc
      [ "schema", `String "masc.standalone_llm_lanes.v1"
      ; "generated_at", `String "2026-08-27T00:00:00Z"
      ; "observed_at_unix", `Float 20.
      ; "observation_only", `Bool true
      ; "exact_run_projection_count", `Int 5
      ; "exact_run_source_total", `Int 5
      ; "exact_run_projection_truncated", `Bool false
      ; "lanes", `List [ duplicate; duplicate; duplicate; duplicate; duplicate ]
      ]
  in
  match Tui_decode.decode_standalone_lanes_snapshot json with
  | Ok _ -> Alcotest.fail "duplicate lane ids decoded as a complete matrix"
  | Error detail ->
      Alcotest.(check bool)
        "error names completeness"
        true
        (String.starts_with
           ~prefix:"standalone lanes: expected each known lane"
           detail)

let fusion_run_json ?(status = "completed") ?(topology = "simple")
    ?(failure_fields = []) run_id =
  `Assoc
    ([ "run_id", `String run_id
     ; "keeper", `String "fusion-keeper"
     ; "preset", `String "trio"
     ; "topology", `String topology
     ; "started_at", `Float 1787557669.715736
     ; "status", `String status
     ]
    @ failure_fields)

let fusion_recorded_detail_json ?(source = "fusion")
    ?(origin_run_id = "fusion-recorded-501") () =
  let run_id = "fusion-recorded-501" in
  `Assoc
    [ "generated_at", `String "2026-08-24T09:00:00Z"
    ; "run", fusion_run_json run_id
    ; ( "evidence"
      , `Assoc
          [ "status", `String "recorded"
          ; ( "post"
            , `Assoc
                [ "id", `String "p-fusion-501"
                ; "title", `String "Fusion title 501"
                ; ( "origin"
                  , `Assoc
                      [ "source", `String source
                      ; "fusion_run_id", `String origin_run_id
                      ] )
                ; ( "meta"
                  , `Assoc
                      [ "question", `String "question-501"
                      ; ( "panel"
                        , `List
                            [ `Assoc
                                [ "model", `String "panel-first"
                                ; "status", `String "answered"
                                ; "answer", `String "answer-first-501"
                                ; "input_tokens", `Int 10
                                ; "output_tokens", `Int 20
                                ]
                            ; `Assoc
                                [ "model", `String "panel-second"
                                ; "status", `String "failed"
                                ; "reason_code", `String "timeout"
                                ; "reason_detail", `String "failure-second-501"
                                ]
                            ] )
                      ; ( "judge"
                        , `Assoc
                            [ "status", `String "synthesized"
                            ; "decision", `String "answer"
                            ; "resolved_answer", `String "judge-answer-501"
                            ; "synthesis", `String "judge-reason-501"
                            ] )
                      ] )
                ] )
          ] )
    ]

let test_decode_fusion_list_and_exact_detail () =
  let failed_fields =
    [ "error", `String "panel unavailable"
    ; "failure_code", `String "panel_failed"
    ]
  in
  let snapshot_json =
    `Assoc
      [ "generated_at", `String "2026-08-24T09:00:00Z"
      ; "count", `Int 2
      ; ( "runs"
        , `List
            [ fusion_run_json "fusion-recorded-501"
            ; fusion_run_json ~status:"failed"
                ~failure_fields:failed_fields "fusion-failed-501"
            ] )
      ]
  in
  (match Tui_decode.decode_fusion_snapshot snapshot_json with
   | Error err -> Alcotest.failf "list decode failed: %s" err
   | Ok snapshot ->
       (match snapshot.Tui_decode.fus_runs with
        | [ first; second ] ->
            Alcotest.(check string) "source order" "fusion-recorded-501"
              first.Tui_decode.fur_run_id;
            (match second.Tui_decode.fur_status with
             | Tui_decode.Fusion_failed failure ->
                 Alcotest.(check string) "typed failure code" "panel_failed"
                   failure.frs_failure_code
             | Tui_decode.Fusion_running | Tui_decode.Fusion_completed ->
                 Alcotest.fail "failed row lost its typed status")
        | runs ->
            Alcotest.failf "expected two fusion rows, got %d"
              (List.length runs)));
  (match
     Tui_decode.decode_fusion_detail (fusion_recorded_detail_json ())
   with
   | Error err -> Alcotest.failf "detail decode failed: %s" err
   | Ok detail ->
       Alcotest.(check string) "detail identity" "fusion-recorded-501"
         detail.Tui_decode.fud_run.fur_run_id;
       (match detail.Tui_decode.fud_evidence with
        | Some evidence ->
            (match evidence.Tui_decode.fe_panel with
             | [ Tui_decode.Fusion_panel_answered answer
               ; Tui_decode.Fusion_panel_failed failure
               ] ->
                 Alcotest.(check string) "first panel stays first" "panel-first"
                   answer.fpa_model;
                 Alcotest.(check string) "second panel failure stays second"
                   "failure-second-501" failure.fpf_reason_detail
             | panel ->
                 Alcotest.failf "expected answered then failed, got %d rows"
                   (List.length panel));
            (match evidence.Tui_decode.fe_judge with
             | Tui_decode.Fusion_judge_synthesized judge ->
                 Alcotest.(check string) "judge reason" "judge-reason-501"
                   judge.fj_reason
             | Tui_decode.Fusion_judge_failed _ ->
                 Alcotest.fail "synthesized judge decoded as failed")
        | None -> Alcotest.fail "recorded evidence lost its Board post"));
  (match
     Tui_decode.decode_fusion_detail
       (fusion_recorded_detail_json ~source:"not-fusion" ())
   with
   | Ok _ -> Alcotest.fail "a non-fusion Board origin decoded as evidence"
   | Error detail ->
       Alcotest.(check bool) "origin mismatch is explicit" true
         (String.starts_with
            ~prefix:"fusion evidence origin.source is \"not-fusion\""
            detail));
  (match
     Tui_decode.decode_fusion_detail
       (fusion_recorded_detail_json ~origin_run_id:"fusion-other" ())
   with
   | Ok _ -> Alcotest.fail "evidence for another Fusion run decoded"
   | Error detail ->
       Alcotest.(check bool) "run identity mismatch is explicit" true
         (String.starts_with
            ~prefix:"fusion evidence origin run id is \"fusion-other\""
            detail));
  let completed_pending =
    `Assoc
      [ "generated_at", `String "2026-08-24T09:00:00Z"
      ; "run", fusion_run_json "fusion-completed-pending"
      ; ( "evidence"
        , `Assoc [ "status", `String "pending"; "post", `Null ] )
      ]
  in
  (match Tui_decode.decode_fusion_detail completed_pending with
   | Ok _ -> Alcotest.fail "a completed run decoded as pending evidence"
   | Error detail ->
       Alcotest.(check string) "pending is running-only"
         "only a running fusion run may have pending evidence" detail);
  let unknown_topology =
    `Assoc
      [ "generated_at", `String "2026-08-24T09:00:00Z"
      ; "count", `Int 1
      ; "runs", `List [ fusion_run_json ~topology:"recursive" "fusion-new" ]
      ]
  in
  match Tui_decode.decode_fusion_snapshot unknown_topology with
  | Ok _ -> Alcotest.fail "an unknown Fusion topology decoded"
  | Error detail ->
      Alcotest.(check bool) "closed topology is explicit" true
        (String.starts_with
           ~prefix:"runs[0]: unknown fusion topology \"recursive\""
           detail)

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

(* GET /api/v1/keepers/tool-approvals — the Approvals surface's held-call
   rows. A row missing a core field is rejected, not dropped: a listing that
   silently thins is how a held call goes unanswered again (masc#30034).
   [because] is optional for compatibility with servers predating task-345. *)
let keeper_tool_approvals_json =
  `Assoc
    [ ( "pending"
      , `List
          [ `Assoc
              [ ("keeper", `String "orbiter")
              ; ("tool_call_id", `String "call-1")
              ; ("tool", `String "Execute")
              ; ("args", `String "{\"argv\":[\"git\",\"status\"]}")
              ; ("question", `String "Run Execute on git status?")
              ; ("because", `String "fs tools change something outside this turn")
              ; ("asked_at", `Float 1787555000.)
              ; ("timeout_sec", `Float 180.)
              ]
          ] )
    ]

let test_decode_keeper_tool_approvals () =
  match Tui_decode.decode_keeper_tool_approvals keeper_tool_approvals_json with
  | Error err -> Alcotest.fail err
  | Ok [ held ] ->
      Alcotest.(check string) "keeper" "orbiter" held.Tui_decode.kta_keeper;
      Alcotest.(check string) "call id" "call-1" held.kta_tool_call_id;
      Alcotest.(check string) "tool" "Execute" held.kta_tool;
      Alcotest.(check string) "question" "Run Execute on git status?"
        held.kta_question;
      Alcotest.(check (option string)) "because rides with the question"
        (Some "fs tools change something outside this turn") held.kta_because;
      Alcotest.(check (float 0.001)) "asked at" 1787555000. held.kta_asked_at;
      Alcotest.(check (float 0.001)) "budget" 180. held.kta_timeout_sec
  | Ok held -> Alcotest.failf "expected one row, got %d" (List.length held)

let test_decode_keeper_tool_approvals_accepts_legacy_row () =
  let legacy =
    `Assoc
      [ ( "pending"
        , `List
            [ `Assoc
                [ ("keeper", `String "orbiter")
                ; ("tool_call_id", `String "call-legacy")
                ; ("tool", `String "Execute")
                ; ("args", `String "{}")
                ; ("question", `String "Run Execute?")
                ; ("asked_at", `Float 1787555000.)
                ; ("timeout_sec", `Float 180.)
                ] ] )
      ]
  in
  match Tui_decode.decode_keeper_tool_approvals legacy with
  | Error err -> Alcotest.fail err
  | Ok [ held ] ->
      Alcotest.(check (option string)) "legacy server has no because" None
        held.Tui_decode.kta_because
  | Ok held -> Alcotest.failf "expected one row, got %d" (List.length held)

let test_decode_keeper_tool_approvals_rejects_a_thin_row () =
  let thin =
    `Assoc [ ("pending", `List [ `Assoc [ ("keeper", `String "orbiter") ] ]) ]
  in
  match Tui_decode.decode_keeper_tool_approvals thin with
  | Ok _ -> Alcotest.fail "a row with no call id decoded"
  | Error _ -> ()

let keeper_turns_json =
  `Assoc
    [ ("schema", `String "masc.keeper_turns.v1")
    ; ( "keepers"
      , `List
          [ `Assoc
              [ ("keeper_name", `String "kidsnote")
              ; ("status", `String "ok")
              ; ( "turn"
                , `Assoc
                    [ ("lane", `String "autonomous")
                    ; ("started_at_unix", `Float 1787828193.5)
                    ] )
              ]
          ; `Assoc
              [ ("keeper_name", `String "analyst")
              ; ("status", `String "ok")
              ; ("turn", `Null)
              ]
          ; `Assoc
              [ ("keeper_name", `String "rondo")
              ; ("status", `String "unavailable")
              ; ("detail", `String "owner_not_found")
              ; ("turn", `Null)
              ]
          ] )
    ]

let test_decode_keeper_turns () =
  match Tui_decode.decode_keeper_turns keeper_turns_json with
  | Error err -> Alcotest.fail err
  | Ok [ running; idle; unavailable ] ->
      Alcotest.(check string) "running keeper" "kidsnote"
        running.Tui_decode.ktr_keeper_name;
      (match running.ktr_state with
       | Tui_decode.Keeper_turn_running { lane; started_at_unix } ->
           Alcotest.(check bool) "autonomous lane" true
             (lane = Tui_decode.Turn_lane_autonomous);
           Alcotest.(check (float 0.001)) "started at" 1787828193.5
             started_at_unix
       | Tui_decode.Keeper_turn_idle | Tui_decode.Keeper_turn_unavailable _ ->
           Alcotest.fail "running keeper decoded as not running");
      Alcotest.(check bool) "idle keeper" true
        (idle.Tui_decode.ktr_state = Tui_decode.Keeper_turn_idle);
      (match unavailable.Tui_decode.ktr_state with
       | Tui_decode.Keeper_turn_unavailable detail ->
           Alcotest.(check string) "unavailable detail" "owner_not_found" detail
       | Tui_decode.Keeper_turn_idle | Tui_decode.Keeper_turn_running _ ->
           Alcotest.fail "an owner lookup failure decoded as a turn state")
  | Ok rows -> Alcotest.failf "expected three rows, got %d" (List.length rows)

let test_decode_keeper_turns_rejects_unknown_lane () =
  let unknown_lane =
    `Assoc
      [ ("schema", `String "masc.keeper_turns.v1")
      ; ( "keepers"
        , `List
            [ `Assoc
                [ ("keeper_name", `String "kidsnote")
                ; ("status", `String "ok")
                ; ( "turn"
                  , `Assoc
                      [ ("lane", `String "warp")
                      ; ("started_at_unix", `Float 1.0)
                      ] )
                ]
            ] )
      ]
  in
  match Tui_decode.decode_keeper_turns unknown_lane with
  | Ok _ -> Alcotest.fail "an unknown lane decoded instead of erroring"
  | Error _ -> ()

let test_decode_keeper_turns_rejects_unknown_schema () =
  let unknown_schema =
    `Assoc [ ("schema", `String "masc.keeper_turns.v2"); ("keepers", `List []) ]
  in
  match Tui_decode.decode_keeper_turns unknown_schema with
  | Ok _ -> Alcotest.fail "an unknown schema decoded instead of erroring"
  | Error _ -> ()

(* GET /api/v1/runtime/resolved, the picker's comprehensive shared document. *)
let picker_default_runtime =
  `Assoc
    [ ("id", `String "ollama_cloud.deepseek")
    ; ("provider", `String "Ollama Cloud")
    ; ("model", `String "deepseek-v4-flash:0731")
    ; ("keeper_dispatchable", `Bool true)
    ; ("keeper_dispatch_blocked_reason", `Null)
    ; ("is_default", `Bool false)
    ]

let runtime_resolved_json =
  `Assoc
    [ ("generated_at_iso", `String "2026-08-24T10:20:02Z")
    ; ("source", `String "/api/v1/runtime/resolved")
    ; ("config_path", `String "/workspace/config/runtime.toml")
    ; ("default_runtime", picker_default_runtime)
    ; ( "runtimes"
      , `List
          [ picker_default_runtime
          ; `Assoc
              [ ("id", `String "exact.embed")
              ; ("provider", `String "Local")
              ; ("model", `String "embed")
              ; ("keeper_dispatchable", `Bool false)
              ; ("keeper_dispatch_blocked_reason", `String "not a keeper model")
              ; ("is_default", `Bool false)
              ]
          ] )
    ; ( "lanes"
      , `List
          [ `Assoc
              [ ("id", `String "ollama_cloud.deepseek")
              ; ( "runtime_ids"
                , `List
                    [ `String "ollama_cloud.deepseek"; `String "exact.embed" ] )
              ; ("preferred_candidate", `Null)
              ; ("preferred_at_ts", `Null)
              ]
          ] )
    ; ( "assignments"
      , `List
          [ `Assoc
              [ ("keeper", `String "orbiter")
              ; ("assignment_source", `String "explicit")
              ; ( "resolved"
                , `Assoc
                    [ ("kind", `String "lane")
                    ; ("id", `String "ollama_cloud.deepseek")
                    ] )
              ]
          ] )
    ]

let test_decode_runtime_resolved () =
  match Tui_decode.decode_runtime_resolved runtime_resolved_json with
  | Error err -> Alcotest.fail err
  | Ok (runtimes, assignments) ->
      Alcotest.(check int) "both runtimes decode" 2 (List.length runtimes);
      (match runtimes with
       | first :: _ ->
           Alcotest.(check string) "id" "ollama_cloud.deepseek"
             first.Tui_decode.ro_id;
           Alcotest.(check bool) "dispatchable" true first.ro_dispatchable;
           Alcotest.(check bool) "top-level default" true first.ro_is_default
       | [] -> Alcotest.fail "no runtimes");
      (match assignments with
       | [ a ] ->
           Alcotest.(check string) "keeper" "orbiter" a.Tui_decode.ra_keeper;
           Alcotest.(check string) "source" "explicit" a.ra_source;
           Alcotest.(check (option string)) "resolved id"
             (Some "ollama_cloud.deepseek") a.ra_target_id
       | other ->
           Alcotest.failf "expected one assignment, got %d" (List.length other))

let runtime_probe_provider ?(status = "reachable") ?(reachable = `Bool true)
    ?(transport = "http") ?(http_status = `Int 200)
    ?(latency_ms = `Float 12.5) ?(error = `Null) runtime_id =
  `Assoc
    [ "runtime_id", `String runtime_id
    ; "provider_id", `String ("provider-" ^ runtime_id)
    ; "provider_display_name", `String "Probe provider label"
    ; "model_id", `String ("probe-model-" ^ runtime_id)
    ; "model_api_name", `String ("probe-api-" ^ runtime_id)
    ; "protocol", `String "openai"
    ; "runtime_kind", `String (if String.equal transport "cli" then "cli" else "http")
    ; "transport", `String transport
    ; "auth_kind", `String "none"
    ; "credential_required", `Bool false
    ; "auth_present", `Bool false
    ; "status", `String status
    ; "reachable", reachable
    ; "http_status", http_status
    ; "latency_ms", latency_ms
    ; "model_count", (if String.equal status "reachable" then `Int 7 else `Null)
    ; "content_type", (if String.equal status "reachable" then `String "application/json" else `Null)
    ; "downloaded_bytes", (if String.equal status "reachable" then `Int 128 else `Null)
    ; "endpoint_url", (if String.equal transport "cli" then `Null else `String "https://runtime.invalid/v1")
    ; "probe_url", (if String.equal transport "cli" then `Null else `String "https://runtime.invalid/v1/models")
    ; "error", error
    ; "checked_at", `String "2026-08-24T10:20:00Z"
    ]

let runtime_probe_surface_json ?(first_status = "reachable")
    ?(first_reachable = `Bool true) () =
  let providers =
    [ runtime_probe_provider ~status:first_status ~reachable:first_reachable
        "runtime-a"
    ; runtime_probe_provider ~status:"skipped_cli" ~reachable:`Null
        ~transport:"cli" ~http_status:`Null ~latency_ms:`Null
        ~error:(`String "CLI runtimes do not expose an HTTP reachability endpoint")
        "runtime-b"
    ; runtime_probe_provider ~status:"network_error" ~reachable:(`Bool false)
        ~http_status:`Null ~latency_ms:(`Float 45.0)
        ~error:(`String "connection refused") "runtime-c"
    ]
  in
  `Assoc
    [ "generated_at", `String "2026-08-24T10:20:01Z"
    ; "refreshed_at_unix", `Float 1787566800.0
    ; "cache_ttl_sec", `Float 15.0
    ; "cache_age_sec", `Float 16.0
    ; "cache_hit", `Bool false
    ; "refresh_state", `String "served_stale"
    ; ( "probe"
      , `Assoc
          [ "source", `String "runtime.toml"
          ; "status", `String "degraded"
          ; "probe_ok", `Bool false
          ; "checked_at", `String "2026-08-24T10:20:00Z"
          ; ( "summary"
            , `Assoc
                [ "runtimes", `Int 3
                ; "probed", `Int 2
                ; "reachable", `Int 1
                ; "failed", `Int 1
                ; "skipped", `Int 1
                ; "default_runtime_id", `String "runtime-a"
                ] )
          ; "providers", `List providers
          ; "errors", `List [ `String "runtime-c: network_error" ]
          ; "observations", `List [ `String "metadata endpoints only" ]
          ; "limitations", `List [ `String "no completion request" ]
          ] )
    ]

let resolved_runtime id provider model =
  `Assoc
    [ "id", `String id
    ; "provider", `String provider
    ; "model", `String model
    ; "effective_max_context", `Int 200000
    ; "max_context_source", `String "capability"
    ; "max_output_tokens", `Int 8192
    ; "is_local", `Bool false
    ; "is_default", `Bool false
    ; "keeper_dispatchable", `Bool true
    ; "keeper_dispatch_blocked_reason", `Null
    ]

let runtime_lane ?(preferred = None) ?(preferred_at = None) id runtime_ids =
  `Assoc
    [ "id", `String id
    ; "runtime_ids", `List (List.map (fun runtime_id -> `String runtime_id) runtime_ids)
    ; "preferred_candidate", (match preferred with Some value -> `String value | None -> `Null)
    ; "preferred_at_ts", (match preferred_at with Some value -> `Float value | None -> `Null)
    ]

let runtime_resolved_surface_json ?(broken_preference = false) () =
  let runtime_a = resolved_runtime "runtime-a" "Resolved A" "model-a" in
  let runtimes =
    [ runtime_a
    ; resolved_runtime "runtime-b" "Resolved B" "model-b"
    ; resolved_runtime "runtime-c" "Resolved C" "model-c"
    ; resolved_runtime "runtime-d" "Resolved D" "model-d"
    ]
  in
  let preferred_at = if broken_preference then None else Some 1787566700.0 in
  `Assoc
    [ "generated_at_iso", `String "2026-08-24T10:20:02Z"
    ; "source", `String "/api/v1/runtime/resolved"
    ; "config_path", `String "/workspace/config/runtime.toml"
    ; "default_runtime", runtime_a
    ; "runtimes", `List runtimes
    ; ( "lanes"
      , `List
          [ runtime_lane ~preferred:(Some "runtime-b") ~preferred_at
              "primary" [ "runtime-a"; "runtime-b" ]
          ; runtime_lane "degraded" [ "runtime-c" ]
          ; runtime_lane "unobserved" [ "runtime-d" ]
          ] )
    ; ( "assignments"
      , `List
          [ `Assoc
              [ "keeper", `String "orbiter"
              ; "assignment_source", `String "default"
              ; ( "resolved"
                , `Assoc [ "kind", `String "lane"; "id", `String "primary" ] )
              ]
          ] )
    ]

let test_decode_and_join_runtime_surface () =
  match
    Tui_decode.decode_runtime_surface_snapshot
      ~probe_json:(runtime_probe_surface_json ())
      ~resolved_json:(runtime_resolved_surface_json ())
  with
  | Error detail -> Alcotest.fail detail
  | Ok snapshot ->
      Alcotest.(check int) "all lane candidates" 4
        (List.length snapshot.Tui_decode.rss_candidates);
      Alcotest.(check int) "no probe-only rows" 0
        snapshot.rss_unassigned_probe_count;
      (match snapshot.rss_probe with
       | Some probe ->
           Alcotest.(check string) "freshness stays producer-owned"
             "served_stale"
             (Tui_decode.runtime_probe_refresh_state_to_string
                probe.rps_refresh_state)
       | None -> Alcotest.fail "fixture probe became unavailable");
      (match snapshot.rss_candidates with
       | first :: preferred :: failed :: unobserved :: [] ->
           Alcotest.(check string) "lane order" "primary" first.rcr_lane_id;
           Alcotest.(check int) "candidate position" 2 preferred.rcr_position;
           Alcotest.(check string) "resolved provider wins" "Resolved A"
             first.rcr_runtime.ro_provider;
           Alcotest.(check (option (float 0.001))) "last success stays typed"
             (Some 1787566700.0) preferred.rcr_preferred_at_ts;
           (match failed.rcr_probe with
            | Some row ->
                Alcotest.(check string) "failure kind" "network_error"
                  (Tui_decode.runtime_provider_status_to_string row.rpp_status)
            | None -> Alcotest.fail "network failure became unobserved");
           Alcotest.(check bool) "stale absence is unobserved" true
             (Option.is_none unobserved.rcr_probe)
       | rows -> Alcotest.failf "expected four candidate rows, got %d" (List.length rows))

let test_runtime_probe_rejects_unknown_status () =
  match
    Tui_decode.decode_runtime_probe_snapshot
      (runtime_probe_surface_json ~first_status:"ok" ())
  with
  | Ok _ -> Alcotest.fail "unknown provider status decoded"
  | Error _ -> ()

let test_runtime_probe_rejects_status_reachability_disagreement () =
  match
    Tui_decode.decode_runtime_probe_snapshot
      (runtime_probe_surface_json ~first_reachable:(`Bool false) ())
  with
  | Ok _ -> Alcotest.fail "reachable status with false reachability decoded"
  | Error _ -> ()

let test_runtime_resolved_rejects_half_preference () =
  match
    Tui_decode.decode_runtime_resolved_snapshot
      (runtime_resolved_surface_json ~broken_preference:true ())
  with
  | Ok _ -> Alcotest.fail "preferred candidate without its timestamp decoded"
  | Error _ -> ()

let test_runtime_surface_keeps_resolved_rows_without_a_probe () =
  match
    Tui_decode.decode_runtime_resolved_snapshot (runtime_resolved_surface_json ())
  with
  | Error detail -> Alcotest.fail detail
  | Ok resolved ->
      (match
         Tui_decode.join_runtime_surface ~probe:None
           ~probe_error:(Some "probe permission denied") ~resolved
       with
       | Error detail -> Alcotest.fail detail
       | Ok snapshot ->
           Alcotest.(check int) "all resolved candidates remain" 4
             (List.length snapshot.rss_candidates);
           Alcotest.(check (option string)) "probe failure remains visible"
             (Some "probe permission denied") snapshot.rss_probe_error;
           Alcotest.(check bool) "every candidate is unobserved" true
             (List.for_all
                (fun row -> Option.is_none row.Tui_decode.rcr_probe)
                snapshot.rss_candidates))

(* [/health] answers before the workspace is fully up, and the footer that
   reads it draws on every surface. A decode that failed on one missing string
   would take the whole tail down to say less than a tail with a gap in it. *)
let health_probe =
  `Assoc
    [ ("status", `String "ok");
      ("server", `String "masc");
      ("version", `String "0.24.0");
      ("build", `Assoc [
        ("binary_commit", `String "030fa9043aafc5c2003f830c86720afff8e8e2ff");
        ("binary_commit_age_seconds", `Float 1106.0);
      ]);
      ("paths", `Assoc [
        ("cwd", `String "/Users/dancer/me");
        ("effective_base_path", `String "/Users/dancer/me");
        ("effective_masc_root", `String "/Users/dancer/me/.masc");
      ]);
    ]

let test_decode_server_identity_reads_a_probe () =
  match Tui_decode.decode_server_identity health_probe with
  | Error detail -> Alcotest.fail detail
  | Ok identity ->
    Alcotest.(check string) "version" "0.24.0" identity.Tui_decode.sid_version;
    Alcotest.(check string) "binary commit"
      "030fa9043aafc5c2003f830c86720afff8e8e2ff"
      identity.Tui_decode.sid_binary_commit;
    Alcotest.(check string) "base path" "/Users/dancer/me"
      identity.Tui_decode.sid_base_path;
    Alcotest.(check string) "masc root" "/Users/dancer/me/.masc"
      identity.Tui_decode.sid_masc_root;
    Alcotest.(check (option (float 0.001))) "binary age" (Some 1106.0)
      identity.Tui_decode.sid_binary_commit_age_s

let test_decode_server_identity_survives_a_bare_health () =
  match Tui_decode.decode_server_identity (`Assoc [ ("status", `String "ok") ]) with
  | Error detail -> Alcotest.fail detail
  | Ok identity ->
    Alcotest.(check string) "no version reads empty rather than failing" ""
      identity.Tui_decode.sid_version;
    Alcotest.(check string) "no base path either" ""
      identity.Tui_decode.sid_base_path;
    Alcotest.(check (option (float 0.001))) "and no age is None" None
      identity.Tui_decode.sid_binary_commit_age_s;
    Alcotest.(check (option bool))
      "an absent worktree verdict is unknown, not a lane" None
      identity.Tui_decode.sid_executable_in_worktree

let test_decode_server_identity_reads_the_worktree_verdict () =
  let with_flag value =
    `Assoc [ ("build", `Assoc [ ("executable_in_worktree", `Bool value) ]) ]
  in
  (match Tui_decode.decode_server_identity (with_flag true) with
   | Error detail -> Alcotest.fail detail
   | Ok identity ->
     Alcotest.(check (option bool)) "a worktree binary says so" (Some true)
       identity.Tui_decode.sid_executable_in_worktree);
  match Tui_decode.decode_server_identity (with_flag false) with
  | Error detail -> Alcotest.fail detail
  | Ok identity ->
    Alcotest.(check (option bool)) "a root binary says so too" (Some false)
      identity.Tui_decode.sid_executable_in_worktree

let test_decode_server_identity_takes_an_integer_age () =
  (* The server writes the age as a float today; a whole-second value would
     arrive as an int and must not read as "age unknown". *)
  let json =
    `Assoc [ ("build", `Assoc [ ("binary_commit_age_seconds", `Int 60) ]) ]
  in
  match Tui_decode.decode_server_identity json with
  | Error detail -> Alcotest.fail detail
  | Ok identity ->
    Alcotest.(check (option (float 0.001))) "an int age still reads"
      (Some 60.0) identity.Tui_decode.sid_binary_commit_age_s

(* GET /api/v1/prompts. Shaped from the live server: sixteen rows, each
   carrying the file value, any override, and what is effective. The row has
   to survive a prompt with no file on disk and one with no description --
   both exist in the registry -- because a row that fails to decode takes the
   whole list down with it. *)
let prompts_payload =
  `Assoc
    [ ("prompts",
       `List
         [ `Assoc
             [ ("key", `String "keeper");
               ("category", `String "keeper");
               ("description", `String "The keeper's standing instructions");
               ("effective", `String "You are a keeper.\nWork the task.");
               ("has_override", `Bool false);
               ("file_exists", `Bool true);
               ("file_path", `String "config/prompts/keeper.md");
               ("source", `String "file");
               ("template_variables", `List [ `String "keeper_instructions" ]);
             ];
           `Assoc
             [ ("key", `String "judge.board");
               ("effective", `String "overridden text");
               ("has_override", `Bool true);
               ("file_exists", `Bool false);
             ];
         ]);
    ]

let test_decode_prompts_reads_the_live_shape () =
  match Tui_decode.decode_prompts prompts_payload with
  | Error detail -> Alcotest.fail detail
  | Ok snapshot ->
    Alcotest.(check int) "two rows" 2 (List.length snapshot.Tui_decode.ps_rows);
    let first = List.hd snapshot.Tui_decode.ps_rows in
    Alcotest.(check string) "key" "keeper" first.Tui_decode.pr_key;
    Alcotest.(check string) "the effective text keeps its line break"
      "You are a keeper.\nWork the task." first.Tui_decode.pr_effective;
    Alcotest.(check bool) "no override" false first.Tui_decode.pr_has_override;
    Alcotest.(check string) "source" "file" first.Tui_decode.pr_source;
    Alcotest.(check (list string)) "template input names"
      [ "keeper_instructions" ] first.Tui_decode.pr_template_variables

let test_decode_prompts_survives_a_sparse_row () =
  match Tui_decode.decode_prompts prompts_payload with
  | Error detail -> Alcotest.fail detail
  | Ok snapshot ->
    let second = List.nth snapshot.Tui_decode.ps_rows 1 in
    Alcotest.(check string) "a row with no description reads empty" ""
      second.Tui_decode.pr_description;
    Alcotest.(check bool) "and its override is carried" true
      second.Tui_decode.pr_has_override;
    Alcotest.(check bool) "as is the absent file" false
      second.Tui_decode.pr_file_exists

let test_decode_prompts_rejects_a_row_with_no_key () =
  (* The key is what a write is addressed to. A row without one cannot be
     edited, so it is a decode failure rather than a row drawn as blank. *)
  let json = `Assoc [ ("prompts", `List [ `Assoc [ ("category", `String "x") ] ]) ] in
  match Tui_decode.decode_prompts json with
  | Ok _ -> Alcotest.fail "a keyless prompt row must not decode"
  | Error _ -> ()

let test_decode_prompts_rejects_a_partial_template_variable_list () =
  let json =
    `Assoc
      [ ( "prompts"
        , `List
            [ `Assoc
                [ "key", `String "librarian"
                ; "template_variables", `List [ `String "current_memory"; `Int 1 ]
                ]
            ] )
      ]
  in
  match Tui_decode.decode_prompts json with
  | Ok _ -> Alcotest.fail "a partial input-contract list must not decode"
  | Error _ -> ()

let test_decode_latest_librarian_input_follows_summary_to_detail () =
  let listing =
    `Assoc
      [ "has_more", `Bool false
      ; ( "runs"
        , `List
            [ `Assoc
                [ "run_id", `String "judge-newer"
                ; "lane", `String "hitl_auto_judge"
                ]
            ; `Assoc
                [ "run_id", `String "lib-latest"
                ; "lane", `String "librarian_exact"
                ]
            ] )
      ]
  in
  let detail =
    `Assoc
      [ ( "run"
        , `Assoc
            [ "actor", `String "omicron"
            ; "status", `String "succeeded"
            ; ( "input"
              , `Assoc
                  [ ( "payload"
                    , `Assoc
                        [ ( "actual_input"
                          , `Assoc
                              [ "keeper_instructions", `String "curate carefully"
                              ; "message_count", `Int 4
                              ] )
                        ] )
                  ] )
            ] )
      ]
  in
  match Tui_decode.decode_latest_librarian_run_id listing with
  | Error detail -> Alcotest.fail detail
  | Ok run_id ->
      Alcotest.(check string) "latest Librarian id" "lib-latest" run_id;
      (match Tui_decode.decode_librarian_actual_input ~run_id detail with
       | Error detail -> Alcotest.fail detail
       | Ok lines ->
           let text = String.concat "\n" lines in
           Alcotest.(check bool) "identity prefix" true
             (Astring.String.is_infix
                ~affix:"lib-latest \xc2\xb7 omicron \xc2\xb7 succeeded"
                text);
           Alcotest.(check bool) "actual instructions" true
             (Astring.String.is_infix ~affix:"curate carefully" text))

let test_decode_latest_librarian_input_requires_actual_input () =
  let detail =
    `Assoc
      [ ( "run"
        , `Assoc
            [ "actor", `String "omicron"
            ; "status", `String "succeeded"
            ; "input", `Assoc [ "payload", `Assoc [] ]
            ] )
      ]
  in
  match Tui_decode.decode_librarian_actual_input ~run_id:"lib-old" detail with
  | Ok _ -> Alcotest.fail "a run without actual_input must not render as empty"
  | Error _ -> ()

let test_decode_librarian_page_keeps_the_server_cursor () =
  let listing =
    `Assoc
      [ "has_more", `Bool true
      ; ( "runs"
        , `List
            [ `Assoc
                [ "run_id", `String "judge-older"
                ; "lane", `String "hitl_auto_judge"
                ; "started_at", `Float 42.5
                ]
            ] )
      ]
  in
  match Tui_decode.decode_librarian_run_page listing with
  | Error detail -> Alcotest.fail detail
  | Ok page ->
      Alcotest.(check (option string)) "no Librarian on this page" None
        page.Tui_decode.lrp_run_id;
      Alcotest.(check (option (pair (float 0.0) string))) "next cursor"
        (Some (42.5, "judge-older")) page.Tui_decode.lrp_next

let lane_run_summary_json ?(lane = "librarian_exact") ?(status = "succeeded")
    ?(completion = true) run_id =
  `Assoc
    ([ "run_id", `String run_id
     ; "lane", `String lane
     ; "actor", `String "omicron"
     ; "started_at", `Float 100.
     ; "status", `String status
     ]
     @
     if completion then
       [ "elapsed_s", `Float 1.25; "selected_slot", `String "qwen-primary" ]
     else [])

let test_decode_lane_run_page_filters_to_one_lane () =
  let listing =
    `Assoc
      [ "has_more", `Bool true
      ; ( "runs"
        , `List
            [ lane_run_summary_json "lib-1"
            ; lane_run_summary_json ~lane:"hitl_auto_judge" "judge-1"
            ; lane_run_summary_json "lib-2"
            ] )
      ]
  in
  match Tui_decode.decode_lane_run_page ~lane:"librarian_exact" listing with
  | Error detail -> Alcotest.fail detail
  | Ok page ->
      Alcotest.(check (list string)) "only the requested lane"
        [ "lib-1"; "lib-2" ]
        (List.map (fun run -> run.Tui_decode.lrs_run_id) page.Tui_decode.lrpg_runs);
      (* The cursor names the page's last row, not the last matching one:
         paging past a page without a hit must still make progress. *)
      Alcotest.(check (option (pair (float 0.0) string))) "next cursor"
        (Some (100., "lib-2")) page.Tui_decode.lrpg_next

let test_decode_lane_run_page_running_run_has_no_completion_fields () =
  let listing =
    `Assoc
      [ "has_more", `Bool false
      ; "runs", `List [ lane_run_summary_json ~status:"running"
                            ~completion:false "lib-live" ]
      ]
  in
  match Tui_decode.decode_lane_run_page ~lane:"librarian_exact" listing with
  | Error detail -> Alcotest.fail detail
  | Ok page ->
      (match page.Tui_decode.lrpg_runs with
       | [ run ] ->
           Alcotest.(check (option (float 0.0))) "no elapsed yet" None
             run.Tui_decode.lrs_elapsed_s;
           Alcotest.(check (option string)) "no slot yet" None
             run.Tui_decode.lrs_selected_slot;
           Alcotest.(check (option (pair (float 0.0) string))) "no next page"
             None page.Tui_decode.lrpg_next
       | _ -> Alcotest.fail "expected exactly one run")

let lane_run_detail_json ?(output = true) run_id =
  `Assoc
    [ ( "run"
      , `Assoc
          ([ "run_id", `String run_id
           ; "lane", `String "compaction_exact"
           ; "actor", `String "omicron"
           ; "started_at", `Float 100.
           ; "status", `String (if output then "succeeded" else "running")
           ; ( "input"
             , `Assoc
                 [ "kind", `String "exact"
                 ; "payload", `Assoc [ "rendered_prompt", `String "compact this" ]
                 ] )
           ]
           @ (if output then
                [ "elapsed_s", `Float 0.5
                ; "selected_slot", `Null
                ; "output", `Assoc [ "summary", `String "done" ]
                ]
              else []))
      )
    ]

let test_decode_lane_run_detail_carries_prompt_and_output () =
  match Tui_decode.decode_lane_run_detail (lane_run_detail_json "cmp-1") with
  | Error detail -> Alcotest.fail detail
  | Ok detail ->
      Alcotest.(check string) "run id" "cmp-1" detail.Tui_decode.lrd_run_id;
      Alcotest.(check string) "lane" "compaction_exact" detail.Tui_decode.lrd_lane;
      Alcotest.(check (option (float 0.0))) "elapsed" (Some 0.5)
        detail.Tui_decode.lrd_elapsed_s;
      (match detail.Tui_decode.lrd_input_payload with
       | `Assoc fields ->
           Alcotest.(check bool) "prompt payload" true
             (List.assoc_opt "rendered_prompt" fields
              = Some (`String "compact this"))
       | _ -> Alcotest.fail "payload must be the recorded object");
      (match detail.Tui_decode.lrd_output with
       | Some (`Assoc fields) ->
           Alcotest.(check bool) "output payload" true
             (List.assoc_opt "summary" fields = Some (`String "done"))
       | _ -> Alcotest.fail "a completed run carries its output")

let test_decode_lane_run_detail_running_has_no_output () =
  match
    Tui_decode.decode_lane_run_detail (lane_run_detail_json ~output:false "cmp-live")
  with
  | Error detail -> Alcotest.fail detail
  | Ok detail ->
      Alcotest.(check (option (float 0.0))) "no elapsed yet" None
        detail.Tui_decode.lrd_elapsed_s;
      Alcotest.(check bool) "no output while running" true
        (Option.is_none detail.Tui_decode.lrd_output)

let test_decode_lane_run_detail_requires_the_payload () =
  let json =
    `Assoc
      [ ( "run"
        , `Assoc
            [ "run_id", `String "cmp-bad"
            ; "lane", `String "compaction_exact"
            ; "actor", `String "omicron"
            ; "started_at", `Float 100.
            ; "status", `String "succeeded"
            ; "input", `Assoc [ "kind", `String "exact" ]
            ] )
      ]
  in
  match Tui_decode.decode_lane_run_detail json with
  | Ok _ -> Alcotest.fail "a run record without input.payload must not decode"
  | Error _ -> ()

(* The composite endpoint serves several screens from one body. These pin the
   part the Secrets tab reads: names and counts, never a value, and a Keeper
   the producer has not projected is absence rather than a rejected reading. *)

let secret_projection_json ~status ~env_names ~mounts =
  `Assoc
    [ ("status", `String status);
      ("configured", `Bool true);
      ("root", `String "/base/.masc/secrets/marlow");
      ("source", `String "workspace_masc_secrets");
      ("env_count", `Int (List.length env_names));
      ("file_count", `Int (List.length mounts));
      ("env_names", `List (List.map (fun n -> `String n) env_names));
      ("file_mounts",
       `List
         (List.map
            (fun (host, container) ->
              `Assoc
                [ ("host_path", `String host);
                  ("container_path", `String container) ])
            mounts));
      ("values_validated", `Bool true);
      ("error", `Null);
    ]

let snapshots_json entries =
  `Assoc
    [ ("generated_at", `Float 1.0);
      ("count", `Int (List.length entries));
      ("snapshots",
       `List
         (List.map
            (fun (keeper, projection) ->
              match projection with
              | None -> `Assoc [ ("keeper", `String keeper) ]
              | Some p ->
                  `Assoc
                    [ ("keeper", `String keeper); ("secret_projection", p) ])
            entries));
    ]

let test_decode_secret_projection_reads_names_not_values () =
  let json =
    snapshots_json
      [ ( "marlow",
          Some
            (secret_projection_json ~status:"ready"
               ~env_names:[ "JIRA_API_TOKEN"; "JIRA_BASE_URL"; "JIRA_EMAIL" ]
               ~mounts:
                 [ ( "/base/.masc/secrets/marlow/files/app.pem",
                     "/tmp/masc-runtime/secrets/app.pem" ) ]) );
      ]
  in
  match Tui_decode.decode_keeper_secret_projections json with
  | Error err -> Alcotest.fail err
  | Ok [ p ] ->
      Alcotest.(check string) "keeper" "marlow" p.Tui_decode.ksp_keeper;
      Alcotest.(check string) "status" "ready"
        (Tui_decode.keeper_secret_status_to_string p.Tui_decode.ksp_status);
      Alcotest.(check (list string)) "env names"
        [ "JIRA_API_TOKEN"; "JIRA_BASE_URL"; "JIRA_EMAIL" ]
        p.Tui_decode.ksp_env_names;
      Alcotest.(check (list string)) "container-side mount path"
        [ "/tmp/masc-runtime/secrets/app.pem" ] p.Tui_decode.ksp_file_paths;
      Alcotest.(check bool) "validated" true p.Tui_decode.ksp_values_validated
  | Ok other ->
      Alcotest.failf "expected one projection, read %d" (List.length other)

let test_decode_secret_projection_skips_unprojected_keeper () =
  let json =
    snapshots_json
      [ ("analyst", None);
        ( "marlow",
          Some
            (secret_projection_json ~status:"absent" ~env_names:[] ~mounts:[]) );
      ]
  in
  match Tui_decode.decode_keeper_secret_projections json with
  | Error err -> Alcotest.fail err
  | Ok [ p ] ->
      Alcotest.(check string) "the projected one is read" "marlow"
        p.Tui_decode.ksp_keeper
  | Ok other ->
      Alcotest.failf "expected one projection, read %d" (List.length other)

let test_decode_secret_projection_keeps_an_unknown_status () =
  (* Folding a word this reader does not know into [Secret_absent] would tell
     the operator the credential is missing when the producer said something
     else entirely. *)
  let json =
    snapshots_json
      [ ( "marlow",
          Some
            (secret_projection_json ~status:"quarantined" ~env_names:[]
               ~mounts:[]) );
      ]
  in
  match Tui_decode.decode_keeper_secret_projections json with
  | Ok [ { Tui_decode.ksp_status = Tui_decode.Secret_status_unknown word; _ } ]
    ->
      Alcotest.(check string) "the producer's word survives" "quarantined" word
  | Ok _ -> Alcotest.fail "an unknown status was folded into a known one"
  | Error err -> Alcotest.fail err

let test_decode_secret_projection_rejects_a_wrong_env_name_type () =
  let json =
    `Assoc
      [ ("snapshots",
         `List
           [ `Assoc
               [ ("keeper", `String "marlow");
                 ("secret_projection",
                  `Assoc
                    [ ("status", `String "ready");
                      ("root", `String "/base/.masc/secrets/marlow");
                      ("env_names", `List [ `Int 7 ]);
                    ]);
               ];
           ]);
      ]
  in
  match Tui_decode.decode_keeper_secret_projections json with
  | Ok _ -> Alcotest.fail "a non-string env name was accepted"
  | Error _ -> ()

(* ── the durable Gate snapshot ──────────────────────────────────────── *)

let gate_snapshot_json ?(queue = `List []) ?(hitl = `Null) () =
  `Assoc [ ("approval_queue", queue); ("hitl", hitl) ]

let test_decode_gate_identity_row_reads_its_target () =
  (* The row a human decides on: an identity_call names its provider and
     remote tool from the stored input, and the closed operation stays
     readable beside it. *)
  let row =
    `Assoc
      [ ("id", `String "appr-1");
        ("keeper_name", `String "kidsnote");
        ("tool_name", `String "identity_call");
        ("input_preview", `String "{\"provider_id\":\"atlassian\"}");
        ("waiting_s", `Int 42);
        ( "input",
          `Assoc
            [ ("provider_id", `String "atlassian");
              ("remote_name", `String "addCommentToJiraIssue");
              ("arguments", `Assoc []);
            ] );
      ]
  in
  match
    Tui_decode.decode_gate_snapshot
      (gate_snapshot_json ~queue:(`List [ row ]) ())
  with
  | Error message -> Alcotest.failf "the snapshot did not decode: %s" message
  | Ok snapshot -> (
      match snapshot.Tui_decode.gs_pending with
      | [ pending ] ->
          Alcotest.check Alcotest.string "operation" "identity_call"
            pending.Tui_decode.gp_operation;
          Alcotest.check Alcotest.string "display"
            "atlassian \xc2\xb7 addCommentToJiraIssue"
            pending.Tui_decode.gp_display_tool;
          Alcotest.check
            Alcotest.(option (float 0.01))
            "waiting" (Some 42.) pending.Tui_decode.gp_waiting_s
      | rows ->
          Alcotest.failf "expected one pending row, got %d" (List.length rows))

let test_decode_gate_null_queue_is_empty_with_modes () =
  (* The server sends [null] when the queue store is unavailable; the lanes
     still say what they say, and the pane must show that rather than fail. *)
  let hitl =
    `Assoc
      [ ("gate_mode", `Assoc [ ("mode", `String "always_allow") ]);
        ("external_gate_mode", `Assoc [ ("mode", `String "manual") ]);
      ]
  in
  match Tui_decode.decode_gate_snapshot (gate_snapshot_json ~queue:`Null ~hitl ()) with
  | Error message -> Alcotest.failf "the snapshot did not decode: %s" message
  | Ok snapshot -> (
      Alcotest.check Alcotest.int "no rows" 0
        (List.length snapshot.Tui_decode.gs_pending);
      match snapshot.Tui_decode.gs_modes with
      | Some modes ->
          Alcotest.check Alcotest.string "workspace lane" "always_allow"
            modes.Tui_decode.glm_workspace;
          Alcotest.check Alcotest.string "external lane" "manual"
            modes.Tui_decode.glm_external
      | None -> Alcotest.fail "the lanes went missing")

let test_decode_gate_row_missing_id_is_an_error () =
  let row =
    `Assoc
      [ ("keeper_name", `String "kidsnote");
        ("tool_name", `String "identity_call");
      ]
  in
  match
    Tui_decode.decode_gate_snapshot
      (gate_snapshot_json ~queue:(`List [ row ]) ())
  with
  | Ok _ -> Alcotest.fail "a row with no id decoded"
  | Error _ -> ()

let keeper_gate_settings_json =
  `Assoc
    [ ( "modes"
      , `List
          [ `Assoc [ ("keeper_name", `String "kidsnote"); ("mode", `String "manual") ] ] )
    ; ("modes_state", `Assoc [ ("state", `String "ready") ])
    ; ( "judges"
      , `List
          [ `Assoc
              [ ("keeper_name", `String "kidsnote")
              ; ("slot_id", `String "glm-coding.glm-5-turbo")
              ] ] )
    ; ("judges_state", `Assoc [ ("state", `String "ready") ])
    ]

let test_decode_keeper_gate_settings_reads_both_lists () =
  match Tui_decode.decode_keeper_gate_settings keeper_gate_settings_json with
  | Error detail -> Alcotest.fail ("decode failed: " ^ detail)
  | Ok (modes, judges) ->
    Alcotest.(check (list (pair string string)))
      "modes" [ ("kidsnote", "manual") ] modes;
    Alcotest.(check (list (pair string string)))
      "judges" [ ("kidsnote", "glm-coding.glm-5-turbo") ] judges

let test_decode_keeper_gate_settings_takes_an_empty_workspace () =
  (* Nobody singled out is a working configuration, not a missing answer. *)
  let json =
    `Assoc
      [ ("modes", `List [])
      ; ("modes_state", `Assoc [ ("state", `String "ready") ])
      ; ("judges", `List [])
      ; ("judges_state", `Assoc [ ("state", `String "ready") ])
      ]
  in
  match Tui_decode.decode_keeper_gate_settings json with
  | Ok ([], []) -> ()
  | Ok _ -> Alcotest.fail "invented a setting nobody made"
  | Error detail -> Alcotest.fail ("decode failed: " ^ detail)

let test_decode_keeper_gate_settings_rejects_a_row_without_a_keeper () =
  (* A row that names no Keeper cannot be shown against one, and dropping it
     silently would leave a setting in force that no detail pane mentions. *)
  let json =
    `Assoc
      [ ("modes", `List [ `Assoc [ ("mode", `String "manual") ] ])
      ; ("judges", `List [])
      ]
  in
  match Tui_decode.decode_keeper_gate_settings json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "accepted a setting that names nobody"


let runtime_params_json =
  `Assoc
    [ ( "parameters"
      , `List
          [ `Assoc
              [ ("key", `String "keeper.hitl.thinking_blocks")
              ; ("current", `Int 5)
              ; ("default", `Int 3)
              ; ("has_override", `Bool true)
              ; ( "meta"
                , `Assoc
                    [ ("description", `String "How many thinking blocks to retain")
                    ; ("value_type", `String "integer")
                    ; ("min_value", `Int 0)
                    ; ("max_value", `Int 20)
                    ] )
              ]
          ; `Assoc
              [ ("key", `String "dashboard.agent_quiet_threshold_sec")
              ; ("current", `Float 300.0)
              ; ("default", `Float 300.0)
              ; ("has_override", `Bool false)
              ]
          ; `Assoc
              [ ("key", `String "keeper.mode")
              ; ("current", `String "careful")
              ; ("default", `String "normal")
              ; ("has_override", `Bool true)
              ]
          ] )
    ; ("surfaces", `List [])
    ]

let test_decode_runtime_params_reads_current_and_default () =
  match Tui_decode.decode_runtime_params runtime_params_json with
  | Error detail -> Alcotest.fail ("decode failed: " ^ detail)
  | Ok rows ->
    (* Current/default travel together, and strings retain quotes so the
       inline editor can round-trip their JSON type. *)
    Alcotest.(check (list (triple string string string)))
      "key, current, default"
      [ ("keeper.hitl.thinking_blocks", "5", "3")
      ; ("dashboard.agent_quiet_threshold_sec", "300.0", "300.0")
      ; ("keeper.mode", {|"careful"|}, {|"normal"|})
      ]
      (List.map
         (fun row ->
           let open Tui_decode in
           row.rpr_key, row.rpr_current_json, row.rpr_default_json)
         rows);
    Alcotest.(check (list bool))
      "and which one somebody moved" [ true; false; true ]
      (List.map (fun row -> row.Tui_decode.rpr_has_override) rows);
    (match rows with
     | first :: _ ->
       let open Tui_decode in
       Alcotest.(check string) "description"
         "How many thinking blocks to retain" first.rpr_description;
       Alcotest.(check string) "type" "integer" first.rpr_value_type;
       Alcotest.(check (option string)) "min" (Some "0") first.rpr_min_json;
       Alcotest.(check (option string)) "max" (Some "20") first.rpr_max_json
     | [] -> Alcotest.fail "expected runtime param rows")

let test_decode_runtime_params_takes_an_empty_registry () =
  match
    Tui_decode.decode_runtime_params (`Assoc [ ("parameters", `List []) ])
  with
  | Ok [] -> ()
  | Ok _ -> Alcotest.fail "invented a parameter"
  | Error detail -> Alcotest.fail ("decode failed: " ^ detail)

let test_decode_runtime_params_rejects_a_row_without_a_key () =
  (* A row with no key cannot be shown against anything, and dropping it
     quietly hides a knob that is in force. *)
  match
    Tui_decode.decode_runtime_params
      (`Assoc [ ("parameters", `List [ `Assoc [ ("current", `Int 1) ] ]) ])
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "accepted a parameter that names nothing"


let () =
  Alcotest.run "tui_decode" [
    ( "decode_runtime_surface",
      [ Alcotest.test_case "joins projection and observation in lane order" `Quick
          test_decode_and_join_runtime_surface
      ; Alcotest.test_case "rejects an unknown provider status" `Quick
          test_runtime_probe_rejects_unknown_status
      ; Alcotest.test_case "rejects status/reachability disagreement" `Quick
          test_runtime_probe_rejects_status_reachability_disagreement
      ; Alcotest.test_case "rejects half a sticky preference" `Quick
          test_runtime_resolved_rejects_half_preference
      ; Alcotest.test_case "keeps resolved rows without a probe" `Quick
          test_runtime_surface_keeps_resolved_rows_without_a_probe
      ] );
    ( "decode_runtime_resolved",
      [ Alcotest.test_case "carries runtimes and assignments" `Quick
          test_decode_runtime_resolved
      ] );
    ( "decode_keeper_tool_approvals",
      [ Alcotest.test_case "carries the whole ask" `Quick
          test_decode_keeper_tool_approvals
      ; Alcotest.test_case "accepts a legacy row without because" `Quick
          test_decode_keeper_tool_approvals_accepts_legacy_row
      ; Alcotest.test_case "rejects a thin row" `Quick
          test_decode_keeper_tool_approvals_rejects_a_thin_row
      ] );
    ( "decode_keeper_turns",
      [ Alcotest.test_case "running, idle, and unavailable rows" `Quick
          test_decode_keeper_turns
      ; Alcotest.test_case "rejects an unknown lane" `Quick
          test_decode_keeper_turns_rejects_unknown_lane
      ; Alcotest.test_case "rejects an unknown schema" `Quick
          test_decode_keeper_turns_rejects_unknown_schema
      ] );
    ( "decode_tools",
      [
        Alcotest.test_case "reads the live shape" `Quick
          test_decode_tool_snapshot_reads_the_live_shape;
        Alcotest.test_case "keeps the warming flag" `Quick
          test_decode_tool_snapshot_keeps_the_warming_flag;
        Alcotest.test_case "a tool projected nowhere" `Quick
          test_decode_tool_projected_nowhere;
        Alcotest.test_case "absent direct-call is off" `Quick
          test_decode_tool_absent_direct_call_is_off;
        Alcotest.test_case "no inventory is an error" `Quick
          test_decode_tool_snapshot_without_inventory_is_an_error;
        Alcotest.test_case "effective surface keeps provenance" `Quick
          test_decode_effective_keeper_surface_keeps_provenance;
        Alcotest.test_case "effective surface rejects legacy Skill names" `Quick
          test_decode_effective_keeper_surface_rejects_legacy_skill_names;
        Alcotest.test_case "effective unavailable stays explicit" `Quick
          test_decode_effective_keeper_surface_does_not_hide_unavailable;
        Alcotest.test_case "effective surface keeps tool suppression" `Quick
          test_decode_effective_keeper_surface_keeps_tool_suppression;
        Alcotest.test_case "Skill activations keep exact receipt and origin" `Quick
          test_decode_skill_activations_keeps_exact_receipt_and_origin;
        Alcotest.test_case "Skill activations keep no session distinct" `Quick
          test_decode_skill_activations_keeps_no_session_distinct;
        Alcotest.test_case "Skill activation unavailable stays explicit" `Quick
          test_decode_skill_activations_does_not_hide_unavailable;
        Alcotest.test_case "Skill activation rejects cross-session turn" `Quick
          test_decode_skill_activations_rejects_cross_session_turn;
        Alcotest.test_case "tool snapshot requires Keeper projection fields" `Quick
          test_decode_tool_snapshot_requires_both_keeper_projection_fields;
        Alcotest.test_case "Skill activation reuses canonical ledger decoder" `Quick
          test_decode_skill_activations_reuses_canonical_ledger_decoder;
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
    ( "decode_keeper_lanes",
      [
        Alcotest.test_case "reads the live shape and keeps unknown values"
          `Quick
          test_decode_keeper_lanes_reads_current_shape_and_keeps_unknown_values;
        Alcotest.test_case "requires the table fields" `Quick
          test_decode_keeper_lanes_requires_the_table_fields;
      ] );
    ( "decode_standalone_lanes",
      [
        Alcotest.test_case "keeps running and no-retained-observation states" `Quick
          test_decode_standalone_lanes_keeps_running_and_no_retained_observation;
        Alcotest.test_case "rejects duplicate lane ids" `Quick
          test_decode_standalone_lanes_rejects_duplicate_ids;
      ] );
    ( "decode_lane_runs",
      [
        Alcotest.test_case "page filters to one lane and keeps the cursor" `Quick
          test_decode_lane_run_page_filters_to_one_lane;
        Alcotest.test_case "running run has no completion fields" `Quick
          test_decode_lane_run_page_running_run_has_no_completion_fields;
        Alcotest.test_case "detail carries prompt and output" `Quick
          test_decode_lane_run_detail_carries_prompt_and_output;
        Alcotest.test_case "running detail has no output" `Quick
          test_decode_lane_run_detail_running_has_no_output;
        Alcotest.test_case "detail requires the payload" `Quick
          test_decode_lane_run_detail_requires_the_payload;
      ] );
    ( "decode_fusion",
      [
        Alcotest.test_case "keeps typed origin and panel-to-judge order" `Quick
          test_decode_fusion_list_and_exact_detail;
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
        Alcotest.test_case "keeps the server timestamps" `Quick
          test_planning_goal_keeps_the_server_timestamps;
        Alcotest.test_case "tolerates missing timestamps" `Quick
          test_planning_goal_tolerates_missing_timestamps;
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
      ; Alcotest.test_case "carries what the call answered" `Quick
          test_keeper_calls_carry_what_the_call_answered
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
    ( "sgr_mouse",
      [
        Alcotest.test_case "wheel up claims its own key" `Quick
          test_sgr_wheel_up_is_its_own_key;
        Alcotest.test_case "wheel down claims its own key" `Quick
          test_sgr_wheel_down_is_its_own_key;
        Alcotest.test_case "clicks, releases, horizontal wheel stay unclaimed"
          `Quick
          test_sgr_click_and_horizontal_wheel_stay_unclaimed;
      ] );
    ( "x10_mouse",
      [
        Alcotest.test_case "wheel up claims its own key" `Quick
          test_x10_wheel_up_is_its_own_key;
        Alcotest.test_case "wheel down claims its own key" `Quick
          test_x10_wheel_down_is_its_own_key;
        Alcotest.test_case "clicks and drags stay unclaimed" `Quick
          test_x10_clicks_and_drags_stay_unclaimed;
        Alcotest.test_case "agrees with the SGR decoder" `Quick
          test_x10_and_sgr_agree_on_the_wheel;
      ] );
    ( "prompts",
      [
        Alcotest.test_case "reads the live shape" `Quick
          test_decode_prompts_reads_the_live_shape;
        Alcotest.test_case "survives a sparse row" `Quick
          test_decode_prompts_survives_a_sparse_row;
        Alcotest.test_case "rejects a row with no key" `Quick
          test_decode_prompts_rejects_a_row_with_no_key;
        Alcotest.test_case "rejects a partial template-variable list" `Quick
          test_decode_prompts_rejects_a_partial_template_variable_list;
        Alcotest.test_case "latest Librarian input follows summary to detail" `Quick
          test_decode_latest_librarian_input_follows_summary_to_detail;
        Alcotest.test_case "latest Librarian input requires actual input" `Quick
          test_decode_latest_librarian_input_requires_actual_input;
        Alcotest.test_case "Librarian page keeps the server cursor" `Quick
          test_decode_librarian_page_keeps_the_server_cursor;
      ] );
    ( "server_identity",
      [
        Alcotest.test_case "reads a health probe" `Quick
          test_decode_server_identity_reads_a_probe;
        Alcotest.test_case "survives a bare health" `Quick
          test_decode_server_identity_survives_a_bare_health;
        Alcotest.test_case "takes an integer age" `Quick
          test_decode_server_identity_takes_an_integer_age;
        Alcotest.test_case "reads the worktree verdict" `Quick
          test_decode_server_identity_reads_the_worktree_verdict;
      ] );
    ( "bounded_parent_depth",
      [
        Alcotest.test_case "stops on cycle" `Quick
          test_bounded_parent_depth_stops_on_cycle;
      ] );
    ( "runtime_params",
      [
        Alcotest.test_case "reads current and default" `Quick
          test_decode_runtime_params_reads_current_and_default;
        Alcotest.test_case "takes an empty registry" `Quick
          test_decode_runtime_params_takes_an_empty_registry;
        Alcotest.test_case "rejects a row without a key" `Quick
          test_decode_runtime_params_rejects_a_row_without_a_key;
      ] );
    ( "keeper_gate_settings",
      [
        Alcotest.test_case "reads both lists" `Quick
          test_decode_keeper_gate_settings_reads_both_lists;
        Alcotest.test_case "takes an empty workspace" `Quick
          test_decode_keeper_gate_settings_takes_an_empty_workspace;
        Alcotest.test_case "rejects a row without a keeper" `Quick
          test_decode_keeper_gate_settings_rejects_a_row_without_a_keeper;
      ] );
    ( "keeper_secret_projection",
      [
        Alcotest.test_case "reads names, never values" `Quick
          test_decode_secret_projection_reads_names_not_values;
        Alcotest.test_case "skips a Keeper with no projection" `Quick
          test_decode_secret_projection_skips_unprojected_keeper;
        Alcotest.test_case "keeps an unknown status" `Quick
          test_decode_secret_projection_keeps_an_unknown_status;
        Alcotest.test_case "rejects a wrong env name type" `Quick
          test_decode_secret_projection_rejects_a_wrong_env_name_type;
      ] );
    ( "gate_snapshot",
      [
        Alcotest.test_case "an identity row reads its target" `Quick
          test_decode_gate_identity_row_reads_its_target;
        Alcotest.test_case "a null queue is empty with modes" `Quick
          test_decode_gate_null_queue_is_empty_with_modes;
        Alcotest.test_case "a row missing its id is an error" `Quick
          test_decode_gate_row_missing_id_is_an_error;
      ] );
  ]
