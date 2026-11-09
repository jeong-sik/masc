(* task-3491: lib/tui_terminal_text.ml had no test file of its own.

   Everything below calls [sanitize_terminal_text] / [sanitize_terminal_lines]
   directly. No TUI frame, font, row order or wording takes part: these are the
   security boundary's own values (which bytes may reach the terminal) and the
   preservation property (the visible text survives the escape). The
   "TUI 화면 문구·배치·행 순서" prohibition does not reach them. *)

open Masc

let raw_control text =
  String.exists
    (fun ch ->
       let code = Char.code ch in
       code < 0x20 || code = 0x7f)
    text
;;

let contains haystack needle = String_util.contains_substring haystack needle

(* A control byte must never be copied through, whichever one it is. *)
let test_control_bytes_never_reach_the_terminal () =
  let cases =
    [ "ESC", "\027[2J"
    ; "BEL", "\007"
    ; "DEL", "\127"
    ; "NUL", "\000"
    ; "CR", "\r"
    ; "tab", "\t"
    ; "vertical tab", "\011"
    ; "backspace", "\b"
    ; "form feed", "\012"
    ]
  in
  List.iter
    (fun (label, input) ->
       let shown = Tui_terminal_text.sanitize_terminal_text input in
       Alcotest.(check bool) (label ^ ": no raw control byte") false (raw_control shown);
       Alcotest.(check bool) (label ^ ": an escape is drawn") true (contains shown "\\x"))
    cases
;;

(* The escape must not cost the text around it. An implementation that dropped
   the whole string would pass the raw-byte check above and fail here. *)
let test_visible_text_survives_the_escape () =
  let input = "before\027[2Jafter" in
  let shown = Tui_terminal_text.sanitize_terminal_text input in
  Alcotest.(check bool) "prefix survives" true (contains shown "before");
  Alcotest.(check bool) "suffix survives" true (contains shown "after");
  Alcotest.(check bool) "sequence body survives" true (contains shown "[2J");
  Alcotest.(check bool)
    "the escape replaces one byte with more than one"
    true
    (String.length shown > String.length input)
;;

(* A C1 control is a codepoint, not a byte, so it takes the \u00NN form. *)
let test_c1_control_uses_the_codepoint_escape () =
  let shown = Tui_terminal_text.sanitize_terminal_text "\194\128" in
  Alcotest.(check bool) "C1 becomes a codepoint escape" true (contains shown "\\u0080");
  Alcotest.(check bool) "no raw C1 byte pair" false (raw_control shown)
;;

(* Printable ASCII and Hangul are the two sets the walk copies unchanged; a
   sanitizer that escaped ordinary text would draw noise in every cell. *)
let test_plain_text_is_returned_unchanged () =
  List.iter
    (fun input ->
       Alcotest.(check string)
         input
         input
         (Tui_terminal_text.sanitize_terminal_text input))
    [ "hello world"
    ; "keeper#42 (ready)"
    ; "a|b->c"
    ; "값 0.5 초"
    ; "안녕하세요"
    ]
;;

(* A multi-byte letter must not be split: neither half is a control byte, and
   the two syllables on both sides of the NUL must both survive whole. *)
let test_multibyte_letters_are_not_read_as_controls () =
  let input = "한\000글" in
  let shown = Tui_terminal_text.sanitize_terminal_text input in
  Alcotest.(check bool) "no raw control byte" false (raw_control shown);
  Alcotest.(check bool) "first syllable intact" true (contains shown "한");
  Alcotest.(check bool) "second syllable intact" true (contains shown "글");
  Alcotest.(check bool) "the NUL itself is drawn" true (contains shown "\\x00")
;;

(* Line shape: LF stays a line break, CR is a control and gets drawn. *)
let test_lines_keep_lf_and_escape_cr () =
  let shown = Tui_terminal_text.sanitize_terminal_lines "one\r\ntwo\000three" in
  Alcotest.(check bool) "no raw CR" false (String.contains shown '\r');
  Alcotest.(check bool) "LF still breaks the line" true (String.contains shown '\n');
  Alcotest.(check int) "one line break preserved" 1 (String.split_on_char '\n' shown |> List.length |> fun n -> n - 1);
  Alcotest.(check bool) "CR is drawn" true (contains shown "\\x0D");
  Alcotest.(check bool) "first line text survives" true (contains shown "one");
  Alcotest.(check bool) "second line text survives" true (contains shown "two");
  Alcotest.(check bool) "third line text survives" true (contains shown "three")
;;

(* Sanitizing an already-sanitized text changes nothing: the escape output is
   itself plain, so a caller that sanitizes twice draws the same frame. *)
let test_sanitize_is_idempotent () =
  List.iter
    (fun input ->
       let once = Tui_terminal_text.sanitize_terminal_text input in
       let twice = Tui_terminal_text.sanitize_terminal_text once in
       Alcotest.(check string) "second pass is a no-op" once twice)
    [ "before\027[2Jafter"; "\000\007\127"; "\194\128"; "평범한 글" ]
;;

let () =
  Alcotest.run
    "terminal text boundary"
    [ ( "security"
      , [ Alcotest.test_case
            "a control byte never reaches the terminal"
            `Quick
            test_control_bytes_never_reach_the_terminal
        ; Alcotest.test_case
            "visible text survives the escape"
            `Quick
            test_visible_text_survives_the_escape
        ; Alcotest.test_case
            "a C1 control uses the codepoint escape"
            `Quick
            test_c1_control_uses_the_codepoint_escape
        ; Alcotest.test_case
            "sanitize is idempotent"
            `Quick
            test_sanitize_is_idempotent
        ] )
    ; ( "preservation"
      , [ Alcotest.test_case
            "plain text is returned unchanged"
            `Quick
            test_plain_text_is_returned_unchanged
        ; Alcotest.test_case
            "multi-byte letters are not read as controls"
            `Quick
            test_multibyte_letters_are_not_read_as_controls
        ; Alcotest.test_case "lines keep LF and escape CR" `Quick test_lines_keep_lf_and_escape_cr
        ] )
    ]
;;
