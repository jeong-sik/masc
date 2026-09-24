(* The reading under the Fusion list is paid for out of the rows the list does
   not use (#38434). Two things are asserted here: the rule that hands out
   those rows, and that the screen asks the rule instead of reserving one row
   the way it used to. *)

let expect label wanted actual = Alcotest.(check int) label wanted actual

let note ~body_rows ~entries ~wanted =
  Masc_tui_types.listing_note_rows ~body_rows ~entries ~wanted

let test_a_short_list_lends_its_blank_rows () =
  (* Eighteen runs on a frame with room for thirty: the rows under the last
     entry were drawn blank while the ruling was cut on the single row below
     them. *)
  expect "the reading packs into three rows and is given three" 3
    (note ~body_rows:30 ~entries:18 ~wanted:3);
  expect "a reading that fits on one row is still one row" 1
    (note ~body_rows:30 ~entries:18 ~wanted:1);
  (* The spare is the bound, not a constant: a reading longer than the frame's
     idle rows stops at them. *)
  expect "the reading stops at the rows the list leaves" 12
    (note ~body_rows:30 ~entries:18 ~wanted:40)

let test_a_full_list_keeps_the_single_row () =
  expect "a list that fills the frame leaves the reading one row" 1
    (note ~body_rows:20 ~entries:19 ~wanted:6);
  expect "a list longer than the frame leaves the reading one row" 1
    (note ~body_rows:20 ~entries:400 ~wanted:6);
  (* An empty selection asks for nothing and still owns the row it draws
     blank, so the frame does not change height when nothing is selected. *)
  expect "the row exists even when there is nothing to read" 1
    (note ~body_rows:20 ~entries:0 ~wanted:0)

(* The property the change is for: a longer reading must never take a row an
   entry is drawn on. Without this a reading that grows silently scrolls the
   list, which is the failure #38432 warns about on the Memory screen. *)
let test_no_entry_loses_its_row () =
  for body_rows = 2 to 40 do
    for entries = 0 to 45 do
      for wanted = 0 to 10 do
        let rows = note ~body_rows ~entries ~wanted in
        if rows < 1 then
          Alcotest.failf "the reading lost its row at %d/%d/%d" body_rows
            entries wanted;
        let list_rows = body_rows - rows in
        if list_rows < min entries (body_rows - 1) then
          Alcotest.failf
            "an entry lost its row at body=%d entries=%d wanted=%d (list kept \
             %d)"
            body_rows entries wanted list_rows
      done
    done
  done

let module_path = "bin/masc_tui_render.ml"

let calls ~callee =
  Ast_grep.count_calls_in_value_binding ~module_path
    ~binding_name:"render_fusion_list" ~callee

(* The rule and the packing both live in the screen that draws the list, and
   the render lives in the executable, which no test can link. Read through
   the source so a reserve written back by hand is seen here. *)
let test_the_screen_asks_for_the_height () =
  expect "the list height comes from the rule, not a reserved row" 1
    (calls ~callee:"listing_note_rows");
  expect "the reading is packed at clause marks" 1
    (calls ~callee:"Message_layout.pack_clauses")

let () =
  Alcotest.run "tui_fusion_summary_rows"
    [ ( "rows for the reading under the list"
      , [ Alcotest.test_case "a short list lends its blank rows" `Quick
            test_a_short_list_lends_its_blank_rows
        ; Alcotest.test_case "a full list keeps the single row" `Quick
            test_a_full_list_keeps_the_single_row
        ; Alcotest.test_case "no entry loses its row" `Quick
            test_no_entry_loses_its_row
        ; Alcotest.test_case "the screen asks for the height" `Quick
            test_the_screen_asks_for_the_height
        ] )
    ]
