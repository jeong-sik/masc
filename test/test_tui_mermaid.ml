(* Mermaid drawn as text. The goldens were produced by the renderer and
   read by eye before they were pinned: the point of pinning them is that a
   change to the layout is a change to what a reader sees, and has to say so
   here. Every glyph is one cell wide, so a row's byte length is not its
   width; the width checks go through the layout module. *)

module Mermaid = Masc_tui_mermaid

let rows = Alcotest.(list string)

let render ?(cols = 80) source =
  match Mermaid.render ~cols source with
  | Ok drawn -> drawn
  | Error (Mermaid.Unsupported what) -> Alcotest.failf "unsupported: %s" what
  | Error (Mermaid.Parse_error { line; what }) -> Alcotest.failf "line %d: %s" line what
  | Error (Mermaid.Too_wide { cells; cols }) -> Alcotest.failf "%d cells in %d cols" cells cols

let failure ?(cols = 80) source =
  match Mermaid.render ~cols source with
  | Ok drawn -> Alcotest.failf "drew %d rows instead of failing" (List.length drawn)
  | Error failure -> failure

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0

(* {1 Goldens} *)

let td_rows =
  [ {|┌───┐|}
  ; {|│ A │|}
  ; {|└─┬─┘|}
  ; {|  │|}
  ; {|  v|}
  ; {|┌─┴─┐|}
  ; {|│ B │|}
  ; {|└───┘|}
  ]

let lr_rows =
  [ {|┌───┐  ┌───┐|}
  ; {|│ A ├─>┤ B │|}
  ; {|└───┘  └───┘|}
  ]

let fanout_rows =
  [ {|    ┌───┐|}
  ; {|    │ A │|}
  ; {|    └─┬─┘|}
  ; {|      │|}
  ; {|  ┌───┤|}
  ; {|  │   └───┐|}
  ; {|  v       v|}
  ; {|┌─┴─┐   ┌─┴─┐|}
  ; {|│ B │   │ C │|}
  ; {|└───┘   └───┘|}
  ]

let label_rows =
  [ {|┌───┐|}
  ; {|│ A │|}
  ; {|└─┬─┘|}
  ; {|  │ yes|}
  ; {|  v|}
  ; {|┌─┴─┐|}
  ; {|│ B │|}
  ; {|└───┘|}
  ]

let bt_rows =
  [ {|┌───┐|}
  ; {|│ B │|}
  ; {|└─┬─┘|}
  ; {|  ^|}
  ; {|  │|}
  ; {|┌─┴─┐|}
  ; {|│ A │|}
  ; {|└───┘|}
  ]

let rl_rows =
  [ {|┌───┐  go ┌───┐|}
  ; {|│ B ├<────┤ A │|}
  ; {|└───┘     └───┘|}
  ]

let shapes_rows =
  [ {|╭───────╮ no  ┌───────┐ yes  ┌─────┐|}
  ; {|│ start ├<───>┤ ⟨ok?⟩ ├─────>┤ end │|}
  ; {|╰───────╯     └───────┘      └─────┘|}
  ]

let korean_rows =
  [ {|┌───────────┐|}
  ; {|│ 요청 접수 │|}
  ; {|└─────┬─────┘|}
  ; {|      │|}
  ; {|      v|}
  ; {|  ┌───┴──┐|}
  ; {|  │ 검토 │|}
  ; {|  └──────┘|}
  ]

let dotted_rows =
  [ {|         ┌───┐|}
  ; {|      ┌┄>┤ B │|}
  ; {|      ┆  └───┘|}
  ; {|┌───┐ ┆|}
  ; {|│ A ├─┴┐|}
  ; {|└───┘  ┃|}
  ; {|       ┃ ┌───┐|}
  ; {|       └>┤ C │|}
  ; {|         └───┘|}
  ]

let test_top_down () = Alcotest.check rows "A --> B" td_rows (render "graph TD\nA --> B")
let test_left_right () = Alcotest.check rows "A --> B" lr_rows (render "graph LR\nA --> B")

let test_fan_out_jogs_on_its_own_bus_rows () =
  Alcotest.check rows "two children" fanout_rows (render "graph TD\nA --> B\nA --> C")

let test_edge_label_sits_beside_the_drop () =
  Alcotest.check rows "|yes|" label_rows (render "graph TD\nA -->|yes| B")

let test_bottom_up_points_up () =
  Alcotest.check rows "BT" bt_rows (render "graph BT\nA --> B")

let test_right_left_reads_left_to_right () =
  Alcotest.check rows "RL with label" rl_rows (render "graph RL\nA -->|go| B")

