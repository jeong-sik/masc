open Alcotest

module R = Masc_mcp.Keeper_registry
module Keeper_types = Masc_mcp.Keeper_types
module KSM = Masc_mcp.Keeper_state_machine
module Audit = Masc_mcp.Keeper_transition_audit
module Meas = Masc_mcp.Keeper_measurement
module Json = Yojson.Safe.Util

let bp = "/tmp/test"

let make_meta name =
  let json = `Assoc [
    ("name", `String name);
    ("agent_name", `String ("agent-" ^ name));
    ("trace_id", `String ("trace-test-" ^ name));
    ("goal", `String "test goal");
  ] in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

(** Wrap each test body in Eio_main.run for Eio.Mutex support. *)
let eio_test name fn =
  test_case name `Quick (fun () -> Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env); fn ())

let sse_payload_json (event : string) : Yojson.Safe.t =
  let prefix = "data: " in
  let prefix_len = String.length prefix in
  let rec find_data_line = function
    | [] -> fail "expected SSE data line"
    | line :: rest ->
        if String.length line >= prefix_len
           && String.sub line 0 prefix_len = prefix
        then
          Yojson.Safe.from_string
            (String.sub line prefix_len (String.length line - prefix_len))
        else
          find_data_line rest
  in
  find_data_line (String.split_on_char '\n' event)

let sse_events_of_type event_type received_events =
  received_events
  |> List.rev
  |> List.filter_map (fun raw_event ->
         let payload = sse_payload_json raw_event in
         match Json.member "type" payload |> Json.to_string_option with
         | Some kind when kind = event_type -> Some payload
         | _ -> None)

(* ── Basic registry operations ─────────────────────────── *)

let test_register_and_get () =
  R.clear ();
  let meta = make_meta "k1" in
  let entry = R.register ~base_path:bp "k1" meta in
  check string "name" "k1" entry.name;
  check string "state" "running" (KSM.phase_to_string entry.phase);
  match R.get ~base_path:bp "k1" with
  | None -> fail "expected entry for k1"
  | Some e -> check string "get name" "k1" e.name

let test_register_offline_and_start () =
  R.clear ();
  let entry = R.register_offline ~base_path:bp "k1-offline" (make_meta "k1-offline") in
  check string "offline phase" "offline" (KSM.phase_to_string entry.phase);
  check bool "not running yet" false (R.is_running ~base_path:bp "k1-offline");
  ignore (R.dispatch_event ~base_path:bp "k1-offline" KSM.Fiber_started);
  match R.get ~base_path:bp "k1-offline" with
  | None -> fail "expected k1-offline"
  | Some e ->
      check string "running after Fiber_started" "running"
        (KSM.phase_to_string e.phase);
      check bool "running after Fiber_started" true
        (R.is_running ~base_path:bp "k1-offline")

let test_register_restarting_and_start () =
  R.clear ();
  let entry = R.register_restarting ~base_path:bp "k1-restart" (make_meta "k1-restart") in
  check string "restarting phase" "restarting" (KSM.phase_to_string entry.phase);
  check bool "not running yet" false (R.is_running ~base_path:bp "k1-restart");
  ignore (R.dispatch_event ~base_path:bp "k1-restart" KSM.Fiber_started);
  match R.get ~base_path:bp "k1-restart" with
  | None -> fail "expected k1-restart"
  | Some e ->
      check string "running after Fiber_started" "running"
        (KSM.phase_to_string e.phase);
      check bool "running after Fiber_started" true
        (R.is_running ~base_path:bp "k1-restart")

