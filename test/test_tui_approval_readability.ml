open Alcotest

module Detail = Masc_tui_approval_detail

let unreadable ~width value =
  Detail.of_fields ~width [ "x", value ]
  |> List.exists (fun (line : Detail.line) -> line.unreadable)

let test_raw_input_owns_expansion_boundaries () =
  (* Both inputs have the same terminal-safe bytes. Only the second contains
     a generated escape overlapping the lexical backslash pair. The cache
     must retain their original source distinction. *)
  let literal = "\\\\x09" in
  let actual_tab = "\\\t" in
  check bool "literal source can fit across complete lexical tokens" false
    (unreadable ~width:6 literal);
  check bool "generated expansion needs more room" true
    (unreadable ~width:6 actual_tab);
  check bool "returning to literal source does not borrow the expansion" false
    (unreadable ~width:6 literal)

let test_current_width_owns_readability () =
  let actual_tab = "\\\t" in
  check bool "initial narrow view cannot disclose the whole expansion" true
    (unreadable ~width:6 actual_tab);
  Detail.begin_frame ();
  check bool "wider view recomputes its disclosure decision" false
    (unreadable ~width:12 actual_tab);
  Detail.begin_frame ();
  check bool "narrower view does not borrow previous readability" true
    (unreadable ~width:6 actual_tab);
  Detail.begin_frame ();
  Detail.begin_frame ();
  check bool "withdrawn encoding is prepared under the current width" false
    (unreadable ~width:12 actual_tab)

let test_escape_reflow_keeps_input_readable () =
  (* Multiple escapes cross successive wrap boundaries. The input fits once
     each complete escape is considered, including when the sanitizer made
     one of them from a control byte. *)
  let prefix = String.make 73 'a' ^ "\\\\" ^ String.make 70 'b' in
  List.iter (fun value ->
    check bool "fitting approval input is readable" false (unreadable ~width:76 value))
    [ prefix ^ "\027é"; prefix ^ "\\x1Bé"; prefix ^ "\027é👩‍💻" ]

let test_a_grapheme_needs_enough_width () =
  check bool "a two-cell grapheme cannot fit a one-cell value area" true
    (unreadable ~width:3 "a中b");
  check bool "the same input fits when its grapheme has two cells" false
    (unreadable ~width:4 "a中b")

let gate_unreadable ~width fields =
  Detail.of_gate_fields ~width fields
  |> List.exists (fun (line : Detail.gate_line) -> line.gate_origin = Detail.Gate_unreadable)

let test_gate_key_escape_reflow () =
  let key = String.make 5 'a' ^ "\\x09\\x1Bé" in
  check bool "fitting Gate key is readable" false
    (gate_unreadable ~width:13 [ key, `String "v" ])

let test_gate_string_escape_reflow () =
  let value = String.make 4 'a' ^ "\\x09\\x1Bé" in
  check bool "fitting Gate string is readable" false
    (gate_unreadable ~width:11 [ "key", `String value ])

let test_gate_json_escape_reflow () =
  let value = "aaa\\\027é" in
  check bool "fitting Gate JSON is readable" false
    (gate_unreadable ~width:13 [ "key", `List [ `String value ] ])

let () =
  run "Approval input disclosure"
    [ "decisions",
      [ test_case "raw input retains its expansion boundary" `Quick test_raw_input_owns_expansion_boundaries;
        test_case "current width determines disclosure" `Quick test_current_width_owns_readability;
        test_case "escape reflow retains readability" `Quick test_escape_reflow_keeps_input_readable;
        test_case "a wide grapheme requires enough width" `Quick test_a_grapheme_needs_enough_width;
        test_case "Gate key reflow retains readability" `Quick test_gate_key_escape_reflow;
        test_case "Gate string reflow retains readability" `Quick test_gate_string_escape_reflow;
        test_case "Gate JSON reflow retains readability" `Quick test_gate_json_escape_reflow ] ]
