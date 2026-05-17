(** Unit tests for the cascade-config / fallback max_tokens clamp introduced
    on 2026-05-17 to fix fleet-wide [pre_dispatch_max_tokens_ceiling_violation]
    after the multilane cascade rollout (see PR body for incident timeline).

    Tests target [Cascade_inference.For_testing.clamp_with_ceiling] so they
    do not need a live cascade.toml on disk; the production helper
    [resolve_max_tokens] composes the same clamp with the catalog-driven
    ceiling lookup. *)

open Masc_mcp

let cascade name =
  Masc_mcp.Keeper_cascade_profile.runtime_name_of_string name

let reset () =
  Cascade_inference.For_testing.reset_auto_max_tokens_clamp_warnings ()

let test_no_ceiling_passes_through () =
  reset ();
  let out =
    Cascade_inference.For_testing.clamp_with_ceiling
      ~cascade_name:(cascade "tier-group.test_a")
      ~source:"cascade_config"
      ~ceiling:None
      16384
  in
  Alcotest.(check int) "no ceiling -> requested returned unchanged" 16384 out

let test_ceiling_above_request_passes_through () =
  reset ();
  let out =
    Cascade_inference.For_testing.clamp_with_ceiling
      ~cascade_name:(cascade "tier-group.test_b")
      ~source:"cascade_config"
      ~ceiling:(Some 32000)
      16384
  in
  Alcotest.(check int) "request below ceiling -> unchanged" 16384 out

let test_ceiling_at_request_passes_through () =
  reset ();
  let out =
    Cascade_inference.For_testing.clamp_with_ceiling
      ~cascade_name:(cascade "tier-group.test_c")
      ~source:"cascade_config"
      ~ceiling:(Some 16384)
      16384
  in
  Alcotest.(check int) "request == ceiling -> unchanged" 16384 out

let test_ceiling_below_request_clamps () =
  reset ();
  let out =
    Cascade_inference.For_testing.clamp_with_ceiling
      ~cascade_name:(cascade "tier-group.glm-coding-with-spark")
      ~source:"cascade_config"
      ~ceiling:(Some 8192)
      16384
  in
  Alcotest.(check int)
    "cascade_config 16384 vs ceiling 8192 -> clamped to ceiling"
    8192 out

let test_fallback_source_clamps () =
  reset ();
  let out =
    Cascade_inference.For_testing.clamp_with_ceiling
      ~cascade_name:(cascade "tier-group.test_d")
      ~source:"fallback"
      ~ceiling:(Some 8192)
      16384
  in
  Alcotest.(check int) "fallback source also clamped" 8192 out

let test_caller_override_source_clamps () =
  reset ();
  let out =
    Cascade_inference.For_testing.clamp_with_ceiling
      ~cascade_name:(cascade "tier-group.test_override")
      ~source:"caller_override"
      ~ceiling:(Some 8192)
      16384
  in
  Alcotest.(check int) "caller override source also clamped" 8192 out

let test_zero_ceiling_treated_as_no_ceiling () =
  reset ();
  let out =
    Cascade_inference.For_testing.clamp_with_ceiling
      ~cascade_name:(cascade "tier-group.test_e")
      ~source:"cascade_config"
      ~ceiling:(Some 0)
      16384
  in
  Alcotest.(check int) "ceiling=0 treated as no ceiling, no clamp" 16384 out

let test_negative_ceiling_treated_as_no_ceiling () =
  reset ();
  let out =
    Cascade_inference.For_testing.clamp_with_ceiling
      ~cascade_name:(cascade "tier-group.test_f")
      ~source:"cascade_config"
      ~ceiling:(Some (-1))
      16384
  in
  Alcotest.(check int) "negative ceiling -> no clamp" 16384 out

let test_warn_dedup_per_tuple () =
  reset ();
  let name = cascade "tier-group.test_g" in
  let first =
    Cascade_inference.For_testing.should_log_auto_max_tokens_clamp
      ~cascade_name:name ~source:"cascade_config" ~max_tokens:16384 ~ceiling:8192
  in
  let second =
    Cascade_inference.For_testing.should_log_auto_max_tokens_clamp
      ~cascade_name:name ~source:"cascade_config" ~max_tokens:16384 ~ceiling:8192
  in
  Alcotest.(check bool) "first occurrence logs" true first;
  Alcotest.(check bool) "duplicate suppressed" false second

let test_warn_emits_distinct_source () =
  reset ();
  let name = cascade "tier-group.test_h" in
  let cfg =
    Cascade_inference.For_testing.should_log_auto_max_tokens_clamp
      ~cascade_name:name ~source:"cascade_config" ~max_tokens:16384 ~ceiling:8192
  in
  let fb =
    Cascade_inference.For_testing.should_log_auto_max_tokens_clamp
      ~cascade_name:name ~source:"fallback" ~max_tokens:16384 ~ceiling:8192
  in
  Alcotest.(check bool) "cascade_config source logs" true cfg;
  Alcotest.(check bool) "fallback source separately logs" true fb

let test_warn_emits_distinct_caller_override_source () =
  reset ();
  let name = cascade "tier-group.test_i" in
  let cfg =
    Cascade_inference.For_testing.should_log_auto_max_tokens_clamp
      ~cascade_name:name ~source:"cascade_config" ~max_tokens:16384 ~ceiling:8192
  in
  let override =
    Cascade_inference.For_testing.should_log_auto_max_tokens_clamp
      ~cascade_name:name ~source:"caller_override" ~max_tokens:16384
      ~ceiling:8192
  in
  Alcotest.(check bool) "cascade_config source logs" true cfg;
  Alcotest.(check bool) "caller_override source separately logs" true override

let () =
  Alcotest.run
    "cascade_inference clamp"
    [ ( "clamp"
      , [ Alcotest.test_case "no ceiling -> passthrough" `Quick
            test_no_ceiling_passes_through
        ; Alcotest.test_case "ceiling above -> passthrough" `Quick
            test_ceiling_above_request_passes_through
        ; Alcotest.test_case "ceiling == request -> passthrough" `Quick
            test_ceiling_at_request_passes_through
        ; Alcotest.test_case "ceiling below -> clamp" `Quick
            test_ceiling_below_request_clamps
        ; Alcotest.test_case "fallback source clamp" `Quick
            test_fallback_source_clamps
        ; Alcotest.test_case "caller override source clamp" `Quick
            test_caller_override_source_clamps
        ; Alcotest.test_case "ceiling=0 -> no clamp" `Quick
            test_zero_ceiling_treated_as_no_ceiling
        ; Alcotest.test_case "negative ceiling -> no clamp" `Quick
            test_negative_ceiling_treated_as_no_ceiling
        ] )
    ; ( "warn-dedup"
      , [ Alcotest.test_case "per-tuple dedup" `Quick test_warn_dedup_per_tuple
        ; Alcotest.test_case "distinct source emits separately" `Quick
            test_warn_emits_distinct_source
        ; Alcotest.test_case "caller override source emits separately" `Quick
            test_warn_emits_distinct_caller_override_source
        ] )
    ]
