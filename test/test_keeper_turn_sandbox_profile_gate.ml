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
    ]
;;
