open Alcotest

module R = Masc_mcp.Keeper_registry
module Keeper_types = Masc_mcp.Keeper_types
module KSM = Masc_mcp.Keeper_state_machine
module Audit = Masc_mcp.Keeper_transition_audit
module Meas = Masc_mcp.Keeper_measurement
module Pages = Masc_mcp.Server_routes_http_pages
module Json = Yojson.Safe.Util

let bp = "/tmp/test"

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else
      Unix.unlink path

let temp_base_path label =
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-%s-%06x" label (Random.bits ()))
  in
  Unix.mkdir base 0o755;
  base

let make_meta name =
  let json = `Assoc [
    ("name", `String name);
    ("agent_name", `String ("agent-" ^ name));
    ("trace_id", `String ("trace-test-" ^ name));
    ("goal", `String "test goal");
  ] in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

let make_stimulus ?(urgency = Masc_mcp.Keeper_event_queue.Normal)
    ?(arrived_at = 0.0) post_id payload =
  Masc_mcp.Keeper_event_queue.{ post_id; urgency; arrived_at; payload }

let test_bonsai_keepers_summary_uses_scoped_registry () =
  let base_path = temp_base_path "bonsai-summary" in
  let other_base_path = temp_base_path "bonsai-summary-other" in
  Fun.protect
    ~finally:(fun () ->
      R.unregister ~base_path "live-keeper";
      R.unregister ~base_path:other_base_path "foreign-keeper";
      rm_rf base_path;
      rm_rf other_base_path)
    (fun () ->
      let base_meta = make_meta "live-keeper" in
      let meta =
        { base_meta with
          max_context_override = Some 1000;
          runtime =
            { base_meta.runtime with
              usage =
                { base_meta.runtime.usage with
                  total_turns = 7;
                  last_total_tokens = 250;
                  last_latency_ms = 1234;
                };
            };
        }
      in
      ignore (R.register ~base_path "live-keeper" meta);
      ignore
        (R.register
           ~base_path:other_base_path
           "foreign-keeper"
           (make_meta "foreign-keeper"));
      R.record_tool_use
        ~base_path
        "live-keeper"
        ~tool_name:"keeper_tasks_list"
        ~success:true;
      let summary = Pages.keepers_summary_from_registry ~base_path in
      check int "scoped keeper count" 1 (List.length summary.keepers);
      match summary.keepers with
      | [ keeper ] ->
          check string "live name" "live-keeper" keeper.name;
          check int "turns from runtime usage" 7 keeper.turn;
          check int "ctx pct from runtime usage" 25 keeper.ctx_pct;
          check int "latency from runtime usage" 1234 keeper.latency_ms;
          check
            (option string)
            "latest tool"
            (Some "keeper_tasks_list")
            keeper.last_tool;
          check bool "mock keeper omitted" true
            (not (String.equal keeper.name "luna"))
      | _ -> fail "expected exactly one scoped keeper")

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
  (* #7889: register_offline must make is_registered true synchronously even
     before the keepalive fiber has transitioned the entry to running. *)
  check bool "registered synchronously after register_offline" true
    (R.is_registered ~base_path:bp "k1-offline");
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

let test_prepare_fiber_launch_resets_stale_runtime_latches () =
  R.clear ();
  let name = "k1-stale-stop" in
  let entry = R.register_restarting ~base_path:bp name (make_meta name) in
  Atomic.set entry.fiber_stop true;
  Atomic.set entry.fiber_wakeup true;
  Atomic.set entry.waiting_for_inference true;
  (match R.prepare_fiber_launch ~base_path:bp name with
   | Ok _ -> ()
   | Error err -> fail (KSM.transition_error_to_string err));
  match R.get ~base_path:bp name with
  | None -> fail "expected k1-stale-stop"
  | Some updated ->
      check bool "fiber_stop reset before launch" false
        (Atomic.get updated.fiber_stop);
      check bool "fiber_wakeup reset before launch" false
        (Atomic.get updated.fiber_wakeup);
      check bool "waiting_for_inference reset before launch" false
        (Atomic.get updated.waiting_for_inference);
      check string "running after prepare launch" "running"
        (KSM.phase_to_string updated.phase);
      check bool "fsm stop_requested reset" false updated.conditions.stop_requested

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
        ; similarity_measurable = true
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

let test_mark_turn_finished_records_completed_turn_outcome_once () =
  R.clear ();
  let keeper_name = "k-completed-turn-audit" in
  ignore (R.register ~base_path:bp keeper_name (make_meta keeper_name));
  R.mark_turn_started ~base_path:bp keeper_name;
  R.set_turn_decision_stage
    ~base_path:bp keeper_name R.Decision_tool_policy_selected;
  R.mark_turn_gate_rejected_by_name keeper_name;
  R.mark_turn_finished ~base_path:bp keeper_name;
  R.mark_turn_finished ~base_path:bp keeper_name;
  match Audit.recent_completed_turns ~keeper_name ~limit:5 with
  | [ turn ] ->
      check int "turn_id recorded" 1 turn.turn_id;
      check bool "started_at recorded" true (turn.started_at > 0.0);
      check bool "ended_at recorded" true (turn.ended_at >= turn.started_at);
      check bool "gate_rejected outcome recorded" true
        (match turn.outcome with
         | Audit.Turn_gate_rejected -> true
         | _ -> false)
  | turns ->
      fail
        (Printf.sprintf "expected exactly one completed turn, got %d"
           (List.length turns))

(* IR-1: mark_turn_finished resets fiber_wakeup as belt-and-suspenders.
   The primary consumer is interruptible_sleep's CAS, but an explicit
   reset in mark_turn_finished guarantees the flag is clean even when
   the heartbeat loop's sleep path was not the one that consumed it. *)
let test_mark_turn_finished_resets_wakeup () =
  R.clear ();
  let keeper_name = "k-wakeup-reset-ir1" in
  let entry = R.register ~base_path:bp keeper_name (make_meta keeper_name) in
  R.mark_turn_started ~base_path:bp keeper_name;
  Atomic.set entry.R.fiber_wakeup true;
  check bool "wakeup set before finish" true (Atomic.get entry.R.fiber_wakeup);
  R.mark_turn_finished ~base_path:bp keeper_name;
  check bool "IR-1: wakeup reset after mark_turn_finished" false
    (Atomic.get entry.R.fiber_wakeup)

let test_mark_turn_finished_updates_last_turn_ts () =
  R.clear ();
  let keeper_name = "k-last-turn-finish" in
  ignore (R.register ~base_path:bp keeper_name (make_meta keeper_name));
  R.mark_turn_started ~base_path:bp keeper_name;
  R.mark_turn_finished ~base_path:bp keeper_name;
  match R.get ~base_path:bp keeper_name with
  | None -> fail "entry missing after mark_turn_finished"
  | Some entry ->
      check bool "last_turn_ts stamped on completed turn" true
        (entry.R.meta.runtime.usage.last_turn_ts > 0.0)

let test_completed_turns_replay_from_default_store () =
  let base_path = temp_base_path "completed-turn-replay" in
  Fun.protect
    ~finally:(fun () ->
      Audit.For_testing.reset_state ();
      rm_rf base_path)
    (fun () ->
      with_env "MASC_BASE_PATH" base_path (fun () ->
          Audit.For_testing.reset_state ();
          let keeper_name = "k-completed-turn-replay" in
          Audit.record_completed_turn ~keeper_name
            {
              Audit.turn_id = 42;
              started_at = 100.0;
              ended_at = 120.0;
              outcome = Audit.Turn_substantive;
            };
          Audit.For_testing.clear_completed_turn_ring ~keeper_name;
          match Audit.recent_completed_turns ~keeper_name ~limit:5 with
          | [ turn ] ->
              check int "turn_id replayed" 42 turn.turn_id;
              check bool "substantive outcome replayed" true
                (match turn.outcome with
                 | Audit.Turn_substantive -> true
                 | _ -> false)
          | turns ->
              fail
                (Printf.sprintf
                   "expected one replayed completed turn, got %d"
                   (List.length turns))))

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

let test_dispatch_event_emits_lifecycle_transition_metric_only_on_phase_change () =
  R.clear ();
  let keeper_name = "k4-lifecycle-metric" in
  let changed_labels =
    [
      ("keeper", keeper_name);
      ("from_phase", "running");
      ("to_phase", "paused");
    ]
  in
  let unchanged_labels =
    [
      ("keeper", keeper_name);
      ("from_phase", "running");
      ("to_phase", "running");
    ]
  in
  let changed_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_lifecycle_transitions
      ~labels:changed_labels ()
  in
  ignore (R.register ~base_path:bp keeper_name (make_meta keeper_name));
  ignore (R.dispatch_event ~base_path:bp keeper_name KSM.Fiber_started);
  check (float 0.001) "no same-phase metric emitted" 0.0
    (Masc_mcp.Prometheus.metric_value_or_zero
       Masc_mcp.Keeper_metrics.metric_keeper_lifecycle_transitions
       ~labels:unchanged_labels ());
  ignore (R.dispatch_event ~base_path:bp keeper_name KSM.Operator_pause);
  let changed_after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_lifecycle_transitions
      ~labels:changed_labels ()
  in
  check (float 0.001) "phase-change transition metric incremented"
    (changed_before +. 1.0) changed_after

let test_dispatch_event_observes_phase_sse_broadcast_failure () =
  R.clear ();
  let keeper_name = "k4-lifecycle-sse-failure" in
  let labels = [("keeper", keeper_name); ("site", "phase_changed")] in
  let before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_sse_broadcast_failures
      ~labels ()
  in
  ignore (R.register ~base_path:bp keeper_name (make_meta keeper_name));
  let original_hook = Atomic.get Masc_mcp.Sse.buffer_commit_test_hook in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Masc_mcp.Sse.buffer_commit_test_hook original_hook)
    (fun () ->
      Atomic.set Masc_mcp.Sse.buffer_commit_test_hook
        (Some (fun () -> failwith "forced phase broadcast failure"));
      match R.dispatch_event ~base_path:bp keeper_name KSM.Operator_pause with
      | Error err ->
          fail
            (KSM.transition_error_to_string err)
      | Ok _ -> ());
  let after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_sse_broadcast_failures
      ~labels ()
  in
  check (float 0.001) "phase SSE failure metric incremented"
    (before +. 1.0) after;
  match R.get ~base_path:bp keeper_name with
  | None -> fail "expected registered keeper"
  | Some entry ->
      check string "phase transition still applied" "paused"
        (KSM.phase_to_string entry.phase)

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

let test_overflow_entry_action_promotes_to_compacting () =
  R.clear ();
  ignore (R.register ~base_path:bp "k-overflow" (make_meta "k-overflow"));
  ignore
    (R.dispatch_event ~base_path:bp "k-overflow"
       (KSM.Context_overflow_detected
          {
            source = `Prompt_rejected;
            token_count = 205_000;
            limit_tokens = Some 200_000;
          }));
  match R.get ~base_path:bp "k-overflow" with
  | None -> fail "expected k-overflow"
  | Some entry ->
      check string "registry auto-promotes overflow to compacting" "compacting"
        (KSM.phase_to_string entry.phase);
      check bool "compaction_active latched" true
        entry.conditions.compaction_active;
      check bool "context_overflow remains latched" true
        entry.conditions.context_overflow

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

