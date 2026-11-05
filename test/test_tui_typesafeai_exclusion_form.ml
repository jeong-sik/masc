(* The runtime.toml pane's exclusion form, driven the way the key loop drives
   it: one decoded key at a time. What it writes is read back with the reader
   the server loads the file with, and a few texts are compared whole because
   the bytes of runtime.toml are what the feature produces. *)

module F = Masc_tui_typesafeai_exclusion_form

let probe = "[models.probe]\napi-name = \"probe\"\n"

let entries names = List.map (fun name -> { F.name; presence = F.Unknown }) names
let roster = entries [ "b"; "a"; "c" ]

let excluding names =
  probe
  ^ "\n[typesafeai]\nexcluded_keepers = ["
  ^ String.concat ", " (List.map (Printf.sprintf "%S") names)
  ^ "]\n"
;;

let opened ?(keepers = roster) text =
  match F.open_on ~source_revision:"rev-1" ~keepers text with
  | Ok form -> form
  | Error reason -> Alcotest.failf "the form did not open: %s" reason
;;

let press form keys =
  List.fold_left
    (fun outcome key ->
       match outcome with
       | F.Editing form -> F.key form key
       | F.Cancelled | F.Submitted _ -> outcome)
    (F.Editing form)
    keys
;;

let edited form keys =
  match press form keys with
  | F.Editing form -> form
  | F.Cancelled -> Alcotest.fail "the form closed before the keys ended"
  | F.Submitted _ -> Alcotest.fail "the form submitted before the keys ended"
;;

let text_of form =
  match F.text_on form with
  | Ok text -> text
  | Error _ -> Alcotest.fail "the form refused a choice it should write"
;;

let excluded_of text =
  match Runtime_toml.parse_string text with
  | Ok config -> config.Runtime_schema.typesafeai.Runtime_schema.excluded_keepers
  | Error errors ->
    Alcotest.failf
      "the written file does not parse: %s"
      (String.concat
         "; "
         (List.map (fun (error : Runtime_toml.parse_error) -> error.Runtime_toml.message) errors))
;;

let sorted names = List.sort String.compare names
let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec go index = index + n <= m && (String.sub text index n = sub || go (index + 1)) in
  go 0
;;

let test_a_file_that_does_not_parse_has_nothing_to_edit () =
  match F.open_on ~keepers:roster "[typesafeai]\nexcluded_keepers = 3\n" with
  | Ok _ -> Alcotest.fail "the form opened on a file the server refuses"
  | Error reason ->
    Alcotest.(check bool) "the reason says the file could not be read" true (reason <> "")
;;

(* Rows are the roster in name order, then the names only the file knows. The
   cursor starts on the first row, so Space there acts on "a". *)
let test_the_files_list_starts_picked_and_unknown_names_come_last () =
  let form = opened (excluding [ "c"; "gone" ]) in
  Alcotest.(check (option string)) "the revision it was opened on" (Some "rev-1") (F.source_revision form);
  (match F.change form with
   | F.Unchanged -> ()
   | F.Changed _ -> Alcotest.fail "an untouched form is a change");
  let rows = F.rows ~width:120 ~height:40 form in
  let index_of name =
    let rec find index = function
      | [] -> Alcotest.failf "no row for %s" name
      | row :: rest -> if contains ~sub:(" " ^ name) row then index else find (index + 1) rest
    in
    find 0 rows
  in
  Alcotest.(check bool) "a before b" true (index_of "a" < index_of "b");
  Alcotest.(check bool) "c before the unknown name" true (index_of "c" < index_of "gone");
  let gone = List.nth rows (index_of "gone") in
  Alcotest.(check bool) "the unknown name is picked" true (contains ~sub:"[x] gone" gone);
  Alcotest.(check bool) "and marked" true (contains ~sub:"키퍼 목록에 없어요" gone);
  Alcotest.(check bool) "c is picked" true (contains ~sub:"[x] c" (List.nth rows (index_of "c")))
;;

let test_picking_a_keeper_writes_the_list_with_it () =
  let form = edited (opened (excluding [ "c" ])) [ " " ] in
  (match F.change form with
   | F.Changed { added; dropped } ->
     Alcotest.(check (list string)) "added" [ "a" ] added;
     Alcotest.(check (list string)) "dropped" [] dropped
   | F.Unchanged -> Alcotest.fail "picking a keeper is no change");
  Alcotest.(check (list string)) "read back" [ "a"; "c" ] (sorted (excluded_of (text_of form)))
;;