let test_dispatch_event_with_audit_preserves_snapshot () =
  R.clear ();
  let keeper_name = "k-audit-guardrail" in
  ignore (R.register ~base_path:bp keeper_name (make_meta keeper_name));
  let measurement : Meas.measurement_snapshot =
    { snapshot_id = "msnap-test"
    ; keeper_name
    ; generation = 1
    ; timestamp = 1000.0
    ; thresholds =
        { compaction_ratio_gate = 0.5
        ; compaction_message_gate = 100
        ; compaction_token_gate = 1000
        ; compaction_cooldown_sec = 60
        ; handoff_threshold = 0.85
        ; handoff_cooldown_sec = 300
        ; auto_handoff_enabled = true
        ; reflect_repetition_threshold = 0.7
        ; plan_goal_alignment_threshold = 0.3
        ; plan_response_alignment_threshold = 0.3
        ; guardrail_repetition_threshold = 0.9
        ; guardrail_goal_alignment_threshold = 0.2
        ; guardrail_response_alignment_threshold = 0.2
        ; guardrail_context_threshold = 0.8
        ; max_consecutive_hb_failures = 5
        ; max_consecutive_turn_failures = 3
        ; model_ratio_multiplier = 1.0
        ; model_handoff_multiplier = 1.0
        }
    ; context =
        { context_ratio = 0.85
        ; message_count = 120
        ; token_count = 2000
        ; max_tokens = 10000
        }
    ; similarity =
        { repetition_risk = 0.95
        ; goal_alignment = 0.1
        ; response_alignment = 0.1
        }
    ; timing =
        { now_ts = 1000.0
        ; idle_seconds = 0
        ; since_last_compaction_sec = 120.0
        ; since_last_handoff_sec = 120.0
        ; proactive_warmup_elapsed = true
        }
    ; failures =
        { consecutive_hb_failures = 0
        ; consecutive_turn_failures = 0
        }
    }
  in
  let context_event =
    KSM.Context_measured {
      context_ratio = measurement.context.context_ratio;
      message_count = measurement.context.message_count;
      token_count = measurement.context.token_count;
      auto_rules =
        { reflect = true
        ; plan = true
        ; compact = true
        ; handoff = true
        ; guardrail_stop = true
        ; guardrail_reason = Some "guardrail fired"
        ; goal_drift = 0.9
        };
    }
  in
  let events =
    [ KSM.Guardrail_stop { reason = "guardrail fired" }
    ; context_event
    ]
  in
  ignore (R.dispatch_event_with_audit
    ~base_path:bp
    ~snapshot:measurement
    ~events_fired:events
    ~selected_event:(List.hd events)
    keeper_name
    context_event);
  match Audit.recent_transitions ~keeper_name ~limit:1 with
  | [] -> fail "expected transition audit"
  | [ audit ] ->
      check string "selected event"
        "guardrail_stop(guardrail fired)"
        (KSM.event_to_string audit.selected_event);
      check int "events_fired preserved" 2 (List.length audit.events_fired);
      (match audit.snapshot with
       | None -> fail "expected measurement snapshot"
       | Some snapshot ->
           check string "snapshot id" "msnap-test" snapshot.snapshot_id);
      check string "new phase" "failing" (KSM.phase_to_string audit.new_phase)
  | _ -> fail "expected exactly one transition audit entry"

let test_unregister () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k2" (make_meta "k2") in
  check bool "exists before" true (Option.is_some (R.get ~base_path:bp "k2"));
  R.unregister ~base_path:bp "k2";
  check bool "gone after" true (Option.is_none (R.get ~base_path:bp "k2"))

let test_all () =
  R.clear ();
  let _e1 = R.register ~base_path:bp "a" (make_meta "a") in
  let _e2 = R.register ~base_path:bp "b" (make_meta "b") in
  let _e3 = R.register ~base_path:bp "c" (make_meta "c") in
  let all = R.all () in
  check int "count" 3 (List.length all)

let test_update_meta () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k3" (make_meta "k3") in
  let updated_meta = { (make_meta "k3") with goal = "updated goal" } in
  R.update_meta ~base_path:bp "k3" updated_meta;
  match R.get ~base_path:bp "k3" with
  | None -> fail "expected k3"
  | Some e -> check string "goal updated" "updated goal" e.meta.goal

let test_set_state () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k4" (make_meta "k4") in
  check bool "running" true (R.is_running ~base_path:bp "k4");
  ignore (R.dispatch_event ~base_path:bp "k4" KSM.Operator_pause);
  check bool "not running after pause" false (R.is_running ~base_path:bp "k4");
  match R.get ~base_path:bp "k4" with
  | None -> fail "expected k4"
  | Some e -> check string "state" "paused" (KSM.phase_to_string e.phase)