let test_shapes_labels_and_a_back_edge () =
  Alcotest.check rows "round, diamond, double rect"
    shapes_rows
    (render "flowchart LR\n  S([start]) --> D{ok?}\n  D -- no --> S\n  D -->|yes| E[[end]]")

let test_wide_glyphs_measure_by_cells () =
  Alcotest.check rows "Korean ids and labels" korean_rows
    (render "graph TD\n  요청[요청 접수] --> 검토")

let test_dotted_and_thick_keep_their_strokes () =
  Alcotest.check rows "-.-> and ==>" dotted_rows (render "graph LR\nA -.-> B\nA ==> C")

(* {1 Shape, not bytes} *)

let test_a_long_edge_passes_through_the_layer_between () =
  let drawn = render "graph TD; A --> B --> C; A --> C" in
  List.iter
    (fun name ->
      Alcotest.(check bool) (name ^ " is drawn") true
        (List.exists (contains name) drawn))
    [ "│ A │"; "│ B │"; "│ C │" ];
  (* three bands of three rows and two channels of four *)
  Alcotest.(check int) "rows" 17 (List.length drawn)

let test_every_row_fits_the_width_asked () =
  let cols = 30 in
  let drawn = render ~cols "graph LR\nA --> B\nA --> C\nB --> D" in
  List.iter
    (fun row ->
      Alcotest.(check bool) row true (Masc_tui_message_layout.display_width row <= cols))
    drawn

let test_same_source_same_bytes () =
  let source = "graph TD\nA --> B\nB --> C\nA --> C\nC --> A" in
  Alcotest.check rows "twice" (render source) (render source)

(* {1 Refusals} *)

let test_a_diagram_of_another_kind_names_itself () =
  match failure "sequenceDiagram\nA->>B: hi" with
  | Mermaid.Unsupported what -> Alcotest.(check string) "the first word" "sequenceDiagram" what
  | Mermaid.Parse_error _ | Mermaid.Too_wide _ -> Alcotest.fail "not an Unsupported"

let test_a_line_this_grammar_cannot_read_names_its_line () =
  match failure "graph TD\nA --> B\nB --> " with
  | Mermaid.Parse_error { line; what } ->
      Alcotest.(check int) "the third line" 3 line;
      Alcotest.(check bool) "says what it wanted" true (contains "node id" what)
  | Mermaid.Unsupported _ | Mermaid.Too_wide _ -> Alcotest.fail "not a Parse_error"

let test_an_unknown_direction_is_refused_on_the_header () =
  match failure "graph XY\nA --> B" with
  | Mermaid.Parse_error { line; _ } -> Alcotest.(check int) "line 1" 1 line
  | Mermaid.Unsupported _ | Mermaid.Too_wide _ -> Alcotest.fail "not a Parse_error"

let test_a_drawing_wider_than_the_pane_says_how_wide () =
  match failure ~cols:20 "graph LR\nA --> B --> C --> D --> E" with
  | Mermaid.Too_wide { cells; cols } ->
      Alcotest.(check int) "cols asked" 20 cols;
      Alcotest.(check bool) "needs more" true (cells > cols)
  | Mermaid.Unsupported _ | Mermaid.Parse_error _ -> Alcotest.fail "not Too_wide"

let test_a_self_edge_is_refused () =
  match failure "graph TD\nA --> A" with
  | Mermaid.Unsupported what -> Alcotest.(check bool) "names the node" true (contains "A" what)
  | Mermaid.Parse_error _ | Mermaid.Too_wide _ -> Alcotest.fail "not an Unsupported"

(* {1 Reading} *)

let parsed source =
  match Mermaid.parse source with
  | Ok (Mermaid.Graph graph) -> graph
  | Error (Mermaid.Unsupported what) -> Alcotest.failf "unsupported: %s" what
  | Error (Mermaid.Parse_error { line; what }) -> Alcotest.failf "line %d: %s" line what
  | Error (Mermaid.Too_wide _) -> Alcotest.fail "parse does not measure"

let test_statements_split_on_semicolons_and_skip_comments () =
  let graph = parsed "graph LR\n%% not a statement\n  %% nor this\nA & B --> C; C --> D" in
  Alcotest.(check (list string)) "nodes in order of appearance"
    [ "A"; "B"; "C"; "D" ]
    (List.map (fun (node : Mermaid.node) -> node.id) graph.nodes);
  Alcotest.(check (list (pair string string))) "one edge per pair"
    [ ("A", "C"); ("B", "C"); ("C", "D") ]
    (List.map (fun (edge : Mermaid.edge) -> (edge.from_id, edge.to_id)) graph.edges)

