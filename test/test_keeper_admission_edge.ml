(** RFC-0357 admission slice: a scheduled-autonomous turn admits on a typed
    stimulus, never on the heartbeat tick itself.

    Pinned here, mapped to the RFC's test list (§7):

    - empty observation + gate on -> [Skip No_actionable_stimulus]
    - each disjunct alone -> [Run]: bootstrap, pending message, pending board
      event, backlog revision edge, due schedule — each carrying its own
      typed reason (the reason list is the predicate; nameless admission is
      unrepresentable)
    - a blind observation (failed backlog read, revision [None]) skips as
      [Backlog_unreadable], never as [No_actionable_stimulus], and does not
      silence the other disjuncts
    - failure-matrix rows at the decision level: a consumed edge
      (version = consumed) stays silent (self-limiting; also the shape of
      "failed turn keeps its in-memory stamp"), an unconsumed edge
      (version > consumed) admits (continuity; also the shape of
      "crash before the durable write re-arms the edge")
    - fast-turn continuity: the revision/projection pair has no wall-clock
      input, so a relevant change landing in the same second still re-admits
    - meta JSON: both consumed fields round-trip; every current field is
      required, and malformed or negative values fail closed.

    The scheduled-admission stamp helper is exercised directly here; the
    post-turn pass-through and CAS merge are covered by their focused suites. *)

open Alcotest
module WO = Masc.Keeper_world_observation
module Inputs = Masc.Keeper_world_observation_inputs

let make_meta name =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("agent_name", `String (Masc.Keeper_identity.keeper_agent_name name))
      ; ("trace_id", `String ("trace-admission-" ^ name))
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)
;;

(* A keeper that has already bootstrapped (a scheduled turn ran before) and
   whose consumption clock sits at [last_consumed]. *)
let projection_a = String.make 64 'a'
let projection_b = String.make 64 'b'

let bootstrapped_meta
      ?(last_consumed = 1)
      ?(last_projection = projection_a)
      ()
  =
  let meta = make_meta "admission" in
  let now = Time_compat.now () in
  { meta with
    autoboot_enabled = true
  ; proactive = { enabled = true }
  ; runtime =
      { meta.runtime with
        proactive_rt =
          { meta.runtime.proactive_rt with
            last_ts = now -. 120.0
          ; last_consumed_backlog_revision = last_consumed
          ; last_consumed_backlog_projection_sha256 = last_projection
          }
      }
  }
;;

(* Never ran a scheduled turn: [last_ts = 0.0] is the bootstrap marker. *)
let never_started_meta () =
  let meta = make_meta "admission-bootstrap" in
  { meta with
    autoboot_enabled = true
  ; proactive = { enabled = true }
  ; runtime =
      { meta.runtime with
        proactive_rt = { meta.runtime.proactive_rt with last_ts = 0.0 }
      }
  }
;;

(* No stimulus anywhere; the backlog exists at revision 1 and has been
   consumed. *)
let base_obs : WO.world_observation =
  { pending_messages = []
  ; pending_board_events = []
  ; idle_seconds = 0
  ; active_goals = []
  ; unclaimed_task_count = 0
  ; claimable_task_count = 0
  ; failed_task_count = 0
  ; scheduled_automation = WO.empty_scheduled_automation_observation
  ; backlog_edge =
      Inputs.Observed_backlog
        { revision = 1
        ; projection_sha256 = projection_a
        ; updated_since_last_scheduled_autonomous = false
        }
  ; running_keeper_fiber_count = 1
  ; connected_surfaces = []
  ; connected_surface_failures = []
  ; own_recent_board_posts = []
  }
;;

let backlog_edge_obs =
  { base_obs with
    backlog_edge =
      Inputs.Observed_backlog
        { revision = 2
        ; projection_sha256 = projection_b
        ; updated_since_last_scheduled_autonomous = true
        }
  ; claimable_task_count = 1
  ; unclaimed_task_count = 1
  }
;;

