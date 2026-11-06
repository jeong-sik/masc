open Masc_tui_types

(* Every place the TUI takes typed text. Spelled out here as well as in
   [quit_key_allowed_for] so that adding a field breaks both: the list in the
   code decides, and this list is the reader that notices. *)
let every_text_target =
  [ ("Collab form", Text_collab_form)
  ; ("account login", Text_account_login)
  ; ("ask answer", Text_ask_answer)
  ; ("fusion launch", Text_fusion_launch)
  ; ("preset name", Text_preset_name)
  ; ("runtime lane name", Text_runtime_lane_name)
  ; ("runtime param", Text_runtime_param)
  ; ("runtime model form", Text_runtime_model_form)
  ; ("runtime account form", Text_runtime_account_form)
  ; ("memory recall form", Text_memory_recall_form)
  ; ("typesafeai exclusion form", Text_typesafeai_exclusion_form)
  ; ("voice wizard", Text_voice_wizard)
  ; ("command palette", Text_palette)
  ; ("row search", Text_row_search)
  ; ("runtime picker filter", Text_runtime_picker_filter)
  ; ("keeper runtime picker filter", Text_keeper_runtime_picker_filter)
  ; ("Skill source filter", Text_skill_source_filter)
  ; ("identity app form", Text_identity_app_form)
  ; ("identity filter", Text_identity_filter)
  ; ("github token", Text_github_token)
  ; ("board draft", Text_board_draft)
  ; ("board attach path", Text_board_attach_path)
  ]

(* A field showing a cursor owns [q]. Three of the first thirteen were named
   and the rest fell through a catch-all, so a [q] typed into the command
   palette armed the exit and the next one ended the process. The list above
   once named seventeen of the eighteen targets (the account login input was
   missing) under a count of sixteen, so the count and the missing field each
   went unnoticed; both are pinned here. *)
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

let () =
  Alcotest.run "masc_tui_quit_key_yields"
    [ ( "quit key"
      , [ Alcotest.test_case "no field lets the quit key through" `Quick
            test_no_field_lets_the_quit_key_through
        ; Alcotest.test_case "with no field open the quit key is a quit key"
            `Quick test_with_no_field_open_the_quit_key_is_a_quit_key
        ] )
    ]
