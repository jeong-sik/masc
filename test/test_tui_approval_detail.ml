(** The ask an approval is asking about, laid out whole.

    The Approvals list draws each ask on one row through [single_line], which
    escapes every byte under 0x20 — a newline becomes the six characters
    [\x0A] — and then cuts to the terminal width. An [Edit] whose replacement
    is a page of code read as its first forty characters, and no other screen
    showed the rest. The operator pressed [y] on something they had not seen.

    These tests pin what the detail keeps: the line breaks the ask was written
    with, and every byte of it somewhere on the pane. *)

module Detail = Masc_tui_approval_detail

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)
let check_string = Alcotest.(check string)

let texts lines = List.map (fun (l : Detail.line) -> l.Detail.text) lines
let joined lines = String.concat "\n" (texts lines)

let contains haystack needle =
  let n = String.length needle in
  let rec go i =
    i + n <= String.length haystack
    && (String.sub haystack i n = needle || go (i + 1))
  in
  n = 0 || go 0

(* The shape the live queue actually holds: an Edit whose replacement is
   OCaml with real newlines in it. *)
let edit_args =
  "{\"file_path\":\"lib/keeper/keeper_chat_events.mli\",\"new_string\":\"  | Tool_approval_requested of\n      { tool_call_id : string\n      ; tool_call_name : string\n      ; args : string\n      }\"}"

let test_newlines_survive_as_line_breaks () =
  let lines = Detail.of_fields ~width:60 [ "args", edit_args ] in
  check_bool "no escaped newline reaches the pane" false
    (contains (joined lines) "\\x0A");
  check_bool "the ask spans more than one row" true (List.length lines > 3)

let test_every_part_of_the_ask_is_on_the_pane () =
  let lines = Detail.of_fields ~width:60 [ "args", edit_args ] in
  let all = joined lines in
  List.iter
    (fun fragment ->
      check_bool ("the pane carries " ^ fragment) true (contains all fragment))
    [ "keeper_chat_events.mli"; "Tool_approval_requested"; "tool_call_name"; "args : string" ]

let test_a_label_introduces_its_value () =
  let lines = Detail.of_fields ~width:60 [ "tool", "Edit"; "args", "x" ] in
  match lines with
  | first :: _ ->
    check_string "the first row is the first label" "tool" first.Detail.text;
    check_bool "and it is marked as one" true (first.Detail.label <> None)
  | [] -> Alcotest.fail "fields produced no rows"

let test_a_blank_value_still_gets_a_row () =
  (* A field that is present and empty is a different fact from one that is
     absent; dropping it would read as the latter. *)
  let lines = Detail.of_fields ~width:60 [ "question", "" ] in
  check_int "the label and one blank row" 2 (List.length lines)

let test_a_blank_line_inside_a_value_is_kept () =
  let lines = Detail.of_fields ~width:60 [ "summary", "first\n\nthird" ] in
  let bodies = List.filter (fun (l : Detail.line) -> l.Detail.label = None) lines in
  check_int "three body rows, the middle one blank" 3 (List.length bodies);
  check_string "and the blank one carries no words" ""
    (String.trim (List.nth (texts bodies) 1))

let test_a_long_line_wraps_rather_than_running_off () =
  let long = String.concat " " (List.init 60 (fun i -> Printf.sprintf "word%d" i)) in
  let lines = Detail.of_fields ~width:40 [ "args", long ] in
  List.iter
    (fun text ->
      check_bool ("row fits the width: " ^ text) true (String.length text <= 40 * 4))
    (texts lines);
  check_bool "the last word survives" true (contains (joined lines) "word59")

let test_a_narrow_pane_still_produces_rows () =
  let lines = Detail.of_fields ~width:1 [ "args", "abc def" ] in
  check_bool "width 1 does not loop or vanish" true (lines <> [])

let () =
  Alcotest.run "tui_approval_detail"
    [ ( "the whole ask"
      , [ Alcotest.test_case "newlines survive as line breaks" `Quick
            test_newlines_survive_as_line_breaks
        ; Alcotest.test_case "every part of the ask is on the pane" `Quick
            test_every_part_of_the_ask_is_on_the_pane
        ; Alcotest.test_case "a label introduces its value" `Quick
            test_a_label_introduces_its_value
        ; Alcotest.test_case "a blank value still gets a row" `Quick
            test_a_blank_value_still_gets_a_row
        ; Alcotest.test_case "a blank line inside a value is kept" `Quick
            test_a_blank_line_inside_a_value_is_kept
        ; Alcotest.test_case "a long line wraps rather than running off" `Quick
            test_a_long_line_wraps_rather_than_running_off
        ; Alcotest.test_case "a narrow pane still produces rows" `Quick
            test_a_narrow_pane_still_produces_rows
        ] )
    ]