let due_schedule_obs =
  { base_obs with
    scheduled_automation =
      { WO.empty_scheduled_automation_observation with
        active_count = 1
      ; due_ready_count = 1
      }
  }
;;

let mention_obs =
  { base_obs with
    pending_messages =
      [ { Masc.Keeper_world_observation_message_scope.message_id = "mention-1"
        ; speaker = "peer"
        ; content = "ping"
        ; kind = Mention
        }
      ]
  }
;;

let board_event_obs =
  { base_obs with
    pending_board_events =
      [ { WO.event_kind = WO.Board_post_created
        ; post_id = "post-1"
        ; author = "peer"
        ; title = "note"
        ; preview = "note body"
        ; hearth = None
        ; post_kind = Masc.Board.Human_post
        ; updated_at = 0.0
        ; explicit_mention = false
        ; matched_targets = []
        ; self_commented = false
        ; new_external_since = 0
        ; latest_external_author = None
        ; latest_external_preview = None
        }
      ]
  }
;;

let with_flag name value f =
  Config_boot_overrides.reset_for_tests ();
  Config_boot_overrides.set name value;
  Fun.protect ~finally:(fun () -> Config_boot_overrides.reset_for_tests ()) f
;;

let without_overrides f =
  Config_boot_overrides.reset_for_tests ();
  Fun.protect ~finally:(fun () -> Config_boot_overrides.reset_for_tests ()) f
;;

let decide ~meta obs = WO.keeper_cycle_decision ~reactive_wake:false ~meta obs

let skip_reasons d =
  match d.WO.verdict with
  | WO.Skip { reasons = first, rest } -> first :: rest
  | WO.Run _ -> []
;;

let run_reasons d =
  match d.WO.verdict with
  | WO.Run { reasons = first, rest } -> first :: rest
  | WO.Skip _ -> []
;;

let is_scheduled d =
  match d.WO.channel with
  | WO.Scheduled_autonomous -> true
  | WO.Reactive -> false
;;

(* ==== §3.1: empty observation is a typed skip, not a turn ==== *)

let test_empty_observation_skips () =
  without_overrides @@ fun () ->
  let d = decide ~meta:(bootstrapped_meta ()) base_obs in
  check bool "no stimulus -> no turn" false d.WO.should_run;
  check bool "scheduled channel" true (is_scheduled d);
  check bool "skip reason is no_actionable_stimulus" true
    (List.exists (( = ) WO.No_actionable_stimulus) (skip_reasons d))
;;

(* ==== §3.1: each disjunct alone admits ==== *)

let test_bootstrap_admits () =
  without_overrides @@ fun () ->
  let d = decide ~meta:(never_started_meta ()) base_obs in
  check bool "bootstrap admits" true d.WO.should_run;
  check bool "scheduled channel" true (is_scheduled d);
  check bool "never_started in reasons" true
    (List.exists (( = ) WO.Never_started) (run_reasons d))
;;

let test_backlog_edge_admits () =
  without_overrides @@ fun () ->
  let d = decide ~meta:(bootstrapped_meta ()) backlog_edge_obs in
  check bool "backlog edge admits" true d.WO.should_run;
  check bool "scheduled channel" true (is_scheduled d);
  check bool "task_backlog observation attached" true
    (List.exists
       (function
         | WO.Task_backlog _ -> true
         | _ -> false)
       (run_reasons d))
;;

let test_external_wake_does_not_admit_backlog_only () =
  without_overrides @@ fun () ->
  let d =
    WO.keeper_cycle_decision
      ~reactive_wake:true
      ~meta:(bootstrapped_meta ())
      backlog_edge_obs
  in
  check bool "broadcast wake does not fan out backlog turn" false d.WO.should_run
;;

let test_due_schedule_admits () =
  without_overrides @@ fun () ->
  let d = decide ~meta:(bootstrapped_meta ()) due_schedule_obs in
  check bool "due schedule admits" true d.WO.should_run;
  check bool "scheduled_automation_due in reasons" true
    (List.exists (( = ) WO.Scheduled_automation_due) (run_reasons d))
