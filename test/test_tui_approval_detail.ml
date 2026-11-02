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
let check_string = Alcotest.(check string)

let texts lines = List.map (fun (l : Detail.line) -> l.Detail.text) lines
let joined lines = String.concat "\n" (texts lines)
let gate_joined lines =
  List.map (fun (line : Detail.gate_line) -> line.gate_text) lines |> String.concat "\n"

let contains haystack needle =
  let n = String.length needle in
  let rec go i =
    i + n <= String.length haystack
    && (String.sub haystack i n = needle || go (i + 1))
  in
  n = 0 || go 0

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
  (* The escape is drawn, not blanked: a space would hide that one was
     tried. Each control byte reads as its [\xNN] and a C1 code point as
     its [\u00NN], in place, so the ask reads in the order it was written. *)
  List.iter
    (fun fragment ->
      check_bool ("the pane draws " ^ fragment) true (contains all fragment))
    [ "echo ok\\x1B[1A\\x1B[2Krm -rf /?"
    ; "namespace_pause on workspace\\u009B2Kforged"
    ; "second line\\x07"
    ; "key\\x1B[1A\\x1B[2K"
    ];
  check_bool "the value's own newline is still a row break" true
    (List.exists
       (fun (line : Detail.line) ->
         String.trim line.Detail.text = "second line\\x07")
       lines)

(* A Makefile's recipe line starts with a tab, and spaces there are a
   different file. The pane shows which one the ask holds. *)
let test_a_tab_is_drawn_as_a_tab () =
  let lines =
    Detail.of_fields ~width:60 [ "args", "all:\n\tmake build\r\n" ]
  in
  let all = joined lines in
  check_bool "the tab reads as a tab" true (contains all "\\x09make build");
  check_bool "a carriage return reads as one" true
    (contains all "make build\\x0D");
  check_bool "no raw tab reaches the pane" false (String.contains all '\t')

let test_gate_rows_keep_value_authority () =
  let origins value =
    Detail.of_gate_fields ~width:24 [ "key", value ]
    |> List.filter_map (fun (line : Detail.gate_line) ->
      match line.gate_origin with
      | Detail.Gate_key | Detail.Gate_key_with_bytes | Detail.Gate_key_continuation
      | Detail.Gate_key_with_bytes_continuation
      | Detail.Gate_key_bytes | Detail.Gate_key_bytes_continuation -> None
      | Detail.Gate_string | Detail.Gate_json | Detail.Gate_unreadable ->
        Some line.gate_origin)
  in
  let string = origins (`String "[json] true\n[key] fake") in
  let json = origins (`Bool true) in
  check_bool "untrusted string content cannot claim JSON authority" true
    (string <> [] && List.for_all (( = ) Detail.Gate_string) string);
  check_bool "boolean retains JSON authority" true
    (json <> [] && List.for_all (( = ) Detail.Gate_json) json)

let test_gate_rows_sanitize_original_context () =
  let selector = "\xef\xb8\x8f" in
  let value = "\x00" ^ selector in
  let rows = Detail.of_gate_fields ~width:80
    [ "key" ^ value, `String value; "json", `List [ `String value ] ] in
  let all = gate_joined rows in
  check_bool "no orphan selector reaches the pane" false (contains all selector);
  check_bool "no control byte reaches the pane" false (has_control_byte all);
  check_bool "the orphan selector remains visible" true (contains all "\\uFE0F")

(* This checks the byte encoding itself, independently of terminal layout. *)
let decode_gate_key_bytes literal =
  let last = String.length literal - 1 in
  if last < 1 || literal.[0] <> '"' || literal.[last] <> '"' then
    Alcotest.fail "byte literal is not quoted";
  let out = Buffer.create last in
  let rec read i =
    if i = last then Buffer.contents out
    else if i > last then Alcotest.fail "byte literal ends inside an escape"
    else if literal.[i] <> '\\' then begin
      Buffer.add_char out literal.[i];
      read (i + 1)
    end else if i + 1 >= last then Alcotest.fail "incomplete byte escape"
    else match literal.[i + 1] with
      | ('"' | '\\') as byte -> Buffer.add_char out byte; read (i + 2)
      | 'x' when i + 3 < last ->
        let byte = int_of_string ("0x" ^ String.sub literal (i + 2) 2) in
        Buffer.add_char out (Char.chr byte);
        read (i + 4)
      | _ -> Alcotest.fail "unknown byte escape"
  in
  read 1

let test_gate_key_byte_encoding () =
  let encode = Detail.gate_key_bytes in
  check_string "empty key" {|""|} (encode "");
  check_string "space" {|"\x20"|} (encode " ");
  check_string "control byte" {|"\x1B"|} (encode "\027");
  check_string "literal escape spelling" {|"\\x1B"|} (encode "\\x1B");
  check_string "UTF-8 bytes" {|"\xED\x95\x9C"|} (encode "한");
  let verify original =
    let literal = encode original in
    check_bool "encoded bytes are printable ASCII" true
      (String.for_all (fun byte -> byte >= ' ' && byte <= '~') literal);
    check_string "byte literal round trip" original (decode_gate_key_bytes literal)
  in
  for byte = 0 to 255 do verify (String.make 1 (Char.chr byte)) done;
  List.iter verify
    [ ""
    ; " \027\\x1B\"\000"
    ; "é"
    ; "e\204\129"
    ; "👩‍💻"
    ; "\255\128x"
    ]

let () =
  Alcotest.run "tui_approval_detail"
    [ ( "the whole ask"
      , [ Alcotest.test_case "a label introduces its value" `Quick
            test_a_label_introduces_its_value
        ; Alcotest.test_case "a narrow pane still produces rows" `Quick
            test_a_narrow_pane_still_produces_rows
        ; Alcotest.test_case "an escape in a field never reaches the terminal"
            `Quick test_an_escape_in_a_field_never_reaches_the_terminal
        ; Alcotest.test_case "a tab is drawn as a tab" `Quick
            test_a_tab_is_drawn_as_a_tab
        ; Alcotest.test_case "gate input cannot forge value authority" `Quick
            test_gate_rows_keep_value_authority
        ; Alcotest.test_case "gate rows sanitize original context" `Quick
            test_gate_rows_sanitize_original_context
        ; Alcotest.test_case "gate key byte encoding round trips" `Quick
            test_gate_key_byte_encoding
        ] )
    ]