let test_dequeue_event_consumes_fifo () =
  R.clear ();
  let keeper_name = "dequeue-fifo" in
  ignore (R.register ~base_path:bp keeper_name (make_meta keeper_name));
  let s1 = make_stimulus "post-1" "first" in
  let s2 =
    make_stimulus ~urgency:Masc_mcp.Keeper_event_queue.Immediate "post-2"
      "second"
  in
  R.enqueue_event ~base_path:bp keeper_name s1;
  R.enqueue_event ~base_path:bp keeper_name s2;
  check int "queued before dequeue" 2
    (Masc_mcp.Keeper_event_queue.length
       (R.event_queue_snapshot ~base_path:bp keeper_name));
  (match R.dequeue_event ~base_path:bp keeper_name with
   | Some stim ->
       check string "first post id" "post-1" stim.post_id;
       check string "first payload" "first" stim.payload
   | None -> fail "expected first stimulus");
  check int "one queued after first dequeue" 1
    (Masc_mcp.Keeper_event_queue.length
       (R.event_queue_snapshot ~base_path:bp keeper_name));
  (match R.dequeue_event ~base_path:bp keeper_name with
   | Some stim ->
       check string "second post id" "post-2" stim.post_id;
       check string "second payload" "second" stim.payload
   | None -> fail "expected second stimulus");
  check bool "empty after drain" true
    (Masc_mcp.Keeper_event_queue.is_empty
       (R.event_queue_snapshot ~base_path:bp keeper_name));
  check bool "dequeue empty returns None" true
    (Option.is_none (R.dequeue_event ~base_path:bp keeper_name))

