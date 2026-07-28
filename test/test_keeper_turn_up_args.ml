open Alcotest
open Masc

let test_resolve_mention_targets_uses_fallback_when_absent () =
  check
    (list string)
    "fallback targets"
    [ "existing" ]
    (Keeper_turn_up_args.resolve_mention_targets
       ~mention_targets_opt:None
       ~fallback_targets:[ "existing" ]
       ~name:"keeper-a")

let test_resolve_mention_targets_preserves_explicit_clear () =
  check
    (list string)
    "explicit clear"
    []
    (Keeper_turn_up_args.resolve_mention_targets
       ~mention_targets_opt:(Some [])
       ~fallback_targets:[ "existing" ]
       ~name:"keeper-a")

let test_resolve_mention_targets_normalizes_explicit_values () =
  check
    (list string)
    "deduped explicit targets"
    [ "alpha"; "beta" ]
    (Keeper_turn_up_args.resolve_mention_targets
       ~mention_targets_opt:(Some [ " alpha "; ""; "beta"; "alpha" ])
       ~fallback_targets:[ "existing" ]
       ~name:"keeper-a")

let override_json value = `Assoc [ "max_context_override", value ]

let test_parse_max_context_override () =
  let check_ok label expected value =
    match Keeper_turn_up_args.parse_max_context_override (override_json value) with
    | Ok actual -> check (pair bool (option int)) label expected actual
    | Error error -> failf "%s: %s" label error
  in
  let check_error label value =
    match Keeper_turn_up_args.parse_max_context_override (override_json value) with
    | Error _ -> ()
    | Ok _ -> failf "%s unexpectedly accepted" label
  in
  check_ok "positive exact" (true, Some 128_001) (`Int 128_001);
  check_ok "zero clears" (true, None) (`Int 0);
  check_ok "null clears" (true, None) `Null;
  check_error "negative" (`Int (-1));
  check_error "fraction" (`Float 3.9);
  check_error "overflow" (`Intlit "999999999999999999999999")

let test_runtime_json_rejects_toml_owned_max_context_override () =
  let parse value =
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "override-fixture"; "max_context_override", value ])
  in
  List.iter
    (fun value ->
      match parse value with
      | Error _ -> ()
      | Ok _ -> fail "TOML-owned max_context_override leaked into runtime JSON")
    [ `Int 128_001
    ; `Null
    ; `Int 0
    ; `Int (-1)
    ; `Float 3.9
    ; `Intlit "999999999999999999999999"
    ]

(* masc#25767: masc_keeper_up described itself as "Create or update a durable keeper"
   while creation required a sandbox_profile readable only from a keeper TOML the tool
   does not write. The argument was parsed and honoured on update but ignored by the
   create gate, so a keeper that did not already exist on disk could not be created —
   the reason the APC run's librarian role was never registered. *)
let test_requested_sandbox_profile_wins_over_the_toml_fallback () =
  let module A = Keeper_turn_up_args in
  check
    bool
    "an explicit request creates without a TOML default"
    true
    (A.resolve_sandbox_profile ~requested:"docker" ~fallback:None ()
     = Keeper_types_profile_toml_io.Docker);
  check
    bool
    "an explicit request overrides the TOML default"
    true
    (A.resolve_sandbox_profile
       ~requested:"local"
       ~fallback:(Some Keeper_types_profile_toml_io.Docker)
       ()
     = Keeper_types_profile_toml_io.Local);
  check
    bool
    "no request keeps the TOML default"
    true
    (A.resolve_sandbox_profile
       ~fallback:(Some Keeper_types_profile_toml_io.Docker)
       ()
     = Keeper_types_profile_toml_io.Docker);
  (* Unparseable is treated as absent rather than mapped to a profile: the tool gate
     rejects it before this point, and inventing an isolation boundary here would hide
     that rejection if the gate were ever bypassed. *)
  check
    bool
    "an unparseable request falls back rather than choosing a boundary"
    true
    (A.resolve_sandbox_profile
       ~requested:"chroot"
       ~fallback:(Some Keeper_types_profile_toml_io.Docker)
       ()
     = Keeper_types_profile_toml_io.Docker);
  (* Nothing stated gets the narrow local + playground-only bootstrap profile. *)
  check
    bool
    "neither stated resolves to the local sandbox default"
    true
    (A.resolve_sandbox_profile ~fallback:None ()
     = Keeper_types_profile_toml_io.Local)
;;

let () =
  run
    "keeper_turn_up_args"
    [ ( "mention_targets"
      , [ test_case
            "absent mention_targets uses fallback"
            `Quick
            test_resolve_mention_targets_uses_fallback_when_absent
        ; test_case
            "explicit empty mention_targets clears"
            `Quick
            test_resolve_mention_targets_preserves_explicit_clear
        ; test_case
            "explicit mention_targets normalize and dedupe"
            `Quick
            test_resolve_mention_targets_normalizes_explicit_values
        ] )
    ; ( "sandbox_profile"
      , [ test_case
            "requested profile wins over the TOML fallback"
            `Quick
            test_requested_sandbox_profile_wins_over_the_toml_fallback
        ] )
    ; ( "max_context_override"
      , [ test_case "request values are exact or rejected" `Quick test_parse_max_context_override
        ; test_case "runtime JSON rejects TOML-owned field" `Quick
            test_runtime_json_rejects_toml_owned_max_context_override
        ] )
    ]
;;