let test_dispatch_event_emits_phase_sse () =
  R.clear ();
  let received_events = ref [] in
  Masc_mcp.Sse.subscribe_external ~id:"keeper-registry-phase"
    ~callback:(fun event -> received_events := event :: !received_events) ();
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Sse.unsubscribe_external "keeper-registry-phase")
    (fun () ->
      ignore (R.register ~base_path:bp "k4-lifecycle" (make_meta "k4-lifecycle"));
      ignore (R.dispatch_event ~base_path:bp "k4-lifecycle" KSM.Operator_pause);
      match sse_events_of_type "keeper_phase_changed" !received_events with
      | [] -> fail "expected keeper_phase_changed SSE event"
      | payload :: _ ->
          check string "phase type" "keeper_phase_changed"
            (Json.member "type" payload |> Json.to_string);
          check string "keeper name" "k4-lifecycle"
            (Json.member "name" payload |> Json.to_string);
          check string "prev phase" "running"
            (Json.member "prev_phase" payload |> Json.to_string);
          check string "new phase" "paused"
            (Json.member "new_phase" payload |> Json.to_string);
          check string "event" "operator_pause"
            (Json.member "event" payload |> Json.to_string))

let test_extended_states () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k4x" (make_meta "k4x") in
  ignore (R.dispatch_event ~base_path:bp "k4x"
    (KSM.Fiber_terminated { outcome = "test" }));
  (match R.get ~base_path:bp "k4x" with
   | None -> fail "expected k4x"
   | Some e -> check string "crashed string" "crashed" (KSM.phase_to_string e.phase));
  R.mark_dead ~base_path:bp "k4x" ~at:123.0;
  match R.get ~base_path:bp "k4x" with
  | None -> fail "expected k4x"
  | Some e ->
      check string "dead string" "dead" (KSM.phase_to_string e.phase);
      check (option (float 0.01)) "dead_since set" (Some 123.0) e.dead_since_ts

let test_stopped_entry_action_is_observability_only () =
  R.clear ();
  let received_events = ref [] in
  Masc_mcp.Sse.subscribe_external ~id:"keeper-registry-stopped"
    ~callback:(fun event -> received_events := event :: !received_events) ();
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Sse.unsubscribe_external "keeper-registry-stopped")
    (fun () ->
      ignore (R.register ~base_path:bp "k4-stop" (make_meta "k4-stop"));
      ignore (R.dispatch_event ~base_path:bp "k4-stop" KSM.Stop_requested);
      ignore (R.dispatch_event ~base_path:bp "k4-stop" KSM.Drain_complete);
      match R.get ~base_path:bp "k4-stop" with
      | None -> fail "expected stopped keeper to remain registered"
      | Some entry ->
          check string "stopped phase" "stopped"
            (KSM.phase_to_string entry.phase);
          let stopped_payload =
            sse_events_of_type "keeper_phase_changed" !received_events
            |> List.find_opt (fun payload ->
                   Json.member "new_phase" payload |> Json.to_string = "stopped")
          in
          (match stopped_payload with
           | None -> fail "expected stopped phase SSE event"
           | Some payload ->
               check string "stop event" "drain_complete"
                 (Json.member "event" payload |> Json.to_string)))

let test_count_running () =
  R.clear ();
  let _e1 = R.register ~base_path:bp "r1" (make_meta "r1") in
  let _e2 = R.register ~base_path:bp "r2" (make_meta "r2") in
  let _e3 = R.register ~base_path:bp "r3" (make_meta "r3") in
  check int "3 running" 3 (R.count_running ());
  ignore (R.dispatch_event ~base_path:bp "r2" KSM.Operator_pause);
  check int "2 running" 2 (R.count_running ());
  R.unregister ~base_path:bp "r1";
  check int "1 running" 1 (R.count_running ())

let test_count_running_atomic_transitions () =
  let bp2 = "/tmp/test-2" in
  R.clear ();
  ignore (R.register ~base_path:bp "fast1" (make_meta "fast1"));
  ignore (R.register ~base_path:bp2 "fast2" (make_meta "fast2"));
  check int "global fast-path count" 2 (R.count_running ());
  check int "scoped count stays exact" 1 (R.count_running ~base_path:bp ());
  ignore (R.dispatch_event ~base_path:bp2 "fast2" KSM.Operator_pause);
  check int "pause decrements global fast-path" 1 (R.count_running ());
  ignore (R.register ~base_path:bp "fast1" (make_meta "fast1"));
  check int "replacing running entry keeps count stable" 1 (R.count_running ());
  R.unregister ~base_path:bp "fast1";
  check int "unregister decrements global fast-path" 0 (R.count_running ());
  R.clear ();
  check int "clear resets global fast-path" 0 (R.count_running ())

