let contains text pattern =
  let rec search i =
    i + String.length pattern <= String.length text
    && (String.sub text i (String.length pattern) = pattern || search (i + 1)) in
  search 0

let test_document_json_escapes_terminal_controls () =
  let bidi = "\226\128\174" and c1 = "\194\128" and selector = "\239\184\143" in
  let emoji = "👩‍💻" in
  let value = `Assoc ["value", `String ("A" ^ bidi ^ c1 ^ "\000" ^ selector ^ emoji)] in
  let rows = value |> Yojson.Safe.pretty_to_string
    |> Masc_tui_render_prim.document_json ~width:120 in
  let shown = rows |> List.map (fun row -> Masc_tui_message_layout.fit_width row 124)
    |> String.concat "" in
  List.iter (fun (label, raw) ->
    Alcotest.(check bool) label false (contains shown raw))
    ["bidi control", bidi; "C1 control", c1; "orphan selector", selector];
  List.iter (fun escape ->
    Alcotest.(check bool) "control is visible as an escape" true (contains shown escape))
    ["\\u202E"; "\\u0080"; "\\uFE0F"];
  Alcotest.(check bool) "valid emoji stays intact" true (contains shown emoji)

let () =
  Alcotest.run "terminal JSON document"
    ["security", [Alcotest.test_case "controls after frame fitting" `Quick
      test_document_json_escapes_terminal_controls]]
