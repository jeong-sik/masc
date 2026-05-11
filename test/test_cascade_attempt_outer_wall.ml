(** RFC-0022 §1 — outer-wall backstop respects the per-profile budget.

    The legacy [per_provider_timeout_s] knob (default 120s) used to be
    enforced as a raw [Eio.Time.with_timeout_exn]. That pre-empted
    attempts before the per-profile attempt-wall ([cloud_fast 180s],
    [cloud_thinking 300s], [local_27b 900s], [local_70b_plus 1800s])
    could fire — making slow local LLMs (Ollama) impossible to use.

    This module verifies the new contract enforced by
    {!Cascade_attempt_liveness_config.outer_wall_for_attempt}.

    The Ollama scenario (slow streaming past 120s) is exercised at the
    rule level: with [Enforce + observer] the outer wall returns
    [None], and the observer drives cancellation. With [Observe /
    Off + observer] the outer wall is raised to the profile's wall so
    the legacy 120s knob cannot kill a healthy slow stream. *)

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
      ~provider_id:"codex_cli"
  in
  Alcotest.(check opt_f) "Enforce + observer → None" None actual

let test_enforce_with_observer_ollama_returns_none () =
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Enforce
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 120.0)
      ~provider_id:"ollama_only"
  in
  Alcotest.(check opt_f)
    "Enforce + observer + ollama → None (observer is authority)"
    None actual

(* ─── Observe / Off + observer: clip outer wall to profile budget ─── *)

let test_observe_ollama_clips_to_local_27b_wall () =
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Observe
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 120.0)
      ~provider_id:"ollama_only"
  in
  Alcotest.(check opt_f)
    "Observe + ollama → local_27b wall 900s (not 120s)"
    (Some L.local_27b.attempt_wall_max)
    actual

let test_off_ollama_clips_to_local_27b_wall () =
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Off
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 120.0)
      ~provider_id:"llama-server"
  in
  Alcotest.(check opt_f)
    "Off + llama-server → local_27b wall 900s"
    (Some L.local_27b.attempt_wall_max)
    actual

let test_observe_ollama_70b_clips_to_local_70b_plus_wall () =
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Observe
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 120.0)
      ~provider_id:"ollama_70b"
  in
  Alcotest.(check opt_f)
    "Observe + ollama_70b → local_70b_plus wall 1800s"
    (Some L.local_70b_plus.attempt_wall_max)
    actual

let test_observe_cloud_fast_keeps_user_t_when_larger () =
  (* User explicitly set a larger budget than the profile default —
     respect it. The clip rule is [max user_t profile_wall]. *)
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Observe
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 600.0)
      ~provider_id:"codex_cli"
  in
  Alcotest.(check opt_f)
    "Observe + codex_cli + user 600s → 600s (>cloud_fast 180s)"
    (Some 600.0) actual

let test_observe_cloud_fast_clips_when_user_smaller () =
  (* The legacy 120s knob is below cloud_fast 180s — clip up. *)
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Observe
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 120.0)
      ~provider_id:"codex_cli"
  in
  Alcotest.(check opt_f)
    "Observe + codex_cli + user 120s → cloud_fast 180s"
    (Some L.cloud_fast.attempt_wall_max)
    actual

(* ─── No observer: pass-through (legacy behaviour preserved) ─── *)

let test_no_observer_passes_through_user_value () =
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Off
      ~observer_attached:false
      ~per_provider_timeout_s:(Some 120.0)
      ~provider_id:"ollama_only"
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
      ~provider_id:"codex_cli"
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
      ~provider_id:"ollama_only"
  in
  Alcotest.(check opt_f) "None input → None output" None actual

let test_none_input_stays_none_off_no_observer () =
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Off
      ~observer_attached:false
      ~per_provider_timeout_s:None
      ~provider_id:"codex_cli"
  in
  Alcotest.(check opt_f) "None + no observer → None" None actual

(* ─── Unknown labels fall back to cloud_fast ─── *)

let test_unknown_label_falls_back_to_cloud_fast () =
  let actual =
    Cfg.outer_wall_for_attempt
      ~mode:Cfg.Observe
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 60.0)
      ~provider_id:"some-future-provider"
  in
  Alcotest.(check opt_f)
    "Observe + unknown → cloud_fast 180s"
    (Some L.cloud_fast.attempt_wall_max)
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
          Alcotest.test_case "ollama_only → local_27b wall" `Quick
            test_observe_ollama_clips_to_local_27b_wall;
          Alcotest.test_case "llama-server (Off) → local_27b wall" `Quick
            test_off_ollama_clips_to_local_27b_wall;
          Alcotest.test_case "ollama_70b → local_70b_plus wall" `Quick
            test_observe_ollama_70b_clips_to_local_70b_plus_wall;
          Alcotest.test_case "user 600s > cloud_fast 180s preserved" `Quick
            test_observe_cloud_fast_keeps_user_t_when_larger;
          Alcotest.test_case "user 120s < cloud_fast 180s clipped" `Quick
            test_observe_cloud_fast_clips_when_user_smaller;
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
          Alcotest.test_case "unknown label → cloud_fast" `Quick
            test_unknown_label_falls_back_to_cloud_fast;
        ] );
    ]
