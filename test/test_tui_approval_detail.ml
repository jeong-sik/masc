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
    (* A value that fits sits beside its name, and the row is still marked
       with the name so the pane can weight it. *)
    check_string "the first row carries the name and its value" "tool  Edit"
      first.Detail.text;
    check_bool "and it is marked as one" true
      (first.Detail.label = Some "tool")
  | [] -> Alcotest.fail "fields produced no rows"

(* Two rows per field cost a screen the operator reads before pressing y. The
   ask that filled it is the operator queue's five short fields. *)
let test_short_fields_take_one_row_each () =
  let fields =
    [ "actor", "masc-tui"
    ; "action", "namespace_pause"
    ; "target", "workspace"
    ; "summary", "namespace_pause on workspace (masc_pause)"
    ]
  in
  check_int "one row per field" 4
    (List.length (Detail.of_fields ~width:100 fields));
  (* On a pane too narrow to hold a name and its value together, the name is
     alone on its row and the value is wrapped under it, rather than cut. *)
  List.iter
    (fun (line : Detail.line) ->
      match line.Detail.label with
      | Some name -> check_string "the name is alone on its row" name line.Detail.text
      | None -> ())
    (Detail.of_fields ~width:12 fields);
  check_bool "and every value is still on the pane" true
    (let all = joined (Detail.of_fields ~width:12 fields) in
     List.for_all (fun (_, value) -> contains all (String.sub value 0 4)) fields)

(* A value with its own line breaks keeps its name a row of its own: the
   wrapped lines start at the indent, not under the label column. *)
let test_a_multi_line_value_keeps_its_own_rows () =
  let lines = Detail.of_fields ~width:60 [ "args", "first\nsecond" ] in
  match lines with
  | first :: _ ->
    check_string "the name is alone on its row" "args" first.Detail.text
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

(* The ask is a model's text. [kta_question] is "Run <tool> on <subject>?"
   with the subject lifted from the command the model wrote, and a command
   carrying ESC [ 1 A ESC [ 2 K moves the cursor up and clears the row the
   operator already read. What is approved is what the store holds, so the
   pane must print these bytes as inert text, never hand them to the
   terminal. The summary is an operator ask's, and the label a wire key's. *)
let cursor_up_and_erase = "\x1b[1A\x1b[2K"
let csi_c1 = "\xc2\x9b"

let has_control_byte text =
  String.exists
    (fun c ->
      let code = Char.code c in
      (code < 0x20 && c <> '\n') || code = 0x7f)
    text

let test_an_escape_in_a_field_never_reaches_the_terminal () =
  let question = "Run Bash on echo ok" ^ cursor_up_and_erase ^ "rm -rf /?" in
  let summary =
    "namespace_pause on workspace" ^ csi_c1 ^ "2Kforged\nsecond line\x07"
  in
  let lines =
    Detail.of_fields ~width:60
      [ "question", question
      ; "summary", summary
      ; "key" ^ cursor_up_and_erase, "value"
      ]
  in
  List.iter
    (fun (line : Detail.line) ->
      check_bool ("no control byte in row: " ^ String.escaped line.Detail.text)
        false (has_control_byte line.Detail.text);
      check_bool "no C1 CSI in row" false (contains line.Detail.text csi_c1);
      Option.iter
        (fun label ->
          check_bool ("no control byte in label: " ^ String.escaped label)
            false (has_control_byte label))
        line.Detail.label)
    lines;
  let all = joined lines in
  List.iter
    (fun fragment ->
      check_bool ("the words around the escape stay: " ^ fragment) true
        (contains all fragment))
    [ "echo ok"; "rm -rf /?"; "namespace_pause"; "2Kforged"; "second line" ];
  check_bool "the value's own newline is still a row break" true
    (List.exists
       (fun (line : Detail.line) -> String.trim line.Detail.text = "second line")
       lines)

let () =
  Alcotest.run "tui_approval_detail"
    [ ( "the whole ask"
      , [ Alcotest.test_case "newlines survive as line breaks" `Quick
            test_newlines_survive_as_line_breaks
        ; Alcotest.test_case "every part of the ask is on the pane" `Quick
            test_every_part_of_the_ask_is_on_the_pane
        ; Alcotest.test_case "a label introduces its value" `Quick
            test_a_label_introduces_its_value
        ; Alcotest.test_case "short fields take one row each" `Quick
            test_short_fields_take_one_row_each
        ; Alcotest.test_case "a multi-line value keeps its own rows" `Quick
            test_a_multi_line_value_keeps_its_own_rows
        ; Alcotest.test_case "a blank value still gets a row" `Quick
            test_a_blank_value_still_gets_a_row
        ; Alcotest.test_case "a blank line inside a value is kept" `Quick
            test_a_blank_line_inside_a_value_is_kept
        ; Alcotest.test_case "a long line wraps rather than running off" `Quick
            test_a_long_line_wraps_rather_than_running_off
        ; Alcotest.test_case "a narrow pane still produces rows" `Quick
            test_a_narrow_pane_still_produces_rows
        ; Alcotest.test_case "an escape in a field never reaches the terminal"
            `Quick test_an_escape_in_a_field_never_reaches_the_terminal
        ] )
    ]
