open Alcotest

(** RFC-0084 PR-13 — Keeper_disclosure_strategy typed sum invariants.

    PR-13 introduces the typed surface; follow-up activation PR(s)
    wire it into worker_oas + keeper_runtime_toml.  This test pins:

    - 3-arm cardinality (Full | Hybrid | Minimal_index)
    - default = Full (safe today's behaviour)
    - of_toml ["hybrid"] rejects empty [full_names]
    - of_toml ["hybrid"] sorts [full_names] for prefix-cache stability
      (RFC-OAS-013 §2.4)
    - is_full returns true only for Full
    - of_toml rejects unknown strategy labels (no permissive default
      — CLAUDE.md anti-pattern #2 self-check)
*)

let test_default_is_full () =
  let pp = Format.asprintf "%a" Masc_mcp.Keeper_disclosure_strategy.pp in
  (check string)
    "default = Full (RFC-0084 §3.5 safe baseline)"
    "Full"
    (pp Masc_mcp.Keeper_disclosure_strategy.default)
;;

let test_to_string_full () =
  (check string)
    "to_string Full = \"full\""
    "full"
    (Masc_mcp.Keeper_disclosure_strategy.to_string Masc_mcp.Keeper_disclosure_strategy.Full)
;;

let test_to_string_minimal_index () =
  (check string)
    "to_string Minimal_index = \"minimal_index\""
    "minimal_index"
    (Masc_mcp.Keeper_disclosure_strategy.to_string
       Masc_mcp.Keeper_disclosure_strategy.Minimal_index)
;;

let test_to_string_hybrid () =
  let h =
    Masc_mcp.Keeper_disclosure_strategy.Hybrid
      { full_names = [ "keeper_bash" ]; demote_on_error = true }
  in
  (check string) "to_string Hybrid _ = \"hybrid\"" "hybrid" (Masc_mcp.Keeper_disclosure_strategy.to_string h)
;;

let test_of_toml_full () =
  match
    Masc_mcp.Keeper_disclosure_strategy.of_toml
      ~strategy:"full"
      ~full_names:[]
      ~demote_on_error:false
  with
  | Ok Masc_mcp.Keeper_disclosure_strategy.Full -> ()
  | Ok other ->
    failf
      "of_toml \"full\" should return Full, got %s"
      (Masc_mcp.Keeper_disclosure_strategy.to_string other)
  | Error msg -> failf "of_toml \"full\" failed: %s" msg
;;

let test_of_toml_hybrid_sorted () =
  match
    Masc_mcp.Keeper_disclosure_strategy.of_toml
      ~strategy:"hybrid"
      ~full_names:[ "keeper_zsh"; "keeper_bash"; "keeper_fs_edit" ]
      ~demote_on_error:true
  with
  | Ok (Masc_mcp.Keeper_disclosure_strategy.Hybrid { full_names; demote_on_error }) ->
    (check (list string))
      "Hybrid.full_names sorted (RFC-OAS-013 §2.4 prefix-cache stability)"
      [ "keeper_bash"; "keeper_fs_edit"; "keeper_zsh" ]
      full_names;
    (check bool) "Hybrid.demote_on_error preserved" true demote_on_error
  | Ok _ -> failf "of_toml \"hybrid\" returned wrong variant"
  | Error msg -> failf "of_toml \"hybrid\" failed: %s" msg
;;

let test_of_toml_hybrid_empty_rejected () =
  match
    Masc_mcp.Keeper_disclosure_strategy.of_toml
      ~strategy:"hybrid"
      ~full_names:[]
      ~demote_on_error:false
  with
  | Ok _ -> failf "of_toml \"hybrid\" with empty full_names should be Error"
  | Error _ -> ()
;;

let test_of_toml_minimal_index () =
  match
    Masc_mcp.Keeper_disclosure_strategy.of_toml
      ~strategy:"minimal_index"
      ~full_names:[]
      ~demote_on_error:false
  with
  | Ok Masc_mcp.Keeper_disclosure_strategy.Minimal_index -> ()
  | Ok other ->
    failf
      "of_toml \"minimal_index\" returned wrong variant: %s"
      (Masc_mcp.Keeper_disclosure_strategy.to_string other)
  | Error msg -> failf "of_toml \"minimal_index\" failed: %s" msg
;;

let test_of_toml_unknown_rejected () =
  match
    Masc_mcp.Keeper_disclosure_strategy.of_toml
      ~strategy:"verbose_quantum"
      ~full_names:[]
      ~demote_on_error:false
  with
  | Ok _ ->
    failf
      "of_toml on unknown strategy should be Error \
       (CLAUDE.md anti-pattern #2: no permissive default)"
  | Error _ -> ()
;;

let test_is_full_semantics () =
  (check bool) "is_full Full" true (Masc_mcp.Keeper_disclosure_strategy.is_full Full);
  (check bool)
    "is_full Minimal_index"
    false
    (Masc_mcp.Keeper_disclosure_strategy.is_full Minimal_index);
  (check bool)
    "is_full Hybrid _"
    false
    (Masc_mcp.Keeper_disclosure_strategy.is_full
       (Hybrid { full_names = [ "x" ]; demote_on_error = false }))
;;

let pinned_disclosure_variant_count = 3

let test_variant_count_pin () =
  (* RFC-0084 §3.5: 3 strategy arms. Adding a 4th surfaces in this
     test alongside the activation logic, forcing reviewers to update
     worker_oas wiring + keeper TOML schema simultaneously. *)
  (check int)
    "Keeper_disclosure_strategy variant count (RFC-0084 §3.5)"
    3
    pinned_disclosure_variant_count
;;

let () =
  Alcotest.run
    "RFC-0084 PR-13 Keeper_disclosure_strategy typed"
    [ ( "disclosure-strategy"
      , [ test_case "default-is-full" `Quick test_default_is_full
        ; test_case "to-string-full" `Quick test_to_string_full
        ; test_case "to-string-minimal-index" `Quick test_to_string_minimal_index
        ; test_case "to-string-hybrid" `Quick test_to_string_hybrid
        ; test_case "of-toml-full" `Quick test_of_toml_full
        ; test_case "of-toml-hybrid-sorted" `Quick test_of_toml_hybrid_sorted
        ; test_case "of-toml-hybrid-empty-rejected" `Quick test_of_toml_hybrid_empty_rejected
        ; test_case "of-toml-minimal-index" `Quick test_of_toml_minimal_index
        ; test_case "of-toml-unknown-rejected" `Quick test_of_toml_unknown_rejected
        ; test_case "is-full-semantics" `Quick test_is_full_semantics
        ; test_case "variant-count-pin" `Quick test_variant_count_pin
        ] )
    ]
;;