let test_record_restart () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k5" (make_meta "k5") in
  R.record_restart ~base_path:bp "k5";
  R.record_restart ~base_path:bp "k5";
  match R.get ~base_path:bp "k5" with
  | None -> fail "expected k5"
  | Some e ->
      check int "restart count" 2 e.restart_count;
      check bool "last_restart_ts set" true (e.last_restart_ts > 0.0)

let test_is_registered () =
  R.clear ();
  check bool "not registered before" false
    (R.is_registered ~base_path:bp "k5x");
  let _entry = R.register ~base_path:bp "k5x" (make_meta "k5x") in
  check bool "registered after add" true
    (R.is_registered ~base_path:bp "k5x");
  R.unregister ~base_path:bp "k5x";
  check bool "not registered after remove" false
    (R.is_registered ~base_path:bp "k5x")

let test_record_error () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k6" (make_meta "k6") in
  check bool "no error initially" true
    (Option.is_none (Option.bind (R.get ~base_path:bp "k6") (fun e -> e.last_error)));
  R.record_error ~base_path:bp "k6" "something broke";
  match R.get ~base_path:bp "k6" with
  | None -> fail "expected k6"
  | Some e ->
    check (option string) "error recorded" (Some "something broke") e.last_error

let test_clear_error () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k6-clear" (make_meta "k6-clear") in
  R.record_error ~base_path:bp "k6-clear" "stale error";
  R.clear_error ~base_path:bp "k6-clear";
  match R.get ~base_path:bp "k6-clear" with
  | None -> fail "expected k6-clear"
  | Some e ->
      check (option string) "error cleared" None e.last_error

let test_get_returns_none_for_missing () =
  R.clear ();
  check (option reject) "nonexistent returns None" None
    (R.get ~base_path:bp "nonexistent")

let test_noop_on_missing () =
  R.clear ();
  R.update_meta ~base_path:bp "ghost" (make_meta "ghost");
  ignore (R.dispatch_event ~base_path:bp "ghost" KSM.Operator_pause);
  R.record_restart ~base_path:bp "ghost";
  R.record_error ~base_path:bp "ghost" "err";
  R.clear_error ~base_path:bp "ghost";
  R.record_crash ~base_path:bp "ghost" 0.0 "crash";
  R.set_grpc_close ~base_path:bp "ghost" None;
  R.wakeup ~base_path:bp "ghost";
  R.unregister ~base_path:bp "ghost";
  check bool "ghost never materialized via no-op ops" true
    (Option.is_none (R.get ~base_path:bp "ghost"))

let test_register_replaces () =
  R.clear ();
  let _e1 = R.register ~base_path:bp "dup" (make_meta "dup") in
  R.record_restart ~base_path:bp "dup";
  let _e2 = R.register ~base_path:bp "dup" (make_meta "dup") in
  match R.get ~base_path:bp "dup" with
  | None -> fail "expected dup"
  | Some e ->
    check int "restart count reset" 0 e.restart_count

(* ── New fields: grpc_close, crash_log, wakeup, fiber_health ── *)

let test_grpc_close () =
  R.clear ();
  let _entry = R.register ~base_path:bp "g1" (make_meta "g1") in
  let called = ref false in
  R.set_grpc_close ~base_path:bp "g1" (Some (fun () -> called := true));
  (match R.get ~base_path:bp "g1" with
   | Some e ->
       (match Atomic.get e.grpc_close with
        | Some f -> f (); check bool "grpc_close called" true !called
        | None -> fail "expected grpc_close")
   | None -> fail "expected g1");
  R.set_grpc_close ~base_path:bp "g1" None;
  match R.get ~base_path:bp "g1" with
  | Some e -> check bool "grpc_close cleared" true (Option.is_none (Atomic.get e.grpc_close))
  | None -> fail "expected g1"

let test_crash_log () =
  R.clear ();
  let _entry = R.register ~base_path:bp "c1" (make_meta "c1") in
  R.record_crash ~base_path:bp "c1" 1.0 "crash-1";
  R.record_crash ~base_path:bp "c1" 2.0 "crash-2";
  R.record_crash ~base_path:bp "c1" 3.0 "crash-3";
  let log = R.crash_log_of ~base_path:bp "c1" in
  check int "3 entries" 3 (List.length log);
  check string "latest first" "crash-3" (snd (List.hd log));
  R.record_crash ~base_path:bp "c1" 4.0 "crash-4";
  R.record_crash ~base_path:bp "c1" 5.0 "crash-5";
  R.record_crash ~base_path:bp "c1" 6.0 "crash-6";
  let log2 = R.crash_log_of ~base_path:bp "c1" in
  check int "capped at 5" 5 (List.length log2)

