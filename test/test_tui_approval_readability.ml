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

let () =
  run "Approval input disclosure"
    [ "decisions",
      [ test_case "raw input retains its expansion boundary" `Quick test_raw_input_owns_expansion_boundaries;
        test_case "current width determines disclosure" `Quick test_current_width_owns_readability ] ]