;;

(* A pending message normally opens a REACTIVE turn. With the reactive gate
   off it must still admit the scheduled channel (RFC-0297 starvation rule +
   RFC-0357 §3.1 message disjunct) — a suppressed lane must not silence a
   typed stimulus. *)
let test_pending_message_admits_scheduled_when_reactive_off () =
  with_flag "MASC_KEEPER_REACTIVE_ENABLED" "false" @@ fun () ->
  let d = decide ~meta:(bootstrapped_meta ()) mention_obs in
  check bool "pending message admits" true d.WO.should_run;
  check bool "scheduled channel" true (is_scheduled d);
  check bool "scope_message_pending in reasons" true
    (List.exists (( = ) WO.Scope_message_pending) (run_reasons d))
;;

let test_pending_board_event_admits_scheduled_when_reactive_off () =
  with_flag "MASC_KEEPER_REACTIVE_ENABLED" "false" @@ fun () ->
  let d = decide ~meta:(bootstrapped_meta ()) board_event_obs in
  check bool "pending board event admits" true d.WO.should_run;
  check bool "scheduled channel" true (is_scheduled d);
  check bool "board_event_pending in reasons" true
    (List.exists (( = ) WO.Board_event_pending) (run_reasons d))
;;

(* ==== §3.3 matrix at the decision level ==== *)

(* Self-limiting: a consumed edge stays silent. This is also the shape of
   matrix row 4 — after a failed turn the in-memory stamp equals the
   observed revision, so the same edge does not re-admit every heartbeat. *)
let test_consumed_edge_stays_silent () =
  without_overrides @@ fun () ->
  let d = decide ~meta:(bootstrapped_meta ~last_consumed:2 ()) base_obs in
  check bool "consumed edge -> silent" false d.WO.should_run;
  check bool "skip reason is no_actionable_stimulus" true
    (List.exists (( = ) WO.No_actionable_stimulus) (skip_reasons d))
;;

let test_scheduled_admission_records_exact_pair () =
  let before = bootstrapped_meta () in
  let after = WO.record_scheduled_backlog_consumption ~meta:before backlog_edge_obs in
  check int "observed revision is recorded" 2
    after.runtime.proactive_rt.last_consumed_backlog_revision;
  check string "projection stays paired with revision" projection_b
    after.runtime.proactive_rt.last_consumed_backlog_projection_sha256
;;

let test_unreadable_admission_does_not_move_pair () =
  let before = bootstrapped_meta () in
  let unreadable =
    { base_obs with backlog_edge = Inputs.Backlog_read_unavailable "test failure" }
  in
  let after = WO.record_scheduled_backlog_consumption ~meta:before unreadable in
  check int "revision stays put" 1
    after.runtime.proactive_rt.last_consumed_backlog_revision;
  check string "projection stays put" projection_a
    after.runtime.proactive_rt.last_consumed_backlog_projection_sha256
;;

(* ==== read failure is not designed silence ==== *)

(* [Backlog_read_unavailable] models a failed backlog read. With no other stimulus the
   skip must say so — recording it as [No_actionable_stimulus] would present
   a blind observation as a considered "nothing to do". *)
let test_unreadable_backlog_skips_as_unreadable () =
  without_overrides @@ fun () ->
  let d =
    decide
      ~meta:(bootstrapped_meta ())
      { base_obs with backlog_edge = Inputs.Backlog_read_unavailable "test failure" }
  in
  check bool "no turn on a blind observation" false d.WO.should_run;
  check bool "skip reason is backlog_unreadable" true
    (List.exists (( = ) WO.Backlog_unreadable) (skip_reasons d));
  check bool "not recorded as designed silence" false
    (List.exists (( = ) WO.No_actionable_stimulus) (skip_reasons d))
;;