(* Dropping the name nobody has empties the list, and an empty choice removes
   the key: the file then reads as excluding nobody. *)
let test_dropping_every_name_removes_the_key () =
  let text = excluding [ "gone" ] in
  let form = edited (opened text) [ "down"; "down"; "down"; " " ] in
  (match F.change form with
   | F.Changed { added; dropped } ->
     Alcotest.(check (list string)) "added" [] added;
     Alcotest.(check (list string)) "dropped" [ "gone" ] dropped
   | F.Unchanged -> Alcotest.fail "dropping the only name is no change");
  let written = text_of form in
  Alcotest.(check (list string)) "read back" [] (excluded_of written);
  Alcotest.(check bool) "the key is gone" false (contains ~sub:"excluded_keepers" written)
;;

let test_the_same_keepers_in_another_order_is_no_change () =
  let text = excluding [ "a"; "c" ] in
  (* Drop "a" and pick it again: it moves to the end of the choice. *)
  let form = edited (opened text) [ " "; " " ] in
  (match F.change form with
   | F.Unchanged -> ()
   | F.Changed _ -> Alcotest.fail "the same keepers in another order are a change");
  Alcotest.(check string) "the text is the file as opened" text (text_of form)
;;

let test_only_the_list_changes () =
  let text =
    probe
    ^ "\n[typesafeai]\n# the lane's own note\nabsorb_gate = true  # kept\nexcluded_keepers = [\"c\"]\nlibrarian_preflight = true\n\n[models.other]\napi-name = \"other\"\n"
  in
  let written = text_of (edited (opened text) [ " " ]) in
  let without_list text =
    String.split_on_char '\n' text
    |> List.filter (fun line ->
      let line = String.trim line in
      not
        (String.starts_with ~prefix:"excluded_keepers" line
         || String.equal line "]"
         || String.starts_with ~prefix:"\"" line))
  in
  Alcotest.(check (list string)) "every other line" (without_list text) (without_list written);
  Alcotest.(check (list string)) "read back" [ "a"; "c" ] (sorted (excluded_of written))
;;

let test_a_list_written_one_name_per_line_can_be_emptied () =
  let text = probe ^ "\n[typesafeai]\nexcluded_keepers = [\n  \"a\",\n  \"b\",\n]\n" in
  let form = edited (opened text) [ " "; "down"; " " ] in
  let written = text_of form in
  Alcotest.(check (list string)) "read back" [] (excluded_of written);
  Alcotest.(check bool) "the key is gone" false (contains ~sub:"excluded_keepers" written)
;;

let test_a_file_without_the_table_gets_one () =
  let form = edited (opened probe) [ "down"; " " ] in
  let written = text_of form in
  Alcotest.(check (list string)) "read back" [ "b" ] (excluded_of written);
  Alcotest.(check bool) "the table is there" true (contains ~sub:"[typesafeai]" written)
;;

let test_esc_abandons_and_enter_submits () =
  let form = opened (excluding [ "c" ]) in
  (match press form [ " "; "esc" ] with
   | F.Cancelled -> ()
   | F.Editing _ | F.Submitted _ -> Alcotest.fail "Esc did not close the form");
  match press form [ " "; "enter" ] with
  | F.Submitted form ->
    Alcotest.(check (list string)) "the choice rides on the submit" [ "a"; "c" ]
      (sorted (excluded_of (text_of form)))
  | F.Editing _ | F.Cancelled -> Alcotest.fail "Enter did not submit"
;;

let test_other_keys_change_nothing () =
  let form = opened (excluding [ "c" ]) in
  let after = edited form [ "q"; "x"; "e"; "r"; "left"; "right" ] in
  Alcotest.(check (list string)) "the same rows" (F.rows ~width:80 ~height:30 form)
    (F.rows ~width:80 ~height:30 after)
;;

let test_a_refusal_is_drawn_and_a_pick_clears_it () =
  let form = F.refused (opened (excluding [ "c" ])) "저장하지 않았어요" in
  let drawn form = String.concat "\n" (F.rows ~width:80 ~height:30 form) in
  Alcotest.(check bool) "the reason is drawn" true (contains ~sub:"저장하지 않았어요" (drawn form));
  Alcotest.(check bool) "a pick clears it" false
    (contains ~sub:"저장하지 않았어요" (drawn (edited form [ " " ])))
;;

let test_the_rows_say_the_board_judgment_still_runs () =
  let rows = String.concat "\n" (F.rows ~width:200 ~height:30 (opened (excluding [ "c" ]))) in
  Alcotest.(check bool) "the exact lane is named" true (contains ~sub:"board_attention_exact" rows);
  Alcotest.(check bool) "the destination is named" true
    (contains ~sub:"https://api.typesafe.ai/v1/systemone" rows)
