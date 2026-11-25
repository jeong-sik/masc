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

let test_render_adaptive_lr_to_td_fallback () =
  let lr_src =
    "flowchart LR\n\
     A[\"Problem and issue\"] --> B[\"Branch change\"]\n\
     B --> C[\"Independent review\"]\n\
     C --> D[\"Land on main\"]"
  in
  (* Strict Mermaid.render at cols=48 refuses horizontal LR as Too_wide *)
  (match Mermaid.render ~cols:48 lr_src with
  | Error (Mermaid.Too_wide { turning_it_fits = Some Mermaid.Top_down; _ }) -> ()
  | Ok _ | Error (Mermaid.Too_wide _ | Mermaid.Unsupported _ | Mermaid.Parse_error _) ->
      Alcotest.fail "expected Too_wide suggesting Top_down at cols=48 for LR");
  (* render_adaptive automatically retries as TD and fits strictly within 48 cells *)
  (match Mermaid.render_adaptive ~cols:48 lr_src with
  | Ok rows ->
      Alcotest.(check bool) "adaptive TD renders multiple rows" true
        (List.length rows >= 8);
      List.iter
        (fun row ->
          Alcotest.(check bool) "each adaptive row fits <= 48 cells" true
            (Grapheme.display_width row <= 48))
        rows;
      let joined = String.concat "\n" rows in
      Alcotest.(check bool) "rendered diagram keeps node labels" true
        (contains "Problem and issue" joined && contains "Land on main" joined);
      Alcotest.(check bool) "rendered diagram draws box borders" true
        (contains "\xe2\x94\x8c" joined || contains "\xe2\x95\xad" joined)
  | Error _ -> Alcotest.fail "expected render_adaptive to fit LR as TD at cols=48");
  (* graph RL also adapts to TD cleanly *)
  (match
     Mermaid.render_adaptive ~cols:48
       "graph RL\nX[Collector] --> Y[Normalizer]\nY --> Z[Renderer]"
   with
  | Ok rows ->
      Alcotest.(check bool) "RL adapts to TD at cols=48" true (rows <> []);
      List.iter
        (fun row ->
          Alcotest.(check bool) "RL adaptive row <= 48 cells" true
            (Grapheme.display_width row <= 48))
        rows
  | Error _ -> Alcotest.fail "expected graph RL to adapt to TD at cols=48");
  (* When even TD cannot fit (cols=8), render_adaptive still fails honestly with Too_wide *)
  match Mermaid.render_adaptive ~cols:8 lr_src with
  | Error (Mermaid.Too_wide { turning_it_fits = None; _ }) -> ()
  | Ok _ | Error (Mermaid.Too_wide _ | Mermaid.Unsupported _ | Mermaid.Parse_error _) ->
      Alcotest.fail "expected honest Too_wide when even TD exceeds cols=8"

