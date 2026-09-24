open Alcotest

module Types = Masc_tui_types

let event event_type : Types.event =
  { timestamp = "12:34:56"; event_type; content = "a sentence" }

(* The level was recorded on every session event and drawn on none, so a
   failed mint and a first install waiting for its workspace read the same.
   An error row carries the chat pane's failure glyph; every other level
   draws what it drew before, so an ordinary row loses no cell of its text. *)
let test_only_an_error_carries_a_mark () =
  check (option string) "an error is marked" (Some "\xe2\x9c\x97")
    (Types.session_event_mark (event "error"));
  List.iter
    (fun level ->
      check (option string) (level ^ " is not marked") None
        (Types.session_event_mark (event level)))
    [ "system"; "info"; "message"; "git"; "observer"; "task"; "" ]

(* The level is compared whole. A level that only contains the word, or
   spells it in capitals, is not one the TUI emits, and marking it would put
   a failure glyph on a row nobody reported as a failure. *)
let test_the_level_is_matched_exactly () =
  List.iter
    (fun level ->
      check (option string) (level ^ " is not an error") None
        (Types.session_event_mark (event level)))
    [ "Error"; "ERROR"; "errors"; "error "; "read_error" ]

let () =
  run "tui_session_event_mark"
    [ ( "session event mark"
      , [ test_case "only an error carries a mark" `Quick
            test_only_an_error_carries_a_mark
        ; test_case "the level is matched exactly" `Quick
            test_the_level_is_matched_exactly
        ] )
    ]
