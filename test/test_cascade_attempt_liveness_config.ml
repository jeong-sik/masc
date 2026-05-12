(** Tests for [Cascade_attempt_liveness_config] (RFC-0022 PR-2/4 §2 +
    RFC-0058 Phase 5.2b).

    Covers: env-flag parsing (default Observe, all aliases),
    cache invalidation via reset_cache_for_test, and the cascade-config-
    driven [budget_for_provider_id] lookup (Phase 5.2b). *)

open Masc_mcp
module Cfg = Cascade_attempt_liveness_config
module L = Cascade_attempt_liveness
module Decl = Cascade_declarative_types

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
  | x ->
    restore ();
    x
  | exception e ->
    restore ();
    raise e
;;

let mode_label = Cfg.mode_label

let check_mode label expected actual =
  Alcotest.(check string) label (mode_label expected) (mode_label actual)
;;

(* -- mode parsing --------------------------------------------------- *)

let test_default_unset () =
  let prior = Sys.getenv_opt env_var in
  Unix.putenv env_var "";
  Cfg.reset_cache_for_test ();
  let m = Cfg.current_mode () in
  (match prior with
   | None -> Unix.putenv env_var ""
   | Some v -> Unix.putenv env_var v);
  Cfg.reset_cache_for_test ();
  check_mode "empty string -> Observe" Observe m
;;

let test_observe_alias () =
  with_env (Some "observe") (fun () -> check_mode "observe" Observe (Cfg.current_mode ()))
;;

let test_off_alias () =
  with_env (Some "off") (fun () -> check_mode "off" Off (Cfg.current_mode ()))
;;

let test_off_zero () =
  with_env (Some "0") (fun () -> check_mode "0 -> Off" Off (Cfg.current_mode ()))
;;

let test_enforce_alias () =
  with_env (Some "enforce") (fun () -> check_mode "enforce" Enforce (Cfg.current_mode ()))
;;

let test_enforce_kill () =
  with_env (Some "kill") (fun () ->
    check_mode "kill -> Enforce" Enforce (Cfg.current_mode ()))
;;

let test_unknown_defaults_observe () =
  with_env (Some "bogus") (fun () ->
    check_mode "unknown -> Observe" Observe (Cfg.current_mode ()))
;;

let test_case_insensitive () =
  with_env (Some "OBSERVE") (fun () ->
    check_mode "OBSERVE upper -> Observe" Observe (Cfg.current_mode ()))
;;

(* -- cache --------------------------------------------------------- *)

let test_cache_first_read () =
  with_env (Some "off") (fun () ->
    let m1 = Cfg.current_mode () in
    Unix.putenv env_var "enforce";
    let m2 = Cfg.current_mode () in
    check_mode "cached Off" Off m1;
    check_mode "still Off after env change without reset" Off m2)
;;

let test_reset_cache () =
  with_env (Some "off") (fun () ->
    let m1 = Cfg.current_mode () in
    Unix.putenv env_var "enforce";
    Cfg.reset_cache_for_test ();
    let m2 = Cfg.current_mode () in
    check_mode "first read Off" Off m1;
    check_mode "after reset Enforce" Enforce m2)
;;

let test_mode_labels () =
  Alcotest.(check string) "off" "off" (mode_label Off);
  Alcotest.(check string) "observe" "observe" (mode_label Observe);
  Alcotest.(check string) "enforce" "enforce" (mode_label Enforce)
;;

(* -- budget_for_provider_id (Phase 5.2b — cascade-config-driven) --- *)

let budget_eq (a : L.budget) (b : L.budget) =
  Float.equal a.ttft_max b.ttft_max
  && Float.equal a.inter_chunk_max b.inter_chunk_max
  && Float.equal a.attempt_wall_max b.attempt_wall_max
;;

let check_budget label expected actual =
  Alcotest.(check bool) label true (budget_eq expected actual)
;;

(* Test helpers — synthesize a minimal cascade_config so the lookup
   path can be exercised without touching disk. *)
let make_provider ~id ~liveness_class : Decl.cascade_provider =
  { id
  ; display_name = id
  ; protocol = "anthropic-cli"
  ; api_format = Decl.Messages_api
  ; transport = Decl.Cli "test"
  ; is_non_interactive = true
  ; credentials = None
  ; liveness_class
  ; capabilities = None
  ; headers = None
  }
;;

let make_cfg (providers : Decl.cascade_provider list) : Decl.cascade_config =
  { providers
  ; models = []
  ; bindings = []
  ; aliases = []
  ; tiers = []
  ; tier_groups = []
  ; routes = []
  ; system_targets = []
  }
;;

(* The five in-tree provider classes from config/cascade.toml live here
   as canonical fixtures; each row exercises one [liveness_class]. *)
let fixture_cfg =
  make_cfg
    [ make_provider ~id:"codex_cli" ~liveness_class:(Some Cloud_fast)
    ; make_provider ~id:"claude_code" ~liveness_class:(Some Cloud_fast)
    ; make_provider ~id:"gemini_cli" ~liveness_class:(Some Cloud_fast)
    ; make_provider ~id:"kimi_cli" ~liveness_class:(Some Cloud_thinking)
    ; make_provider ~id:"glm-coding" ~liveness_class:(Some Cloud_thinking)
    ; make_provider ~id:"ollama" ~liveness_class:(Some Local_27b)
    ; make_provider ~id:"big-local" ~liveness_class:(Some Local_70b_plus)
    ; make_provider ~id:"no-class" ~liveness_class:None
    ]