let test_started_at () =
  R.clear ();
  check bool "none for missing" true (Option.is_none (R.started_at ~base_path:bp "nope"));
  let _entry = R.register ~base_path:bp "s1" (make_meta "s1") in
  check bool "some for existing" true (Option.is_some (R.started_at ~base_path:bp "s1"))

let test_wakeup () =
  R.clear ();
  let entry = R.register ~base_path:bp "w1" (make_meta "w1") in
  check bool "wakeup initially false" false (Atomic.get entry.fiber_wakeup);
  R.wakeup ~base_path:bp "w1";
  check bool "wakeup set" true (Atomic.get entry.fiber_wakeup)

let test_wakeup_all () =
  R.clear ();
  let e1 = R.register ~base_path:bp "wa1" (make_meta "wa1") in
  let e2 = R.register ~base_path:bp "wa2" (make_meta "wa2") in
  let e3 = R.register ~base_path:bp "wa3" (make_meta "wa3") in
  let e4 = R.register ~base_path:bp "wa4" (make_meta "wa4") in
  ignore (R.dispatch_event ~base_path:bp "wa3" KSM.Stop_requested);
  ignore (R.dispatch_event ~base_path:bp "wa3" KSM.Drain_complete);
  ignore (R.dispatch_event ~base_path:bp "wa4" KSM.Operator_pause);
  R.wakeup_all ();
  check bool "wa1 woken" true (Atomic.get e1.fiber_wakeup);
  check bool "wa2 woken" true (Atomic.get e2.fiber_wakeup);
  check bool "wa3 not woken (stopped)" false (Atomic.get e3.fiber_wakeup);
  check bool "wa4 not woken (paused)" false (Atomic.get e4.fiber_wakeup)

let test_fiber_health_alive () =
  R.clear ();
  let _entry = R.register ~base_path:bp "fh1" (make_meta "fh1") in
  match R.fiber_health_of ~base_path:bp "fh1" with
  | Keeper_types.Fiber_alive -> ()
  | _ -> fail "expected Fiber_alive"

let test_fiber_health_unknown () =
  R.clear ();
  match R.fiber_health_of ~base_path:bp "nonexistent" with
  | Keeper_types.Fiber_unknown -> ()
  | _ -> fail "expected Fiber_unknown"

let test_fiber_health_stopped () =
  R.clear ();
  let entry = R.register ~base_path:bp "fh2" (make_meta "fh2") in
  Eio.Promise.resolve entry.done_r `Stopped;
  match R.fiber_health_of ~base_path:bp "fh2" with
  | Keeper_types.Fiber_unknown -> ()
  | _ -> fail "expected Fiber_unknown for stopped"

let test_fiber_health_crashed () =
  R.clear ();
  let entry = R.register ~base_path:bp "fh3" (make_meta "fh3") in
  Eio.Promise.resolve entry.done_r (`Crashed "test crash");
  match R.fiber_health_of ~base_path:bp "fh3" with
  | Keeper_types.Fiber_zombie -> ()
  | _ -> fail "expected Fiber_zombie for crashed"

let test_fiber_health_crashed_state_without_done_signal () =
  R.clear ();
  let _entry = R.register ~base_path:bp "fh3-state" (make_meta "fh3-state") in
  ignore (R.dispatch_event ~base_path:bp "fh3-state"
    (KSM.Fiber_terminated { outcome = "test" }));
  match R.fiber_health_of ~base_path:bp "fh3-state" with
  | Keeper_types.Fiber_zombie -> ()
  | _ -> fail "expected Fiber_zombie for explicit crashed state"

let test_fiber_health_dead_state () =
  R.clear ();
  let _entry = R.register ~base_path:bp "fh4" (make_meta "fh4") in
  R.mark_dead ~base_path:bp "fh4" ~at:42.0;
  match R.fiber_health_of ~base_path:bp "fh4" with
  | Keeper_types.Fiber_dead -> ()
  | _ -> fail "expected Fiber_dead for dead state"

