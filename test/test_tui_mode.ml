(* The precedence table, asserted. Each case raises one flag on top of all
   the flags below it in the order, and the higher one must win — exactly
   the dispatch's arm order in masc_tui.ml. If a dispatch arm moves, this
   is the alarm that says the mirror moved too. *)

open Masc_tui_mode

let mode =
  Alcotest.testable
    (fun fmt m ->
      Format.pp_print_string fmt
        (match label m with Some l -> l | None -> "normal"))
    ( = )

let all_raised =
  { image_open = true
  ; help_open = true
  ; palette_open = true
  ; search_active = true
  ; board_composing = true
  ; message_mode = true
  ; composer_focused = true
  ; pending = Some "vote"
  }

let test_the_order_is_the_dispatch_order () =
  (* Strip the winner off, top to bottom; each step's expected mode is the
     next arm down. *)
  let check name expected flags =
    Alcotest.check mode name expected (active flags)
  in
  check "image over everything" Image_overlay all_raised;
  let f = { all_raised with image_open = false } in
  check "help over the palette" Help f;
  let f = { f with help_open = false } in
  check "palette over search" Palette f;
  let f = { f with palette_open = false } in
  check "search over board compose" Search f;
  let f = { f with search_active = false } in
  check "board compose over the chat pane" Board_compose f;
  let f = { f with board_composing = false } in
  check "the chat pane over the composer" Message_edit f;
  let f = { f with message_mode = false } in
  check "the composer over an armed action" Composer f;
  let f = { f with composer_focused = false } in
  check "an armed action over normal" (Pending "vote") f;
  let f = { f with pending = None } in
  check "nothing raised is normal" Normal f

let test_normal_is_the_quiet_state () =
  Alcotest.check mode "no flags" Normal (active no_flags);
  Alcotest.(check (option string)) "normal has no chip" None (label Normal)

let test_labels_name_the_owner () =
  Alcotest.(check (option string)) "search chip" (Some "search")
    (label Search);
  Alcotest.(check (option string)) "pending names the armed action"
    (Some "vote?")
    (label (Pending "vote"))

let () =
  Alcotest.run "masc_tui_mode"
    [ ( "precedence"
      , [ Alcotest.test_case "the order is the dispatch order" `Quick
            test_the_order_is_the_dispatch_order
        ; Alcotest.test_case "normal is the quiet state" `Quick
            test_normal_is_the_quiet_state
        ; Alcotest.test_case "labels name the owner" `Quick
            test_labels_name_the_owner
        ] )
    ]