let test_both_label_spellings_read_the_same () =
  let labels source =
    List.map (fun (edge : Mermaid.edge) -> edge.label) (parsed source).edges
  in
  Alcotest.(check (list (option string))) "|text|" [ Some "yes" ] (labels "graph TD\nA -->|yes| B");
  Alcotest.(check (list (option string))) "-- text -->" [ Some "yes" ]
    (labels "graph TD\nA -- yes --> B");
  Alcotest.(check (list (option string))) "quoted, with a break"
    [ Some "one two" ]
    (labels "graph TD\nA -->|\"one<br/>two\"| B")

let test_strokes_heads_and_shapes_are_read () =
  let graph = parsed "graph TD\nA(round) -.-> B{dia}\nB ==> C[[rect]]\nC --- A" in
  let shapes = List.map (fun (node : Mermaid.node) -> node.shape) graph.nodes in
  Alcotest.(check bool) "round, diamond, rect" true
    (shapes = [ Mermaid.Round; Mermaid.Diamond; Mermaid.Rect ]);
  let strokes = List.map (fun (edge : Mermaid.edge) -> (edge.style, edge.directed)) graph.edges in
  Alcotest.(check bool) "dotted, thick, undirected solid" true
    (strokes = [ (Mermaid.Dotted, true); (Mermaid.Thick, true); (Mermaid.Solid, false) ])

let test_styling_statements_change_nothing () =
  let plain = parsed "graph TD\nA --> B" in
  let styled =
    parsed "graph TD\nA --> B\nclassDef big fill:#f00\nclass A big\nstyle B stroke:#000\nlinkStyle 0 stroke:#0f0\nclick A href \"x\""
  in
  Alcotest.(check int) "same nodes" (List.length plain.nodes) (List.length styled.nodes);
  Alcotest.(check int) "same edges" (List.length plain.edges) (List.length styled.edges)

let () =
  Alcotest.run "tui mermaid"
    [ ( "goldens"
      , [ Alcotest.test_case "top down" `Quick test_top_down
        ; Alcotest.test_case "left right" `Quick test_left_right
        ; Alcotest.test_case "fan out jogs on its own bus rows" `Quick
            test_fan_out_jogs_on_its_own_bus_rows
        ; Alcotest.test_case "edge label sits beside the drop" `Quick
            test_edge_label_sits_beside_the_drop
        ; Alcotest.test_case "bottom up points up" `Quick test_bottom_up_points_up
        ; Alcotest.test_case "right left reads left to right" `Quick
            test_right_left_reads_left_to_right
        ; Alcotest.test_case "shapes, labels and a back edge" `Quick
            test_shapes_labels_and_a_back_edge
        ; Alcotest.test_case "wide glyphs measure by cells" `Quick
            test_wide_glyphs_measure_by_cells
        ; Alcotest.test_case "dotted and thick keep their strokes" `Quick
            test_dotted_and_thick_keep_their_strokes
        ] )
    ; ( "shape"
      , [ Alcotest.test_case "a long edge passes through the layer between" `Quick
            test_a_long_edge_passes_through_the_layer_between
        ; Alcotest.test_case "every row fits the width asked" `Quick
            test_every_row_fits_the_width_asked
        ; Alcotest.test_case "same source, same bytes" `Quick test_same_source_same_bytes
        ] )
    ; ( "refusals"
      , [ Alcotest.test_case "another kind names itself" `Quick
            test_a_diagram_of_another_kind_names_itself
        ; Alcotest.test_case "an unreadable line names its line" `Quick
            test_a_line_this_grammar_cannot_read_names_its_line
        ; Alcotest.test_case "an unknown direction is refused on the header" `Quick
            test_an_unknown_direction_is_refused_on_the_header
        ; Alcotest.test_case "wider than the pane says how wide" `Quick
            test_a_drawing_wider_than_the_pane_says_how_wide
        ; Alcotest.test_case "a self edge is refused" `Quick test_a_self_edge_is_refused
        ] )
    ; ( "reading"
      , [ Alcotest.test_case "statements split on semicolons and skip comments" `Quick
            test_statements_split_on_semicolons_and_skip_comments
        ; Alcotest.test_case "both label spellings read the same" `Quick
            test_both_label_spellings_read_the_same
        ; Alcotest.test_case "strokes, heads and shapes are read" `Quick
            test_strokes_heads_and_shapes_are_read
        ; Alcotest.test_case "styling statements change nothing" `Quick
            test_styling_statements_change_nothing
        ] )
    ]
