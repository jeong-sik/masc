(** Tests for [Cascade_attempt_liveness_config] (RFC-0022 PR-2/4 §2).

    Covers: env-flag parsing (unset defaults to Enforce; empty/unknown parse
    as Observe), cache invalidation via reset_cache_for_test, and living
    success-history budget selection. *)

open Masc_mcp
module Cfg = Cascade_attempt_liveness_config
module L = Cascade_attempt_liveness

let env_var = "MASC_CASCADE_ATTEMPT_LIVENESS"

external unsetenv : string -> unit = "masc_test_unsetenv"

let with_env value f =
  let prior = Sys.getenv_opt env_var in
  (match value with
   | None -> unsetenv env_var
   | Some v -> Unix.putenv env_var v);
  Cfg.reset_cache_for_test ();
  let restore () =
    (match prior with
     | None -> unsetenv env_var
     | Some v -> Unix.putenv env_var v);
    Cfg.reset_cache_for_test ()
  in
  match f () with
  | x -> restore (); x
  | exception e -> restore (); raise e

let mode_label = Cfg.mode_label

let check_mode label expected actual =
  Alcotest.(check string) label (mode_label expected) (mode_label actual)

(* -- mode parsing --------------------------------------------------- *)

let test_unset_defaults_enforce () =
  with_env None (fun () ->
      check_mode "unset -> Enforce" Enforce (Cfg.current_mode ()))

let test_empty_string_alias () =
  with_env (Some "") (fun () ->
      check_mode "empty string -> Observe" Observe (Cfg.current_mode ()))

let test_observe_alias () =
  with_env (Some "observe") (fun () ->
      check_mode "observe" Observe (Cfg.current_mode ()))

let test_off_alias () =
  with_env (Some "off") (fun () ->
      check_mode "off" Off (Cfg.current_mode ()))

let test_off_zero () =
  with_env (Some "0") (fun () ->
      check_mode "0 -> Off" Off (Cfg.current_mode ()))

let test_enforce_alias () =
  with_env (Some "enforce") (fun () ->
      check_mode "enforce" Enforce (Cfg.current_mode ()))

let test_enforce_kill () =
  with_env (Some "kill") (fun () ->
      check_mode "kill -> Enforce" Enforce (Cfg.current_mode ()))

let test_unknown_defaults_observe () =
  with_env (Some "garbage") (fun () ->
      check_mode "garbage -> Observe" Observe (Cfg.current_mode ()))

let test_case_insensitive () =
  with_env (Some "OFF") (fun () ->
      check_mode "OFF -> Off" Off (Cfg.current_mode ()))

(* -- cache contract ------------------------------------------------- *)

let test_cache_first_read () =
  with_env (Some "off") (fun () ->
      let m1 = Cfg.current_mode () in
      (* Mutate env after first read; cached value should persist. *)
      Unix.putenv env_var "enforce";
      let m2 = Cfg.current_mode () in
      check_mode "first read" Off m1;
      check_mode "cached, ignores mutation" Off m2)

let test_reset_cache () =
  with_env (Some "off") (fun () ->
      let _ = Cfg.current_mode () in
      Unix.putenv env_var "enforce";
      Cfg.reset_cache_for_test ();
      check_mode "after reset, sees enforce" Enforce (Cfg.current_mode ()))

(* -- mode_label round-trip ----------------------------------------- *)

let test_mode_labels () =
  Alcotest.(check string) "off" "off" (mode_label Off);
  Alcotest.(check string) "observe" "observe" (mode_label Observe);
  Alcotest.(check string) "enforce" "enforce" (mode_label Enforce)

(* -- living budget selection --------------------------------------- *)

let budget_eq (a : L.budget) (b : L.budget) =
  Float.equal a.ttft_max b.ttft_max
  && Float.equal a.inter_chunk_max b.inter_chunk_max
  && Float.equal a.attempt_wall_max b.attempt_wall_max

let check_budget label expected actual =
  Alcotest.(check bool) label true (budget_eq expected actual)

let test_budget_bootstrap_when_empty () =
  Cfg.reset_success_history_for_test ();
  let resolved = Cfg.budget_for_candidate ~candidate_key:"provider:model-a" in
  check_budget "empty history -> bootstrap" L.bootstrap resolved.budget;
  Alcotest.(check string)
    "source" "bootstrap" (Cfg.budget_source_label resolved.source)