;;

let budget_of cfg pid = Cfg.budget_for_provider_id ~cfg ~provider_id:pid ()

let test_budget_cloud_fast () =
  check_budget "codex_cli -> cloud_fast" L.cloud_fast (budget_of fixture_cfg "codex_cli");
  check_budget
    "claude_code -> cloud_fast"
    L.cloud_fast
    (budget_of fixture_cfg "claude_code");
  check_budget
    "gemini_cli -> cloud_fast"
    L.cloud_fast
    (budget_of fixture_cfg "gemini_cli")
;;

let test_budget_cloud_thinking () =
  check_budget
    "kimi_cli -> cloud_thinking"
    L.cloud_thinking
    (budget_of fixture_cfg "kimi_cli");
  check_budget
    "glm-coding -> cloud_thinking"
    L.cloud_thinking
    (budget_of fixture_cfg "glm-coding")
;;

let test_budget_local_27b () =
  check_budget "ollama -> local_27b" L.local_27b (budget_of fixture_cfg "ollama")
;;

let test_budget_local_70b_plus () =
  check_budget
    "big-local -> local_70b_plus"
    L.local_70b_plus
    (budget_of fixture_cfg "big-local")
;;

let test_budget_missing_class_fallback () =
  (* Provider exists but has no liveness_class — falls back to cloud_fast. *)
  check_budget "no-class -> cloud_fast" L.cloud_fast (budget_of fixture_cfg "no-class")
;;

let test_budget_unknown_provider () =
  (* Provider id not in cascade config — falls back to cloud_fast. *)
  check_budget
    "weird_provider_xyz -> cloud_fast"
    L.cloud_fast
    (budget_of fixture_cfg "weird_provider_xyz")
;;

let test_budget_case_insensitive () =
  check_budget
    "GLM-CODING -> cloud_thinking"
    L.cloud_thinking
    (budget_of fixture_cfg "GLM-CODING");
  check_budget "Codex_Cli -> cloud_fast" L.cloud_fast (budget_of fixture_cfg "Codex_Cli")
;;

let test_budget_whitespace_trim () =
  check_budget
    "  codex_cli  -> cloud_fast"
    L.cloud_fast
    (budget_of fixture_cfg "  codex_cli  ")
;;

(* Sanity: omitting [?cfg] uses the lazy disk-loaded cache (or returns
   cloud_fast when the disk config does not parse). We don't pin the
   in-tree config/cascade.toml contents here — the assertion is purely
   that the call shape works without an explicit [~cfg]. *)
let test_budget_no_explicit_cfg () =
  Cfg.reset_cache_for_test ();
  let b = Cfg.budget_for_provider_id ~provider_id:"weird_provider_xyz" () in
  Alcotest.(check bool) "fallback returns a valid budget" true (budget_eq L.cloud_fast b)
;;

let () =
  Alcotest.run
    "cascade_attempt_liveness_config"
    [ ( "mode parsing"
      , [ Alcotest.test_case "default unset -> observe" `Quick test_default_unset
        ; Alcotest.test_case "observe" `Quick test_observe_alias
        ; Alcotest.test_case "off" `Quick test_off_alias
        ; Alcotest.test_case "off via 0" `Quick test_off_zero
        ; Alcotest.test_case "enforce" `Quick test_enforce_alias
        ; Alcotest.test_case "enforce via kill" `Quick test_enforce_kill
        ; Alcotest.test_case "unknown -> observe" `Quick test_unknown_defaults_observe
        ; Alcotest.test_case "case insensitive" `Quick test_case_insensitive
        ] )
    ; ( "cache"
      , [ Alcotest.test_case "first read cached" `Quick test_cache_first_read
        ; Alcotest.test_case "reset_cache_for_test re-reads" `Quick test_reset_cache
        ] )
    ; "mode_label", [ Alcotest.test_case "stable labels" `Quick test_mode_labels ]
    ; ( "budget_for_provider_id (Phase 5.2b)"
      , [ Alcotest.test_case "cloud_fast providers" `Quick test_budget_cloud_fast
        ; Alcotest.test_case "cloud_thinking providers" `Quick test_budget_cloud_thinking
        ; Alcotest.test_case "local_27b provider" `Quick test_budget_local_27b
        ; Alcotest.test_case "local_70b_plus provider" `Quick test_budget_local_70b_plus
        ; Alcotest.test_case
            "provider without class -> cloud_fast"
            `Quick
            test_budget_missing_class_fallback
        ; Alcotest.test_case
            "unknown provider -> cloud_fast"
            `Quick
            test_budget_unknown_provider
        ; Alcotest.test_case "case insensitive" `Quick test_budget_case_insensitive
        ; Alcotest.test_case "whitespace trim" `Quick test_budget_whitespace_trim
        ; Alcotest.test_case
            "no explicit ?cfg uses disk cache fallback"
            `Quick
            test_budget_no_explicit_cfg
        ] )
    ]
;;
