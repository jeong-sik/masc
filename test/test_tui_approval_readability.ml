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

let contains ~needle text =
  let rec search at =
    at + String.length needle <= String.length text
    && (String.sub text at (String.length needle) = needle || search (at + 1))
  in
  search 0

let check_wrapped_input ~width ~raw ~expected ~graphemes =
  let rows = Detail.of_fields ~width [ "args", raw ] in
  check bool "the input is readable at this width" false
    (List.exists (fun (line : Detail.line) -> line.unreadable) rows);
  List.iter (fun (line : Detail.line) ->
    check bool "each row fits the available cells" true
      (Masc_tui_message_layout.display_width line.text <= width)) rows;
  (* These fixtures contain no spaces, so trimming a rendered value does not
     alter its input bytes and does not depend on a particular indentation. *)
  let values = List.filter_map (fun (line : Detail.line) ->
    match line.label with None -> Some (String.trim line.text) | Some _ -> None) rows
  in
  check string "the full terminal-safe input is retained" expected (String.concat "" values);
  check bool "the JSON backslash pair stays on one row" true
    (List.exists (contains ~needle:"\\\\") values);
  check bool "the control escape stays on one row" true
    (List.exists (contains ~needle:"\\x1B") values);
  List.iter (fun grapheme ->
    check bool "each grapheme stays on one row" true
      (List.exists (contains ~needle:grapheme) values)) graphemes

let test_escape_reflow_keeps_approval_input () =
  (* Two escapes straddle different row boundaries. Correcting the first
     boundary leaves only a fragment of the second in the next row. *)
  let prefix = String.make 73 'a' ^ "\\\\" ^ String.make 70 'b' in
  let expected = prefix ^ "\\x1Bé" in
  check_wrapped_input ~width:76 ~raw:(prefix ^ "\027é") ~expected ~graphemes:[ "é" ];
  (* Literal terminal-safe bytes have no source map, but need the same
     complete, readable wrapping as a generated control escape. *)
  check_wrapped_input ~width:76 ~raw:expected ~expected ~graphemes:[ "é" ];
  let graphemes = "é👩‍💻" in
  check_wrapped_input ~width:76 ~raw:(prefix ^ "\027" ^ graphemes)
    ~expected:(prefix ^ "\\x1B" ^ graphemes) ~graphemes:[ "é"; "👩‍💻" ]

let test_a_grapheme_needs_enough_width () =
  check bool "a two-cell grapheme cannot fit a one-cell value area" true
    (unreadable ~width:3 "a中b");
  check bool "the same input fits when its grapheme has two cells" false
    (unreadable ~width:4 "a中b")

let check_gate_input ~width ~fields ~selected ~expected ~escapes =
  let rows = Detail.of_gate_fields ~width fields in
  check bool "the Gate input is readable" false
    (List.exists (fun (line : Detail.gate_line) -> line.gate_origin = Detail.Gate_unreadable) rows);
  List.iter (fun (line : Detail.gate_line) ->
    check bool "each Gate row fits the available cells" true
      (String.length (Detail.prefix line.gate_origin)
       + Masc_tui_message_layout.display_width line.gate_text <= width)) rows;
  let values = List.filter_map (fun (line : Detail.gate_line) ->
    if selected line.gate_origin then Some line.gate_text else None) rows in
  check string "the full Gate input is retained" expected (String.concat "" values);
  List.iter (fun escape ->
    check bool "each escape stays on one row" true
      (List.exists (contains ~needle:escape) values)) escapes

let test_gate_key_escape_reflow () =
  let key = String.make 5 'a' ^ "\\x09\\x1Bé" in
  check_gate_input ~width:13 ~fields:[ key, `String "v" ]
    ~selected:(function Detail.Gate_key | Detail.Gate_key_continuation -> true
      | Detail.Gate_string | Detail.Gate_json | Detail.Gate_unreadable -> false)
    ~expected:key ~escapes:[ "\\x09"; "\\x1B" ]

let test_gate_string_escape_reflow () =
  let value = String.make 4 'a' ^ "\\x09\\x1Bé" in
  check_gate_input ~width:11 ~fields:[ "key", `String value ]
    ~selected:(( = ) Detail.Gate_string) ~expected:value ~escapes:[ "\\x09"; "\\x1B" ]

let test_gate_json_escape_reflow () =
  let value = "aaa\\\027é" in
  let expected = "[\"aaa" ^ "\\\\" ^ "\\u001b" ^ "é\"]" in
  check_gate_input ~width:13 ~fields:[ "key", `List [ `String value ] ]
    ~selected:(( = ) Detail.Gate_json) ~expected ~escapes:[ "\\\\"; "\\u001b" ]

let () =
  run "Approval input disclosure"
    [ "decisions",
      [ test_case "raw input retains its expansion boundary" `Quick test_raw_input_owns_expansion_boundaries;
        test_case "current width determines disclosure" `Quick test_current_width_owns_readability;
        test_case "escape reflow retains the input" `Quick test_escape_reflow_keeps_approval_input;
        test_case "a wide grapheme requires enough width" `Quick test_a_grapheme_needs_enough_width;
        test_case "Gate key reflow retains the input" `Quick test_gate_key_escape_reflow;
        test_case "Gate string reflow retains the input" `Quick test_gate_string_escape_reflow;
        test_case "Gate JSON reflow retains the input" `Quick test_gate_json_escape_reflow ] ]
