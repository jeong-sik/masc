(** Tests for [Cascade_attempt_liveness_observer] (RFC-0022 PR-2/4 §4-6).

    Coverage:
    - Counter increments per outcome (kill_total + observed_total).
    - [Observe] mode: never raises and does not Switch.fail (RFC §4
      structural contract).
    - [Enforce] mode: raises [Liveness_kill] via Switch.fail on Outcome.
    - [Off] mode: wrap_on_event returns the original callback verbatim.
    - Tick fiber is explicitly stopped when the provider attempt ends
      without a terminal stream event (Eio resource ledger). *)

open Masc_mcp
module L = Cascade_attempt_liveness
module Cfg = Cascade_attempt_liveness_config
module Obs = Cascade_attempt_liveness_observer

(* -- helpers ------------------------------------------------------- *)

let mk_observer ?(mode = Cfg.Observe) ?(budget = L.bootstrap)
    ?(cascade = "test_cascade") ?(provider = "test_provider")
    ?candidate_key ?(started_at = 0.0) () =
  ignore provider;
  Obs.create ~mode ~budget ~cascade_label:cascade ?candidate_key ~started_at ()

let public_provider = "runtime"

let counter_value name labels =
  Prometheus.metric_value_or_zero name ~labels ()

let kill_value mode kind cascade provider =
  counter_value Prometheus.metric_cascade_attempt_liveness_kill
    [
      ("mode", mode);
      ("kind", kind);
      ("cascade", cascade);
      ("provider", provider);
    ]

let observed_value cascade provider outcome =
  counter_value Prometheus.metric_cascade_attempt_liveness_observed
    [
      ("cascade", cascade);
      ("provider", provider);
      ("outcome", outcome);
    ]

let stop = Agent_sdk.Types.MessageStop

(* -- Off mode: wrap_on_event returns the original ------------------ *)

let test_off_returns_original () =
  let obs = mk_observer ~mode:Cfg.Off () in
  let original = Some (fun (_ : Agent_sdk.Types.sse_event) -> ()) in
  let wrapped = Obs.wrap_on_event obs original in
  Alcotest.(check bool)
    "Off returns original (physical equality)" true (wrapped == original)

let test_off_finalize_is_noop () =
  let cascade = "off_cascade_finalize" in
  let provider = "off_provider_finalize" in
  let obs = mk_observer ~mode:Cfg.Off ~cascade ~provider () in
  let before = observed_value cascade public_provider "success" in
  Obs.finalize obs;
  let after = observed_value cascade public_provider "success" in
  Alcotest.(check (float 1e-6))
    "Off finalize emits no observed counter" before after

(* -- Observe mode: counter emitted, no raise ---------------------- *)

let test_observe_emits_kill_counter_no_raise () =
  let cascade = "observe_kill_cascade" in
  let provider = "observe_kill_provider" in
  (* TTFT 30s, force a Tick at t=40 to trigger No_first_token. *)
  let obs =
    mk_observer ~mode:Cfg.Observe ~cascade ~provider ~started_at:0.0 ()
  in
  (* Manually exercise the FSM via a Provider_wire_error event so we
     stay synchronous and deterministic — Observe must counter+log
     but never raise. *)
  let original_calls = ref 0 in
  let original = Some (fun (_ : Agent_sdk.Types.sse_event) -> incr original_calls) in
  let wrapped = Obs.wrap_on_event obs original in
  match wrapped with
  | None -> Alcotest.fail "Observe should return Some wrapper"
  | Some f ->
      let before =
        kill_value "observe" "provider_error" cascade public_provider
      in
      f (Agent_sdk.Types.SSEError "boom");
      let after =
        kill_value "observe" "provider_error" cascade public_provider
      in
      Alcotest.(check int) "original called" 1 !original_calls;
      Alcotest.(check (float 1e-6))
        "Observe wire_error emits kill counter" (before +. 1.0) after;
      (* Observe must reach Failed without raising. *)
      (match Obs.current_state_for_test obs with
       | L.Failed (L.Provider_error _) -> ()
       | _ -> Alcotest.fail "expected Failed Provider_error")