(* A failed backlog read must not silence the other disjuncts: a pending
   message is a complete stimulus on its own. *)
let test_unreadable_backlog_does_not_silence_other_stimuli () =
  with_flag "MASC_KEEPER_REACTIVE_ENABLED" "false" @@ fun () ->
  let d =
    decide
      ~meta:(bootstrapped_meta ())
      { mention_obs with backlog_edge = Inputs.Backlog_read_unavailable "test failure" }
  in
  check bool "message still admits" true d.WO.should_run;
  check bool "scope_message_pending in reasons" true
    (List.exists (( = ) WO.Scope_message_pending) (run_reasons d))
;;

let test_recovery_backlog_is_not_authoritative () =
  without_overrides @@ fun () ->
  let recovery =
    { Workspace.primary_error = "primary backlog is corrupt"
    ; recovery_path = "/workspace/tasks/backlog.json.last-good"
    }
  in
  let d =
    decide
      ~meta:(bootstrapped_meta ())
      { base_obs with
        backlog_edge =
          Inputs.Recovery_backlog
            { revision = 2
            ; projection_sha256 = projection_b
            ; recovery
            }
      }
  in
  check bool "recovery snapshot does not admit a scheduled edge" false d.WO.should_run;
  check bool "recovery snapshot is not designed silence" true
    (List.exists (( = ) WO.Backlog_unreadable) (skip_reasons d));
  let rendered =
    Inputs.backlog_edge_observation_to_string
      (Inputs.Recovery_backlog
         { revision = 2; projection_sha256 = projection_b; recovery })
  in
  check bool "recovery provenance stays visible" true
    (String_util.contains_substring rendered "recovery(revision=2");
  check bool "recovery path is not model-facing" false
    (String_util.contains_substring rendered recovery.recovery_path);
  check bool "primary parser error is not model-facing" false
    (String_util.contains_substring rendered recovery.primary_error)
;;

let test_unavailable_backlog_error_is_not_model_facing () =
  let raw_error = "hostile parser text from backlog" in
  let rendered =
    Inputs.backlog_edge_observation_to_string
      (Inputs.Backlog_read_unavailable raw_error)
  in
  check string "typed state remains visible" "unavailable" rendered;
  check bool "raw parser text stays out of prompt" false
    (String_util.contains_substring rendered raw_error)
;;

(* ==== §3.2: the edge is a revision compare, no clock anywhere ==== *)

let edge ~last_consumed ~last_projection ~version ~projection =
  let meta = bootstrapped_meta ~last_consumed ~last_projection () in
  let backlog : Masc_domain.backlog =
    { tasks = []; last_updated = "not-a-timestamp"; version }
  in
  Inputs.backlog_updated_since_last_scheduled_autonomous
    ~meta
    ~backlog
    ~projection_sha256:projection
;;

let test_edge_is_pure_revision_compare () =
  (* genesis: never consumed, any live backlog is one pending edge *)
  check bool "0 < 1 and changed projection edges" true
    (edge
       ~last_consumed:0
       ~last_projection:""
       ~version:1
       ~projection:projection_a);
  (* consumed exactly: silent *)
  check bool "5 = 5 silent" false
    (edge
       ~last_consumed:5
       ~last_projection:projection_a
       ~version:5
       ~projection:projection_b);
  check bool "new revision with unchanged projection is silent" false
    (edge
       ~last_consumed:5
       ~last_projection:projection_a
       ~version:6
       ~projection:projection_a);
  (* fast-turn continuity: a commit in the same wall-clock instant as the
     stamp still edges, because only the revision moved. [last_updated] is
     deliberately unparseable — proof the clock and the ISO field are not
     inputs (the old implementation returned [false] forever on a parse
     failure). *)
  check bool "5 < 6 edges" true
    (edge
       ~last_consumed:5
       ~last_projection:projection_a
       ~version:6
       ~projection:projection_b);
  check bool "6 = 6 silent after stamp" false
    (edge
       ~last_consumed:6
       ~last_projection:projection_b
       ~version:6
       ~projection:projection_b);
  check bool "6 < 7 re-edges on another projection" true
    (edge
       ~last_consumed:6
       ~last_projection:projection_b
       ~version:7
       ~projection:projection_a)
