(** RFC-0357 admission slice: a scheduled-autonomous turn admits on a typed
    stimulus, never on the heartbeat tick itself.

    Pinned here, mapped to the RFC's test list (§7):

    - empty observation + gate on -> [Skip No_actionable_stimulus]
    - each disjunct alone -> [Run]: bootstrap, pending message, pending board
      event, backlog revision edge, due schedule
    - failure-matrix rows at the decision level: a consumed edge
      (version = consumed) stays silent (self-limiting; also the shape of
      "failed turn keeps its in-memory stamp"), an unconsumed edge
      (version > consumed) admits (continuity; also the shape of
      "crash before the durable write re-arms the edge")
    - fast-turn continuity: the edge is a revision compare only — no
      wall-clock input anywhere, so a change landing in the same second as
      the previous admission still re-admits (asserted by using a
      freshly-stamped meta and only bumping the revision)
    - meta JSON: [last_consumed_backlog_revision] round-trips; an ABSENT
      field decodes as genesis 0 (pre-RFC metas must not invalidate); a
      PRESENT malformed or negative value fails the decode (fail-closed).

    Not covered here (stated, not hidden): the in-memory stamp write in
    [keeper_heartbeat_loop] and the [update_metrics_from_result]
    pass-through are integration surfaces exercised by the heartbeat suites;
    building a [Keeper_agent_run.run_result] fixture is out of scope for
    this unit file. *)

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
let bootstrapped_meta ?(last_consumed = 1) () =
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
   consumed ([backlog_updated_since_last_scheduled_autonomous = false]). *)
let base_obs : WO.world_observation =
  { pending_messages = []
  ; pending_board_events = []
  ; idle_seconds = 0
  ; active_goals = []
  ; unclaimed_task_count = 0
  ; claimable_task_count = 0
  ; failed_task_count = 0
  ; scheduled_automation = WO.empty_scheduled_automation_observation
  ; backlog_updated_since_last_scheduled_autonomous = false
  ; backlog_revision = Some 1
  ; running_keeper_fiber_count = 1
  ; connected_surfaces = []
  ; connected_surface_failures = []
  ; own_recent_board_posts = []
  }
;;

let backlog_edge_obs =
  { base_obs with
    backlog_updated_since_last_scheduled_autonomous = true
  ; backlog_revision = Some 2
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
  check bool "scheduled channel" true (is_scheduled d)
;;

let test_pending_board_event_admits_scheduled_when_reactive_off () =
  with_flag "MASC_KEEPER_REACTIVE_ENABLED" "false" @@ fun () ->
  let d = decide ~meta:(bootstrapped_meta ()) board_event_obs in
  check bool "pending board event admits" true d.WO.should_run;
  check bool "scheduled channel" true (is_scheduled d)
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

(* ==== §3.2: the edge is a revision compare, no clock anywhere ==== *)

let edge ~last_consumed ~version =
  let meta = bootstrapped_meta ~last_consumed () in
  let backlog : Masc_domain.backlog =
    { tasks = []; last_updated = "not-a-timestamp"; version }
  in
  Inputs.backlog_updated_since_last_scheduled_autonomous ~meta ~backlog
;;

let test_edge_is_pure_revision_compare () =
  (* genesis: never consumed, any live backlog is one pending edge *)
  check bool "0 < 1 edges" true (edge ~last_consumed:0 ~version:1);
  (* consumed exactly: silent *)
  check bool "5 = 5 silent" false (edge ~last_consumed:5 ~version:5);
  (* fast-turn continuity: a commit in the same wall-clock instant as the
     stamp still edges, because only the revision moved. [last_updated] is
     deliberately unparseable — proof the clock and the ISO field are not
     inputs (the old implementation returned [false] forever on a parse
     failure). *)
  check bool "5 < 6 edges" true (edge ~last_consumed:5 ~version:6);
  check bool "6 = 6 silent after stamp" false (edge ~last_consumed:6 ~version:6);
  check bool "6 < 7 re-edges" true (edge ~last_consumed:6 ~version:7)
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
      decoded.runtime.proactive_rt.last_consumed_backlog_revision
;;

let test_meta_json_absent_is_genesis () =
  let meta = bootstrapped_meta ~last_consumed:42 () in
  let json =
    json_with_field meta ~f:(fun fields ->
      List.filter
        (fun (key, _) -> not (String.equal key "last_consumed_backlog_revision"))
        fields)
  in
  match Masc.Keeper_meta_json_parse.meta_of_json json with
  | Error e -> Alcotest.fail ("absent field must decode (pre-RFC meta): " ^ e)
  | Ok decoded ->
    check int "absent decodes as genesis 0" 0
      decoded.runtime.proactive_rt.last_consumed_backlog_revision
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
  | Error _ -> ()
;;

let () =
  Alcotest.run
    "Keeper Admission Edge"
    [ ( "admission"
      , [ test_case "empty observation skips" `Quick test_empty_observation_skips
        ; test_case "bootstrap admits" `Quick test_bootstrap_admits
        ; test_case "backlog edge admits" `Quick test_backlog_edge_admits
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
        ] )
    ; ( "edge_compare"
      , [ test_case "pure revision compare" `Quick test_edge_is_pure_revision_compare ] )
    ; ( "meta_json"
      , [ test_case "roundtrip" `Quick test_meta_json_roundtrip
        ; test_case "absent is genesis" `Quick test_meta_json_absent_is_genesis
        ; test_case "malformed fails closed" `Quick test_meta_json_malformed_fails_closed
        ] )
    ]
;;