let test_observe_parse_failure_is_wire_error () =
  let cascade = "observe_parse_failure_cascade" in
  let provider = "observe_parse_failure_provider" in
  let obs =
    mk_observer ~mode:Cfg.Observe ~cascade ~provider ~started_at:0.0 ()
  in
  let wrapped = Obs.wrap_on_event obs None in
  match wrapped with
  | None -> Alcotest.fail "Observe should return Some wrapper"
  | Some f ->
      let before =
        kill_value "observe" "provider_error" cascade public_provider
      in
      f (Agent_sdk.Types.SSEParseFailed { raw = "{not json"; reason = "json" });
      let after =
        kill_value "observe" "provider_error" cascade public_provider
      in
      Alcotest.(check (float 1e-6))
        "SSE parse failure emits provider_error kill counter"
        (before +. 1.0) after;
      (match Obs.current_state_for_test obs with
       | L.Failed (L.Provider_error _) -> ()
       | _ -> Alcotest.fail "expected Failed Provider_error")

let test_observe_done_completes () =
  let cascade = "observe_done_cascade" in
  let provider = "observe_done_provider" in
  let obs =
    mk_observer ~mode:Cfg.Observe ~cascade ~provider ~started_at:0.0 ()
  in
  let wrapped = Obs.wrap_on_event obs None in
  match wrapped with
  | None -> Alcotest.fail "Observe should return Some wrapper"
  | Some f ->
      f stop;
      Alcotest.(check bool)
        "Done -> Success state" true
        (match Obs.current_state_for_test obs with
         | L.Success -> true
         | _ -> false)

let test_observe_finalize_emits_outcome () =
  let cascade = "observe_finalize_cascade" in
  let provider = "observe_finalize_provider" in
  let obs =
    mk_observer ~mode:Cfg.Observe ~cascade ~provider ~started_at:0.0 ()
  in
  let wrapped = Obs.wrap_on_event obs None in
  (match wrapped with
   | Some f -> f stop
   | None -> Alcotest.fail "wrapper missing");
  let before = observed_value cascade public_provider "success" in
  Obs.finalize obs;
  let after = observed_value cascade public_provider "success" in
  Alcotest.(check (float 1e-6))
    "finalize emits success outcome" (before +. 1.0) after;
  (* Idempotent. *)
  Obs.finalize obs;
  let after2 = observed_value cascade public_provider "success" in
  Alcotest.(check (float 1e-6))
    "finalize is idempotent" after after2

let test_success_sample_waits_for_accept_gate () =
  let candidate_key = "provider:model-a" in
  Cfg.reset_success_history_for_test ();
  let obs =
    mk_observer
      ~mode:Cfg.Observe
      ~candidate_key
      ~started_at:(Time_compat.now ())
      ()
  in
  let wrapped = Obs.wrap_on_event obs None in
  (match wrapped with
   | Some f -> f stop
   | None -> Alcotest.fail "wrapper missing");
  Obs.finalize obs;
  Alcotest.(check bool)
    "finalize exposes a success sample"
    true
    (match Obs.success_sample_for_candidate obs with
     | Some (key, _) -> String.equal key candidate_key
     | None -> false);
  Alcotest.(check int)
    "observer does not train budget before accept"
    0
    (Cfg.success_sample_count_for_test ~candidate_key)

let test_observe_finalize_pending_is_wire_error () =
  let cascade = "observe_pending_cascade" in
  let provider = "observe_pending_provider" in
  let obs =
    mk_observer ~mode:Cfg.Observe ~cascade ~provider ~started_at:0.0 ()
  in
  let before = observed_value cascade public_provider "wire_error" in
  Obs.finalize obs;
  let after = observed_value cascade public_provider "wire_error" in
  Alcotest.(check (float 1e-6))
    "Awaiting at finalize -> wire_error" (before +. 1.0) after

(* -- Enforce mode: Switch.fail raised ---------------------------- *)

