open Alcotest
open Dashboard_execution_builders

let yojson = testable Yojson.Safe.pp Yojson.Safe.equal

(* [tool_audit_at] dates the last action now: it comes from the tool call log
   rather than from a keeper-meta mirror of it. *)
(* Liveness is read from two fields now, not from one status word: [paused] is
   a person's decision and [diagnostic.health_state] is an observation. A
   single word cannot carry both. *)
let keeper ?(health = "offline") ?(status = "offline") ?(tool_audit_at = "")
    ?(updated_at = "") ?(keepalive_running = false) ?(turn_count = 0)
    ?(paused = `Bool false) () =
  `Assoc
    [
      ("name", `String "omega");
      ("keeper_id", `String "k-executor");
      ("diagnostic", `Assoc [ ("health_state", `String health) ]);
      (* Still on the wire and still passed through to the row, but no longer
         read for any decision here. *)
      ("status", `String status);
      ("paused", paused);
      ("keepalive_running", `Bool keepalive_running);
      ("turn_count", `Int turn_count);
      ("updated_at", `String updated_at);
      ("tool_audit_at", `String tool_audit_at);
      ("recent_input_preview", `Null);
      ("recent_output_preview", `Null);
      ("recent_tool_names", `List []);
      ("latest_tool_names", `List []);
      ("latest_action_source", `Null);
      ("context_ratio", `Null);
    ]

let state_of row =
  Yojson.Safe.Util.(row.json |> member "state" |> to_string)

let lifecycle_of row =
  Yojson.Safe.Util.(row.json |> member "lifecycle" |> to_string)

let status_of row =
  Yojson.Safe.Util.(row.json |> member "status" |> to_string)

let note_of row =
  Yojson.Safe.Util.(row.json |> member "note" |> to_string)

let build_one k =
  List.hd (build_continuity_briefs ~now_ts:1_000_000_000.0 [ k ])

let test_offline_without_signal_is_critical () =
  let row = build_one (keeper ()) in
  check string "lifecycle" "offline" (lifecycle_of row);
  check string "state" "critical" (state_of row)

let test_offline_with_persisted_action_stays_critical () =
  let row =
    build_one
      (keeper ~tool_audit_at:"2001-09-09T01:46:40Z"
         ~turn_count:1  ())
  in
  check string "lifecycle" "offline" (lifecycle_of row);
  check string "state" "critical" (state_of row)

let test_running_flag_does_not_override_offline_status () =
  let row =
    build_one
      (keeper ~keepalive_running:true
         ~tool_audit_at:"2001-09-09T01:46:40Z" ~turn_count:1
          ())
  in
  check string "status" "offline" (status_of row);
  check string "lifecycle" "offline" (lifecycle_of row);
  check string "state" "critical" (state_of row)

let test_reconciled_active_status_is_healthy_active () =
  let row =
    build_one
      (keeper
         ~health:"healthy"
         ~status:"active"
         ~keepalive_running:true
         ~tool_audit_at:"2001-09-09T01:46:40Z"
         ~turn_count:1
         ())
  in
  (* [status] is passed through untouched; the verdicts below come from
     health. Setting the two independently is what shows they are separate. *)
  check string "status" "active" (status_of row);
  check string "lifecycle" "active" (lifecycle_of row);
  check string "state" "healthy" (state_of row)

(* Health, not the status word, decides whether a keeper is stopped: an
   offline reading is critical even when the row's other signals look fresh. *)
let test_offline_health_is_stopped () =
  let row =
    build_one
      (keeper ~health:"offline" ~status:"offline" ~keepalive_running:true
         ~tool_audit_at:"2001-09-09T01:46:40Z" ~turn_count:1 ())
  in
  check string "lifecycle" "offline" (lifecycle_of row);
  check string "state" "critical" (state_of row)

(* A failing keeper carries every activity signal a working one does, so read
   as live it would land in the healthy branch and say "정상 동작 중" beside a
   Failing phase. It is not offline either: its keepalive runs, so its
   lifecycle still follows its own activity. *)
let test_failing_health_is_not_healthy () =
  let row =
    build_one
      (keeper ~health:"failing" ~status:"active" ~keepalive_running:true
         ~tool_audit_at:"2001-09-09T01:46:40Z" ~turn_count:4 ())
  in
  check string "state" "critical" (state_of row);
  check string "note" "오류 발생" (note_of row);
  check string "lifecycle" "active" (lifecycle_of row)

(* The operator pauses a keeper that was running a moment ago. Every activity
   signal still looks fresh, so the healthy branch is the one this row falls
   into unless the pause is classified on its own. Reporting a stopped keeper as
   "정상 동작 중" is a worse signal than the offline misread this PR removed. *)
let test_paused_keeper_with_fresh_activity_is_not_healthy () =
  let row =
    build_one
      (keeper
         ~health:"healthy"
         ~status:"paused"
         ~paused:(`Bool true)
         ~tool_audit_at:"2001-09-09T01:46:40Z"
         ~updated_at:"2001-09-09T01:46:40Z"
         ~turn_count:4
         ())
  in
  check string "status" "paused" (status_of row);
  check string "lifecycle" "idle" (lifecycle_of row);
  check string "state" "warning" (state_of row);
  check string "note" "운영자 일시정지" (note_of row)