let test_shared_refs () =
  R.clear ();
  let entry = R.register ~base_path:bp "ref1" (make_meta "ref1") in
  let entry_via_get = match R.get ~base_path:bp "ref1" with Some e -> e | None -> fail "expected ref1" in
  Atomic.set entry.fiber_wakeup true;
  check bool "shared wakeup atomic" true (Atomic.get entry_via_get.fiber_wakeup);
  Atomic.set entry_via_get.fiber_stop true;
  check bool "shared stop atomic" true (Atomic.get entry.fiber_stop)

let test_spawn_slots () =
  R.clear ();
  check bool "slots available" true (R.spawn_slots_available ())

(* ── Board tracking tests ─────────────────────────────── *)

let test_last_agent_count_default () =
  R.clear ();
  check int "0 for unknown" 0 (R.get_last_agent_count ~base_path:bp "none")

let test_last_agent_count_set_get () =
  R.clear ();
  ignore (R.register ~base_path:bp "ac1" (make_meta "ac1"));
  R.set_last_agent_count ~base_path:bp "ac1" 42;
  check int "set then get" 42 (R.get_last_agent_count ~base_path:bp "ac1")

let test_board_wakeup_debounce () =
  R.clear ();
  ignore (R.register ~base_path:bp "bw1" (make_meta "bw1"));
  let first = R.board_wakeup_allowed ~base_path:bp "bw1" ~post_id:"p1" ~debounce_sec:60.0 in
  let second = R.board_wakeup_allowed ~base_path:bp "bw1" ~post_id:"p1" ~debounce_sec:60.0 in
  check bool "first allowed" true first;
  check bool "second blocked" false second

let test_board_wakeup_different_post () =
  R.clear ();
  ignore (R.register ~base_path:bp "bw2" (make_meta "bw2"));
  let first = R.board_wakeup_allowed ~base_path:bp "bw2" ~post_id:"p1" ~debounce_sec:60.0 in
  let second = R.board_wakeup_allowed ~base_path:bp "bw2" ~post_id:"p2" ~debounce_sec:60.0 in
  check bool "p1 allowed" true first;
  check bool "p2 allowed" true second

let test_cleanup_tracking () =
  R.clear ();
  ignore (R.register ~base_path:bp "ct1" (make_meta "ct1"));
  R.set_last_agent_count ~base_path:bp "ct1" 10;
  ignore (R.board_wakeup_allowed ~base_path:bp "ct1" ~post_id:"x" ~debounce_sec:60.0);
  R.cleanup_tracking ~base_path:bp "ct1";
  check int "agent count reset" 0 (R.get_last_agent_count ~base_path:bp "ct1");
  let allowed = R.board_wakeup_allowed ~base_path:bp "ct1" ~post_id:"x" ~debounce_sec:60.0 in
  check bool "wakeup allowed after cleanup" true allowed

let test_find_by_agent_name () =
  R.clear ();
  let _entry = R.register ~base_path:bp "fn1" (make_meta "fn1") in
  let _entry2 = R.register ~base_path:bp "fn2" (make_meta "fn2") in
  (match R.find_by_agent_name "agent-fn2" with
   | Some e -> check string "found by agent_name" "fn2" e.name
   | None -> fail "expected fn2 via agent_name");
  check bool "not found returns None" true
    (Option.is_none (R.find_by_agent_name "agent-nonexistent"))

(* ── resolve_config tests ────────────────────────────────── *)

module Coord_setup = Coord_utils_backend_setup

(** Minimal in-memory config for testing resolve_config.
    Only base_path matters; backend is a throwaway Memory instance. *)
let make_test_config base_path : Coord_setup.config =
  let backend_config : Backend_types.config = {
    backend_type = Backend_types.Memory;
    base_path;
    node_id = "test";
    cluster_name = "test";
    pubsub_max_messages = 100;
  } in
  {
    base_path;
    workspace_path = base_path;
    lock_expiry_minutes = 2;
    backend_config;
    backend = Coord_setup.Memory (Backend.Memory.create ());
  }

let test_resolve_config_scoped_hit () =
  R.clear ();
  let _entry = R.register ~base_path:bp "rc1" (make_meta "rc1") in
  let config = make_test_config bp in
  let resolved = R.resolve_config config "rc1" in
  check string "scoped hit keeps base_path" bp resolved.base_path