let test_dequeue_event_respects_base_path_and_missing_keeper () =
  R.clear ();
  let name = "dequeue-scope" in
  let other_bp = "/tmp/test-dequeue-scope-other" in
  ignore (R.register ~base_path:bp name (make_meta name));
  ignore (R.register ~base_path:other_bp name (make_meta name));
  R.enqueue_event ~base_path:bp name (make_stimulus "scoped" "payload");
  check bool "missing keeper returns None" true
    (Option.is_none (R.dequeue_event ~base_path:bp "missing-dequeue"));
  check bool "other base path stays empty" true
    (Option.is_none (R.dequeue_event ~base_path:other_bp name));
  match R.dequeue_event ~base_path:bp name with
  | Some stim -> check string "scoped payload" "payload" stim.payload
  | None -> fail "expected scoped stimulus"

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

let test_try_resolve_done_wins_once () =
  R.clear ();
  let entry = R.register ~base_path:bp "resolve-once" (make_meta "resolve-once") in
  check bool "first resolve wins" true (R.try_resolve_done entry `Stopped);
  check bool "second resolve loses" false
    (R.try_resolve_done entry (`Crashed "late crash"));
  match Eio.Promise.await entry.done_p with
  | `Stopped -> ()
  | `Crashed reason -> fail ("expected stopped, got crashed: " ^ reason)

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

