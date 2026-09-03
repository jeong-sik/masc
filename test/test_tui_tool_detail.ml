open Alcotest

module Tool_detail = Masc_tui_tool_detail

(* The layout tests read through the plain palette, which is the identity for
   every role: what they pin is where a label, a separator and a branch land,
   and a colour in the middle of the string would be measuring the escape. *)
let said label value =
  { Tool_detail.fd_label = label
  ; fd_value = Tool_detail.Text value
  ; fd_tone = ""
  }

let served label payload =
  { Tool_detail.fd_label = label
  ; fd_value = Tool_detail.Document payload
  ; fd_tone = ""
  }

(* The defect this module was extracted to close: a tool result that is one
   long JSON line left the tree after the label and the terminal wrapped the
   rest at column zero, so every wrapped row lost its branch glyph. Serving
   the document one member per line puts those rows back inside the branch
   that owns them. *)
let test_json_payload_becomes_indented_rows () =
  let payload = {|{"argv":["gh","auth","status"],"cwd":"."}|} in
  let rendered = Tool_detail.tree [ served "input" payload ] in
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

let rows_of value = String.split_on_char '\n' (Tool_detail.structured value)

let has_row rows needle =
  List.exists (fun row -> String.equal (String.trim row) needle) rows
;;

let contains_escape rows =
  List.exists
    (fun row ->
      let n = String.length row in
      let rec at i = i + 1 < n && ((row.[i] = '\\' && row.[i + 1] = '"') || at (i + 1)) in
      at 0)
    rows
;;

(* A result that carries a result: artifact_read returns the artifact's
   content, and that content was itself a tool result, whose [output] was
   the command's table. Three layers, each escaping the one below. The value
   the keeper meant is the innermost, and the pane shows it as structure. *)
let test_string_documents_unfold_into_the_tree () =
  let innermost = {|{"ok":true,"status":{"kind":"exit","code":0},"output":"a\tb\nc\td\n"}|} in
  let middle = Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "content", `String innermost ]) in
  let outer = Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "content", `String middle ]) in
  let rows = rows_of outer in
  check bool "no escaped quote survives" false (contains_escape rows);
  check bool "the innermost status is a member" true (has_row rows {|"kind": "exit",|});
  check bool "the innermost code is a member" true (has_row rows {|"code": 0|});
  check bool "the table is a block" true (has_row rows {|"output": ||});
  check bool "tabs are drawn as a bar" true (has_row rows "a \xe2\x94\x8a b");
  check bool "the trailing newline adds no empty line" true (has_row rows "c \xe2\x94\x8a d");
  check bool "the block ends where the next member starts" false (has_row rows "")
;;

