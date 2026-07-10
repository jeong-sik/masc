(** Golden tests for the composite observer surfacing registry state that
    previously existed in [Keeper_registry.registry_entry] but was never
    emitted in [snapshot_to_json] (A-PR-2 observability gaps G2/G5/G10):

    - live_turn [selected_model] / [active_tool_count] (G2)
    - [last_skip] {ts, reasons} (G5)
    - [board_cursor] {ts, post_id} and [board_wakeups] count (G10)

    Each case drives the registry through its public mutators, then asserts
    the projected JSON. The observer is a pure projection, so these tests
    pin the wire shape without exercising the full keepalive loop. *)

open Alcotest
module Keeper_registry = Masc.Keeper_registry
module Observer = Masc.Keeper_composite_observer
module J = Yojson.Safe.Util

let temp_base () =
  let d = Filename.temp_file "keeper_composite_surface_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("agent-" ^ name));
          ("trace_id", `String ("trace-" ^ name));
          ("allowed_paths", `List [ `String "*" ]);
        ])
  with
  | Ok meta -> meta
  | Error e -> failwith ("make_meta failed: " ^ e)
;;

(* Register a keeper and return the fresh entry after [setup] has run its
   registry mutations, so the observer sees the mutated SSOT. *)
let observed_json ~base ~name ~setup () =
  ignore (Keeper_registry.register ~base_path:base name (make_meta name));
  setup ();
  match Keeper_registry.get ~base_path:base name with
  | Some entry -> Observer.snapshot_to_json (Observer.observe entry)
  | None -> failwith "keeper vanished from registry after register"
;;

(* ── G2: live turn surfaces the selected model and active tool count ── *)

let test_live_turn_surfaces_model_and_tools () =
  let base = temp_base () in
  let name = "live-keeper" in
  let json =
    observed_json ~base ~name
      ~setup:(fun () ->
        Keeper_registry.mark_turn_started ~base_path:base
          ~wake:Keeper_registry.Proactive_tick name;
        Keeper_registry.set_turn_selected_model ~base_path:base name
          (Some "claude-sonnet");
        Keeper_registry.record_turn_tool_inflight ~base_path:base name ~count:3)
      ()
  in
  check bool "is_live true" true (J.member "is_live" json |> J.to_bool);
  let live = J.member "live_turn" json in
  (match live with
   | `Null -> fail "live_turn should be present while a turn is active"
   | _ -> ());
  check string "live_turn.selected_model surfaced" "claude-sonnet"
    (J.member "selected_model" live |> J.to_string);
  check int "live_turn.active_tool_count surfaced" 3
    (J.member "active_tool_count" live |> J.to_int)
;;

let test_live_turn_model_null_before_selection () =
  let base = temp_base () in
  let name = "live-nomodel" in
  let json =
    observed_json ~base ~name
      ~setup:(fun () ->
        Keeper_registry.mark_turn_started ~base_path:base
          ~wake:Keeper_registry.Proactive_tick name)
      ()
  in
  let live = J.member "live_turn" json in
  check bool "selected_model is JSON null before routing" true
    (match J.member "selected_model" live with `Null -> true | _ -> false);
  check int "active_tool_count defaults to 0" 0
    (J.member "active_tool_count" live |> J.to_int)
;;

(* ── G5: idle keeper surfaces the most recent skip verdict ──────────── *)

let test_last_skip_surfaced () =
  let base = temp_base () in
  let name = "skip-keeper" in
  let reasons = [ "cooldown_pending"; "no_signal" ] in
  let json =
    observed_json ~base ~name
      ~setup:(fun () ->
        Keeper_registry.record_skip_reasons ~base_path:base name ~reasons)
      ()
  in
  let skip = J.member "last_skip" json in
  (match skip with
   | `Null -> fail "last_skip should be present after a recorded skip"
   | _ -> ());
  check (list string) "last_skip.reasons preserved in order" reasons
    (J.member "reasons" skip |> J.to_list |> List.map J.to_string);
  check bool "last_skip.ts is a float" true
    (match J.member "ts" skip with `Float _ -> true | _ -> false)
;;

(* ── G10: board cursor + wakeup ledger cardinality ──────────────────── *)

let test_board_cursor_and_wakeups () =
  let base = temp_base () in
  let name = "board-keeper" in
  let json =
    observed_json ~base ~name
      ~setup:(fun () ->
        Keeper_registry.set_board_cursor ~base_path:base name 1234.5
          (Some "post-42");
        ignore
          (Keeper_registry.board_wakeup_allowed ~base_path:base name
             ~dedup_key:"fingerprint-a" ~debounce_sec:60.0);
        ignore
          (Keeper_registry.board_wakeup_allowed ~base_path:base name
             ~dedup_key:"fingerprint-b" ~debounce_sec:60.0))
      ()
  in
  let cursor = J.member "board_cursor" json in
  check (float 1e-6) "board_cursor.ts surfaced" 1234.5
    (J.member "ts" cursor |> J.to_float);
  check string "board_cursor.post_id surfaced" "post-42"
    (J.member "post_id" cursor |> J.to_string);
  check int "board_wakeups counts distinct dedup keys" 2
    (J.member "board_wakeups" json |> J.to_int)
;;

(* ── #16 (38-bug campaign PR-5): run_state / wake surfacing ──────────── *)

let test_run_state_in_turn_reports_woken_wake () =
  let base = temp_base () in
  let name = "woken-keeper" in
  let json =
    observed_json ~base ~name
      ~setup:(fun () ->
        Keeper_registry.mark_turn_started ~base_path:base
          ~wake:
            (Keeper_registry.Woken
               [ Masc.Keeper_event_queue.Bootstrap
               ; Masc.Keeper_event_queue.No_progress_recovery
               ])
          name)
      ()
  in
  let rs = J.member "run_state" json in
  check string "run_state.kind is in_turn" "in_turn"
    (J.member "kind" rs |> J.to_string);
  check string "run_state.wake_kind is woken" "woken"
    (J.member "wake_kind" rs |> J.to_string);
  check (list string) "run_state.stimulus_kinds preserves order"
    [ "bootstrap"; "no_progress_recovery" ]
    (J.member "stimulus_kinds" rs |> J.to_list |> List.map J.to_string);
  check bool "run_state.started_at is a float" true
    (match J.member "started_at" rs with `Float _ -> true | _ -> false)
;;

let test_run_state_in_turn_reports_proactive_tick () =
  let base = temp_base () in
  let name = "proactive-keeper" in
  let json =
    observed_json ~base ~name
      ~setup:(fun () ->
        Keeper_registry.mark_turn_started ~base_path:base
          ~wake:Keeper_registry.Proactive_tick name)
      ()
  in
  let rs = J.member "run_state" json in
  check string "run_state.wake_kind is proactive_tick" "proactive_tick"
    (J.member "wake_kind" rs |> J.to_string);
  check (list string) "run_state.stimulus_kinds is empty" []
    (J.member "stimulus_kinds" rs |> J.to_list |> List.map J.to_string)
;;

let test_run_state_waiting_when_running_idle () =
  let base = temp_base () in
  let name = "waiting-keeper" in
  let json = observed_json ~base ~name ~setup:(fun () -> ()) () in
  let rs = J.member "run_state" json in
  check string "run_state.kind is waiting for a Running keeper with no live turn"
    "waiting" (J.member "kind" rs |> J.to_string);
  check int "run_state.queue_depth is 0 for a fresh keeper" 0
    (J.member "queue_depth" rs |> J.to_int)
;;

let test_run_state_suspended_for_non_running_phase () =
  let base = temp_base () in
  let name = "offline-keeper" in
  ignore (Keeper_registry.register_offline ~base_path:base name (make_meta name));
  let json =
    match Keeper_registry.get ~base_path:base name with
    | Some entry -> Observer.snapshot_to_json (Observer.observe entry)
    | None -> failwith "keeper vanished from registry after register_offline"
  in
  let rs = J.member "run_state" json in
  check string "run_state.kind is suspended for an Offline keeper" "suspended"
    (J.member "kind" rs |> J.to_string);
  check string "run_state.phase mirrors the raw phase" "offline"
    (J.member "phase" rs |> J.to_string)
;;

(* ── Idle default shape: additive fields degrade to null/zero ───────── *)

let test_idle_defaults_are_null_or_zero () =
  let base = temp_base () in
  let name = "idle-keeper" in
  let json = observed_json ~base ~name ~setup:(fun () -> ()) () in
  check bool "live_turn null when idle" true
    (match J.member "live_turn" json with `Null -> true | _ -> false);
  check bool "last_skip null before any skip" true
    (match J.member "last_skip" json with `Null -> true | _ -> false);
  check bool "livelock null when not in a livelock" true
    (match J.member "livelock" json with `Null -> true | _ -> false);
  let cursor = J.member "board_cursor" json in
  check (float 1e-6) "board_cursor.ts defaults to 0.0" 0.0
    (J.member "ts" cursor |> J.to_float);
  check bool "board_cursor.post_id null before consumption" true
    (match J.member "post_id" cursor with `Null -> true | _ -> false);
  check int "board_wakeups defaults to 0" 0
    (J.member "board_wakeups" json |> J.to_int)
;;

let () =
  run "keeper_composite_live_turn_surface"
    [
      ( "live_turn",
        [
          test_case "surfaces selected model and active tool count" `Quick
            test_live_turn_surfaces_model_and_tools;
          test_case "model null before runtime selection" `Quick
            test_live_turn_model_null_before_selection;
        ] );
      ( "last_skip",
        [ test_case "surfaces recent skip verdict" `Quick test_last_skip_surfaced ]
      );
      ( "run_state",
        [
          test_case "in_turn reports the woken wake and its stimuli" `Quick
            test_run_state_in_turn_reports_woken_wake;
          test_case "in_turn reports the proactive tick wake" `Quick
            test_run_state_in_turn_reports_proactive_tick;
          test_case "waiting for a Running keeper with no live turn" `Quick
            test_run_state_waiting_when_running_idle;
          test_case "suspended for a non-Running phase" `Quick
            test_run_state_suspended_for_non_running_phase;
        ] );
      ( "board",
        [
          test_case "surfaces cursor and wakeup cardinality" `Quick
            test_board_cursor_and_wakeups;
        ] );
      ( "defaults",
        [
          test_case "idle additive fields are null or zero" `Quick
            test_idle_defaults_are_null_or_zero;
        ] );
    ]
;;
