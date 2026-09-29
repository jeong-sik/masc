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

let card_named name =
  match
    Masc_tui_play_card.make ~project:(fun _ -> None) ~name
      ~expires_at:"2026-09-30T04:12:33Z"
      ~link:("https://masc.example.com/play#" ^ name)
  with
  | Ok card -> card
  | Error reason -> failf "the fixture link was refused: %s" reason

(* The invite card holds a link the server will not show again, so it takes
   the keys only while it is on screen, and the sweep that closes the other
   overlays leaves it: an unrelated event must not take the only copy. *)
let test_the_invite_card_owns_the_keys_only_while_shown () =
  let state = fresh () in
  let card = card_named "minsu" in
  state.Types.play_invite <- { Types.cards = [ card ]; shown_name = None };
  check bool "a kept card that is not shown does not own the keys" false
    (Types.modal_owns_keys state);
  state.Types.play_invite <- { Types.cards = [ card ]; shown_name = Some "minsu" };
  check bool "a shown card owns the keys" true (Types.modal_owns_keys state);
  Types.close_key_modals state;
  check bool "the sweep that closes the other overlays leaves it" true
    (Types.modal_owns_keys state)

let shown_name state =
  Option.map Masc_tui_play_card.name (Types.play_card_shown state)

let kept_names state =
  List.map Masc_tui_play_card.name state.Types.play_invite.Types.cards

let store state name =
  state.Types.play_invite <-
    Types.play_invite_store state.Types.play_invite (card_named name)

let holds_earlier state = Types.play_invite_holds_earlier state.Types.play_invite

(* The server sends each link once, so a second invite must leave the first
   card reachable, and revoking one invite must take only its own card. *)
let test_issued_cards_are_kept_by_name () =
  let state = fresh () in
  store state "minsu";
  check bool "one card has no earlier card to point at" false (holds_earlier state);
  store state "jiwon";
  check bool "a second card points at the first" true (holds_earlier state);
  check (list string) "both cards stay, newest first" [ "jiwon"; "minsu" ]
    (kept_names state);
  check (option string) "the newest is the one on screen" (Some "jiwon")
    (shown_name state);
  check (option string) "/play link with no name is the newest" (Some "jiwon")
    (Option.map Masc_tui_play_card.name (Types.play_invite_latest state));
  check (option string) "/play link minsu finds the earlier one" (Some "minsu")
    (Option.map Masc_tui_play_card.name (Types.play_invite_find state "minsu"));
  check (option string) "a name that was never issued finds nothing" None
    (Option.map Masc_tui_play_card.name (Types.play_invite_find state "guest1"));
  state.Types.play_invite <- Types.play_invite_forget state.Types.play_invite "minsu";
  check (list string) "revoking minsu keeps jiwon" [ "jiwon" ] (kept_names state);
  check (option string) "and jiwon stays on screen" (Some "jiwon") (shown_name state);
  check bool "one card is left with no earlier card" false (holds_earlier state);
  state.Types.play_invite <- Types.play_invite_forget state.Types.play_invite "jiwon";
  check (list string) "revoking the last leaves none" [] (kept_names state);
  check bool "and nothing owns the keys" false (Types.modal_owns_keys state);
  check (option string) "/play link then has nothing to open" None
    (Option.map Masc_tui_play_card.name (Types.play_invite_latest state))

(* A name is one live invite on the server, so a card that arrives under a
   name already held belongs to a reissued invite and takes the old card's
   place. *)
let test_a_reissued_name_replaces_its_card () =
  let state = fresh () in
  List.iter (store state) [ "minsu"; "jiwon"; "minsu" ];
  check (list string) "one card per name, the reissued one first"
    [ "minsu"; "jiwon" ] (kept_names state);
  check bool "the other name is still there to point at" true (holds_earlier state);
  (* A name issued again with nothing else kept leaves no earlier card, so the
     issue notice must not send the operator to one. *)
  let alone = fresh () in
  List.iter (store alone) [ "minsu"; "minsu" ];
  check (list string) "the old card of that name is gone" [ "minsu" ] (kept_names alone);
  check bool "and there is nothing earlier to point at" false (holds_earlier alone)

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
        ; test_case "issued invite cards are kept by name" `Quick
            test_issued_cards_are_kept_by_name
        ; test_case "a reissued name replaces its card" `Quick
            test_a_reissued_name_replaces_its_card
        ] )
    ; ( "motion"
      , [ test_case "moving marks share one pace" `Quick test_moving_marks_share_one_pace ] )
    ]
