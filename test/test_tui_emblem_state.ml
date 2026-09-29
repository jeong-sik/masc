(* Key ownership of overlays and the shared pace of moving marks. *)

open Alcotest
module Types = Masc_tui_types

let fresh () =
  let state = Types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  state.Types.connection_status <- Types.Connecting;
  state

let open_each state =
  [ ("help", fun () -> state.Types.help_open <- true)
  ; ("deletions", fun () -> state.Types.keeper_deletions_open <- true)
  ; ("agenda", fun () -> state.Types.agenda_open <- true)
  ; ("context inspector", fun () -> state.Types.context_inspector_open <- true)
  ; ("about", fun () -> state.Types.about_open <- true)
  ]

let test_each_key_owning_overlay_owns_the_keys () =
  let state = fresh () in
  check bool "nothing open" false (Types.modal_owns_keys state);
  List.iter
    (fun (name, open_it) ->
      Types.close_key_modals state;
      open_it ();
      check bool (name ^ " owns the keys") true (Types.modal_owns_keys state))
    (open_each state);
  List.iter (fun (_, open_it) -> open_it ()) (open_each state);
  state.Types.help_scroll <- 4;
  state.Types.agenda_scroll <- 3;
  state.Types.context_inspector_scroll <- 2;
  Types.close_key_modals state;
  check bool "closing them all leaves none" false (Types.modal_owns_keys state);
  check int "help starts at its top next time" 0 state.Types.help_scroll;
  check int "the agenda too" 0 state.Types.agenda_scroll;
  check int "and the inspector" 0 state.Types.context_inspector_scroll

(* The invite card holds a link the server will not show again, so it takes
   the keys only while it is on screen, and the sweep that closes the other
   overlays leaves it: an unrelated event must not take the only copy. *)
let test_the_invite_card_owns_the_keys_only_while_shown () =
  let state = fresh () in
  let card =
    match
      Masc_tui_play_card.make ~project:(fun _ -> None) ~name:"minsu"
        ~expires_at:"2026-09-30T04:12:33Z" ~link:"https://masc.example.com/play#abc"
    with
    | Ok card -> card
    | Error reason -> failf "the fixture link was refused: %s" reason
  in
  state.Types.play_invite <- Types.Play_invite_held card;
  check bool "a held card does not own the keys" false (Types.modal_owns_keys state);
  state.Types.play_invite <- Types.Play_invite_shown card;
  check bool "a shown card owns the keys" true (Types.modal_owns_keys state);
  Types.close_key_modals state;
  check bool "the sweep that closes the other overlays leaves it" true
    (Types.modal_owns_keys state)

let test_the_palette_is_not_one_of_them () =
  (* The palette takes typed text, which the text-field rule already routes;
     it is not a key-swallowing overlay. *)
  let state = fresh () in
  state.Types.palette_open <- true;
  check bool "the palette" false (Types.modal_owns_keys state)

let test_moving_marks_share_one_pace () =
  check (float 1e-9) "not started" 0.0 (Types.motion_elapsed_seconds (-1));
  check (float 1e-9) "the first step" 0.0 (Types.motion_elapsed_seconds 0);
  check (float 1e-9) "ten steps"
    (10.0 *. Int64.to_float Types.motion_step_ns /. 1e9)
    (Types.motion_elapsed_seconds 10)

let () =
  run "tui_emblem_state"
    [ ( "overlays"
      , [ test_case "each key-owning overlay owns the keys" `Quick
            test_each_key_owning_overlay_owns_the_keys
        ; test_case "the palette is not one of them" `Quick
            test_the_palette_is_not_one_of_them
        ; test_case "the invite card owns the keys only while shown" `Quick
            test_the_invite_card_owns_the_keys_only_while_shown
        ] )
    ; ( "motion"
      , [ test_case "moving marks share one pace" `Quick test_moving_marks_share_one_pace ] )
    ]
