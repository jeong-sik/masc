open Alcotest
module Types = Masc_tui_types

(* The Memory header draws two readings -- a fact total and a Librarian line --
   and both are absent whenever no snapshot has arrived. "Absent" has two
   causes, though, and only one of them is a wait. These pin that the header
   names the cause that holds, because the screen draws the other answer a few
   rows lower: the table puts the server's own reason in red. A header that
   said "waiting" during a failure was the line an operator read first. *)

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
  check (option string) "the total names the failure" (Some "  Total: load failed")
    (line_starting "  Total:" lines);
  check (option string) "so does the Librarian line"
    (Some "  Librarian: load failed")
    (line_starting "  Librarian:" lines)

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
