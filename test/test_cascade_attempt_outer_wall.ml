(** RFC-0022 §1 — outer-wall backstop respects living candidate budgets.

    The legacy [per_provider_timeout_s] knob (default 120s) used to be
    enforced as a raw [Eio.Time.with_timeout_exn]. That pre-empted
    attempts before the liveness observer's attempt-wall could fire.

    This module verifies the new contract enforced by
    {!Cascade_attempt_liveness_config.outer_wall_for_attempt}.

    With [Enforce + observer] the outer wall returns [None], and the
    observer drives cancellation. With [Observe / Off + observer] the
    outer wall is raised to the candidate's living budget so the legacy
    knob cannot kill a healthy slow stream. *)

open Masc_mcp
module Cfg = Cascade_attempt_liveness_config
module L = Cascade_attempt_liveness

let f = Alcotest.float 1e-6
let opt_f = Alcotest.option f

(* ─── Enforce mode + observer attached: outer wall is suppressed ─── *)

let test_enforce_with_observer_returns_none () =
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Enforce
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 120.0)
      ~candidate_key:"provider:model-a"
  in
  Alcotest.(check opt_f) "Enforce + observer → None" None actual

let test_enforce_with_observer_ollama_returns_none () =
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Enforce
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 120.0)
      ~candidate_key:"provider:model-a"
  in
  Alcotest.(check opt_f)
    "Enforce + observer + ollama → None (observer is authority)"
    None actual

(* ─── Observe / Off + observer: clip outer wall to living budget ─── *)

let test_observe_empty_history_clips_to_bootstrap_wall () =
  Cfg.reset_success_history_for_test ();
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Observe
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 120.0)
      ~candidate_key:"provider:model-a"
  in
  Alcotest.(check opt_f)
    "Observe + empty history → bootstrap wall (not 120s)"
    (Some L.bootstrap.attempt_wall_max)
    actual

let test_off_empty_history_clips_to_bootstrap_wall () =
  Cfg.reset_success_history_for_test ();
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Off
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 120.0)
      ~candidate_key:"provider:model-a"
  in
  Alcotest.(check opt_f)
    "Off + empty history → bootstrap wall"
    (Some L.bootstrap.attempt_wall_max)
    actual

let test_observed_success_history_clips_to_candidate_wall () =
  Cfg.reset_success_history_for_test ();
  Cfg.record_success_sample
    ~candidate_key:"provider:model-a"
    { Cfg.ttft_ms = 50_000.0; max_inter_chunk_ms = 10_000.0; wall_ms = 600_000.0 };
  let expected =
    let resolved = Cfg.budget_for_candidate ~candidate_key:"provider:model-a" in
    resolved.budget.attempt_wall_max
  in
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Observe
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 120.0)
      ~candidate_key:"provider:model-a"
  in
  Alcotest.(check opt_f)
    "Observe + observed success history → candidate wall"
    (Some expected)
    actual

let test_observe_keeps_user_t_when_larger () =
  Cfg.reset_success_history_for_test ();
  (* User explicitly set a larger budget than the bootstrap default —
     respect it. The clip rule is [max user_t profile_wall]. *)
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Observe
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 3600.0)
      ~candidate_key:"provider:model-a"
  in
  Alcotest.(check opt_f)
    "Observe + user 3600s → 3600s (>bootstrap)"
    (Some 3600.0) actual

let test_observe_bootstrap_clips_when_user_smaller () =
  Cfg.reset_success_history_for_test ();
  (* The legacy 120s knob is below bootstrap — clip up. *)
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Observe
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 120.0)
      ~candidate_key:"provider:model-a"
  in
  Alcotest.(check opt_f)
    "Observe + user 120s → bootstrap wall"
    (Some L.bootstrap.attempt_wall_max)
    actual

(* ─── No observer: pass-through (legacy behaviour preserved) ─── *)

let test_no_observer_passes_through_user_value () =
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Off
      ~observer_attached:false
      ~per_provider_timeout_s:(Some 120.0)
      ~candidate_key:"provider:model-a"
  in
  Alcotest.(check opt_f)
    "Off + no observer → unchanged 120s (legacy)"
    (Some 120.0) actual

let test_enforce_without_observer_passes_through () =
  (* Defensive: Enforce was set but observer wasn't constructed
     (e.g. liveness module disabled at compile-time or no clock).
     We must not silently drop the legacy wall. *)
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Enforce
      ~observer_attached:false
      ~per_provider_timeout_s:(Some 120.0)
      ~candidate_key:"provider:model-a"
  in
  Alcotest.(check opt_f)
    "Enforce + no observer → unchanged 120s (no silent drop)"
    (Some 120.0) actual

(* ─── No legacy timeout configured: returns None in all modes ─── *)

let test_none_input_stays_none_observe_with_observer () =
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Observe
      ~observer_attached:true
      ~per_provider_timeout_s:None
      ~candidate_key:"provider:model-a"
  in
  Alcotest.(check opt_f) "None input → None output" None actual

let test_none_input_stays_none_off_no_observer () =
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Off
      ~observer_attached:false
      ~per_provider_timeout_s:None
      ~candidate_key:"provider:model-a"
  in
  Alcotest.(check opt_f) "None + no observer → None" None actual

(* ─── Unknown candidate keys fall back to explicit bootstrap ─── *)

let test_unknown_candidate_uses_bootstrap () =
  Cfg.reset_success_history_for_test ();
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Observe
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 60.0)
      ~candidate_key:"some-future-provider:some-model"
  in
  Alcotest.(check opt_f)
    "Observe + unknown candidate → bootstrap"
    (Some L.bootstrap.attempt_wall_max)
    actual

let () =
  Alcotest.run "cascade-attempt-outer-wall"
    [
      ( "enforce-suppresses-outer-wall",
        [
          Alcotest.test_case "codex_cli" `Quick
            test_enforce_with_observer_returns_none;
          Alcotest.test_case "ollama_only" `Quick
            test_enforce_with_observer_ollama_returns_none;
        ] );
      ( "observe-clips-to-budget",
        [
          Alcotest.test_case "empty history → bootstrap wall" `Quick
            test_observe_empty_history_clips_to_bootstrap_wall;
          Alcotest.test_case "Off empty history → bootstrap wall" `Quick
            test_off_empty_history_clips_to_bootstrap_wall;
          Alcotest.test_case "observed history → candidate wall" `Quick
            test_observed_success_history_clips_to_candidate_wall;
          Alcotest.test_case "user 3600s > bootstrap preserved" `Quick
            test_observe_keeps_user_t_when_larger;
          Alcotest.test_case "user 120s < bootstrap clipped" `Quick
            test_observe_bootstrap_clips_when_user_smaller;
        ] );
      ( "no-observer-pass-through",
        [
          Alcotest.test_case "Off + no observer" `Quick
            test_no_observer_passes_through_user_value;
          Alcotest.test_case "Enforce + no observer (defensive)" `Quick
            test_enforce_without_observer_passes_through;
        ] );
      ( "none-input",
        [
          Alcotest.test_case "Observe + observer + None" `Quick
            test_none_input_stays_none_observe_with_observer;
          Alcotest.test_case "Off + no observer + None" `Quick
            test_none_input_stays_none_off_no_observer;
        ] );
      ( "fallback",
        [
          Alcotest.test_case "unknown candidate → bootstrap" `Quick
            test_unknown_candidate_uses_bootstrap;
        ] );
    ]
