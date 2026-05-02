(** test_effective_oas_env — Gemini CLI MCP auto-enable verification.

    Pins three invariants of [Keeper_types_profile.effective_oas_env]:

    1. Default injection: when no OAS_GEMINI_* env vars are set,
       [OAS_GEMINI_ALLOWED_MCP] is injected with value "masc".
    2. Disabled passthrough: when [OAS_GEMINI_NO_MCP=true],
       injection must NOT occur (operator opted out).
    3. Operator override preserved: when operator sets a custom
       [OAS_GEMINI_ALLOWED_MCP], it is preserved verbatim.

    Also pins [keeper_oas_context_of_defaults] derived field:
    4. [gemini_allowed_mcp_derived] is [true] when default injection
       occurs, [false] when operator or disabled.

    Cross-reference:
    - [lib/keeper/keeper_types_profile.ml] — [effective_oas_env]
    - [lib/keeper/keeper_mcp_provider_audit.ml] — SSOT audit table
    - OAS [transport_gemini_cli.ml:67-85] — sentinel behavior *)

open Alcotest

module KTP = Masc_mcp.Keeper_types_profile

(* ── effective_oas_env tests ───────────────────────────────── *)

let test_default_injects_masc () =
  let pairs = KTP.effective_oas_env [] in
  match List.assoc_opt "OAS_GEMINI_ALLOWED_MCP" pairs with
  | Some value ->
    check string "default injection is 'masc'" "masc" value
  | None ->
    fail "OAS_GEMINI_ALLOWED_MCP not injected on empty input"

let test_disabled_skips_injection () =
  let pairs =
    KTP.effective_oas_env [ ("OAS_GEMINI_NO_MCP", "true") ]
  in
  match List.assoc_opt "OAS_GEMINI_ALLOWED_MCP" pairs with
  | Some _ ->
    fail "OAS_GEMINI_ALLOWED_MCP injected despite NO_MCP=true"
  | None ->
    check bool "disabled skips injection" true true

let test_operator_override_preserved () =
  let pairs =
    KTP.effective_oas_env
      [ ("OAS_GEMINI_ALLOWED_MCP", "custom-server,other") ]
  in
  match List.assoc_opt "OAS_GEMINI_ALLOWED_MCP" pairs with
  | Some value ->
    check string "operator override preserved"
      "custom-server,other" value
  | None ->
    fail "OAS_GEMINI_ALLOWED_MCP missing despite operator setting"

let test_operator_empty_string_preserved () =
  (* When operator explicitly sets empty string, the key exists in input
     so List.assoc_opt finds "" (the first match) even though injection
     appends "masc" as a second entry. This means operator's empty-string
     opt-out is preserved — the transport reads the first value. *)
  let pairs =
    KTP.effective_oas_env [ ("OAS_GEMINI_ALLOWED_MCP", "") ]
  in
  match List.assoc_opt "OAS_GEMINI_ALLOWED_MCP" pairs with
  | Some value ->
    check string "empty string preserved (first match)" "" value
  | None ->
    fail "OAS_GEMINI_ALLOWED_MCP missing"

let test_approval_mode_injected_with_no_mcp () =
  let pairs =
    KTP.effective_oas_env [ ("OAS_GEMINI_NO_MCP", "true") ]
  in
  match List.assoc_opt "OAS_GEMINI_APPROVAL_MODE" pairs with
  | Some value ->
    check string "approval mode injected when MCP disabled" "plan" value
  | None ->
    fail "OAS_GEMINI_APPROVAL_MODE not injected when MCP disabled"

let test_approval_mode_not_overridden () =
  let pairs =
    KTP.effective_oas_env
      [
        ("OAS_GEMINI_NO_MCP", "true");
        ("OAS_GEMINI_APPROVAL_MODE", "auto");
      ]
  in
  match List.assoc_opt "OAS_GEMINI_APPROVAL_MODE" pairs with
  | Some value ->
    check string "operator approval mode preserved" "auto" value
  | None ->
    fail "OAS_GEMINI_APPROVAL_MODE missing"

(* ── keeper_oas_context_of_defaults tests ──────────────────── *)

let test_context_derived_flag_default () =
  let defaults = { KTP.empty_keeper_profile_defaults with oas_env = [] } in
  let ctx = KTP.keeper_oas_context_of_defaults defaults in
  check bool "gemini_allowed_mcp_derived is true by default"
    true ctx.gemini_allowed_mcp_derived

let test_context_derived_flag_disabled () =
  let defaults =
    {
      KTP.empty_keeper_profile_defaults with
      oas_env = [ ("OAS_GEMINI_NO_MCP", "true") ];
    }
  in
  let ctx = KTP.keeper_oas_context_of_defaults defaults in
  check bool "gemini_allowed_mcp_derived is false when disabled"
    false ctx.gemini_allowed_mcp_derived

let test_context_derived_flag_operator () =
  let defaults =
    {
      KTP.empty_keeper_profile_defaults with
      oas_env = [ ("OAS_GEMINI_ALLOWED_MCP", "my-server") ];
    }
  in
  let ctx = KTP.keeper_oas_context_of_defaults defaults in
  check bool "gemini_allowed_mcp_derived is false when operator set"
    false ctx.gemini_allowed_mcp_derived

let test_context_env_pairs_contain_masc () =
  let defaults = { KTP.empty_keeper_profile_defaults with oas_env = [] } in
  let ctx = KTP.keeper_oas_context_of_defaults defaults in
  match List.assoc_opt "OAS_GEMINI_ALLOWED_MCP" ctx.env_pairs with
  | Some value ->
    check string "env_pairs contains masc" "masc" value
  | None ->
    fail "OAS_GEMINI_ALLOWED_MCP missing from env_pairs"

(* ── Test suite ────────────────────────────────────────────── *)

let () =
  Alcotest.run "effective_oas_env"
    [
      ( "injection",
        [
          Alcotest.test_case "empty input injects OAS_GEMINI_ALLOWED_MCP=masc"
            `Quick test_default_injects_masc;
          Alcotest.test_case "NO_MCP=true skips injection"
            `Quick test_disabled_skips_injection;
          Alcotest.test_case "operator override preserved verbatim"
            `Quick test_operator_override_preserved;
          Alcotest.test_case "empty string preserved as operator opt-out"
            `Quick test_operator_empty_string_preserved;
        ] );
      ( "approval_mode",
        [
          Alcotest.test_case "approval mode injected when MCP disabled"
            `Quick test_approval_mode_injected_with_no_mcp;
          Alcotest.test_case "operator approval mode not overridden"
            `Quick test_approval_mode_not_overridden;
        ] );
      ( "context_derived",
        [
          Alcotest.test_case "gemini_allowed_mcp_derived true by default"
            `Quick test_context_derived_flag_default;
          Alcotest.test_case "gemini_allowed_mcp_derived false when disabled"
            `Quick test_context_derived_flag_disabled;
          Alcotest.test_case "gemini_allowed_mcp_derived false when operator set"
            `Quick test_context_derived_flag_operator;
          Alcotest.test_case "env_pairs contains masc from context"
            `Quick test_context_env_pairs_contain_masc;
        ] );
    ]
