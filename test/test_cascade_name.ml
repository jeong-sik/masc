(** RFC-0163 Phase A: Cascade_name.t unit tests.

    Validates the canonical-prefix enforcement that replaces the
    auto-normalize bypass in [cascade_catalog_runtime_resolve.ml]. *)

open Alcotest

module CN = Cascade_name

(* ── Valid parse tests ─────────────────────────────────────────── *)

let test_tier_group_prefix () =
  match CN.of_string "tier-group.strict_tool_candidates" with
  | Ok t ->
    check string "round-trip" "tier-group.strict_tool_candidates" (CN.to_string t)
  | Error _ -> fail "expected Ok for tier-group prefix"

let test_tier_prefix () =
  match CN.of_string "tier.primary" with
  | Ok t -> check string "round-trip" "tier.primary" (CN.to_string t)
  | Error _ -> fail "expected Ok for tier prefix"

let test_route_prefix () =
  match CN.of_string "route.default" with
  | Ok t -> check string "round-trip" "route.default" (CN.to_string t)
  | Error _ -> fail "expected Ok for route prefix"

let test_whitespace_trimmed () =
  match CN.of_string "  tier-group.x  " with
  | Ok t -> check string "round-trip" "tier-group.x" (CN.to_string t)
  | Error _ -> fail "expected Ok after trimming"

(* ── Invalid parse tests ───────────────────────────────────────── *)

let test_bare_short_form () =
  match CN.of_string "strict_tool_candidates" with
  | Ok _ -> fail "expected Error for bare short form"
  | Error `Invalid_prefix -> ()
  | Error `Empty -> fail "expected Invalid_prefix, got Empty"

let test_empty_string () =
  match CN.of_string "" with
  | Ok _ -> fail "expected Error for empty string"
  | Error `Empty -> ()
  | Error `Invalid_prefix -> fail "expected Empty, got Invalid_prefix"

let test_whitespace_only () =
  match CN.of_string "   " with
  | Ok _ -> fail "expected Error for whitespace-only"
  | Error `Empty -> ()
  | Error `Invalid_prefix -> fail "expected Empty, got Invalid_prefix"

let test_unknown_prefix () =
  match CN.of_string "group.something" with
  | Ok _ -> fail "expected Error for unknown prefix"
  | Error `Invalid_prefix -> ()
  | Error `Empty -> fail "expected Invalid_prefix, got Empty"

(* ── of_string_exn tests ──────────────────────────────────────── *)

let test_of_string_exn_ok () =
  check string "exn round-trip" "tier-group.x" (CN.to_string (CN.of_string_exn "tier-group.x"))

let test_is_canonical_prefix () =
  check bool "tier-group. is canonical" true (CN.is_canonical_prefix "tier-group.x");
  check bool "tier. is canonical" true (CN.is_canonical_prefix "tier.x");
  check bool "route. is canonical" true (CN.is_canonical_prefix "route.x");
  check bool "bare is not canonical" false (CN.is_canonical_prefix "x");
  check bool "empty is not canonical" false (CN.is_canonical_prefix "")

let () =
  Alcotest.run "cascade_name"
    [ ( "valid"
      , [ test_case "tier-group prefix" `Quick test_tier_group_prefix
        ; test_case "tier prefix" `Quick test_tier_prefix
        ; test_case "route prefix" `Quick test_route_prefix
        ; test_case "whitespace trimmed" `Quick test_whitespace_trimmed
        ] )
    ; ( "invalid"
      , [ test_case "bare short form" `Quick test_bare_short_form
        ; test_case "empty string" `Quick test_empty_string
        ; test_case "whitespace only" `Quick test_whitespace_only
        ; test_case "unknown prefix" `Quick test_unknown_prefix
        ] )
    ; ( "exn_and_helpers"
      , [ test_case "of_string_exn ok" `Quick test_of_string_exn_ok
        ; test_case "is_canonical_prefix" `Quick test_is_canonical_prefix
        ] )
    ]