let test_record_success_sample_updates_candidate_budget () =
  Cfg.reset_success_history_for_test ();
  Cfg.record_success_sample
    ~candidate_key:"provider:model-a"
    { Cfg.ttft_ms = 42_000.0; max_inter_chunk_ms = 12_000.0; wall_ms = 90_000.0 };
  let resolved = Cfg.budget_for_candidate ~candidate_key:"provider:model-a" in
  Alcotest.(check string)
    "source" "observed_success" (Cfg.budget_source_label resolved.source);
  Alcotest.(check int)
    "sample count" 1 (Cfg.success_sample_count_for_test ~candidate_key:"provider:model-a");
  Alcotest.(check bool)
    "ttft carries headroom over observed sample"
    true
    (resolved.budget.ttft_max > 42.0);
  Alcotest.(check bool)
    "wall remains above observed sample"
    true
    (resolved.budget.attempt_wall_max > 90.0)

let test_candidate_keys_are_model_scoped () =
  Cfg.reset_success_history_for_test ();
  Cfg.record_success_sample
    ~candidate_key:"provider:model-fast"
    { Cfg.ttft_ms = 1_000.0; max_inter_chunk_ms = 500.0; wall_ms = 20_000.0 };
  Cfg.record_success_sample
    ~candidate_key:"provider:model-slow"
    { Cfg.ttft_ms = 120_000.0; max_inter_chunk_ms = 40_000.0; wall_ms = 600_000.0 };
  let fast = Cfg.budget_for_candidate ~candidate_key:"provider:model-fast" in
  let slow = Cfg.budget_for_candidate ~candidate_key:"provider:model-slow" in
  Alcotest.(check bool)
    "same provider can have different model budgets"
    true
    (slow.budget.attempt_wall_max > fast.budget.attempt_wall_max)

let test_invalid_success_sample_ignored () =
  Cfg.reset_success_history_for_test ();
  Cfg.record_success_sample
    ~candidate_key:"provider:model-a"
    { Cfg.ttft_ms = nan; max_inter_chunk_ms = 1.0; wall_ms = 2.0 };
  Alcotest.(check int)
    "invalid sample ignored"
    0
    (Cfg.success_sample_count_for_test ~candidate_key:"provider:model-a")

let test_success_history_candidate_count_is_bounded () =
  Cfg.reset_success_history_for_test ();
  for i = 0 to 2049 do
    Cfg.record_success_sample
      ~candidate_key:(Printf.sprintf "provider:model-%03d" i)
      { Cfg.ttft_ms = 1_000.0; max_inter_chunk_ms = 1_000.0; wall_ms = 2_000.0 }
  done;
  Alcotest.(check int)
    "oldest candidate evicted"
    0
    (Cfg.success_sample_count_for_test ~candidate_key:"provider:model-000");
  Alcotest.(check int)
    "newest candidate retained"
    1
    (Cfg.success_sample_count_for_test ~candidate_key:"provider:model-2049")

let () =
  Alcotest.run "cascade_attempt_liveness_config"
    [
      ( "mode parsing",
        [
          Alcotest.test_case "unset -> enforce" `Quick
            test_unset_defaults_enforce;
          Alcotest.test_case "empty string -> observe" `Quick
            test_empty_string_alias;
          Alcotest.test_case "observe" `Quick test_observe_alias;
          Alcotest.test_case "off" `Quick test_off_alias;
          Alcotest.test_case "off via 0" `Quick test_off_zero;
          Alcotest.test_case "enforce" `Quick test_enforce_alias;
          Alcotest.test_case "enforce via kill" `Quick test_enforce_kill;
          Alcotest.test_case "unknown -> observe" `Quick
            test_unknown_defaults_observe;
          Alcotest.test_case "case insensitive" `Quick test_case_insensitive;
        ] );
      ( "cache",
        [
          Alcotest.test_case "first read cached" `Quick test_cache_first_read;
          Alcotest.test_case "reset_cache_for_test re-reads" `Quick
            test_reset_cache;
        ] );
      ( "mode_label",
        [ Alcotest.test_case "stable labels" `Quick test_mode_labels ] );
      ( "living budget",
        [
          Alcotest.test_case "empty history -> bootstrap" `Quick
            test_budget_bootstrap_when_empty;
          Alcotest.test_case "success sample updates budget" `Quick
            test_record_success_sample_updates_candidate_budget;
          Alcotest.test_case "candidate keys are model scoped" `Quick
            test_candidate_keys_are_model_scoped;
          Alcotest.test_case "invalid sample ignored" `Quick
            test_invalid_success_sample_ignored;
          Alcotest.test_case "candidate count bounded" `Quick
            test_success_history_candidate_count_is_bounded;
        ] );
    ]