(* P0-2 (2026-05-07): orphan-drop counter wiring through update_entry.

   Validation strategy: call a public update_entry caller
   ([R.set_last_agent_count]) against a [name] that was never registered.
   Each call hits the [None] branch and bumps the orphan-drop metric.
   At drop #5 (= [orphan_drop_threshold]) the threshold-breached
   counter increments exactly once. The 6th drop within the window
   does NOT bump it again (edge-trigger). After a successful update on
   the same name (post-register), the per-name state is cleared.

   We deliberately do not assert specific counter totals across
   registry tests because the metric is process-wide; instead, we
   pin deltas inside this single test using a unique [name]. *)
let test_update_entry_orphan_drop_emits_metrics () =
  R.clear ();
  let name = "orphan-drop-counter-test" in
  let labels = [ "name", name ] in
  let dropped_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_registry_update_dropped
      ~labels ()
  in
  let breached_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_registry_orphan_threshold_breached
      ~labels ()
  in
  (* 5 drops on a never-registered name: each bumps _dropped, the 5th
     bumps _orphan_threshold_breached exactly once. *)
  for _ = 1 to 5 do
    R.set_last_agent_count ~base_path:bp name 0
  done;
  let dropped_after_5 =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_registry_update_dropped
      ~labels ()
  in
  let breached_after_5 =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_registry_orphan_threshold_breached
      ~labels ()
  in
  check (float 0.001) "dropped counter +=5"
    (dropped_before +. 5.0) dropped_after_5;
  check (float 0.001) "threshold breached exactly once at drop #5"
    (breached_before +. 1.0) breached_after_5;
  (* 6th drop in same window: only _dropped bumps, breach edge-trigger
     does not re-fire. *)
  R.set_last_agent_count ~base_path:bp name 0;
  let dropped_after_6 =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_registry_update_dropped
      ~labels ()
  in
  let breached_after_6 =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_registry_orphan_threshold_breached
      ~labels ()
  in
  check (float 0.001) "dropped counter +=6"
    (dropped_before +. 6.0) dropped_after_6;
  check (float 0.001) "threshold breach is edge-triggered (still +1)"
    (breached_before +. 1.0) breached_after_6;
  (* Once the keeper is registered and update succeeds, per-name state
     is cleared. Subsequent re-deregistration would start a fresh
     window, but we don't simulate that here — the cleared-on-success
     contract is enough to prove orphan resolution detected. *)
  ignore (R.register ~base_path:bp name (make_meta name));
  R.set_last_agent_count ~base_path:bp name 7;
  check int "successful update applies"
    7 (R.get_last_agent_count ~base_path:bp name)

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

let test_directive_keeper_name_alias () =
  R.clear ();
  let _entry = R.register ~base_path:bp "dra1" (make_meta "dra1") in
  KK.process_directive ~agent_name:"dra1" "pause";
  (match R.get ~base_path:bp "dra1" with
   | Some e -> check bool "paused via keeper name alias" true e.meta.paused
   | None -> fail "expected dra1");
  KK.process_directive ~agent_name:"dra1" "resume";
  match R.get ~base_path:bp "dra1" with
  | Some e -> check bool "resumed via keeper name alias" false e.meta.paused
  | None -> fail "expected dra1"

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

let test_directive_pause_persists_meta () =
  R.clear ();
  let base_dir = temp_base_path "directive-pause-persist" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = make_test_config base_dir in
      let meta = make_meta "dpersist" in
      (match Keeper_types.write_meta ~force:true config meta with
       | Ok () -> ()
       | Error err -> fail ("write_meta failed: " ^ err));
      ignore (R.register ~base_path:base_dir "dpersist" meta);
      KK.process_directive ~agent_name:"agent-dpersist" "pause";
      match Keeper_types.read_meta config "dpersist" with
      | Ok (Some persisted) ->
          check bool "paused persisted" true persisted.paused
      | Ok None -> fail "expected persisted meta"
      | Error err -> fail ("read_meta failed: " ^ err))

let test_directive_claim_persists_meta () =
  R.clear ();
  let base_dir = temp_base_path "directive-claim-persist" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = make_test_config base_dir in
      let meta = make_meta "dclaimpersist" in
      (match Keeper_types.write_meta ~force:true config meta with
       | Ok () -> ()
       | Error err -> fail ("write_meta failed: " ^ err));
      ignore (R.register ~base_path:base_dir "dclaimpersist" meta);
      KK.process_directive ~agent_name:"agent-dclaimpersist" "claim:T-77";
      match Keeper_types.read_meta config "dclaimpersist" with
      | Ok (Some persisted) ->
          (match persisted.current_task_id with
           | Some task_id ->
               check string "claimed task persisted" "T-77"
                 (Masc_mcp.Keeper_id.Task_id.to_string task_id)
           | None -> fail "expected persisted current_task_id")
      | Ok None -> fail "expected persisted meta"
      | Error err -> fail ("read_meta failed: " ^ err))

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

