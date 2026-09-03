(** The questions panel lets an operator see and reach what is waiting.

    Both facts are wiring in the masc_tui executable, which nothing links
    (task-550), so they are read off the source the way the other TUI wiring
    suites read theirs.

    Measured 2026-09-03 on a live Approvals surface with two open asks: no
    caret was drawn on any row, the choices carried no number, and the footer
    offered [a] with nothing to say which ask it would open. Both halves had
    the same cause -- the panel and the keys treated "a cursor exists" and
    "the operator is answering" as one state. *)

let render = "bin/masc_tui_render.ml"
let executable = "bin/masc_tui.ml"

(* [j]/[k] belong to the approval queue above this panel, so the asks are
   walked with the two keys that do not collide. Before this there was no
   browsing arm at all: [move_ask_cursor] was reachable only from inside the
   answering mode, so [a] opened whichever ask the cursor had last been left
   on and a second waiting ask could not be reached without answering the
   first. Three call sites: two in the answering arm, one browsing. *)
let test_the_ask_list_can_be_walked_before_answering () =
  Alcotest.(check int)
    "the cursor moves from the browsing arm as well as the answering one" 3
    (Ast_grep.count_calls ~module_path:executable ~callee:"move_ask_cursor")
;;

(* A key the footer offers and the surface does not answer is worse than no
   key: the operator presses it and reads the silence as a broken pane.

   The label is asserted through the one name both footers read, not by
   pinning either sentence. [ and ] call the same function in both modes --
   they walk the asks -- and this surface used to call that "question" while
   browsing and "ask" while answering: one key, two names, on one screen.
   Pinning the sentences would have frozen that; naming it once is what makes
   the two unable to disagree. *)
let test_the_two_modes_give_the_walk_one_name () =
  Alcotest.(check int) "the browsing footer and the answering one share a name"
    1
    (Ast_grep.count_exact_string_literals_in_value_binding ~module_path:render
       ~binding_name:"render_approvals" ~needle:"[/]:ask");
  Alcotest.(check int)
    "and no second spelling survives beside it" 0
    (Ast_grep.count_exact_string_literals_in_value_binding ~module_path:render
       ~binding_name:"render_approvals" ~needle:"[/]:question")
;;

(* The vocabulary is the repository's, not this surface's. [ and ] walk the
   container a surface is a list of: Board says post, Changes says keeper,
   Approvals says ask. Three surfaces, three names -- a fourth means one of
   them has started calling the same key something of its own. *)
let test_the_bracket_keys_keep_one_vocabulary () =
  let names = [ "[/]:ask"; "[/]:keeper"; "[/]:post" ] in
  List.iter
    (fun name ->
       Alcotest.(check int) (name ^ " is the name one surface uses") 1
         (Ast_grep.count_string_literals ~module_path:render ~needle:name))
    names;
  (* Every bracket-key label in the file is one of those three. A fourth is a
     surface that has started calling the walk something of its own, which is
     how this surface came to say both "ask" and "question". *)
  Alcotest.(check int) "and no surface spells the walk a fourth way" 3
    (Ast_grep.count_string_literals ~module_path:render ~needle:"[/]:")
;;

(* The panel is drawn by [draw_ask_questions], and the caret it draws is the
   only mark saying where the cursor sits. It reads [ask_cursor] and
   [ask_question_cursor] -- the same two fields the keys move -- so what the
   operator sees and what [a] opens cannot disagree. *)
let test_the_caret_is_drawn_from_the_cursor_the_keys_move () =
  let writes field =
    Ast_grep.count_field_writes_in_module ~module_path:executable ~field
  in
  Alcotest.(check bool) "the keys move the ask cursor" true
    (writes "ask_cursor" > 0);
  Alcotest.(check bool) "and the question cursor under it" true
    (writes "ask_question_cursor" > 0)
;;

let () =
  Alcotest.run "tui_ask_selection_wiring"
    [ ( "selection"
      , [ Alcotest.test_case "the list can be walked before answering" `Quick
            test_the_ask_list_can_be_walked_before_answering
        ; Alcotest.test_case "the two modes give the walk one name" `Quick
            test_the_two_modes_give_the_walk_one_name
        ; Alcotest.test_case "the bracket keys keep one vocabulary" `Quick
            test_the_bracket_keys_keep_one_vocabulary
        ; Alcotest.test_case "the caret reads the cursor the keys move" `Quick
            test_the_caret_is_drawn_from_the_cursor_the_keys_move
        ] )
    ]
;;