;;

let make_todo ~id ~created_by : Masc_domain.task =
  { id
  ; title = "Task " ^ id
  ; description = ""
  ; task_status = Masc_domain.Todo
  ; priority = 3
  ; files = []
  ; created_at = "2026-08-03T00:00:00Z"
  ; created_by
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }
;;

let test_self_authored_todo_does_not_change_projection () =
  let meta = bootstrapped_meta () in
  let empty = Inputs.relevant_backlog_projection_sha256 ~meta [] in
  let self =
    Inputs.relevant_backlog_projection_sha256
      ~meta
      [ make_todo ~id:"self" ~created_by:(Some meta.name) ]
  in
  let peer =
    Inputs.relevant_backlog_projection_sha256
      ~meta
      [ make_todo ~id:"peer" ~created_by:(Some "peer") ]
  in
  check string "self-authored Todo is outside projection" empty self;
  check bool "peer Todo changes projection" true (not (String.equal empty peer))
;;

(* ==== meta JSON: durable consumption clock ==== *)

let json_with_field meta ~f =
  match Masc.Keeper_meta_json.meta_to_json meta with
  | `Assoc fields -> `Assoc (f fields)
  | other -> Alcotest.failf "meta_to_json not an object: %s" (Yojson.Safe.to_string other)
;;

let test_meta_json_roundtrip () =
  let meta = bootstrapped_meta ~last_consumed:42 () in
  let json = Masc.Keeper_meta_json.meta_to_json meta in
  match Masc.Keeper_meta_json_parse.meta_of_json json with
  | Error e -> Alcotest.fail ("roundtrip decode failed: " ^ e)
  | Ok decoded ->
    check int "consumption clock survives the roundtrip" 42
      decoded.runtime.proactive_rt.last_consumed_backlog_revision;
    check string "projection survives the roundtrip" projection_a
      decoded.runtime.proactive_rt.last_consumed_backlog_projection_sha256
;;

let test_meta_json_absent_pair_fails_closed () =
  let meta = bootstrapped_meta ~last_consumed:42 () in
  let remove field fields =
    List.filter (fun (key, _) -> not (String.equal key field)) fields
  in
  List.iter
    (fun field ->
       match Masc.Keeper_meta_json_parse.meta_of_json (json_with_field meta ~f:(remove field)) with
       | Error _ -> ()
       | Ok _ -> Alcotest.failf "missing current field %s must fail the decode" field)
    [ "last_consumed_backlog_revision"; "last_consumed_backlog_projection_sha256" ]
;;

let test_meta_json_missing_required_field_fails () =
  let meta = bootstrapped_meta ~last_consumed:42 () in
  let json =
    json_with_field meta ~f:(fun fields ->
      List.filter (fun (key, _) -> not (String.equal key "total_turns")) fields)
  in
  match Masc.Keeper_meta_json_parse.meta_of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "missing non-genesis field must fail the decode"
;;