let test_resolve_config_cross_base_path () =
  R.clear ();
  let bp2 = "/tmp/other" in
  let _entry = R.register ~base_path:bp2 "rc2" (make_meta "rc2") in
  let config = make_test_config bp in
  let resolved = R.resolve_config config "rc2" in
  check string "cross-base_path keeps original scope" bp resolved.base_path

let test_resolve_config_not_found () =
  R.clear ();
  let config = make_test_config bp in
  let resolved = R.resolve_config config "nonexistent" in
  check string "unknown keeper keeps original" bp resolved.base_path

let test_resolve_config_empty_name () =
  R.clear ();
  let config = make_test_config bp in
  let resolved = R.resolve_config config "" in
  check string "empty name keeps original" bp resolved.base_path

(* ── Directive processing tests ─────────────────────────── *)

module KK = Masc_mcp.Keeper_keepalive

let test_directive_pause () =
  R.clear ();
  let _entry = R.register ~base_path:bp "dp1" (make_meta "dp1") in
  KK.process_directive ~agent_name:"agent-dp1" "pause";
  match R.get ~base_path:bp "dp1" with
  | Some e -> check bool "paused after directive" true e.meta.paused
  | None -> fail "expected dp1"

let test_directive_resume () =
  R.clear ();
  let _entry = R.register ~base_path:bp "dr1" (make_meta "dr1") in
  KK.process_directive ~agent_name:"agent-dr1" "pause";
  KK.process_directive ~agent_name:"agent-dr1" "resume";
  match R.get ~base_path:bp "dr1" with
  | Some e -> check bool "resumed after directive" false e.meta.paused
  | None -> fail "expected dr1"

let test_directive_claim () =
  R.clear ();
  let _entry = R.register ~base_path:bp "dc1" (make_meta "dc1") in
  KK.process_directive ~agent_name:"agent-dc1" "claim:T-42";
  match R.get ~base_path:bp "dc1" with
  | Some e ->
    (match e.meta.current_task_id with
     | Some tid -> check string "task assigned" "T-42" (Masc_mcp.Keeper_id.Task_id.to_string tid)
     | None -> fail "expected current_task_id set")
  | None -> fail "expected dc1"

let test_directive_unknown_no_crash () =
  R.clear ();
  let _entry = R.register ~base_path:bp "du1" (make_meta "du1") in
  KK.process_directive ~agent_name:"agent-du1" "unknown-directive";
  check bool "still running after unknown directive" true
    (R.is_running ~base_path:bp "du1")

let test_directive_nonexistent_agent () =
  R.clear ();
  KK.process_directive ~agent_name:"ghost-agent" "pause";
  check bool "directive on ghost agent leaves registry empty" true
    (Option.is_none (R.get ~base_path:bp "ghost-agent"))

let test_stop_keepalive_scoped_to_base_path () =
  R.clear ();
  let bp2 = "/tmp/stop-other" in
  let entry_a = R.register ~base_path:bp "shared-stop" (make_meta "shared-stop") in
  let entry_b = R.register ~base_path:bp2 "shared-stop" (make_meta "shared-stop") in
  check bool "base path A stop initially false" false
    (Atomic.get entry_a.fiber_stop);
  check bool "base path B stop initially false" false
    (Atomic.get entry_b.fiber_stop);
  KK.stop_keepalive ~base_path:bp "shared-stop";
  check bool "base path A stop set" true (Atomic.get entry_a.fiber_stop);
  check bool "base path B stop stays unset" false
    (Atomic.get entry_b.fiber_stop)

let test_wakeup_keeper_scoped_to_base_path () =
  R.clear ();
  let bp2 = "/tmp/wakeup-other" in
  let entry_a = R.register ~base_path:bp "shared" (make_meta "shared") in
  let entry_b = R.register ~base_path:bp2 "shared" (make_meta "shared") in
  check bool "base path A wakeup initially false" false
    (Atomic.get entry_a.fiber_wakeup);
  check bool "base path B wakeup initially false" false
    (Atomic.get entry_b.fiber_wakeup);
  KK.wakeup_keeper ~base_path:bp "shared";
  check bool "base path A wakeup set" true (Atomic.get entry_a.fiber_wakeup);
  check bool "base path B wakeup stays unset" false
    (Atomic.get entry_b.fiber_wakeup)