let test_board_signal_wakeup_ignores_unmatched_posts_without_opt_in () =
  R.clear ();
  let base_dir = temp_base_path "board-wakeup-ignore" in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Board.reset_global_for_test ();
      Masc_mcp.Board_dispatch.reset_for_test ();
      rm_rf base_dir)
    (fun () ->
      with_env "MASC_BASE_PATH" base_dir (fun () ->
        Masc_mcp.Board.reset_global_for_test ();
        Masc_mcp.Board_dispatch.reset_for_test ();
        Masc_mcp.Board_dispatch.init_jsonl ();
        let config = make_test_config base_dir in
        let alpha = make_meta "alpha" in
        let beta = make_meta "beta" in
        ignore (Keeper_types.write_meta ~force:true config alpha);
        ignore (Keeper_types.write_meta ~force:true config beta);
        let entry_a = R.register ~base_path:base_dir "alpha" alpha in
        let entry_b = R.register ~base_path:base_dir "beta" beta in
        let post =
          match
            Masc_mcp.Board_dispatch.create_post ~author:"alice"
              ~title:"General update"
              ~content:"No direct mention here"
              ~post_kind:Masc_mcp.Board.Human_post ()
          with
          | Ok post -> post
          | Error err -> fail (Masc_mcp.Board.show_board_error err)
        in
        let signal : Masc_mcp.Board_dispatch.keeper_board_signal =
          {
            kind = Masc_mcp.Board_dispatch.Board_post_created;
            post_id = Masc_mcp.Board.Post_id.to_string post.id;
            author = "alice";
            title = post.title;
            content = post.content;
            hearth = post.hearth;
          }
        in
        KK.wakeup_relevant_keeper_for_board_signal ~config signal;
        check bool "alpha not woken" false (Atomic.get entry_a.fiber_wakeup);
        check bool "beta not woken" false (Atomic.get entry_b.fiber_wakeup)))

let test_board_signal_wakeup_only_wakes_opted_in_scope_keeper () =
  R.clear ();
  let base_dir = temp_base_path "board-wakeup-optin" in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Board.reset_global_for_test ();
      Masc_mcp.Board_dispatch.reset_for_test ();
      rm_rf base_dir)
    (fun () ->
      with_env "MASC_BASE_PATH" base_dir (fun () ->
        Masc_mcp.Board.reset_global_for_test ();
        Masc_mcp.Board_dispatch.reset_for_test ();
        Masc_mcp.Board_dispatch.init_jsonl ();
        let config = make_test_config base_dir in
        let opted_in_base = make_meta "opted-in" in
        let opted_in = { opted_in_base with room_signal_prompt_enabled = true } in
        let defaulted = make_meta "defaulted" in
        ignore (Keeper_types.write_meta ~force:true config opted_in);
        ignore (Keeper_types.write_meta ~force:true config defaulted);
        let entry_a = R.register ~base_path:base_dir "opted-in" opted_in in
        let entry_b = R.register ~base_path:base_dir "defaulted" defaulted in
        let post =
          match
            Masc_mcp.Board_dispatch.create_post ~author:"alice"
              ~title:"General update"
              ~content:"No direct mention here"
              ~post_kind:Masc_mcp.Board.Human_post ()
          with
          | Ok post -> post
          | Error err -> fail (Masc_mcp.Board.show_board_error err)
        in
        let signal : Masc_mcp.Board_dispatch.keeper_board_signal =
          {
            kind = Masc_mcp.Board_dispatch.Board_post_created;
            post_id = Masc_mcp.Board.Post_id.to_string post.id;
            author = "alice";
            title = post.title;
            content = post.content;
            hearth = post.hearth;
          }
        in
        KK.wakeup_relevant_keeper_for_board_signal ~config signal;
        check bool "opted-in keeper woken" true (Atomic.get entry_a.fiber_wakeup);
        check int "opted-in keeper queued board stimulus" 1
          (R.event_queue_snapshot ~base_path:base_dir "opted-in"
           |> Masc_mcp.Keeper_event_queue.length);
        check bool "defaulted keeper stays asleep" false
          (Atomic.get entry_b.fiber_wakeup);
        check int "defaulted keeper has no stimulus" 0
          (R.event_queue_snapshot ~base_path:base_dir "defaulted"
           |> Masc_mcp.Keeper_event_queue.length)))

