module Mermaid = Masc_tui_ui.Mermaid
module Grapheme = Masc_tui_term.Grapheme

let node_id =
  let scope_text = function
    | Mermaid.Top_level -> ""
    | Mermaid.Inside id -> " of " ^ id
  in
  let scope_equal a b =
    match a, b with
    | Mermaid.Top_level, Mermaid.Top_level -> true
    | Mermaid.Inside a, Mermaid.Inside b -> String.equal a b
    | Mermaid.Top_level, Mermaid.Inside _ | Mermaid.Inside _, Mermaid.Top_level ->
        false
  in
  Alcotest.testable
    (fun fmt id ->
      Format.pp_print_string fmt
        (match id with
         | Mermaid.Named name -> name
         | Mermaid.Initial scope -> "[*] start" ^ scope_text scope
         | Mermaid.Final scope -> "[*] end" ^ scope_text scope))
    (fun a b ->
      match a, b with
      | Mermaid.Named a, Mermaid.Named b -> String.equal a b
      | Mermaid.Initial a, Mermaid.Initial b | Mermaid.Final a, Mermaid.Final b ->
          scope_equal a b
      | Mermaid.Named _, (Mermaid.Initial _ | Mermaid.Final _)
      | Mermaid.Initial _, (Mermaid.Named _ | Mermaid.Final _)
      | Mermaid.Final _, (Mermaid.Named _ | Mermaid.Initial _) ->
          false)

let render ?(cols = 80) source =
  match Mermaid.render ~cols source with
  | Ok drawn -> drawn
  | Error (Mermaid.Unsupported what) -> Alcotest.failf "unsupported: %s" what
  | Error (Mermaid.Parse_error { line; what }) ->
      Alcotest.failf "line %d: %s" line what
  | Error (Mermaid.Too_wide { cells; cols; _ }) ->
      Alcotest.failf "%d cells in %d cols" cells cols

let failure ?(cols = 80) source =
  match Mermaid.render ~cols source with
  | Ok drawn -> Alcotest.failf "drew %d rows instead of failing" (List.length drawn)
  | Error err -> err

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i =
    i + n <= h && (String.sub haystack i n = needle || go (i + 1))
  in
  n = 0 || go 0

let parsed source =
  match Mermaid.parse source with
  | Ok (Mermaid.Graph g) -> g
  | Ok (Mermaid.Sequence _) -> Alcotest.fail "read as sequence"
  | Error (Mermaid.Unsupported what) -> Alcotest.failf "unsupported: %s" what
  | Error (Mermaid.Parse_error { line; what }) ->
      Alcotest.failf "line %d: %s" line what
  | Error (Mermaid.Too_wide _) -> Alcotest.fail "parse does not measure"

let test_flowchart_parsing_and_shapes () =
  let g =
    parsed
      "flowchart TD\n\
       DB[(Postgres)]\n\
       SUB[[Worker]]\n\
       ST([Pill])\n\
       CIR((Ring))\n\
       REC[Box]\n\
       HEX{{Six}}\n\
       ODD>Flag]\n\
       DB & SUB -->|sync| REC; REC -.-> ODD"
  in
  let shapes = List.map (fun (n : Mermaid.node) -> n.shape) g.nodes in
  Alcotest.(check bool) "all shapes recognized" true
    (shapes
    = [
        Mermaid.Database;
        Mermaid.Subroutine;
        Mermaid.Stadium;
        Mermaid.Circle;
        Mermaid.Rect;
        Mermaid.Hexagon;
        Mermaid.Asymmetric;
      ]);
  Alcotest.(check int) "three edges" 3 (List.length g.edges);
  let rows = render ~cols:100 "flowchart TD\nA[시작] -->|검증| B[완료]" in
  Alcotest.(check bool) "non-empty rows" true (rows <> []);
  List.iter
    (fun row ->
      Alcotest.(check bool) "row fits within 100 cells" true
        (Grapheme.display_width row <= 100))
    rows