let test_wakeup_all_scoped_to_base_path () =
  R.clear ();
  let bp2 = "/tmp/wakeup-all-other" in
  let entry_a = R.register ~base_path:bp "all-a" (make_meta "all-a") in
  let entry_b = R.register ~base_path:bp2 "all-b" (make_meta "all-b") in
  check bool "base path A all wakeup initially false" false
    (Atomic.get entry_a.fiber_wakeup);
  check bool "base path B all wakeup initially false" false
    (Atomic.get entry_b.fiber_wakeup);
  KK.wakeup_all_keepers ~base_path:bp ();
  check bool "base path A all wakeup set" true (Atomic.get entry_a.fiber_wakeup);
  check bool "base path B all wakeup stays unset" false
    (Atomic.get entry_b.fiber_wakeup)

let () =
  run "Keeper_registry"
    [
      ( "basic",
        [
          eio_test "register and get" test_register_and_get;
          eio_test "register offline and start" test_register_offline_and_start;
          eio_test "register restarting and start" test_register_restarting_and_start;
          eio_test "dispatch event with audit preserves snapshot"
            test_dispatch_event_with_audit_preserves_snapshot;
          eio_test "unregister" test_unregister;
          eio_test "all" test_all;
          eio_test "update meta" test_update_meta;
          eio_test "set state" test_set_state;
          eio_test "dispatch event emits phase SSE"
            test_dispatch_event_emits_phase_sse;
          eio_test "extended states" test_extended_states;
          eio_test "stopped entry action is observability-only"
            test_stopped_entry_action_is_observability_only;
          eio_test "count running" test_count_running;
          eio_test "count running atomic transitions" test_count_running_atomic_transitions;
          eio_test "record restart" test_record_restart;
          eio_test "is_registered" test_is_registered;
          eio_test "record error" test_record_error;
          eio_test "clear error" test_clear_error;
          eio_test "get returns None for missing" test_get_returns_none_for_missing;
          eio_test "noop on missing keys" test_noop_on_missing;
          eio_test "register replaces existing" test_register_replaces;
        ] );
      ( "extended",
        [
          eio_test "grpc_close" test_grpc_close;
          eio_test "crash log" test_crash_log;
          eio_test "started_at" test_started_at;
          eio_test "wakeup" test_wakeup;
          eio_test "wakeup_all" test_wakeup_all;
          eio_test "fiber_health alive" test_fiber_health_alive;
          eio_test "fiber_health unknown" test_fiber_health_unknown;
          eio_test "fiber_health stopped" test_fiber_health_stopped;
          eio_test "fiber_health crashed" test_fiber_health_crashed;
          eio_test "fiber_health explicit crashed state" test_fiber_health_crashed_state_without_done_signal;
          eio_test "fiber_health dead state" test_fiber_health_dead_state;
          eio_test "shared refs" test_shared_refs;
          eio_test "spawn slots" test_spawn_slots;
        ] );
      ( "board_tracking",
        [
          eio_test "last_agent_count default 0" test_last_agent_count_default;
          eio_test "last_agent_count set/get" test_last_agent_count_set_get;
          eio_test "board wakeup debounce" test_board_wakeup_debounce;
          eio_test "board wakeup different post" test_board_wakeup_different_post;
          eio_test "cleanup_tracking resets" test_cleanup_tracking;
        ] );
      ( "agent_name_lookup",
        [
          eio_test "find_by_agent_name" test_find_by_agent_name;
        ] );
      ( "resolve_config",
        [
          eio_test "scoped hit" test_resolve_config_scoped_hit;
          eio_test "cross base_path" test_resolve_config_cross_base_path;
          eio_test "not found" test_resolve_config_not_found;
          eio_test "empty name" test_resolve_config_empty_name;
        ] );
      ( "directives",
        [
          eio_test "pause directive" test_directive_pause;
          eio_test "resume directive" test_directive_resume;
          eio_test "claim directive" test_directive_claim;
          eio_test "unknown directive no crash" test_directive_unknown_no_crash;
          eio_test "nonexistent agent no crash" test_directive_nonexistent_agent;
          eio_test "stop keepalive scoped to base_path"
            test_stop_keepalive_scoped_to_base_path;
          eio_test "wakeup keeper scoped to base_path"
            test_wakeup_keeper_scoped_to_base_path;
          eio_test "wakeup all scoped to base_path"
            test_wakeup_all_scoped_to_base_path;
        ] );
    ]
