open Alcotest
module Types = Masc_tui_types

(* The Memory header draws a fact total and a Librarian line. When the first
   read fails, the error row gives the cause and these cells have no value.
   An unread first visit still explains what is pending. *)

let header_lines state =
  let out = ref [] in
  let push line = out := line :: !out in
  Masc_tui_render_memory.render_memory_body ~cols:120 ~budget:20 state ~push
    ~push_styled:(fun ~style:_ line -> push line)
    ~push_selected:push
    ~push_divider:(fun () -> push "--")
    ~push_empty:(fun () -> push "");
  List.rev !out

let state_with_error detail =
  let state =
    Types.create_state ~workspace:"me" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.memory_health_error <- detail;
  state

let line_starting prefix lines =
  List.find_opt (fun l -> String.starts_with ~prefix l) lines

let test_a_failed_load_is_not_a_wait () =
  let lines =
    header_lines
      (state_with_error
         (Some "memory health load failed: (GET failed: connect refused)"))
  in
  check (option string) "the total is unavailable"
    (Some ("  Total: " ^ Masc_tui_theme.Glyph.no_value))
    (line_starting "  Total:" lines);
  check (option string) "so is the Librarian value"
    (Some ("  Librarian: " ^ Masc_tui_theme.Glyph.no_value))
    (line_starting "  Librarian:" lines);
  check int "the detailed cause is shown once" 1
    (List.length
       (List.filter
          (fun line ->
             String.equal line
               "  memory health load failed: (GET failed: connect refused)")
          lines))

let test_nothing_yet_is_still_a_wait () =
  let lines = header_lines (state_with_error None) in
  check (option string) "the total still waits"
    (Some "  Total: waiting for memory snapshots")
    (line_starting "  Total:" lines);
  check (option string) "and so does the Librarian line"
    (Some "  Librarian: waiting for health data")
    (line_starting "  Librarian:" lines)

let () =
  run "tui memory header states"
    [ ( "absent readings"
      , [ test_case "a failed load is not a wait" `Quick
            test_a_failed_load_is_not_a_wait
        ; test_case "nothing yet is still a wait" `Quick
            test_nothing_yet_is_still_a_wait
        ] )
    ]