(* A box label's line break: each line takes a row of its own. *)
let box_side = "\xe2\x94\x82" (* │ *)
and box_top_left = "\xe2\x94\x8c" (* ┌ *)
and box_bottom_left = "\xe2\x94\x94" (* └ *)
and box_rule = "\xe2\x94\x80" (* ─ *)

let index_of pred rows =
  let rec go i = function
    | [] -> None
    | row :: rest -> if pred row then Some i else go (i + 1) rest
  in
  go 0 rows

(* The row of a box that shows [text], wherever the box stands in the row. *)
let has_box_line text row =
  contains (box_side ^ " " ^ text ^ " ") (String.trim row)

let rows_fit cols rows =
  List.for_all (fun row -> Grapheme.display_width row <= cols) rows

(* Every glyph of every row is the byte of its label that its position names. *)
let check_traced_rows source cols =
  match
    ( Mermaid.render_with_source_labels ~cols source,
      Mermaid.render ~cols source )
  with
  | Ok traced, Ok plain ->
      Alcotest.(check (list string)) "traced rows equal plain rows" plain traced.rendered_rows;
      Alcotest.(check int) "a drawn break leaves no undrawn source" 0
        (List.length traced.undrawn_sources);
      (match traced.labels with
       | Mermaid.Incomplete _ -> Alcotest.fail "expected Complete labels"
       | Mermaid.Complete labels ->
           List.iteri
             (fun row text ->
               Array.iteri
                 (fun byte -> function
                   | None -> ()
                   | Some (pos : Mermaid.semantic_position) ->
                       let lbl =
                         List.find
                           (fun (l : Mermaid.sourced_label) -> l.identity = pos.identity)
                           labels
                       in
                       Alcotest.(check char) "glyph matches semantic byte" text.[byte]
                         lbl.text.[pos.byte])
                 traced.rendered_positions.(row))
             plain)
  | _ -> Alcotest.fail ("expected traced render to succeed for: " ^ source)

let test_box_labels_draw_line_breaks () =
  let src = "flowchart TD\nE[\"one<br/>two words<br/>three\"] --> F(\"a<br/>bb\")" in
  let labels (g : Mermaid.graph) =
    List.map (fun (n : Mermaid.node) -> n.label) g.nodes
  in
  Alcotest.(check (list string)) "a box label keeps its line breaks"
    [ "one\ntwo words\nthree"; "a\nbb" ]
    (labels (parsed src));
  (* Top down: the lines take consecutive rows of a box as wide as the
     longest line. *)
  let rows = render ~cols:40 src in
  let shown text = index_of (has_box_line text) rows in
  let row k = List.nth rows k in
  (match shown "one", shown "two words", shown "three" with
   | Some a, Some b, Some c ->
       Alcotest.(check int) "the second line follows the first" 1 (b - a);
       Alcotest.(check int) "the third line follows the second" 1 (c - b);
       Alcotest.(check bool) "the box opens above the first line" true
         (String.starts_with ~prefix:box_top_left (String.trim (row (a - 1))));
       Alcotest.(check bool) "the box closes below the last line" true
         (String.starts_with ~prefix:box_bottom_left (String.trim (row (a + 3))));
       Alcotest.(check int) "the box is as wide as its longest line and the pad" 13
         (Grapheme.display_width (row (a - 1)));
       Alcotest.(check bool) "no row is wider than that box" true (rows_fit 13 rows)
   | _ ->
       Alcotest.failf "expected the three label lines of the first box in: %s"
         (String.concat " / " rows));
  (match shown "a", shown "bb" with
   | Some a, Some b ->
       Alcotest.(check int) "a rounded box draws its lines on consecutive rows" 1 (b - a);
       Alcotest.(check bool) "the rounded box has a rule above its first line" true
         (contains box_rule (row (a - 1)))
   | _ ->
       Alcotest.failf "expected the two label lines of the rounded box in: %s"
         (String.concat " / " rows));
  (* Left to right: the flow runs along the rows and the lines still stack. *)
  let lr =
    render ~cols:60 "flowchart LR\nA[\"x<br/>yy<br/>zzz\"] --> B(\"q<br/>rr\")"
  in
  let lr_shown text = index_of (has_box_line text) lr in
  (match lr_shown "x", lr_shown "yy", lr_shown "zzz", lr_shown "q", lr_shown "rr" with
   | Some a, Some b, Some c, Some d, Some e ->
       Alcotest.(check (list int)) "lines stack downward under a left-to-right flow"
         [ 1; 1; 1 ] [ b - a; c - b; e - d ];
       Alcotest.(check bool) "an arrow still joins the boxes" true (List.exists (contains ">") lr)
   | _ ->
       Alcotest.failf "expected the label lines of the left-to-right boxes in: %s"
         (String.concat " / " lr));
  (* Nothing changes for a label without a break or for another shape. *)
  let single = render ~cols:40 "flowchart TD\nA[one two]" in
  Alcotest.(check int) "a label without a break keeps a three-row box" 3 (List.length single);
  Alcotest.(check int) "and the width it had" 11 (Grapheme.display_width (List.hd single));
  Alcotest.(check (list string)) "another shape takes the break as a space" [ "alpha beta" ]
    (labels (parsed "flowchart TD\nC((alpha<br/>beta))"));
  Alcotest.(check bool) "and draws it on one row" true
    (List.exists (contains "alpha beta") (render ~cols:40 "flowchart TD\nC((alpha<br/>beta))"));
  (* A long fact: the lineage generator wraps it and joins the lines with
     breaks. Joined into one row it could not fit any pane. *)
  let wrapped = String.concat "<br/>" (List.init 22 (fun _ -> String.make 40 'x')) in
  let card =
    Printf.sprintf "flowchart TD\nE[\"made · r62 · 11-23 21:31\"] --> F(\"%s\")" wrapped
  in
  (match Mermaid.render ~cols:60 card with
   | Ok card_rows ->
       Alcotest.(check bool) "the wrapped lines fit a 60 column pane" true (rows_fit 60 card_rows);
       Alcotest.(check bool) "each wrapped line has its own row" true (List.length card_rows >= 24)
   | Error (Mermaid.Too_wide { cells; cols; _ }) ->
       Alcotest.failf "%d cells in %d cols: the wrapped lines were joined into one row" cells cols
   | Error (Mermaid.Unsupported what) -> Alcotest.failf "unsupported: %s" what
   | Error (Mermaid.Parse_error { line; what }) -> Alcotest.failf "line %d: %s" line what);
  check_traced_rows src 40;
  (match Mermaid.render_with_status ~cols:40 src with
   | Ok { Mermaid.undrawn_sources = []; _ } -> ()
   | Ok _ -> Alcotest.fail "a drawn break is not undrawn source"
   | Error (Mermaid.Unsupported what) -> Alcotest.failf "a drawn break needs no source: %s" what
   | Error (Mermaid.Parse_error { line; what }) -> Alcotest.failf "line %d: %s" line what
   | Error (Mermaid.Too_wide { cells; cols; _ }) -> Alcotest.failf "%d cells in %d cols" cells cols)

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
          Alcotest.test_case "render_adaptive auto-retries LR/RL as TD on Too_wide"
            `Quick test_render_adaptive_lr_to_td_fallback;
          Alcotest.test_case "a box label draws each <br/> line on its own row" `Quick
            test_box_labels_draw_line_breaks;
        ] );
    ]
