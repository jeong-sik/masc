(* Both keeper turn entry points must take the meta they run with from
   [Keeper_unified_turn_pre_dispatch.turn_profile_and_meta].

   Durable keeper JSON carries none of [keeper_meta]'s config fields, so a
   registry entry's [sandbox_profile] is always the decoder's placeholder
   [Local]; the keeper TOML is the only source that can say [docker]. When
   each entry point spelled the two-step overlay itself,
   [Keeper_unified_turn.run_keeper_cycle] kept the first step and dropped the
   second: it loaded the profile snapshot for the runtime builder and then ran
   the turn on the un-overlaid [entry.meta]. Every heartbeat turn's [Execute]
   dispatched to the host while its keeper declared [docker] -- measured on
   2026-08-27 as 2450 host calls against 15 contained ones across the seven
   keepers that declared it (#30982).

   Loading the snapshot on a turn path without applying it is the shape that
   caused this, so that is what these tests forbid. *)

let turn_entry_points =
  [ "lib/keeper/keeper_unified_turn.ml"; "lib/keeper/keeper_turn.ml" ]
;;

let shared_resolver = "Keeper_unified_turn_pre_dispatch.turn_profile_and_meta"

let bare_loader = "Keeper_unified_turn_pre_dispatch.load_profile_defaults"

let test_entry_points_do_not_load_the_snapshot_alone () =
  Alcotest.(check int)
    "a turn entry point never loads the profile snapshot on its own -- doing \
     so is how the overlay went missing"
    0
    (Ast_grep.count_calls_across_files
       ~module_paths:turn_entry_points
       ~callee:bare_loader)
;;

let test_every_entry_point_resolves_through_the_shared_function () =
  List.iter
    (fun module_path ->
      Alcotest.(check int)
        (Printf.sprintf "%s resolves its turn meta through %s" module_path shared_resolver)
        1
        (Ast_grep.count_calls ~module_path ~callee:shared_resolver))
    turn_entry_points
;;

let test_entry_points_do_not_apply_the_overlay_themselves () =
  Alcotest.(check int)
    "the overlay is applied in one place, not once per entry point"
    0
    (Ast_grep.count_calls_across_files
       ~module_paths:turn_entry_points
       ~callee:"Keeper_meta_contract.effective_meta_of_profile_defaults")
;;

(* ------------------------------------------------------------------ *)
(* Config-load gate: profile defaults resolving to [Local]            *)
(* ------------------------------------------------------------------ *)

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0
;;

let hatch_key = "MASC_EXEC_ALLOW_LOCAL_PLAYGROUND"

(* Every case restores the cleared state so no empty-string value leaks into
   the next case (env is process-global). Same hygiene as
   test_keeper_turn_up_args. *)
let with_hatch value f =
  Unix.putenv hatch_key value;
  Fun.protect ~finally:(fun () -> Unix.putenv hatch_key "") f
;;

(* A keeper TOML that declares [sandbox_profile = "local"]: the manifest
   source is present and the resolved profile is [Local]. *)
let local_profile_defaults =
  { Masc.Keeper_types_profile.empty_keeper_profile_defaults with
    manifest_path = Some ".masc/config/keepers/local-gated.toml"
  ; sandbox_profile = Some Keeper_types_profile_sandbox.Local
  }
;;

let gate_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "local-gated"
        ; "agent_name", `String "keeper-local-gated-agent"
        ; "trace_id", `String "trace-local-gated"
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail err
;;

let test_local_profile_defaults_rejected_when_gate_off () =
  with_hatch "" (fun () ->
      match
        Masc.Keeper_meta_contract.effective_meta_of_profile_defaults
          local_profile_defaults
          (gate_meta ())
      with
      | Error msg ->
        Alcotest.(check bool) "error names disabled" true (contains "disabled" msg)
      | Ok _ ->
        Alcotest.fail "local profile defaults must be rejected when the gate is off")
;;

let test_local_profile_defaults_allowed_with_hatch () =
  with_hatch "true" (fun () ->
      match
        Masc.Keeper_meta_contract.effective_meta_of_profile_defaults
          local_profile_defaults
          (gate_meta ())
      with
      | Ok meta ->
        Alcotest.(check string)
          "hatch keeps the resolved profile"
          "local"
          (Masc.Keeper_types_profile.sandbox_profile_to_string meta.sandbox_profile)
      | Error err -> Alcotest.fail ("hatch must allow local: " ^ err))
;;

(* No profile source at all: the resolution falls back to the meta's own
   [sandbox_profile], which for any durable keeper JSON is the decoder's
   placeholder [Local] -- the gate rejects that fallback just the same. *)
let test_no_profile_source_fallback_rejected_when_gate_off () =
  with_hatch "" (fun () ->
      match
        Masc.Keeper_meta_contract.effective_meta_of_profile_defaults
          Masc.Keeper_types_profile.empty_keeper_profile_defaults
          (gate_meta ())
      with
      | Error msg ->
        Alcotest.(check bool) "error names disabled" true (contains "disabled" msg)
      | Ok _ ->
        Alcotest.fail "no-source fallback to Local must be rejected when the gate is off")
;;

let () =
  Alcotest.run
    "keeper_turn_sandbox_profile_gate"
    [ ( "turn_meta_resolution"
      , [ Alcotest.test_case
            "turn entry points do not load the profile snapshot alone"
            `Quick
            test_entry_points_do_not_load_the_snapshot_alone
        ; Alcotest.test_case
            "every turn entry point resolves through the shared function"
            `Quick
            test_every_entry_point_resolves_through_the_shared_function
        ; Alcotest.test_case
            "the overlay is not re-applied per entry point"
            `Quick
            test_entry_points_do_not_apply_the_overlay_themselves
        ] )
    ; ( "config_load_gate"
      , [ Alcotest.test_case
            "local profile defaults rejected when the gate is off"
            `Quick
            test_local_profile_defaults_rejected_when_gate_off
        ; Alcotest.test_case
            "local profile defaults allowed with the hatch set"
            `Quick
            test_local_profile_defaults_allowed_with_hatch
        ; Alcotest.test_case
            "no-profile-source fallback to local rejected when the gate is off"
            `Quick
            test_no_profile_source_fallback_rejected_when_gate_off
        ] )
    ]
;;