let test_board_signal_wakeup_keeps_thread_reply_after_self_comment () =
  R.clear ();
  let base_dir = temp_base_path "board-wakeup-followup" in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Board.reset_global_for_test ();
      Masc_mcp.Board_dispatch.reset_for_test ();
      rm_rf base_dir)
    (fun () ->
      with_env "MASC_BASE_PATH" base_dir (fun () ->
        Masc_mcp.Board.reset_global_for_test ();
        Masc_mcp.Board_dispatch.reset_for_test ();
        Masc_mcp.Board_dispatch.init_jsonl ();
        let config = make_test_config base_dir in
        let participant = make_meta "participant" in
        let bystander = make_meta "bystander" in
        ignore (Keeper_types.write_meta ~force:true config participant);
        ignore (Keeper_types.write_meta ~force:true config bystander);
        let entry_a = R.register ~base_path:base_dir "participant" participant in
        let entry_b = R.register ~base_path:base_dir "bystander" bystander in
        let post =
          match
            Masc_mcp.Board_dispatch.create_post ~author:"alice"
              ~title:"General update"
              ~content:"No direct mention here"
              ~post_kind:Masc_mcp.Board.Human_post ()
          with
          | Ok post -> post
          | Error err -> fail (Masc_mcp.Board.show_board_error err)
        in
        let post_id = Masc_mcp.Board.Post_id.to_string post.id in
        (match
           Masc_mcp.Board_dispatch.add_comment ~post_id ~author:"participant"
             ~content:"I am following this thread."
             ()
         with
        | Ok _ -> ()
        | Error err -> fail (Masc_mcp.Board.show_board_error err));
        Unix.sleepf 0.02;
        (match
           Masc_mcp.Board_dispatch.add_comment ~post_id ~author:"bob"
             ~content:"There is a new question for you."
             ()
         with
        | Ok _ -> ()
        | Error err -> fail (Masc_mcp.Board.show_board_error err));
        let signal : Masc_mcp.Board_dispatch.keeper_board_signal =
          {
            kind = Masc_mcp.Board_dispatch.Board_comment_added;
            post_id;
            author = "bob";
            title = post.title;
            content = "There is a new question for you.";
            hearth = post.hearth;
          }
        in
        KK.wakeup_relevant_keeper_for_board_signal ~config signal;
        check bool "participant keeper woken" true
          (Atomic.get entry_a.fiber_wakeup);
        check int "participant keeper queued board stimulus" 1
          (R.event_queue_snapshot ~base_path:base_dir "participant"
           |> Masc_mcp.Keeper_event_queue.length);
        check bool "bystander keeper stays asleep" false
          (Atomic.get entry_b.fiber_wakeup);
        check int "bystander keeper has no stimulus" 0
          (R.event_queue_snapshot ~base_path:base_dir "bystander"
           |> Masc_mcp.Keeper_event_queue.length)))

let test_effective_keepalive_meta_prefers_registry_when_disk_unchanged () =
  R.clear ();
  let stale = make_meta "loop-meta" in
  let fresh =
    {
      stale with
      continuity_summary = "fresh continuity";
      runtime =
        {
          stale.runtime with
          usage = { stale.runtime.usage with total_turns = 9 };
        };
    }
  in
  ignore (R.register ~base_path:bp "loop-meta" fresh);
  let chosen =
    KK.effective_keepalive_meta
      ~base_path:bp
      ~fallback:stale
      ~disk_meta_opt:None
  in
  check string "continuity comes from registry" "fresh continuity"
    chosen.continuity_summary;
  check int "turn count comes from registry" 9
    chosen.runtime.usage.total_turns

(* ── RFC-0045: SDK turn boundary alignment ─────────────────── *)

let drive_turn_to_finalizing keeper_name =
  R.mark_turn_started ~base_path:bp keeper_name;
  R.set_turn_decision_stage
    ~base_path:bp keeper_name R.Decision_tool_policy_selected;
  R.set_turn_cascade_state ~base_path:bp keeper_name R.Cascade_selecting;
  R.set_turn_cascade_state ~base_path:bp keeper_name R.Cascade_trying;
  R.set_turn_cascade_state ~base_path:bp keeper_name R.Cascade_done

let test_mark_sdk_turn_started_resets_after_finalizing () =
  R.clear ();
  let keeper_name = "k-rfc-0045-reset" in
  ignore (R.register ~base_path:bp keeper_name (make_meta keeper_name));
  drive_turn_to_finalizing keeper_name;
  R.mark_sdk_turn_started ~base_path:bp keeper_name;
  match R.get ~base_path:bp keeper_name with
  | None -> fail "entry missing after mark_sdk_turn_started"
  | Some entry ->
    (match entry.R.current_turn_observation with
     | None -> fail "observation cleared by mark_sdk_turn_started"
     | Some obs ->
       check bool "turn_phase reset to Turn_prompting" true
         (obs.R.turn_phase = R.Turn_prompting);
       check bool "cascade_state reset to Cascade_idle" true
         (obs.R.cascade_state = R.Cascade_idle);
       check bool "decision_stage reset to Decision_undecided" true
         (obs.R.decision_stage = R.Decision_undecided))