(* Only a string that looks like a document and parses as one unfolds. A
   quoted scalar and a string that merely starts with a brace are the
   producer's text and stay strings. *)
let test_only_documents_unfold () =
  let payload = {|{"n":"42","t":"true","brace":"{not json","doc":"{\"k\":1}"}|} in
  let rows = rows_of payload in
  check bool "quoted number stays quoted" true (has_row rows {|"n": "42",|});
  check bool "quoted bool stays quoted" true (has_row rows {|"t": "true",|});
  check bool "a brace that is not a document stays a string" true
    (has_row rows {|"brace": "{not json",|});
  check bool "a document unfolds" true (has_row rows {|"k": 1|})
;;

(* A multi-line string is a block: the marker on the member's line, the lines
   raw under it, indented one level past the member. Continuations inside the
   tree then keep the block under the branch that owns it. *)
let test_multiline_strings_become_blocks () =
  let rows = rows_of {|{"first":"x","text":"line one\nline two","last":1}|} in
  check (list string) "block rows"
    [ "{"; {|  "first": "x",|}; {|  "text": ||}; "    line one"; "    line two"; {|  "last": 1|}; "}" ]
    rows
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
      [ said "state" "RETURNED"
      ; said "tool" "Execute"
      ; said "schedule" "serial"
      ; said "identity" "execution=exec-1"
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
  let wide = Tool_detail.tree [ said "identity" "a"; said "x" "b" ] in
  let narrow = Tool_detail.tree [ said "x" "b" ] in
  match separator_columns wide, separator_columns narrow with
  | wide_column :: _, narrow_column :: _ ->
    check bool "narrow tree is narrower" true (narrow_column < wide_column)
  | _ -> fail "expected separators"
;;

(* The tree closes on its last field so two adjacent tool calls do not read as
   one call with many unrelated rows. *)
let test_last_field_closes_the_tree () =
  let rendered = Tool_detail.tree [ said "state" "RETURNED"; said "tool" "Execute" ] in
  match rendered with
  | [ first; second ] ->
    check bool "first branches" true
      (String.length first > 4 && String.equal (String.sub first 0 4) "  \xe2\x94");
    check bool "last closes" true
      (String.length second > 4 && String.equal (String.sub second 2 3) "\xe2\x95\xb0")
  | _ -> fail "expected two rows"
;;


(* --- the palette: which role each part of a served document is drawn in --- *)

(* Markers rather than escape codes. What is being pinned is that a key is
   drawn as a key and a number as a number, not what colour this theme
   happens to give them -- and a marker survives being read in a diff. *)
let marked =
  { Tool_detail.branch = "<br>"
  ; label = "<lab>"
  ; separator = "<sep>"
  ; key = "<key>"
  ; string_ = "<str>"
  ; number = "<num>"
  ; literal = "<lit>"
  ; punctuation = "<pun>"
  ; reset = "<->"
  }

let holds needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.equal (String.sub haystack i n) needle || scan (i + 1)) in
  n = 0 || scan 0

let test_each_part_of_a_document_draws_in_its_own_role () =
  let payload =
    {|{"cwd":".","width":1,"deferred":true,"repo":null}|}
  in
  let rendered = Tool_detail.structured ~palette:marked payload in
  check bool "the key is a key" true (holds {|<key>"cwd"<->|} rendered);
  check bool "the string is a string" true (holds {|<str>"."<->|} rendered);
  check bool "the number is a number" true (holds "<num>1<->" rendered);
  check bool "true is a literal" true (holds "<lit>true<->" rendered);
  check bool "null is a literal" true (holds "<lit>null<->" rendered);
  check bool "the brace recedes" true (holds "<pun>{<->" rendered);
  check bool "so does the colon" true (holds "<pun>: <->" rendered)

let test_the_plain_palette_leaves_the_text_alone () =
  (* Every role empty is the identity, which is what keeps the layout tests
     above measuring text and not escapes. *)
  let payload = {|{"cwd":"."}|} in
  check string "plain is the default" (Tool_detail.structured payload)
    (Tool_detail.structured ~palette:Tool_detail.plain payload)

let test_a_value_is_painted_after_it_is_made_safe () =
  (* The sweep that makes a value terminal-safe replaces control bytes with
     spaces, and an escape code is control bytes. Painting a sanitised string
     keeps the marker; sanitising a painted one would eat it. The value here
     carries a real escape, which must not survive as one. *)
  let rendered =
    Tool_detail.tree ~palette:marked
      [ { Tool_detail.fd_label = "state"
        ; fd_value = Tool_detail.Text "RET\027[31mURNED"
        ; fd_tone = "<tone>"
        } ]
  in
  match rendered with
  | [ row ] ->
    check bool "the field's own tone is applied" true (holds "<tone>" row);
    check bool "the value's escape did not survive" false
      (String.contains row '\027')
  | _ -> fail "expected one row"

let test_a_block_keeps_the_pane_foreground () =
  (* A command's output is bytes this module cannot read, so it claims no
     role for them -- only the marker that opens the block recedes. *)
  let payload = {|{"output":"line one\nline two"}|} in
  let rendered = Tool_detail.structured ~palette:marked payload in
  check bool "the block marker recedes" true (holds "<pun>|<->" rendered);
  (* Four spaces, not two: the block sits one level inside the key that owns
     it, which the rows contract in [test_multiline_strings_become_blocks]
     already pins. This assertion is about the line carrying no palette
     wrapper, so it has to quote the indent the renderer actually emits or it
     fails for the wrong reason. *)
  check bool "the block's own line is unpainted" true
    (holds "\n    line one" rendered)

let () =
  run
    "tui_tool_detail"
    [ ( "structured"
      , [ test_case "json payload becomes indented rows" `Quick
            test_json_payload_becomes_indented_rows
        ; test_case "non-json payload is unchanged" `Quick
            test_non_json_payload_is_unchanged
        ; test_case "string documents unfold into the tree" `Quick
            test_string_documents_unfold_into_the_tree
        ; test_case "only documents unfold" `Quick test_only_documents_unfold
        ; test_case "multi-line strings become blocks" `Quick
            test_multiline_strings_become_blocks
        ] )
    ; ( "tree"
      , [ test_case "labels share a separator column" `Quick
            test_labels_share_a_separator_column
        ; test_case "padding does not leak between trees" `Quick
            test_padding_does_not_leak_between_trees
        ; test_case "last field closes the tree" `Quick
            test_last_field_closes_the_tree
        ] )
    ; ( "palette"
      , [ test_case "each part of a document draws in its own role" `Quick
            test_each_part_of_a_document_draws_in_its_own_role
        ; test_case "the plain palette leaves the text alone" `Quick
            test_the_plain_palette_leaves_the_text_alone
        ; test_case "a value is painted after it is made safe" `Quick
            test_a_value_is_painted_after_it_is_made_safe
        ; test_case "a block keeps the pane foreground" `Quick
            test_a_block_keeps_the_pane_foreground
        ] )
    ]
;;
