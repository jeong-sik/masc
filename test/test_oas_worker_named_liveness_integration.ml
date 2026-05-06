(** Integration smoke for the cascade attempt-liveness wiring in
    [oas_worker_named.ml] (RFC-0022 PR-2 §4 commit 4).

    This test does not spin up a real provider — that surface needs a
    live OAS attempt loop with a mock SSE server, which lands as the
    PR-3 e2e fixture. Instead we pin the observable wiring contract:

    1. The env-flag bridge ([Cascade_attempt_liveness_config.current_mode])
       reads the same MASC_CASCADE_ATTEMPT_LIVENESS variable that
       try_provider consults — preventing a future rename from
       silently splitting the call sites.

    2. The observer module is reachable through the
       [Cascade_attempt_liveness_observer.{create, wrap_on_event,
       register_attempt_switch, finalize}] surface that try_provider
       depends on, with the expected mode contract (Off pass-through;
       Observe wraps; Enforce wraps + scopes cancellation to the provider
       attempt switch even when no clock is available).

    3. End-to-end finalize emits the observed_total counter with the
       outcome label that try_provider's `finalize_liveness ()` call
       will produce. *)

open Masc_mcp
module Cfg = Cascade_attempt_liveness_config
module Obs = Cascade_attempt_liveness_observer

let env_var = "MASC_CASCADE_ATTEMPT_LIVENESS"

let with_env value f =
  let prior = Sys.getenv_opt env_var in
  (match value with
   | None -> Unix.putenv env_var ""
   | Some v -> Unix.putenv env_var v);
  Cfg.reset_cache_for_test ();
  let restore () =
    (match prior with
     | None -> Unix.putenv env_var ""
     | Some v -> Unix.putenv env_var v);
    Cfg.reset_cache_for_test ()
  in
  match f () with
  | x -> restore (); x
  | exception e -> restore (); raise e

(* -- env-flag bridge contract ------------------------------------- *)

let test_env_off_short_circuits () =
  with_env (Some "off") (fun () ->
      Alcotest.(check string)
        "MASC_CASCADE_ATTEMPT_LIVENESS=off -> Off mode"
        "off"
        (Cfg.mode_label (Cfg.current_mode ())))

let test_env_observe_default () =
  with_env None (fun () ->
      Alcotest.(check string)
        "default -> Observe (RFC §9 Phase A)"
        "observe"
        (Cfg.mode_label (Cfg.current_mode ())))

let test_env_enforce () =
  with_env (Some "enforce") (fun () ->
      Alcotest.(check string)
        "MASC_CASCADE_ATTEMPT_LIVENESS=enforce -> Enforce mode"
        "enforce"
        (Cfg.mode_label (Cfg.current_mode ())))

(* -- end-to-end finalize emits observed_total -------------------- *)

let observed_value cascade provider outcome =
  Prometheus.metric_value_or_zero
    Prometheus.metric_cascade_attempt_liveness_observed
    ~labels:
      [
        ("cascade", cascade);
        ("provider", provider);
        ("outcome", outcome);
      ]
    ()

let test_e2e_observe_finalize_emits_observed_total () =
  with_env (Some "observe") (fun () ->
      let cascade = "integ_observe_cascade" in
      let provider = "integ_observe_provider" in
      let mode = Cfg.current_mode () in
      let budget = Cfg.budget_for_label provider in
      let obs =
        Obs.create ~mode ~budget ~cascade_label:cascade
          ~provider_label:provider ~started_at:0.0
      in
      (* Simulate: provider streamed Done before any chunk -> Success. *)
      let wrapped = Obs.wrap_on_event obs None in
      (match wrapped with
       | Some f -> f Agent_sdk.Types.MessageStop
       | None -> Alcotest.fail "Observe should wrap");
      let before = observed_value cascade provider "success" in
      Obs.finalize obs;
      let after = observed_value cascade provider "success" in
      Alcotest.(check (float 1e-6))
        "observed_total{outcome=success} incremented"
        (before +. 1.0) after)

let test_e2e_off_no_observed_total () =
  with_env (Some "off") (fun () ->
      let cascade = "integ_off_cascade" in
      let provider = "integ_off_provider" in
      let mode = Cfg.current_mode () in
      let budget = Cfg.budget_for_label provider in
      let obs =
        Obs.create ~mode ~budget ~cascade_label:cascade
          ~provider_label:provider ~started_at:0.0
      in
      let before = observed_value cascade provider "wire_error" in
      Obs.finalize obs;
      let after = observed_value cascade provider "wire_error" in
      Alcotest.(check (float 1e-6))
        "Off finalize emits no observed counter" before after)

let test_enforce_registered_switch_kills_attempt_without_tick_clock () =
  let cascade = "integ_enforce_cascade" in
  let provider = "integ_enforce_provider" in
  let raised = ref None in
  with_env (Some "enforce") (fun () ->
      Eio_main.run (fun _env ->
          try
            Eio.Switch.run (fun attempt_sw ->
                let mode = Cfg.current_mode () in
                let budget = Cfg.budget_for_label provider in
                let obs =
                  Obs.create ~mode ~budget ~cascade_label:cascade
                    ~provider_label:provider ~started_at:0.0
                in
                Obs.register_attempt_switch obs ~sw:attempt_sw;
                let wrapped = Obs.wrap_on_event obs None in
                (match wrapped with
                 | Some f -> f (Agent_sdk.Types.SSEError "wire boom")
                 | None -> Alcotest.fail "Enforce should wrap");
                Eio.Fiber.yield ())
          with
          | Obs.Liveness_kill failure ->
              raised := Some (Cascade_attempt_liveness.failure_kind_label failure)
          | exn ->
              Alcotest.failf "unexpected exception: %s" (Printexc.to_string exn)));
  Alcotest.(check (option string))
    "registered attempt switch receives enforce kill without tick fiber"
    (Some "provider_error")
    !raised

let () =
  Alcotest.run "oas_worker_named_liveness_integration"
    [
      ( "env flag bridge",
        [
          Alcotest.test_case "off short-circuits" `Quick
            test_env_off_short_circuits;
          Alcotest.test_case "default observe" `Quick test_env_observe_default;
          Alcotest.test_case "enforce alias" `Quick test_env_enforce;
        ] );
      ( "end to end",
        [
          Alcotest.test_case "Observe e2e finalize emits observed_total"
            `Quick test_e2e_observe_finalize_emits_observed_total;
          Alcotest.test_case "Off e2e emits nothing" `Quick
            test_e2e_off_no_observed_total;
        ] );
      ( "source contract",
        [
          Alcotest.test_case
            "enforce kill is scoped without clock tick fiber" `Quick
            test_enforce_registered_switch_kills_attempt_without_tick_clock;
        ] );
    ]
