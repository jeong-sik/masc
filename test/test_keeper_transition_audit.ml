(** Negative / edge-case tests for Keeper_transition_audit.
    These cover the paths that PR #9686 added but didn't test. *)

open Alcotest

module Audit = Masc.Keeper_transition_audit
module KTF = Masc.Keeper_turn_fsm
module KSM = Keeper_state_machine
module P = Masc.Otel_metric_store

let fail = Alcotest.fail

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_transition_audit_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let with_env key value f =
  let old_value = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old_value with
      | Some old -> Unix.putenv key old
      | None -> Unix.putenv key "")
    f

let test_runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}

let ensure_test_runtime =
  let initialized = ref false in
  fun () ->
    if not !initialized then (
      let path = Filename.temp_file "keeper_transition_audit_runtime_" ".toml" in
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc test_runtime_toml);
      Fun.protect
        ~finally:(fun () ->
          try Sys.remove path with
          | Sys_error _ -> ())
        (fun () ->
          match Runtime.init_default ~config_path:path with
          | Ok () -> initialized := true
          | Error msg -> fail msg))

let keeper_meta name =
  ensure_test_runtime ();
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String (name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
          ("runtime_id", `String Masc.(Keeper_config.default_runtime_id ()));
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let transition ?(prev_phase = KSM.Running) ?(new_phase = KSM.Paused)
    ?(selected_event = KSM.Operator_pause) () : Audit.transition_record =
  {
    Audit.snapshot = None;
    events_fired = [ selected_event ];
    selected_event;
    prev_phase;
    new_phase;
    transition_outcome = "applied";
    wall_clock_at_decision = 1_712_000_000.5;
  }

let transition_audit_failure_count site =
  P.metric_value_or_zero Keeper_metrics.(to_string TransitionAuditFailures)
    ~labels:[("site", site)]
    ()

let with_invalid_default_store f =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Audit.For_testing.reset_state ();
      cleanup_dir base_dir)
    (fun () ->
      let base_file = Filename.concat base_dir "not-a-dir" in
      let oc = open_out base_file in
      close_out oc;
      with_env "MASC_KEEPER_TRANSITION_LOG" "" (fun () ->
          with_env "MASC_BASE_PATH" base_file (fun () ->
              with_env "MASC_BASE_PATH_INPUT" base_file f)))

let read_jsonl path =
  let ic = open_in path in
  let rec loop acc =
    match input_line ic with
    | line -> loop (Yojson.Safe.from_string line :: acc)
    | exception End_of_file -> List.rev acc
  in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> loop [])

(* ── Helpers to exercise the JSON round-trip via store ─────────── *)

let test_recent_completed_turns_empty_store () =
  Audit.For_testing.reset_state ();
  let turns = Audit.recent_completed_turns ~keeper_name:"never-seen" ~limit:5 in
  check int "empty store returns []" 0 (List.length turns)

let test_record_and_read_multiple_turns () =
  Audit.For_testing.reset_state ();
  let keeper_name = "multi-turn-keeper" in
  for i = 1 to 3 do
    Audit.record_completed_turn ~keeper_name
      {
        Audit.turn_id = i;
        started_at = float_of_int (i * 10);
        ended_at = float_of_int (i * 10 + 5);
        outcome = Audit.Turn_failed;
      }
  done;
  let turns = Audit.recent_completed_turns ~keeper_name ~limit:5 in
  check int "3 turns recorded" 3 (List.length turns);
  List.iteri
    (fun idx turn ->
      let expected_id = 3 - idx in
      check int (Printf.sprintf "turn %d id" idx) expected_id turn.Audit.turn_id)
    turns

let test_ring_capacity_limit () =
  Audit.For_testing.reset_state ();
  let keeper_name = "capacity-keeper" in
  for i = 1 to 55 do
    Audit.record_completed_turn ~keeper_name
      {
        Audit.turn_id = i;
        started_at = float_of_int i;
        ended_at = float_of_int (i + 1);
        outcome = Audit.Turn_failed;
      }
  done;
  let turns = Audit.recent_completed_turns ~keeper_name ~limit:100 in
  check int "ring capacity caps at 50" 50 (List.length turns);
  (* newest should be 55, oldest in result should be 6 *)
  match turns with
  | newest :: _ -> check int "newest is 55" 55 newest.Audit.turn_id
  | [] -> fail "expected at least one turn"

let test_ring_ordering_is_newest_first () =
  Audit.For_testing.reset_state ();
  let keeper_name = "order-keeper" in
  Audit.record_completed_turn ~keeper_name
    { Audit.turn_id = 1; started_at = 1.0; ended_at = 2.0; outcome = Audit.Turn_substantive };
  Audit.record_completed_turn ~keeper_name
    { Audit.turn_id = 2; started_at = 3.0; ended_at = 4.0; outcome = Audit.Turn_failed };
  let turns = Audit.recent_completed_turns ~keeper_name ~limit:2 in
  check int "first is newest" 2 (List.hd turns).Audit.turn_id;
  check int "second is older" 1 (List.nth turns 1).Audit.turn_id

let test_limit_respected () =
  Audit.For_testing.reset_state ();
  let keeper_name = "limit-keeper" in
  for i = 1 to 10 do
    Audit.record_completed_turn ~keeper_name
      {
        Audit.turn_id = i;
        started_at = float_of_int i;
        ended_at = float_of_int (i + 1);
        outcome = Audit.Turn_substantive;
      }
  done;
  let turns = Audit.recent_completed_turns ~keeper_name ~limit:3 in
  check int "limit respected" 3 (List.length turns);
  check int "newest within limit" 10 (List.hd turns).Audit.turn_id

let test_transition_json_preserves_observation_only () =
  let json = Audit.to_json (transition ()) in
  let open Yojson.Safe.Util in
  check string "event type" "operator_pause"
    (json |> member "event_type" |> to_string);
  check string "previous phase" "running" (json |> member "prev_phase" |> to_string);
  check string "new phase" "Paused" (json |> member "new_phase" |> to_string);
  check string "outcome" "applied"
    (json |> member "transition_outcome" |> to_string);
  check int "transition JSON has only observed fields" 8
    (match json with `Assoc fields -> List.length fields | _ -> 0)

let test_runtime_trust_timeline_carries_transition_observation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Audit.For_testing.reset_state ();
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Audit.For_testing.reset_state ();
      cleanup_dir base_dir)
    (fun () ->
      let sink = Filename.concat base_dir "transition-audit.jsonl" in
      with_env "MASC_KEEPER_TRANSITION_LOG" sink (fun () ->
          let keeper_name = "runtime-trust-transition-observation" in
          let config = Masc.Workspace.default_config base_dir in
          let meta = keeper_meta keeper_name in
          Audit.record_transition ~keeper_name (transition ());
          let snapshot =
            Masc.Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta
          in
          let open Yojson.Safe.Util in
          let event = snapshot |> member "latest_causal_event" in
          check string "latest event kind" "transition"
            (event |> member "kind" |> to_string);
          check bool "transition next action absent" true
            (event |> member "next_human_action" = `Null);
          check string "transition severity is informational" "info"
            (event |> member "severity" |> to_string);
          check bool "transition summary preserves outcome" true
            (String_util.contains_substring_ci
               (event |> member "summary" |> to_string)
               "outcome=applied")))

let test_turn_fsm_emit_transition_appends_wal_row () =
  Audit.For_testing.reset_state ();
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Audit.For_testing.reset_state ();
      cleanup_dir base_dir)
    (fun () ->
      let sink = Filename.concat base_dir "transition-audit.jsonl" in
      with_env "MASC_KEEPER_TRANSITION_LOG" sink (fun () ->
          KTF.emit_transition
            ~keeper_name:"turn-fsm-wal-keeper"
            ~turn_id:42
            ~prev:KTF.Streaming
            KTF.Completing;
          match read_jsonl sink with
          | [ json ] ->
            let open Yojson.Safe.Util in
            check string "keeper" "turn-fsm-wal-keeper"
              (json |> member "keeper" |> to_string);
            let row = json |> member "turn_fsm_transition" in
            check int "turn_id" 42 (row |> member "turn_id" |> to_int);
            check string "prev_state" "streaming"
              (row |> member "prev_state" |> to_string);
            check string "new_state" "completing"
              (row |> member "new_state" |> to_string);
            check string "action" "StreamComplete"
              (row |> member "action" |> to_string)
          | rows ->
            failf "expected one turn_fsm_transition row, got %d" (List.length rows)))

(* ── Async append queue ─────────────────────────────────────────── *)

let default_store_dir base_dir =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path:base_dir)
    "transition-audit"

(* With enqueue mode on, recording must not write the store inline (that
   inline write under shared locks is what parked 12 keepers in the
   2026-06-10 freeze); the row lands only when the drain runs. *)
let test_async_queue_defers_store_write_until_flush () =
  Audit.For_testing.reset_state ();
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Audit.For_testing.reset_state ();
      cleanup_dir base_dir)
    (fun () ->
      with_env "MASC_KEEPER_TRANSITION_LOG" "" (fun () ->
          with_env "MASC_BASE_PATH" base_dir (fun () ->
              with_env "MASC_BASE_PATH_INPUT" base_dir (fun () ->
                  Audit.For_testing.set_async_append_active true;
                  KTF.emit_transition
                    ~keeper_name:"async-queue-keeper"
                    ~turn_id:7
                    ~prev:KTF.Streaming
                    KTF.Completing;
                  check int "record queued, not yet flushed" 1
                    (Audit.For_testing.queued_count ());
                  check bool "store not written before flush" false
                    (Sys.file_exists (default_store_dir base_dir));
                  let written = Audit.flush_pending () in
                  check int "flush writes the queued record" 1 written;
                  check int "queue drained" 0 (Audit.For_testing.queued_count ());
                  check int "nothing dropped" 0 (Audit.For_testing.dropped_count ());
                  check bool "store materialized by flush" true
                    (Sys.file_exists (default_store_dir base_dir))))))

(* Synchronous fallback: before [start_flush_fiber] (tests, non-server
   embedders) recording appends inline, preserving previous behavior. *)
let test_sync_fallback_appends_inline () =
  Audit.For_testing.reset_state ();
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Audit.For_testing.reset_state ();
      cleanup_dir base_dir)
    (fun () ->
      with_env "MASC_KEEPER_TRANSITION_LOG" "" (fun () ->
          with_env "MASC_BASE_PATH" base_dir (fun () ->
              with_env "MASC_BASE_PATH_INPUT" base_dir (fun () ->
                  KTF.emit_transition
                    ~keeper_name:"sync-fallback-keeper"
                    ~turn_id:8
                    ~prev:KTF.Streaming
                    KTF.Completing;
                  check int "nothing queued in sync mode" 0
                    (Audit.For_testing.queued_count ());
                  check bool "store written inline" true
                    (Sys.file_exists (default_store_dir base_dir))))))

let test_default_transition_append_failure_is_observed_and_ring_retained () =
  Audit.For_testing.reset_state ();
  with_invalid_default_store (fun () ->
      let keeper_name = "default-transition-failure-keeper" in
      let before =
        transition_audit_failure_count "default_transition_append"
      in
      Audit.record_transition ~keeper_name (transition ());
      let after =
        transition_audit_failure_count "default_transition_append"
      in
      check (float 0.0001) "default transition append failure counted"
        (before +. 1.0) after;
      check int "ring still records transition" 1
        (List.length (Audit.recent_transitions ~keeper_name ~limit:5)))

let test_default_completed_append_failure_is_observed_and_ring_retained () =
  Audit.For_testing.reset_state ();
  with_invalid_default_store (fun () ->
      let keeper_name = "default-completed-failure-keeper" in
      let before =
        transition_audit_failure_count "default_completed_append"
      in
      Audit.record_completed_turn ~keeper_name
        {
          Audit.turn_id = 1;
          started_at = 1.0;
          ended_at = 2.0;
          outcome = Audit.Turn_failed;
        };
      let after =
        transition_audit_failure_count "default_completed_append"
      in
      check (float 0.0001) "default completed append failure counted"
        (before +. 1.0) after;
      check int "completed turn ring still records turn" 1
        (List.length
           (Audit.recent_completed_turns ~keeper_name ~limit:5)))

let test_sink_append_failure_is_observed_and_ring_retained () =
  Audit.For_testing.reset_state ();
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Audit.For_testing.reset_state ();
      cleanup_dir base_dir)
    (fun () ->
      let missing_parent = Filename.concat base_dir "missing-parent" in
      let sink = Filename.concat missing_parent "transition-audit.jsonl" in
      with_env "MASC_KEEPER_TRANSITION_LOG" sink (fun () ->
          let keeper_name = "sink-failure-keeper" in
          let before = transition_audit_failure_count "sink_append" in
          Audit.record_transition ~keeper_name (transition ());
          let after = transition_audit_failure_count "sink_append" in
          check (float 0.0001) "sink append failure counted"
            (before +. 1.0) after;
          check int "ring still records transition" 1
            (List.length
               (Audit.recent_transitions ~keeper_name ~limit:5))))

let test_completed_turn_sink_failure_is_observed_and_ring_retained () =
  Audit.For_testing.reset_state ();
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Audit.For_testing.reset_state ();
      cleanup_dir base_dir)
    (fun () ->
      let missing_parent = Filename.concat base_dir "missing-parent" in
      let sink = Filename.concat missing_parent "transition-audit.jsonl" in
      with_env "MASC_KEEPER_TRANSITION_LOG" sink (fun () ->
          let keeper_name = "completed-sink-failure-keeper" in
          let before =
            transition_audit_failure_count "sink_completed_append"
          in
          Audit.record_completed_turn ~keeper_name
            {
              Audit.turn_id = 1;
              started_at = 1.0;
              ended_at = 2.0;
              outcome = Audit.Turn_failed;
            };
          let after =
            transition_audit_failure_count "sink_completed_append"
          in
          check (float 0.0001) "completed sink append failure counted"
            (before +. 1.0) after;
          check int "completed turn ring still records turn" 1
            (List.length
               (Audit.recent_completed_turns ~keeper_name ~limit:5))))

let test_turn_fsm_sink_failure_is_observed () =
  Audit.For_testing.reset_state ();
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Audit.For_testing.reset_state ();
      cleanup_dir base_dir)
    (fun () ->
      let missing_parent = Filename.concat base_dir "missing-parent" in
      let sink = Filename.concat missing_parent "transition-audit.jsonl" in
      with_env "MASC_KEEPER_TRANSITION_LOG" sink (fun () ->
          let before = transition_audit_failure_count "sink_turn_fsm_append" in
          Audit.record_turn_fsm_transition
            ~keeper_name:"turn-fsm-sink-failure"
            { turn_fsm_turn_id = 1
            ; turn_fsm_prev_state = "Streaming"
            ; turn_fsm_new_state = "Completing"
            ; turn_fsm_action = "StreamComplete"
            ; turn_fsm_stop_signaled_before = None
            ; turn_fsm_stop_signaled_after = None
            ; turn_fsm_wall_clock_at = 1.0
            };
          let after = transition_audit_failure_count "sink_turn_fsm_append" in
          check (float 0.0001) "turn fsm sink append failure counted"
            (before +. 1.0) after))

let test_append_failure_observer_reraises_cancelled () =
  let raised = ref false in
  (try
     Audit.For_testing.observe_append_failure
       ~site:"unit_cancel"
       (Eio.Cancel.Cancelled (Failure "synthetic cancel"))
   with Eio.Cancel.Cancelled _ -> raised := true);
  check bool "cancel is re-raised" true !raised

(* ── Run ───────────────────────────────────────────────────────── *)

let () =
  run "Keeper_transition_audit"
    [
      ( "recent_completed_turns",
        [
          test_case "empty store" `Quick test_recent_completed_turns_empty_store;
          test_case "record and read multiple" `Quick test_record_and_read_multiple_turns;
          test_case "ring capacity limit" `Quick test_ring_capacity_limit;
          test_case "ring ordering newest first" `Quick test_ring_ordering_is_newest_first;
          test_case "limit respected" `Quick test_limit_respected;
        ] );
      ( "transition_observation",
        [
          test_case "operator pause remains an exact observation" `Quick
            test_transition_json_preserves_observation_only;
          test_case "runtime trust timeline carries observation" `Quick
            test_runtime_trust_timeline_carries_transition_observation;
          test_case "turn FSM emit appends WAL row" `Quick
            test_turn_fsm_emit_transition_appends_wal_row;
        ] );
      ( "async_append_queue",
        [
          test_case "enqueue defers store write until flush" `Quick
            test_async_queue_defers_store_write_until_flush;
          test_case "sync fallback appends inline" `Quick
            test_sync_fallback_appends_inline;
        ] );
      ( "append_failures",
        [
          test_case "default transition append failure observed and ring retained" `Quick
            test_default_transition_append_failure_is_observed_and_ring_retained;
          test_case "default completed append failure observed and ring retained" `Quick
            test_default_completed_append_failure_is_observed_and_ring_retained;
          test_case "sink append failure observed and ring retained" `Quick
            test_sink_append_failure_is_observed_and_ring_retained;
          test_case "completed sink append failure observed and ring retained" `Quick
            test_completed_turn_sink_failure_is_observed_and_ring_retained;
          test_case "turn FSM sink failure observed" `Quick
            test_turn_fsm_sink_failure_is_observed;
          test_case "observer re-raises cancellation" `Quick
            test_append_failure_observer_reraises_cancelled;
        ] );
    ]