let test_enforce_switch_fail () =
  let cascade = "enforce_cascade" in
  let provider = "enforce_provider" in
  let raised = ref None in
  Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      try
        Eio.Switch.run (fun sw ->
            let obs =
              mk_observer ~mode:Cfg.Enforce ~cascade ~provider
                ~started_at:0.0 ()
            in
            Obs.start_tick_fiber obs ~sw ~clock;
            let wrapped = Obs.wrap_on_event obs None in
            (match wrapped with
             | Some f -> f (Agent_sdk.Types.SSEError "wire boom")
             | None -> Alcotest.fail "Enforce wrapper missing");
            (* Allow the Switch.fail to propagate. *)
            Eio.Fiber.yield ())
      with
      | Obs.Liveness_kill failure ->
          raised := Some (L.failure_kind_label failure)
      | exn ->
          Alcotest.failf "unexpected exception: %s" (Printexc.to_string exn));
  Alcotest.(check (option string))
    "Liveness_kill raised in Enforce mode"
    (Some "provider_error") !raised

(* -- Tick fiber lifetime ----------------------------------------- *)

let test_tick_fiber_dies_with_switch () =
  (* Build observer in Observe mode (no kill), start tick fiber, then
     close the switch. Eio's structured concurrency guarantees fiber
     teardown — if the fiber leaks, Switch.run would hang. *)
  Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run (fun sw ->
          let obs =
            mk_observer ~mode:Cfg.Observe ~started_at:0.0 ()
          in
          Obs.start_tick_fiber obs ~sw ~clock;
          (* Force the FSM terminal so the loop exits naturally too. *)
          let wrapped = Obs.wrap_on_event obs None in
          (match wrapped with
           | Some f -> f stop
           | None -> ());
          Eio.Fiber.yield ()));
  Alcotest.(check bool) "Switch.run returned cleanly" true true

let test_tick_fiber_stops_without_terminal_event () =
  (* A provider can return an API error before any SSE terminal event.
     The attempt owner must be able to stop the tick loop immediately;
     otherwise Switch.run waits for the long bootstrap TTFT tick. *)
  Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      Eio.Time.with_timeout_exn clock 0.5 (fun () ->
          Eio.Switch.run (fun sw ->
              let obs =
                mk_observer ~mode:Cfg.Enforce ~started_at:(Time_compat.now ()) ()
              in
              Obs.start_tick_fiber obs ~sw ~clock;
              Obs.stop_tick_fiber obs;
              Eio.Fiber.yield ())));
  Alcotest.(check bool)
    "pending tick fiber stopped before bootstrap tick" true true

let () =
  Alcotest.run "cascade_attempt_liveness_observer"
    [
      ( "off",
        [
          Alcotest.test_case "wrap returns original" `Quick
            test_off_returns_original;
          Alcotest.test_case "finalize noop" `Quick test_off_finalize_is_noop;
        ] );
      ( "observe",
        [
          Alcotest.test_case "wire_error emits kill counter, no raise"
            `Quick test_observe_emits_kill_counter_no_raise;
          Alcotest.test_case "parse failure is wire_error" `Quick
            test_observe_parse_failure_is_wire_error;
          Alcotest.test_case "Done completes to Success" `Quick
            test_observe_done_completes;
          Alcotest.test_case "finalize emits outcome and is idempotent"
            `Quick test_observe_finalize_emits_outcome;
          Alcotest.test_case "success sample waits for accept gate" `Quick
            test_success_sample_waits_for_accept_gate;
          Alcotest.test_case "pending finalize -> wire_error" `Quick
            test_observe_finalize_pending_is_wire_error;
        ] );
      ( "enforce",
        [
          Alcotest.test_case "Outcome -> Switch.fail Liveness_kill" `Quick
            test_enforce_switch_fail;
        ] );
      ( "lifetime",
        [
          Alcotest.test_case "tick fiber dies with switch" `Quick
            test_tick_fiber_dies_with_switch;
          Alcotest.test_case
            "tick fiber stops without terminal stream event"
            `Quick
            test_tick_fiber_stops_without_terminal_event;
        ] );
    ]