;;

let test_a_keeper_name_cannot_colour_the_pane () =
  let form = edited (opened ~keepers:(entries [ "x\027[31my" ]) probe) [ " " ] in
  List.iter
    (fun row ->
       Alcotest.(check bool) "no escape byte in a row" false (String.contains row '\027'))
    (F.rows ~width:80 ~height:20 form)
;;

let test_a_stopped_keeper_is_drawn_apart_from_a_running_one () =
  let rows_with presence = F.rows ~width:80 ~height:30 (opened ~keepers:[ { F.name = "a"; presence } ] probe) in
  Alcotest.(check bool) "stopped is not drawn as running" true
    (rows_with F.Stopped <> rows_with F.Running);
  Alcotest.(check (list string)) "unknown is drawn as running" (rows_with F.Running)
    (rows_with F.Unknown)
;;

let long = List.init 40 (fun index -> Printf.sprintf "keeper-%02d" index)

let test_the_rows_fit_the_height_they_are_given () =
  List.iter
    (fun keys ->
       let form = edited (opened ~keepers:(entries long) probe) keys in
       List.iter
         (fun height ->
            List.iter
              (fun width ->
                 let rows = F.rows ~width ~height form in
                 Alcotest.(check bool)
                   (Printf.sprintf "%d rows in a pane of %d x %d" (List.length rows) width height)
                   true
                   (List.length rows <= height))
              [ 60; 80; 200 ])
         [ 14; 20; 50 ])
    [ [ " " ]; [ " "; "down"; " "; "down"; "down"; " "; "down"; "down"; "down"; " " ] ]
;;

let test_rows_are_drawn_at_any_size () =
  List.iter
    (fun keepers ->
       let form = edited (opened ~keepers probe) [ "down"; " " ] in
       List.iter
         (fun height ->
            List.iter
              (fun width ->
                 Alcotest.(check bool) "something is drawn" true (F.rows ~width ~height form <> []))
              [ 1; 20; 80; 200 ])
         [ 0; 1; 2; 5; 50 ])
    [ []; entries long ]
;;

let () =
  Alcotest.run
    "tui_typesafeai_exclusion_form"
    [ ( "opening"
      , [ Alcotest.test_case "a file that does not parse has nothing to edit" `Quick
            test_a_file_that_does_not_parse_has_nothing_to_edit
        ; Alcotest.test_case "the file's list starts picked and unknown names come last" `Quick
            test_the_files_list_starts_picked_and_unknown_names_come_last
        ] )
    ; ( "writing"
      , [ Alcotest.test_case "picking a keeper writes the list with it" `Quick
            test_picking_a_keeper_writes_the_list_with_it
        ; Alcotest.test_case "dropping every name removes the key" `Quick
            test_dropping_every_name_removes_the_key
        ; Alcotest.test_case "the same keepers in another order is no change" `Quick
            test_the_same_keepers_in_another_order_is_no_change
        ; Alcotest.test_case "only the list changes" `Quick test_only_the_list_changes
        ; Alcotest.test_case "a list written one name per line can be emptied" `Quick
            test_a_list_written_one_name_per_line_can_be_emptied
        ; Alcotest.test_case "a file without the table gets one" `Quick
            test_a_file_without_the_table_gets_one
        ] )
    ; ( "keys"
      , [ Alcotest.test_case "Esc abandons and Enter submits" `Quick
            test_esc_abandons_and_enter_submits
        ; Alcotest.test_case "other keys change nothing" `Quick test_other_keys_change_nothing
        ; Alcotest.test_case "a refusal is drawn and a pick clears it" `Quick
            test_a_refusal_is_drawn_and_a_pick_clears_it
        ] )
    ; ( "rows"
      , [ Alcotest.test_case "the rows say the board judgment still runs" `Quick
            test_the_rows_say_the_board_judgment_still_runs
        ; Alcotest.test_case "a keeper name cannot colour the pane" `Quick
            test_a_keeper_name_cannot_colour_the_pane
        ; Alcotest.test_case "a stopped keeper is drawn apart from a running one" `Quick
            test_a_stopped_keeper_is_drawn_apart_from_a_running_one
        ; Alcotest.test_case "the rows fit the height they are given" `Quick
            test_the_rows_fit_the_height_they_are_given
        ; Alcotest.test_case "rows are drawn at any size" `Quick test_rows_are_drawn_at_any_size
        ] )
    ]
;;
