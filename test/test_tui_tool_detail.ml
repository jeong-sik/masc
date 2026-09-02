open Alcotest

module Tool_detail = Masc_tui_tool_detail

(* The defect this module was extracted to close: a tool result that is one
   long JSON line left the tree after the label and the terminal wrapped the
   rest at column zero, so every wrapped row lost its branch glyph. Serving
   the document one member per line puts those rows back inside the branch
   that owns them. *)
let test_json_payload_becomes_indented_rows () =
  let payload = {|{"argv":["gh","auth","status"],"cwd":"."}|} in
  let rendered = Tool_detail.tree [ "input", Tool_detail.structured payload ] in
  check bool "more than one row" true (List.length rendered > 1);
  (match rendered with
   | [] -> fail "expected rows"
   | first :: rest ->
     check bool "label owns the opening brace" true
       (String.length first > 0
        && Option.is_some (String.index_opt first '{'));
     List.iter
       (fun row ->
         check bool
           (Printf.sprintf "continuation row is indented: %S" row)
           true
           (String.length row >= 5 && String.equal (String.sub row 0 5) "     "))
       rest)
;;

(* A payload that is not a JSON document is already in its best shape. Parsing
   it and handing back something else would rewrite operator-facing text that
   the producer chose. *)
let test_non_json_payload_is_unchanged () =
  check string "bare word" "RETURNED" (Tool_detail.structured "RETURNED");
  check string "prose" "812 bytes" (Tool_detail.structured "812 bytes");
  check string "broken json" "{not json" (Tool_detail.structured "{not json");
  (* A bare scalar parses as JSON but is not a document: re-serving it would
     turn 42 into 42 and "x" into "\"x\"", which is not an improvement. *)
  check string "scalar number" "42" (Tool_detail.structured "42")
;;

(* Alignment is the second promise: within one tree every separator sits in
   the same column, so the values read as a column. *)
let separator_columns rendered =
  List.filter_map
    (fun row ->
      let separator = "\xc2\xb7" in
      let limit = String.length row - String.length separator in
      let rec at index =
        if index > limit
        then None
        else if String.equal (String.sub row index (String.length separator)) separator
        then Some index
        else at (index + 1)
      in
      at 0)
    rendered
;;

let test_labels_share_a_separator_column () =
  let rendered =
    Tool_detail.tree
      [ "state", "RETURNED"
      ; "tool", "Execute"
      ; "schedule", "serial"
      ; "identity", "execution=exec-1"
      ]
  in
  check int "one row per field" 4 (List.length rendered);
  match separator_columns rendered with
  | [] -> fail "expected a separator on every row"
  | column :: rest ->
    List.iter (fun other -> check int "separator column" column other) rest
;;

(* The padding is computed per call. A tree of short labels must not inherit
   the width of a tree that happened to hold a long one. *)
let test_padding_does_not_leak_between_trees () =
  let wide = Tool_detail.tree [ "identity", "a"; "x", "b" ] in
  let narrow = Tool_detail.tree [ "x", "b" ] in
  match separator_columns wide, separator_columns narrow with
  | wide_column :: _, narrow_column :: _ ->
    check bool "narrow tree is narrower" true (narrow_column < wide_column)
  | _ -> fail "expected separators"
;;

(* The tree closes on its last field so two adjacent tool calls do not read as
   one call with many unrelated rows. *)
let test_last_field_closes_the_tree () =
  let rendered = Tool_detail.tree [ "state", "RETURNED"; "tool", "Execute" ] in
  match rendered with
  | [ first; second ] ->
    check bool "first branches" true
      (String.length first > 4 && String.equal (String.sub first 0 4) "  \xe2\x94");
    check bool "last closes" true
      (String.length second > 4 && String.equal (String.sub second 2 3) "\xe2\x95\xb0")
  | _ -> fail "expected two rows"
;;

let () =
  run
    "tui_tool_detail"
    [ ( "structured"
      , [ test_case "json payload becomes indented rows" `Quick
            test_json_payload_becomes_indented_rows
        ; test_case "non-json payload is unchanged" `Quick
            test_non_json_payload_is_unchanged
        ] )
    ; ( "tree"
      , [ test_case "labels share a separator column" `Quick
            test_labels_share_a_separator_column
        ; test_case "padding does not leak between trees" `Quick
            test_padding_does_not_leak_between_trees
        ; test_case "last field closes the tree" `Quick
            test_last_field_closes_the_tree
        ] )
    ]
;;