let test_mark_sdk_turn_started_preserves_keeper_scope () =
  R.clear ();
  let keeper_name = "k-rfc-0045-preserve" in
  ignore (R.register ~base_path:bp keeper_name (make_meta keeper_name));
  drive_turn_to_finalizing keeper_name;
  let started_at_before, turn_id_before =
    match R.get ~base_path:bp keeper_name with
    | Some { current_turn_observation = Some obs; _ } ->
      (obs.R.started_at, obs.R.turn_id)
    | _ -> fail "obs missing before SDK boundary"
  in
  R.mark_sdk_turn_started ~base_path:bp keeper_name;
  match R.get ~base_path:bp keeper_name with
  | Some { current_turn_observation = Some obs; _ } ->
    check int "turn_id preserved across SDK boundary"
      turn_id_before obs.R.turn_id;
    check (float 1e-6) "started_at preserved" started_at_before obs.R.started_at
  | _ -> fail "obs missing after SDK boundary"

let test_mark_sdk_turn_started_no_op_without_obs () =
  R.clear ();
  let keeper_name = "k-rfc-0045-no-obs" in
  ignore (R.register ~base_path:bp keeper_name (make_meta keeper_name));
  (* No mark_turn_started has been called yet. *)
  R.mark_sdk_turn_started ~base_path:bp keeper_name;
  match R.get ~base_path:bp keeper_name with
  | Some { current_turn_observation = None; _ } -> ()
  | Some { current_turn_observation = Some _; _ } ->
    fail "mark_sdk_turn_started installed observation without keeper-turn"
  | None -> fail "entry missing"

(* The production [Assert_failure] at keeper_registry.ml:775 was triggered
   when the SDK fired [before_turn_params] for a second time inside one
   keeper-turn.  This test reproduces the same shape: two
   [set_turn_cascade_state(Cascade_selecting)] calls separated by a
   [Cascade_done] terminal, with [mark_sdk_turn_started] used as the
   boundary.  Without the RFC-0045 boundary call this test would crash
   on the second [set_turn_cascade_state]. *)
let test_two_sdk_turn_boundaries_no_assert () =
  R.clear ();
  let keeper_name = "k-rfc-0045-two-boundaries" in
  ignore (R.register ~base_path:bp keeper_name (make_meta keeper_name));
  drive_turn_to_finalizing keeper_name;
  (* Second SDK turn arrives via before_turn_params hook. *)
  R.mark_sdk_turn_started ~base_path:bp keeper_name;
  R.set_turn_decision_stage
    ~base_path:bp keeper_name R.Decision_tool_policy_selected;
  R.set_turn_cascade_state ~base_path:bp keeper_name R.Cascade_selecting;
  match R.get ~base_path:bp keeper_name with
  | Some { current_turn_observation = Some obs; _ } ->
    check bool "second SDK turn lands in Cascade_selecting / Turn_prompting" true
      (obs.R.cascade_state = R.Cascade_selecting
       && obs.R.turn_phase = R.Turn_prompting)
  | _ -> fail "obs missing after second SDK boundary"

let test_effective_keepalive_meta_prefers_disk_when_present () =
  R.clear ();
  let stale = make_meta "loop-meta-disk" in
  let registry_meta =
    {
      stale with
      continuity_summary = "registry continuity";
      runtime =
        {
          stale.runtime with
          usage = { stale.runtime.usage with total_turns = 3 };
        };
    }
  in
  let disk_meta =
    {
      stale with
      continuity_summary = "disk continuity";
      runtime =
        {
          stale.runtime with
          usage = { stale.runtime.usage with total_turns = 11 };
        };
    }
  in
  ignore (R.register ~base_path:bp "loop-meta-disk" registry_meta);
  let chosen =
    KK.effective_keepalive_meta
      ~base_path:bp
      ~fallback:stale
      ~disk_meta_opt:(Some disk_meta)
  in
  check string "continuity comes from disk" "disk continuity"
    chosen.continuity_summary;
  check int "turn count comes from disk" 11
    chosen.runtime.usage.total_turns