(* A pause is not a liveness failure, so it must not inherit the offline
   verdict either. *)
let test_paused_keeper_is_not_critical () =
  let row = build_one (keeper ~paused:(`Bool true) ()) in
  check string "state" "warning" (state_of row);
  check string "note" "운영자 일시정지" (note_of row)

(* Pause is read before health, so a paused keeper never reaches the health
   parse. It must still reject a health this build cannot read: accepting
   producer drift for free on paused keepers would reopen the permissive
   fallback one field over. *)
let test_unknown_status_is_rejected_even_when_paused () =
  check_raises
    "unknown status stays a rejected parse"
    (Invalid_argument
       "dashboard continuity: keeper \"omega\" has unknown health \"suspended\"")
    (fun () ->
      ignore
        (build_one
           (keeper ~health:"suspended" ~paused:(`Bool true) ())))

let test_non_boolean_paused_is_rejected () =
  check_raises
    "paused must be a boolean"
    (Invalid_argument
       "dashboard continuity: keeper paused is not a boolean: \"true\"")
    (fun () ->
      ignore
        (build_one
           (keeper ~health:"healthy" ~status:"active"
              ~paused:(`String "true") ())))

(* The operator snapshot lists a Keeper declared in config that has never
   booted as a declaration row: no diagnostic, so no health. Its presence must
   not take down the briefs of the keepers that do run. Seen live 2026-09-19:
   [imp] had such a row and every execution render raised on its health "". *)
let declared_row =
  Masc.Keeper_declared_roster.to_json
    { Masc.Keeper_declared_roster.name = "imp"
    ; requirements = [ Masc.Keeper_declared_roster.Runtime_check_required ]
    }

let names_of rows =
  List.map
    (fun (row : continuity_context) ->
      Yojson.Safe.Util.(row.json |> member "name" |> to_string))
    rows

let test_declaration_row_has_no_brief () =
  let rows =
    build_continuity_briefs ~now_ts:1_000_000_000.0
      [ declared_row; keeper ~health:"healthy" ~status:"active" () ]
  in
  check (list string) "only the running keeper gets a brief" [ "omega" ]
    (names_of rows)

let test_declaration_row_alone_gives_no_briefs () =
  check (list string) "a declared-only fleet has no continuity" []
    (names_of (build_continuity_briefs ~now_ts:1_000_000_000.0 [ declared_row ]))

let test_non_boolean_declaration_only_is_rejected () =
  let row =
    match keeper ~health:"healthy" () with
    | `Assoc fields -> `Assoc (("declaration_only", `String "yes") :: fields)
    | other -> other
  in
  check_raises
    "declaration_only must be a boolean"
    (Invalid_argument
       "dashboard continuity: keeper \"omega\": keeper row declaration_only \
        is not a boolean: \"yes\"")
    (fun () -> ignore (build_one row))

let () =
  run "dashboard_continuity_briefs"
    [
      ( "liveness from paused and health",
        [
          test_case "no signal -> critical" `Quick
            test_offline_without_signal_is_critical;
          test_case "persisted action without runtime -> critical" `Quick
            test_offline_with_persisted_action_stays_critical;
          test_case "running flag cannot override offline status" `Quick
            test_running_flag_does_not_override_offline_status;
          test_case "reconciled active status -> healthy active" `Quick
            test_reconciled_active_status_is_healthy_active;
          test_case "offline health is stopped" `Quick
            test_offline_health_is_stopped;
          test_case "failing health is not healthy" `Quick
            test_failing_health_is_not_healthy;
          test_case "paused keeper with fresh activity is not healthy" `Quick
            test_paused_keeper_with_fresh_activity_is_not_healthy;
          test_case "paused keeper is not critical" `Quick
            test_paused_keeper_is_not_critical;
          test_case "unknown status is rejected even when paused" `Quick
            test_unknown_status_is_rejected_even_when_paused;
          test_case "non-boolean paused is rejected" `Quick
            test_non_boolean_paused_is_rejected;
        ] );
      ( "declaration rows",
        [
          test_case "declared keeper gets no brief beside a running one" `Quick
            test_declaration_row_has_no_brief;
          test_case "declared-only fleet has no continuity" `Quick
            test_declaration_row_alone_gives_no_briefs;
          test_case "non-boolean declaration_only is rejected" `Quick
            test_non_boolean_declaration_only_is_rejected;
        ] );
    ]
