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

let rec rm_rf path =
  if Sys.is_directory path
  then (
    Array.iter (fun entry -> rm_rf (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

(* Recursive, not [Unix.rmdir]: once any test in this binary has installed the
   process-global Eio fs (the persist round-trip below), later contexts can
   materialize files under their base, and an empty-dir-only cleanup fails the
   wrong test. *)
let with_test_context f =
  let base = Filename.temp_file "keeper-turn-up-args-" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let ctx : _ Keeper_types_profile.context =
        { config = Workspace.default_config base
        ; agent_name = "test-agent"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = None
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.non_runtime_publication_recovery_provider
        }
      in
      f ctx)

let test_parse_rejects_runtime_agent_identity_as_keeper_name () =
  with_test_context @@ fun ctx ->
  List.iter
    (fun agent_name ->
      match
        Keeper_turn_up_args.parse ctx
          (`Assoc [ "name", `String agent_name ])
      with
      | Ok _ ->
        failf "runtime agent identity %S was accepted as a keeper name" agent_name
      | Error result ->
        let body = Keeper_types_profile.tool_result_body result in
        check bool "identifies the wrong identity kind" true
          (String.starts_with body ~prefix:"invalid keeper name:");
        check bool "names the canonical keeper" true
          (String.ends_with body
             ~suffix:"use the canonical keeper name \"omega\""))
    [ "keeper-omega-agent"
    ; "keeper_omega_agent"
    ; "keeper-omega_agent"
    ; "keeper_omega-agent"
    ]

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

let wake_prompt_json value = `Assoc [ "autonomous_wake_prompt", value ]

(* Shares Env_config_keeper.KeeperAutonomous.validate_wake_prompt with the
   fleet env reader and the keeper TOML parser, so the cases below pin the
   whole contract once: blank rejected (never folded into "unset"), byte
   bound enforced at the boundary, null as the only explicit clear. *)
let test_parse_autonomous_wake_prompt () =
  let parse value =
    Keeper_turn_up_args.parse_autonomous_wake_prompt (wake_prompt_json value)
  in
  let check_ok label expected value =
    match parse value with
    | Ok actual -> check (pair bool (option string)) label expected actual
    | Error error -> failf "%s: %s" label error
  in
  let check_error label value =
    match parse value with
    | Error _ -> ()
    | Ok _ -> failf "%s unexpectedly accepted" label
  in
  (match Keeper_turn_up_args.parse_autonomous_wake_prompt (`Assoc []) with
   | Ok actual ->
     check (pair bool (option string)) "absent field" (false, None) actual
   | Error error -> failf "absent field: %s" error);
  check_ok "null clears" (true, None) `Null;
  check_ok
    "value is trimmed and preserved"
    (true, Some "백로그를 확인하고 하나 진행해.")
    (`String "  백로그를 확인하고 하나 진행해. \n");
  check_error "blank is rejected, not folded into unset" (`String "   ");
  check_error "empty is rejected" (`String "");
  check_error "non-string" (`Int 3);
  let bound = Env_config_keeper.KeeperAutonomous.max_wake_prompt_bytes in
  check_ok
    "exactly at the byte bound"
    (true, Some (String.make bound 'a'))
    (`String (String.make bound 'a'));
  check_error "one byte over the bound" (`String (String.make (bound + 1) 'a'))

(* Unlike [with_test_context], persist writes the keeper TOML under the
   base, so cleanup must be recursive. *)
let with_persisting_context f =
  let base = Filename.temp_file "keeper-turn-up-persist-" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
      Eio_main.run @@ fun env ->
      if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw ->
      let ctx : _ Keeper_types_profile.context =
        { config = Workspace.default_config base
        ; agent_name = "test-agent"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = None
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.non_runtime_publication_recovery_provider
        }
      in
      f ctx)

(* End-to-end for the settable surface behind the dashboard PATCH and
   masc_keeper_up: parse -> TOML persist -> profile-defaults read-back, then
   an explicit null clears the key instead of writing an empty one. *)
let test_persist_round_trips_wake_prompt () =
  with_persisting_context @@ fun ctx ->
  let name = "wake-persist-fixture" in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ])
    with
    | Ok meta -> meta
    | Error error -> failf "meta fixture: %s" error
  in
  let parse_or_fail json =
    match Keeper_turn_up_args.parse ctx json with
    | Ok parsed -> parsed
    | Error result -> failf "parse: %s" (Keeper_types_profile.tool_result_body result)
  in
  let persist_or_fail parsed =
    match
      Keeper_turn_up_config_persistence.persist ~config:ctx.config ~parsed ~meta
    with
    | Ok (_ : Keeper_turn_up_config_persistence.outcome) -> ()
    | Error error -> failf "persist: %s" error
  in
  let read_back () =
    match
      Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
        ~base_path:ctx.config.base_path
        name
    with
    | Ok defaults -> defaults.Keeper_types_profile.autonomous_wake_prompt
    | Error error ->
      failf "read back: %s" (Keeper_types_profile.keeper_toml_load_error_to_string error)
  in
  persist_or_fail
    (parse_or_fail
       (`Assoc
          [ "name", `String name
          ; "instructions", `String "fixture instructions"
          ; "autonomous_wake_prompt", `String "백로그를 확인하고 하나 진행해."
          ]));
  check
    (option string)
    "persisted keeper TOML round-trips through the profile parser"
    (Some "백로그를 확인하고 하나 진행해.")
    (read_back ());
  persist_or_fail
    (parse_or_fail (`Assoc [ "name", `String name; "autonomous_wake_prompt", `Null ]));
  check
    (option string)
    "an explicit null removes the key instead of writing an empty value"
    None
    (read_back ())

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
    ; ( "autonomous_wake_prompt"
      , [ test_case
            "shared wake-prompt contract: trim, blank reject, byte bound, null clear"
            `Quick
            test_parse_autonomous_wake_prompt
        ; test_case
            "persist round-trips the keeper TOML and null removes the key"
            `Quick
            test_persist_round_trips_wake_prompt
        ] )
    ; ( "keeper_name"
      , [ test_case
            "runtime agent identities are rejected"
            `Quick
            test_parse_rejects_runtime_agent_identity_as_keeper_name
        ] )
    ]
;;