let () =
  run "Keeper_registry"
    [
      ( "basic",
        [
          eio_test "bonsai summary uses scoped registry"
            test_bonsai_keepers_summary_uses_scoped_registry;
          eio_test "register and get" test_register_and_get;
          eio_test "register offline and start" test_register_offline_and_start;
          eio_test "register restarting and start" test_register_restarting_and_start;
          eio_test "prepare fiber launch resets stale latches"
            test_prepare_fiber_launch_resets_stale_runtime_latches;
          eio_test "dispatch event with audit preserves snapshot"
            test_dispatch_event_with_audit_preserves_snapshot;
          eio_test "mark_turn_finished records completed turn outcome once"
            test_mark_turn_finished_records_completed_turn_outcome_once;
          eio_test "mark_turn_finished resets fiber_wakeup (IR-1)"
            test_mark_turn_finished_resets_wakeup;
          eio_test "mark_turn_finished updates last_turn_ts"
            test_mark_turn_finished_updates_last_turn_ts;
          eio_test "completed turns replay from default store"
            test_completed_turns_replay_from_default_store;
          eio_test "unregister" test_unregister;
          eio_test "all" test_all;
          eio_test "update meta" test_update_meta;
          eio_test "set state" test_set_state;
          eio_test "dispatch event emits phase SSE"
            test_dispatch_event_emits_phase_sse;
          eio_test "dispatch event emits lifecycle metric only on phase change"
            test_dispatch_event_emits_lifecycle_transition_metric_only_on_phase_change;
          eio_test "dispatch event observes phase SSE broadcast failure"
            test_dispatch_event_observes_phase_sse_broadcast_failure;
          eio_test "extended states" test_extended_states;
          eio_test "stopped entry action is observability-only"
            test_stopped_entry_action_is_observability_only;
          eio_test "overflow entry action promotes to compacting"
            test_overflow_entry_action_promotes_to_compacting;
          eio_test "count running" test_count_running;
          eio_test "count running atomic transitions" test_count_running_atomic_transitions;
          eio_test "record restart" test_record_restart;
          eio_test "is_registered" test_is_registered;
          eio_test "record error" test_record_error;
          eio_test "clear error" test_clear_error;
          eio_test "get returns None for missing" test_get_returns_none_for_missing;
          eio_test "noop on missing keys" test_noop_on_missing;
          eio_test "register replaces existing" test_register_replaces;
          eio_test "dequeue event consumes FIFO"
            test_dequeue_event_consumes_fifo;
          eio_test "dequeue event respects base path and missing keeper"
            test_dequeue_event_respects_base_path_and_missing_keeper;
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
          eio_test "try_resolve_done wins once" test_try_resolve_done_wins_once;
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
      ( "orphan_observability",
        [
          eio_test "update_entry orphan drops emit metrics + edge breach"
            test_update_entry_orphan_drop_emits_metrics;
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
          eio_test "keeper-name directive alias" test_directive_keeper_name_alias;
          eio_test "claim directive" test_directive_claim;
          eio_test "pause directive persists meta" test_directive_pause_persists_meta;
          eio_test "claim directive persists meta" test_directive_claim_persists_meta;
          eio_test "unknown directive no crash" test_directive_unknown_no_crash;
          eio_test "nonexistent agent no crash" test_directive_nonexistent_agent;
          eio_test "stop keepalive scoped to base_path"
            test_stop_keepalive_scoped_to_base_path;
          eio_test "wakeup keeper scoped to base_path"
            test_wakeup_keeper_scoped_to_base_path;
          eio_test "wakeup all scoped to base_path"
            test_wakeup_all_scoped_to_base_path;
          eio_test "board wakeup ignores unmatched posts without opt-in"
            test_board_signal_wakeup_ignores_unmatched_posts_without_opt_in;
          eio_test "board wakeup only wakes opted-in scope keeper"
            test_board_signal_wakeup_only_wakes_opted_in_scope_keeper;
          eio_test "board wakeup keeps thread reply after self comment"
            test_board_signal_wakeup_keeps_thread_reply_after_self_comment;
          eio_test "effective keepalive meta prefers registry when disk unchanged"
            test_effective_keepalive_meta_prefers_registry_when_disk_unchanged;
          eio_test "effective keepalive meta prefers disk when present"
            test_effective_keepalive_meta_prefers_disk_when_present;
        ] );
      ( "rfc_0045_sdk_turn_boundary",
        [
          eio_test "mark_sdk_turn_started resets in-turn FSM after Turn_finalizing"
            test_mark_sdk_turn_started_resets_after_finalizing;
          eio_test "mark_sdk_turn_started preserves keeper-turn-scoped data"
            test_mark_sdk_turn_started_preserves_keeper_scope;
          eio_test "mark_sdk_turn_started no-op without observation"
            test_mark_sdk_turn_started_no_op_without_obs;
          eio_test "two SDK-turn boundaries inside one keeper-turn"
            test_two_sdk_turn_boundaries_no_assert;
        ] );
    ]
