(** Drift gate for [canonical_keeper_meta_key_names].

    The reflection-via-roundtrip pattern in [keeper_meta_json.ml] derives the
    canonical key list by parsing a minimal seed JSON and re-serialising it.
    If a future change adds a new fail-loud required field to [meta_of_json]
    without updating the seed, the seed parse fails and the function silently
    falls back to [fallback_canonical_keeper_meta_key_names] — which floods
    [warn_unknown_keeper_meta_keys] on every keeper read.

    Regression: PR #11594 (fail-loud sandbox_profile/network_mode parsing,
    2026-04-28) broke this without test coverage; production logs flooded
    with "unknown keys" warnings on every reconcile tick (~3000/day). *)

open Masc_mcp

let target_keys =
  [ "sandbox_profile"
  ; "network_mode"
  ; "shared_memory_scope"
  ; "tool_preset_source"
  ; "max_checkpoint_messages"
  ; "always_approve"
  ; "keeper_id"
  ; "meta_version"
  ]

let test_canonical_includes_post_pr11594_keys () =
  let canonical = Keeper_meta_json.canonical_keeper_meta_key_names in
  List.iter
    (fun key ->
      Alcotest.(check bool)
        (Printf.sprintf
           "canonical_keeper_meta_key_names contains %s (seed must satisfy \
            fail-loud parse)"
           key)
        true
        (List.mem key canonical))
    target_keys

let test_canonical_disjoint_from_fallback_when_seed_parses () =
  (* When the seed parses, [canonical_keeper_meta_key_names] should be derived
     from [meta_to_json], not from [fallback_canonical_keeper_meta_key_names].
     The static fallback is missing post-PR-11594 keys; if our canonical list
     equals it byte-for-byte we are silently in fallback mode. *)
  let canonical = Keeper_meta_json.canonical_keeper_meta_key_names in
  let fallback = Keeper_meta_json.fallback_canonical_keeper_meta_key_names in
  Alcotest.(check bool)
    "canonical list differs from fallback (seed parse must succeed)"
    true
    (canonical <> fallback)

let () =
  Alcotest.run
    "keeper_meta_canonical_seed"
    [ ( "drift_gate"
      , [ Alcotest.test_case
            "post-PR-11594 keys present"
            `Quick
            test_canonical_includes_post_pr11594_keys
        ; Alcotest.test_case
            "not collapsed to fallback"
            `Quick
            test_canonical_disjoint_from_fallback_when_seed_parses
        ] )
    ]
;;
