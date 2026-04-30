(** Unit tests for Cascade_inventory.

    These tests exercise the pure score / best_runner_among helpers in
    isolation; the catalog-enumeration wrapper that turns a process-wide
    fleet into a [scored_provider list] is integration-level work and
    lives elsewhere. *)

open Alcotest

module H = Masc_mcp.Cascade_health_tracker
module Inv = Masc_mcp.Cascade_inventory
module Kcp = Masc_mcp.Keeper_cascade_profile

(* Build a Provider_config.t from a cascade label, e.g.
   "codex_cli:gpt-5.3-codex" or "ollama:auto".  Reuses the existing
   parse helper so the inventory tests don't drift away from real
   provider shapes. *)
let provider_of_label label =
  match Masc_mcp.Cascade_config.parse_model_string label with
  | Some cfg -> cfg
  | None -> fail ("expected model label to parse: " ^ label)

let mk_scored ?(cascade_name = "test") ?(score = 0.0) label =
  Inv.
    {
      cascade_name = Kcp.Runtime_name cascade_name;
      provider = provider_of_label label;
      score;
    }

(* ── score_provider ─────────────────────────────────────────────── *)

let test_score_unknown_provider_full () =
  (* A provider with no tracker history scores 1.0 — success_rate=1.0
     (optimistic) × latency_score=1.0 (no samples) = 1.0. *)
  let h = H.create () in
  let p = provider_of_label "codex_cli:gpt-5.3-codex" in
  let s = Inv.score_provider h ~exclude:[] ~keeper_assignable:true p in
  check (float 0.001) "unknown provider scores 1.0" 1.0 s

let test_score_excluded_zero () =
  let h = H.create () in
  let p = provider_of_label "codex_cli:gpt-5.3-codex" in
  let s = Inv.score_provider h
            ~exclude:[p.Llm_provider.Provider_config.model_id]
            ~keeper_assignable:true p
  in
  check (float 0.001) "excluded provider scores 0.0" 0.0 s

let test_score_cooldown_zero () =
  let h = H.create () in
  let p = provider_of_label "codex_cli:gpt-5.3-codex" in
  (* Trigger cooldown via 3 consecutive failures (default threshold). *)
  H.record_failure h ~provider_key:p.model_id ();
  H.record_failure h ~provider_key:p.model_id ();
  H.record_failure h ~provider_key:p.model_id ();
  let s = Inv.score_provider h ~exclude:[] ~keeper_assignable:true p in
  check (float 0.001) "cooled-down provider scores 0.0" 0.0 s

let test_score_keeper_unassignable_zero () =
  let h = H.create () in
  let p = provider_of_label "codex_cli:gpt-5.3-codex" in
  let s = Inv.score_provider h ~exclude:[] ~keeper_assignable:false p in
  check (float 0.001) "keeper_assignable=false → score 0.0" 0.0 s

let test_score_combines_success_and_latency () =
  (* Provider with 1 success + 1 failure (success_rate=0.5) and a slow
     latency (8000 ms, well above 2000 ms baseline → latency_score≈0.25)
     should produce score ≈ 0.125, not 1.0 and not 0.0. *)
  let h = H.create () in
  let p = provider_of_label "codex_cli:gpt-5.3-codex" in
  H.record_success h ~provider_key:p.model_id ~latency_ms:8000.0 ();
  H.record_failure h ~provider_key:p.model_id ();
  let s = Inv.score_provider h ~exclude:[] ~keeper_assignable:true p in
  check bool
    (Printf.sprintf "score=%.3f should be in (0.05, 0.20)" s)
    true (s > 0.05 && s < 0.20)

(* ── best_runner_among ──────────────────────────────────────────── *)

let test_best_runner_empty_returns_none () =
  let h = H.create () in
  match Inv.best_runner_among ~health:h ~exclude:[] [] with
  | None -> ()
  | Some _ -> fail "empty inventory must return None"

let test_best_runner_all_zero_returns_none () =
  let h = H.create () in
  let candidates = [
    mk_scored "codex_cli:gpt-5.3-codex" ~score:0.0;
    mk_scored "gemini_cli:auto" ~score:0.0;
  ] in
  match Inv.best_runner_among ~health:h ~exclude:[] candidates with
  | None -> ()
  | Some _ -> fail "all-zero scores must return None"

let test_best_runner_picks_highest_score () =
  let h = H.create () in
  let candidates = [
    mk_scored "codex_cli:gpt-5.3-codex" ~score:0.3;
    mk_scored "gemini_cli:auto" ~score:0.8;
    mk_scored "ollama:auto" ~score:0.5;
  ] in
  match Inv.best_runner_among ~health:h ~exclude:[] candidates with
  | None -> fail "expected a winner"
  | Some sp ->
    check (float 0.001) "winner has score 0.8" 0.8 sp.score

let test_best_runner_excludes_provider () =
  (* The exclude list takes precedence over the score — even a 1.0
     candidate is skipped if its model_id is in [exclude]. *)
  let h = H.create () in
  let high = mk_scored "codex_cli:gpt-5.3-codex" ~score:1.0 in
  let lower = mk_scored "gemini_cli:auto" ~score:0.4 in
  let candidates = [high; lower] in
  match Inv.best_runner_among
          ~health:h
          ~exclude:[high.provider.model_id]
          candidates
  with
  | None -> fail "lower-score provider should win after exclusion"
  | Some sp ->
    check string "winner is the non-excluded one"
      lower.provider.model_id sp.provider.model_id

let test_best_runner_ties_break_to_first () =
  let h = H.create () in
  let a = mk_scored "codex_cli:gpt-5.3-codex" ~score:0.5 in
  let b = mk_scored "gemini_cli:auto" ~score:0.5 in
  match Inv.best_runner_among ~health:h ~exclude:[] [a; b] with
  | None -> fail "expected a winner"
  | Some sp ->
    check string "ties break to first input"
      a.provider.model_id sp.provider.model_id

(* ── Suite ──────────────────────────────────────────────────────── *)

let () =
  run "cascade_inventory" [
    "score_provider", [
      test_case "unknown provider full score" `Quick
        test_score_unknown_provider_full;
      test_case "excluded provider scores 0" `Quick
        test_score_excluded_zero;
      test_case "cooled-down provider scores 0" `Quick
        test_score_cooldown_zero;
      test_case "keeper_assignable=false scores 0" `Quick
        test_score_keeper_unassignable_zero;
      test_case "score combines success_rate and latency" `Quick
        test_score_combines_success_and_latency;
    ];
    "best_runner_among", [
      test_case "empty input returns None" `Quick
        test_best_runner_empty_returns_none;
      test_case "all-zero scores return None" `Quick
        test_best_runner_all_zero_returns_none;
      test_case "picks highest score" `Quick
        test_best_runner_picks_highest_score;
      test_case "exclude list overrides score" `Quick
        test_best_runner_excludes_provider;
      test_case "ties break to first input" `Quick
        test_best_runner_ties_break_to_first;
    ];
  ]
