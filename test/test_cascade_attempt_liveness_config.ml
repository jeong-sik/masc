(** Tests for [Cascade_attempt_liveness_config] (RFC-0022 PR-2/4 §2).

    Covers: env-flag parsing (default Observe, all aliases),
    cache invalidation via reset_cache_for_test, label→budget mapping. *)

open Masc_mcp
module Cfg = Cascade_attempt_liveness_config
module L = Cascade_attempt_liveness

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

let mode_label = Cfg.mode_label

let check_mode label expected actual =
  Alcotest.(check string) label (mode_label expected) (mode_label actual)

(* -- mode parsing --------------------------------------------------- *)

let test_default_unset () =
  let prior = Sys.getenv_opt env_var in
  Unix.putenv env_var "";
  Cfg.reset_cache_for_test ();
  (* Empty string parses as Observe by parse_mode contract. *)
  let m = Cfg.current_mode () in
  (match prior with
   | None -> Unix.putenv env_var ""
   | Some v -> Unix.putenv env_var v);
  Cfg.reset_cache_for_test ();
  check_mode "empty string -> Observe" Observe m

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

(* -- budget_for_label ---------------------------------------------- *)

let budget_eq (a : L.budget) (b : L.budget) =
  Float.equal a.ttft_max b.ttft_max
  && Float.equal a.inter_chunk_max b.inter_chunk_max
  && Float.equal a.attempt_wall_max b.attempt_wall_max

let check_budget label expected actual =
  Alcotest.(check bool) label true (budget_eq expected actual)

let test_budget_codex_cli () =
  check_budget "codex_cli -> cloud_fast" L.cloud_fast
    (Cfg.budget_for_label "codex_cli")

let test_budget_claude_code () =
  check_budget "claude_code -> cloud_fast" L.cloud_fast
    (Cfg.budget_for_label "claude_code")

let test_budget_glm_coding () =
  check_budget "glm-coding -> cloud_thinking" L.cloud_thinking
    (Cfg.budget_for_label "glm-coding")

let test_budget_kimi () =
  check_budget "kimi-for-coding -> cloud_thinking" L.cloud_thinking
    (Cfg.budget_for_label "kimi-for-coding")

let test_budget_local () =
  check_budget "ollama_only -> local_27b" L.local_27b
    (Cfg.budget_for_label "ollama_only");
  check_budget "llama-server -> local_27b" L.local_27b
    (Cfg.budget_for_label "llama-server")

let test_budget_local_70b () =
  check_budget "local_70b_plus -> local_70b_plus" L.local_70b_plus
    (Cfg.budget_for_label "local_70b_plus")

let test_budget_unknown_default () =
  check_budget "unknown -> cloud_fast" L.cloud_fast
    (Cfg.budget_for_label "weird_provider_xyz")

let test_budget_case_insensitive () =
  check_budget "GLM-CODING -> cloud_thinking" L.cloud_thinking
    (Cfg.budget_for_label "GLM-CODING")

let () =
  Alcotest.run "cascade_attempt_liveness_config"
    [
      ( "mode parsing",
        [
          Alcotest.test_case "default unset -> observe" `Quick
            test_default_unset;
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
      ( "budget_for_label",
        [
          Alcotest.test_case "codex_cli" `Quick test_budget_codex_cli;
          Alcotest.test_case "claude_code" `Quick test_budget_claude_code;
          Alcotest.test_case "glm-coding" `Quick test_budget_glm_coding;
          Alcotest.test_case "kimi-for-coding" `Quick test_budget_kimi;
          Alcotest.test_case "local 27b" `Quick test_budget_local;
          Alcotest.test_case "local 70b plus" `Quick test_budget_local_70b;
          Alcotest.test_case "unknown -> cloud_fast" `Quick
            test_budget_unknown_default;
          Alcotest.test_case "case insensitive" `Quick
            test_budget_case_insensitive;
        ] );
    ]
