(* The tool inventory as rows with its families shown. A hundred tools drawn
   flat is a hundred rows read one at a time; the names already carry the
   grouping, so the rows say so. *)

open Alcotest

module Tree = Masc_tui_tool_tree
module Decode = Masc.Tui_decode

let tool ?(surfaces = [ "mcp" ]) ?(direct = false) name : Decode.tool_entry =
  { tl_name = name
  ; tl_description = ""
  ; tl_surfaces = surfaces
  ; tl_direct_call = direct
  }

let tool_with_description name description : Decode.tool_entry =
  { tl_name = name
  ; tl_description = description
  ; tl_surfaces = [ "mcp" ]
  ; tl_direct_call = false
  }

let shape rows =
  List.map
    (function
      | Tree.Family { name; count } -> Printf.sprintf "[%s %d]" name count
      | Tree.Tool t -> t.Decode.tl_name)
    rows

let test_a_shared_prefix_becomes_a_heading () =
  check (list string) "the family is drawn once, above its tools"
    [ "[masc_board 2]"; "masc_board_list"; "masc_board_post" ]
    (shape (Tree.rows [ tool "masc_board_list"; tool "masc_board_post" ]))
;;

(* A heading over one row says nothing the row does not, and inventing one
   per tool would put a hundred headings over a hundred tools. *)
let test_a_prefix_one_tool_has_is_not_a_family () =
  check (list string) "the lone tool stays a plain row"
    [ "masc_agent_card"; "[masc_board 2]"; "masc_board_list"; "masc_board_post" ]
    (shape
       (Tree.rows
          [ tool "masc_agent_card"; tool "masc_board_list"; tool "masc_board_post" ]))
;;

let test_a_name_with_two_segments_has_no_family () =
  check (option string) "two segments group with nothing" None
    (Tree.family_of "masc_status");
  check (option string) "three segments name a family" (Some "masc_board")
    (Tree.family_of "masc_board_post")
;;

(* The caller's order is kept: the server sorts by name, which is what puts a
   family's tools next to each other in the first place. Reordering here would
   move a tool an operator is looking for. *)
let test_the_given_order_is_kept () =
  check (list string) "a family interrupted by another name is two headings"
    [ "[masc_board 2]"
    ; "masc_board_list"
    ; "[masc_keeper 2]"
    ; "masc_keeper_up"
    ; "masc_keeper_down"
    ; "[masc_board 2]"
    ; "masc_board_post"
    ]
    (shape
       (Tree.rows
          [ tool "masc_board_list"
          ; tool "masc_keeper_up"
          ; tool "masc_keeper_down"
          ; tool "masc_board_post"
          ]))
;;

let test_the_count_says_tools_not_rows () =
  let rows = Tree.rows [ tool "masc_board_list"; tool "masc_board_post" ] in
  check int "three rows, two of them tools" 3 (List.length rows);
  check int "the header should say two" 2 (Tree.tool_count rows)
;;

(* A filter matches the name and the description, so it finds what spelling
   scattered: the family-less task tools surface under the same "task" as the
   masc_task_* family, and a description's word works when the name does not
   carry it. *)
let test_a_filter_gathers_what_spelling_scattered () =
  (* masc_transition matches through its description, not its name: the
     fixture gives it one, the way the real declaration does. The lone
     masc_task survivor carries no heading -- the two-tool family rule holds
     over what is shown, so a count is never inflated by hidden tools. *)
  check (list string) "one word, every spelling of it"
    [ "masc_task_history"; "masc_tasks"; "masc_transition" ]
    (shape
       (Tree.rows ~filter:"task"
          [ tool "masc_board_post"
          ; tool "masc_task_history"
          ; tool "masc_tasks"
          ; tool_with_description "masc_transition" "move a task between states"
          ]))
;;

let test_a_filter_matches_the_description_too () =
  check (list string) "a description word finds the tool"
    [ "masc_deliver" ]
    (shape
       (Tree.rows ~filter:"deliver"
          [ tool_with_description "masc_deliver" "hand finished work over"
          ; tool "masc_board_post"
          ]))
;;

let test_a_case_blind_filter_and_an_empty_one () =
  check (list string) "upper case still matches"
    [ "masc_board_post" ]
    (shape (Tree.rows ~filter:"BOARD" [ tool "masc_board_post"; tool "masc_gc" ]));
  check (list string) "empty filter is no filter"
    [ "masc_board_post"; "masc_gc" ]
    (shape (Tree.rows ~filter:"" [ tool "masc_board_post"; tool "masc_gc" ]))
;;

let () =
  run "tui_tool_tree"
    [ ( "families"
      , [ test_case "a shared prefix becomes a heading" `Quick
            test_a_shared_prefix_becomes_a_heading
        ; test_case "a prefix one tool has is not a family" `Quick
            test_a_prefix_one_tool_has_is_not_a_family
        ; test_case "a two-segment name has no family" `Quick
            test_a_name_with_two_segments_has_no_family
        ; test_case "the given order is kept" `Quick test_the_given_order_is_kept
        ; test_case "the count says tools, not rows" `Quick
            test_the_count_says_tools_not_rows
        ] )
    ; ( "filter"
      , [ test_case "a filter gathers what spelling scattered" `Quick
            test_a_filter_gathers_what_spelling_scattered
        ; test_case "a filter matches the description too" `Quick
            test_a_filter_matches_the_description_too
        ; test_case "a case-blind filter and an empty one" `Quick
            test_a_case_blind_filter_and_an_empty_one
        ] )
    ]
;;