let test_korean_and_unicode_display_width () =
  let source = "flowchart LR\nA[한국어 노드] -->|상태| B[결과]" in
  let wide_rows = render ~cols:80 source in
  Alcotest.(check bool) "renders Korean flowchart" true (wide_rows <> []);
  List.iter
    (fun row ->
      Alcotest.(check bool) "row cell width <= 80" true
        (Grapheme.display_width row <= 80))
    wide_rows;
  (* Box around "한국어 노드" needs 11 cells + 4 pad = 15 cells, plus arrow + B[결과] (8 cells)
     -> requires well over 20 cells horizontally, so cols:20 must fail Too_wide and suggest TD! *)
  match failure ~cols:20 source with
  | Mermaid.Too_wide { cells; cols; turning_it_fits = Some Mermaid.Top_down } ->
      Alcotest.(check int) "reported cols" 20 cols;
      Alcotest.(check bool) "measured Korean width > 20" true (cells > 20);
      let turned = render ~cols:20 "flowchart TD\nA[한국어 노드] -->|상태| B[결과]" in
      Alcotest.(check bool) "suggested TD fits" true (turned <> [])
  | Mermaid.Too_wide { turning_it_fits; _ } ->
      Alcotest.failf "expected TD suggestion, got %s"
        (match turning_it_fits with
         | None -> "None"
         | Some d -> Mermaid.direction_word d)
  | Mermaid.Unsupported _ | Mermaid.Parse_error _ ->
      Alcotest.fail "expected Too_wide for narrow Korean LR diagram"

let test_state_diagram_and_composites () =
  let src =
    {|stateDiagram-v2
      [*] --> First
      state First {
          [*] --> second
          second --> [*]
      }
      [*] --> NamedComposite
      NamedComposite: Another Composite
      state NamedComposite {
          [*] --> namedSimple
          namedSimple --> [*]
      }|}
  in
  let g = parsed src in
  Alcotest.(check int) "two top-level composite states" 2 (List.length g.groups);
  Alcotest.(check (list node_id)) "composite state nodes preserve scoped [*]"
    Mermaid.
      [
        Initial Top_level;
        Initial (Inside "First");
        Named "second";
        Final (Inside "First");
        Initial (Inside "NamedComposite");
        Named "namedSimple";
        Final (Inside "NamedComposite");
      ]
    (List.map (fun (n : Mermaid.node) -> n.id) g.nodes);
  let rows = render ~cols:80 src in
  Alcotest.(check bool) "composite state renders" true (rows <> []);
  match
    failure
      "stateDiagram-v2\nstate A {\n[*] --> B\n}\nstate B {\n[*] --> A\n}"
  with
  | Mermaid.Unsupported what ->
      Alcotest.(check bool) "self-nested composite refused" true
        (contains "inside itself" what)
  | Mermaid.Parse_error _ | Mermaid.Too_wide _ ->
      Alcotest.fail "expected Unsupported for cyclic composite state"

let test_sequence_diagram () =
  let src =
    "sequenceDiagram\n\
     participant A as Alice\n\
     participant B as 밥\n\
     alt ok\n\
     A->>B: 안녕\n\
     else retry\n\
     B-->>A: 다시\n\
     end"
  in
  (match Mermaid.parse src with
   | Ok (Mermaid.Sequence seq) ->
       Alcotest.(check (list string)) "participants" [ "A"; "B" ]
         (List.map (fun (p : Mermaid.participant) -> p.pid) seq.participants);
       Alcotest.(check (list string)) "aliases" [ "Alice"; "밥" ]
         (List.map (fun (p : Mermaid.participant) -> p.alias) seq.participants)
   | Ok (Mermaid.Graph _) -> Alcotest.fail "expected Sequence"
   | Error _ -> Alcotest.fail "sequence must parse");
  let rows = render ~cols:80 src in
  Alcotest.(check bool) "sequence renders" true (rows <> []);
  List.iter
    (fun row ->
      Alcotest.(check bool) "sequence row <= 80 cells" true
        (Grapheme.display_width row <= 80))
    rows