let test_meta_json_malformed_fails_closed () =
  let meta = bootstrapped_meta ~last_consumed:42 () in
  let replace value fields =
    List.map
      (fun (key, v) ->
         if String.equal key "last_consumed_backlog_revision" then key, value else key, v)
      fields
  in
  (match
     Masc.Keeper_meta_json_parse.meta_of_json
       (json_with_field meta ~f:(replace (`String "42")))
   with
   | Ok _ -> Alcotest.fail "string revision must fail the decode"
   | Error _ -> ());
  match
    Masc.Keeper_meta_json_parse.meta_of_json
      (json_with_field meta ~f:(replace (`Int (-3))))
  with
  | Ok _ -> Alcotest.fail "negative revision must fail the decode"
  | Error _ -> ();
  let malformed_projection fields =
    List.map
      (fun (key, value) ->
         if String.equal key "last_consumed_backlog_projection_sha256"
         then key, `String "not-a-sha256"
         else key, value)
      fields
  in
  match
    Masc.Keeper_meta_json_parse.meta_of_json
      (json_with_field meta ~f:malformed_projection)
  with
  | Ok _ -> Alcotest.fail "malformed projection digest must fail the decode"
  | Error _ -> ();
  let inconsistent_genesis fields =
    List.map
      (fun (key, value) ->
         if String.equal key "last_consumed_backlog_revision"
         then key, `Int 0
         else if String.equal key "last_consumed_backlog_projection_sha256"
         then key, `String projection_a
         else key, value)
      fields
  in
  (match
     Masc.Keeper_meta_json_parse.meta_of_json
       (json_with_field meta ~f:inconsistent_genesis)
   with
   | Ok _ -> Alcotest.fail "genesis revision must not carry a non-empty projection"
   | Error _ -> ());
  let inconsistent_consumed fields =
    List.map
      (fun (key, value) ->
         if String.equal key "last_consumed_backlog_revision"
         then key, `Int 42
         else if String.equal key "last_consumed_backlog_projection_sha256"
         then key, `String ""
         else key, value)
      fields
  in
  match
    Masc.Keeper_meta_json_parse.meta_of_json
      (json_with_field meta ~f:inconsistent_consumed)
  with
  | Ok _ -> Alcotest.fail "consumed revision must carry its projection"
  | Error _ -> ()
;;

let () =
  Alcotest.run
    "Keeper Admission Edge"
    [ ( "admission"
      , [ test_case "empty observation skips" `Quick test_empty_observation_skips
        ; test_case "bootstrap admits" `Quick test_bootstrap_admits
        ; test_case "backlog edge admits" `Quick test_backlog_edge_admits
        ; test_case
            "external wake suppresses backlog-only admission"
            `Quick
            test_external_wake_does_not_admit_backlog_only
        ; test_case "due schedule admits" `Quick test_due_schedule_admits
        ; test_case
            "pending message admits scheduled when reactive off"
            `Quick
            test_pending_message_admits_scheduled_when_reactive_off
        ; test_case
            "pending board event admits scheduled when reactive off"
            `Quick
            test_pending_board_event_admits_scheduled_when_reactive_off
        ; test_case "consumed edge stays silent" `Quick test_consumed_edge_stays_silent
        ; test_case
            "scheduled admission records exact pair"
            `Quick
            test_scheduled_admission_records_exact_pair
        ; test_case
            "unreadable admission does not move pair"
            `Quick
            test_unreadable_admission_does_not_move_pair
        ; test_case
            "unreadable backlog skips as unreadable"
            `Quick
            test_unreadable_backlog_skips_as_unreadable
        ; test_case
            "unreadable backlog does not silence other stimuli"
            `Quick
            test_unreadable_backlog_does_not_silence_other_stimuli
        ; test_case
            "recovery backlog is not authoritative"
            `Quick
            test_recovery_backlog_is_not_authoritative
        ; test_case
            "unavailable backlog error is not model-facing"
            `Quick
            test_unavailable_backlog_error_is_not_model_facing
        ] )
    ; ( "edge_compare"
      , [ test_case "revision and projection pair" `Quick test_edge_is_pure_revision_compare
        ; test_case
            "self-authored Todo does not change projection"
            `Quick
            test_self_authored_todo_does_not_change_projection
        ] )
    ; ( "meta_json"
      , [ test_case "roundtrip" `Quick test_meta_json_roundtrip
        ; test_case
            "absent pair fails closed"
            `Quick
            test_meta_json_absent_pair_fails_closed
        ; test_case
            "missing required field fails"
            `Quick
            test_meta_json_missing_required_field_fails
        ; test_case "malformed fails closed" `Quick test_meta_json_malformed_fails_closed
        ] )
    ]
;;
