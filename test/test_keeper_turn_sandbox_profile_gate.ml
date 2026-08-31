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
  (* #31178 sanctions exactly one direct re-application: the owner-projection
     refresh inside [Keeper_unified_turn.run_keeper_cycle] reapplies the
     already-loaded [entry_profile_defaults] rather than re-reading the
     profile, so two reads in one turn cannot disagree. Every other entry
     point must resolve through [turn_profile_and_meta]. *)
  List.iter
    (fun (module_path, sanctioned) ->
      Alcotest.(check int)
        (Printf.sprintf
           "%s applies the overlay only at its sanctioned sites" module_path)
        sanctioned
        (Ast_grep.count_calls
           ~module_path
           ~callee:"Keeper_meta_contract.effective_meta_of_profile_defaults"))
    [ "lib/keeper/keeper_unified_turn.ml", 1; "lib/keeper/keeper_turn.ml", 0 ]
;;

(* ------------------------------------------------------------------ *)
(* Config-load gate: profile defaults resolving to [Local]            *)
(* ------------------------------------------------------------------ *)

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0
;;

let gate_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "unstated-profile"
        ; "trace_id", `String "trace-unstated-profile"
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail err
;;

(* No profile source at all. This used to fall back to the meta's own
   [sandbox_profile] -- for any durable keeper JSON, the decoder's placeholder
   -- and a feature flag defaulting to off was what stopped that from becoming
   host execution. The placeholder is gone as an answer: a keeper with nothing
   stating a profile has none, and there is no flag that changes it. *)
let test_no_profile_source_is_refused () =
  match
    Masc.Keeper_meta_contract.effective_meta_of_profile_defaults
      Masc.Keeper_types_profile.empty_keeper_profile_defaults
      (gate_meta ())
  with
  | Error msg ->
    Alcotest.(check bool)
      "the error says a profile is required"
      true
      (contains "sandbox_profile is required" msg)
  | Ok _ -> Alcotest.fail "a keeper with no profile source must be refused"
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
            "a keeper with no profile source is refused"
            `Quick
            test_no_profile_source_is_refused
        ] )
    ]
;;