let test_refusals_and_failures () =
  (match failure "classDiagram\n  Animal <|-- Duck" with
   | Mermaid.Unsupported what ->
       Alcotest.(check string) "unsupported diagram kind" "classDiagram" what
   | Mermaid.Parse_error _ | Mermaid.Too_wide _ ->
       Alcotest.fail "expected Unsupported");
  (match failure "graph TD\nA --> B\nB --> " with
   | Mermaid.Parse_error { line; _ } -> Alcotest.(check int) "line 3" 3 line
   | Mermaid.Unsupported _ | Mermaid.Too_wide _ ->
       Alcotest.fail "expected Parse_error");
  (match failure "graph TD\nA --> A" with
   | Mermaid.Unsupported what ->
       Alcotest.(check bool) "self edge names node" true (contains "A" what)
   | Mermaid.Parse_error _ | Mermaid.Too_wide _ ->
       Alcotest.fail "expected Unsupported for self edge");
  (match failure "graph TD\nsubgraph One\nA --> B\nend\nB --> C" with
   | Mermaid.Unsupported what ->
       Alcotest.(check bool) "subgraph crossing refused" true
         (contains "crosses a subgraph boundary" what)
   | Mermaid.Parse_error _ | Mermaid.Too_wide _ ->
       Alcotest.fail "expected Unsupported for subgraph crossing");
  (* Standalone combining mark (zero-width) is rejected cleanly *)
  (match failure "graph TD\nA[\xcc\x81]" with
   | Mermaid.Unsupported _ -> ()
   | Mermaid.Parse_error _ | Mermaid.Too_wide _ ->
       Alcotest.fail "expected Unsupported for standalone zero-width mark");
  (* Default-ignorable tag scalar that display_width strips must also be refused *)
  let tag_spoof = "\xe2\x98\xba\xf3\xa0\x80\xa0\xe2\x98\xba\xf3\xa0\x80\xa0" in
  match failure ("graph TD\nA[" ^ tag_spoof ^ "]") with
  | Mermaid.Unsupported _ -> ()
  | Mermaid.Parse_error _ | Mermaid.Too_wide _ ->
      Alcotest.fail "expected Unsupported for stripped default-ignorable tag scalar"

let test_canvas_source_positions_and_undrawn () =
  let ok_fixtures =
    [
      "flowchart TD\nA[repeat] -->|repeat| B[repeat]";
      "flowchart LR\nA[한글] -->|café| B[e\xcc\x81]";
      "sequenceDiagram\nparticipant A as Alice\nparticipant B as Bob\nA->>B: hello";
      "stateDiagram-v2\n[*] --> Active\nActive: label";
    ]
  in
  List.iter
    (fun source ->
      match
        ( Mermaid.render_with_source_labels ~cols:120 source,
          Mermaid.render ~cols:120 source )
      with
      | Ok traced, Ok plain ->
          Alcotest.(check (list string)) "identical rows" plain traced.rendered_rows;
          let labels =
            match traced.labels with
            | Mermaid.Complete ls -> ls
            | Mermaid.Incomplete _ -> Alcotest.fail "expected Complete labels"
          in
          List.iteri
            (fun row text ->
              let positions = traced.rendered_positions.(row) in
              Alcotest.(check int) "one position per byte" (String.length text)
                (Array.length positions);
              Array.iteri
                (fun byte -> function
                  | None -> ()
                  | Some (pos : Mermaid.semantic_position) ->
                      let lbl =
                        List.find
                          (fun (l : Mermaid.sourced_label) -> l.identity = pos.identity)
                          labels
                      in
                      Alcotest.(check char) "glyph matches semantic byte"
                        text.[byte] lbl.text.[pos.byte])
                positions)
            plain
      | _ -> Alcotest.fail ("expected traced render to succeed for: " ^ source))
    ok_fixtures;
  (* Traced and plain rendering agree identically on overlapping-edge refusal *)
  let overlap_src =
    "flowchart TD\nA[repeat] -->|repeat| B[repeat]\nB -->|back| A"
  in
  (match
     ( Mermaid.render_with_source_labels ~cols:120 overlap_src,
       Mermaid.render ~cols:120 overlap_src )
   with
   | Error traced, Error plain ->
       Alcotest.(check bool) "traced and plain agree on refusal" true
         (traced = plain)
   | _ -> Alcotest.fail "expected overlapping parallel edge labels to be refused");
  (* Styling statements interleaved between declarations trigger source fallback *)
  (match
     Mermaid.render_with_status ~cols:120
       "graph TD\nA[first]\nclassDef hot fill:red\nB[second]"
   with
   | Error (Mermaid.Unsupported _) -> ()
   | Ok _ | Error (Mermaid.Parse_error _ | Mermaid.Too_wide _) ->
       Alcotest.fail "interleaved classDef should require source fallback");
  (* Trailing styling is preserved as undrawn_sources *)
  match
    Mermaid.render_with_status ~cols:120
      "graph TD\nA[ok]\n  style A fill:#f00"
  with
  | Ok { undrawn_sources = [ { placement = Mermaid.After_diagram; _ } ]; _ } -> ()
  | _ -> Alcotest.fail "trailing style should report After_diagram undrawn span"

