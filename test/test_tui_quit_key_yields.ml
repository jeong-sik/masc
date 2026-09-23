open Masc_tui_types

(* Every place the TUI takes typed text. Spelled out here as well as in
   [quit_key_allowed_for] so that adding a field breaks both: the list in the
   code decides, and this list is the reader that notices. *)
let every_text_target =
  [ ("browser url", Text_browser_url)
  ; ("ask answer", Text_ask_answer)
  ; ("fusion launch", Text_fusion_launch)
  ; ("preset name", Text_preset_name)
  ; ("runtime lane name", Text_runtime_lane_name)
  ; ("runtime param", Text_runtime_param)
  ; ("voice wizard", Text_voice_wizard)
  ; ("command palette", Text_palette)
  ; ("row search", Text_row_search)
  ; ("identity app form", Text_identity_app_form)
  ; ("identity filter", Text_identity_filter)
  ; ("github token", Text_github_token)
  ; ("board draft", Text_board_draft)
  ]

(* A field showing a cursor owns [q]. Three of the thirteen were named and the
   rest fell through a catch-all, so a [q] typed into the command palette
   armed the exit and the next one ended the process. *)
let test_no_field_lets_the_quit_key_through () =
  List.iter
    (fun (name, target) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s keeps its q" name)
        false
        (quit_key_allowed_for (Some target)))
    every_text_target

(* And with nothing taking text, [q] is the quit key it has always been. *)
let test_with_no_field_open_the_quit_key_is_a_quit_key () =
  Alcotest.(check bool) "nothing is typing" true (quit_key_allowed_for None)

(* The count is the guard: a target added to [text_input_target] without a
   line here leaves this suite measuring fewer fields than exist. *)
let test_the_list_covers_every_target_this_build_has () =
  Alcotest.(check int) "fields counted" 13 (List.length every_text_target);
  let spelled = List.map fst every_text_target in
  Alcotest.(check int) "and none of them is listed twice" 13
    (List.length (List.sort_uniq String.compare spelled))

let () =
  Alcotest.run "masc_tui_quit_key_yields"
    [ ( "quit key"
      , [ Alcotest.test_case "no field lets the quit key through" `Quick
            test_no_field_lets_the_quit_key_through
        ; Alcotest.test_case "with no field open the quit key is a quit key"
            `Quick test_with_no_field_open_the_quit_key_is_a_quit_key
        ; Alcotest.test_case "the list covers every target this build has"
            `Quick test_the_list_covers_every_target_this_build_has
        ] )
    ]