let test_quoted_semicolons_and_class_attachment () =
  let semi_src =
    "flowchart TD\nA[\"a; b\"] --> B[\"#quot;x#quot;\"]\nA --> C[\"c; d\"]; C --> B"
  in
  let g = parsed semi_src in
  Alcotest.(check (list string)) "quoted labels keep semicolons and entities"
    [ "a; b"; "#quot;x#quot;"; "c; d" ]
    (List.map (fun (n : Mermaid.node) -> n.label) g.nodes);
  let semi_rows = render ~cols:100 semi_src in
  Alcotest.(check bool) "quoted semicolon flowchart renders" true
    (semi_rows <> []);
  let cls_src =
    "flowchart TD\n\
     classDef ok fill:#052e16\n\
     classDef warn fill:#451a03\n\
     A[\"hello\"]:::ok --> B[\"world\"]:::warn\n\
     B -.-> C:::ok"
  in
  let gc = parsed cls_src in
  Alcotest.(check (list string)) ":::className attaches cleanly without polluting labels"
    [ "hello"; "world"; "C" ]
    (List.map (fun (n : Mermaid.node) -> n.label) gc.nodes);
  let cls_rows = render ~cols:100 cls_src in
  Alcotest.(check bool) ":::className flowchart renders" true (cls_rows <> []);
  (match Mermaid.render_with_source_labels ~cols:100 "flowchart TD\nA[\"a; b\"]:::ok --> B[\"#quot;x#quot;\"]:::warn" with
   | Ok { labels = Mermaid.Complete _; rendered_rows; _ } ->
       Alcotest.(check bool) "traced render succeeds with quoted ; and :::class"
         true (rendered_rows <> [])
   | Ok { labels = Mermaid.Incomplete _; _ } | Error _ ->
       Alcotest.fail "traced render must map quoted ; and :::class completely");
  match failure "flowchart TD\nA[\"bad\"]::: --> B" with
  | Mermaid.Parse_error { line; _ } -> Alcotest.(check int) "empty ::: fails line 2" 2 line
  | Mermaid.Unsupported _ | Mermaid.Too_wide _ ->
      Alcotest.fail "expected Parse_error for empty ::: class name"

let () =
  Alcotest.run "masc_tui_v2_mermaid"
    [
      ( "mermaid",
        [
          Alcotest.test_case "flowchart parsing & shapes" `Quick
            test_flowchart_parsing_and_shapes;
          Alcotest.test_case "Korean & Unicode cell widths + Too_wide turning" `Quick
            test_korean_and_unicode_display_width;
          Alcotest.test_case "state diagram & composite states" `Quick
            test_state_diagram_and_composites;
          Alcotest.test_case "sequence diagram with Korean aliases" `Quick
            test_sequence_diagram;
          Alcotest.test_case "unsupported / parse error / zero-width refusals" `Quick
            test_refusals_and_failures;
          Alcotest.test_case "source byte positions & undrawn source decisions" `Quick
            test_canvas_source_positions_and_undrawn;
          Alcotest.test_case "quoted semicolons & :::className suffixes" `Quick
            test_quoted_semicolons_and_class_attachment;
        ] );
    ]
