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

let seq_basic_rows =
  [ {|┌───────┐   ┌─────┐|}
  ; {|│ Alice │   │ Bob │|}
  ; {|└───┬───┘   └──┬──┘|}
  ; {|    │          │|}
  ; {|    │ hello    │|}
  ; {|    ├─────────>┤|}
  ; {|    │ hi       │|}
  ; {|    ├<┄┄┄┄┄┄┄┄┄┤|}
  ; {|    │          │|}
  ]

let seq_full_rows =
  [ {| ┌───────┐   ┌─────┐|}
  ; {| │ Alice │   │ Bob │|}
  ; {| └───┬───┘   └──┬──┘|}
  ; {|     │          │|}
  ; {|     │ request  │|}
  ; {|     ├─────────>┤|}
  ; {|┌─ loop every 2s ────────┐|}
  ; {|│    │          │   poll │|}
  ; {|│    │          ├──┐     │|}
  ; {|│    │          │<─┘     │|}
  ; {|│    │ status   │        │|}
  ; {|│    ├<┄┄┄┄┄┄┄┄┄┤        │|}
  ; {|└────┼──────────┼────────┘|}
  ; {|┌─ alt ok ──────┼────────┐|}
  ; {|│    │ done     │        │|}
  ; {|│    ├─────────x┤        │|}
  ; {|├┄ else failed ┄┼┄┄┄┄┄┄┄┄┤|}
  ; {|│┌─────────────────┐     │|}
  ; {|││ retry later     │     │|}
  ; {|│└─────────────────┘     │|}
  ; {|└────┼──────────┼────────┘|}
  ; {|     │          │|}
  ]

let test_sequence_messages_run_between_lifelines () =
  Alcotest.check rows "two messages" seq_basic_rows
    (render "sequenceDiagram\n  Alice->>Bob: hello\n  Bob-->>Alice: hi")

let test_sequence_frames_notes_and_a_self_message () =
  Alcotest.check rows "loop, alt/else, note, self message, cross head" seq_full_rows
    (render
       "sequenceDiagram\n  participant A as Alice\n  participant B as Bob\n  A->>B: request\n  loop every 2s\n    B->>B: poll\n    B-->>A: status\n  end\n  alt ok\n    A-x B: done\n  else failed\n    Note over A,B: retry later\n  end")

let test_sequence_text_widens_the_gap_it_crosses () =
  let drawn = render "sequenceDiagram\n  A->>B: a considerably longer message text\n  B->>A: ok" in
  Alcotest.(check bool) "the text is whole" true
    (List.exists (contains "a considerably longer message text") drawn);
  List.iter
    (fun row -> Alcotest.(check bool) row true (Masc_tui_message_layout.display_width row <= 80))
    drawn

let test_sequence_reads_declarations_and_skips_styling () =
  match
    Mermaid.parse
      "sequenceDiagram\n  autonumber\n  participant B as Bob\n  activate B\n  A->>+B: hi\n  deactivate B"
  with
  | Ok (Mermaid.Sequence seq) ->
      Alcotest.(check (list string)) "declared first, then first seen" [ "B"; "A" ]
        (List.map (fun (p : Mermaid.participant) -> p.pid) seq.participants);
      Alcotest.(check (list string)) "the alias is what the box says" [ "Bob"; "A" ]
        (List.map (fun (p : Mermaid.participant) -> p.alias) seq.participants);
      Alcotest.(check int) "one message, nothing else" 1 (List.length seq.events)
  | Ok (Mermaid.Graph _) -> Alcotest.fail "read as a graph"
  | Error (Mermaid.Unsupported what) -> Alcotest.failf "unsupported: %s" what
  | Error (Mermaid.Parse_error { line; what }) -> Alcotest.failf "line %d: %s" line what
  | Error (Mermaid.Too_wide _) -> Alcotest.fail "parse does not measure"

let test_sequence_refuses_a_line_that_is_not_a_message () =
  match failure "sequenceDiagram\n  A->>B: hi\n  this is not a message" with
  | Mermaid.Parse_error { line; _ } -> Alcotest.(check int) "the third line" 3 line
  | Mermaid.Unsupported _ | Mermaid.Too_wide _ -> Alcotest.fail "not a Parse_error"

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
  match failure "classDiagram\n  Animal <|-- Duck" with
  | Mermaid.Unsupported what -> Alcotest.(check string) "the first word" "classDiagram" what
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
  | Mermaid.Too_wide { cells; cols; turning_it_fits = _ } ->
      Alcotest.(check int) "cols asked" 20 cols;
      Alcotest.(check bool) "needs more" true (cells > cols)
  | Mermaid.Unsupported _ | Mermaid.Parse_error _ -> Alcotest.fail "not Too_wide"

(* A chain across a narrow pane is the case a reader meets in chat: it needs
   several times the columns it would need rows, and "needs 150, has 81" alone
   leaves them with nothing to do about it. *)
let test_a_chain_too_wide_says_which_way_would_fit () =
  match failure ~cols:20 "graph LR\nA --> B --> C --> D --> E" with
  | Mermaid.Too_wide { turning_it_fits = Some direction; _ } ->
      Alcotest.(check string) "names the direction the source would carry" "TD"
        (Mermaid.direction_word direction);
      (* The claim has to be true: the same graph, that way, draws. *)
      (match Mermaid.render ~cols:20 "graph TD\nA --> B --> C --> D --> E" with
       | Ok rows -> Alcotest.(check bool) "and it does draw" true (rows <> [])
       | Error _ -> Alcotest.fail "the direction it named does not fit either")
  | Mermaid.Too_wide { turning_it_fits = None; _ } ->
      Alcotest.fail "a chain that fits downward was not offered"
  | Mermaid.Unsupported _ | Mermaid.Parse_error _ -> Alcotest.fail "not Too_wide"

(* Turning is not always the answer, and saying it is would send the reader to
   rewrite a diagram that comes back the same size. A single node too wide for
   the pane is too wide either way. *)
let test_turning_is_not_offered_when_it_does_not_help () =
  match failure ~cols:8 "graph TD\nA[a label far wider than eight cells]" with
  | Mermaid.Too_wide { turning_it_fits = None; _ } -> ()
  | Mermaid.Too_wide { turning_it_fits = Some direction; _ } ->
      Alcotest.failf "offered %s for a graph no direction fits"
        (Mermaid.direction_word direction)
  | Mermaid.Unsupported _ | Mermaid.Parse_error _ -> Alcotest.fail "not Too_wide"

let test_a_self_edge_is_refused () =
  match failure "graph TD\nA --> A" with
  | Mermaid.Unsupported what -> Alcotest.(check bool) "names the node" true (contains "A" what)
  | Mermaid.Parse_error _ | Mermaid.Too_wide _ -> Alcotest.fail "not an Unsupported"

(* {1 Reading} *)

let parsed source =
  match Mermaid.parse source with
  | Ok (Mermaid.Graph graph) -> graph
  | Ok (Mermaid.Sequence _) -> Alcotest.fail "read as a sequence"
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

(* {1 Subgraphs} *)

(* A subgraph is laid out on its own and the drawing is placed in the scope
   above as one box, with the title on its top edge. That title is what
   tells a box holding boxes apart from a node's box. *)
let test_a_subgraph_draws_a_titled_box_around_its_members () =
  Alcotest.check rows "subgraph"
    [ {|┌─ Group ─┐|}
    ; {|│┌───┐    │|}
    ; {|││ A │    │|}
    ; {|│└─┬─┘    │|}
    ; {|│  │      │|}
    ; {|│  v      │|}
    ; {|│┌─┴─┐    │|}
    ; {|││ B │    │|}
    ; {|│└───┘    │|}
    ; {|└─────────┘|}
    ]
    (render "graph TD\nsubgraph One [\"Group\"]\nA --> B\nend")

(* Nesting is the same thing one level down, so it needs no rule of its
   own: the inner box is an item of the outer scope. *)
let test_a_nested_subgraph_is_a_box_inside_a_box () =
  Alcotest.check rows "nested"
    [ {|┌─ Out ──┐|}
    ; {|│┌─ In ─┐│|}
    ; {|││┌───┐ ││|}
    ; {|│││ A │ ││|}
    ; {|││└─┬─┘ ││|}
    ; {|││  │   ││|}
    ; {|││  v   ││|}
    ; {|││┌─┴─┐ ││|}
    ; {|│││ B │ ││|}
    ; {|││└───┘ ││|}
    ; {|│└──────┘│|}
    ; {|└────────┘|}
    ]
    (render "graph TD\nsubgraph Outer [\"Out\"]\nsubgraph Inner [\"In\"]\nA --> B\nend\nend")

(* An edge may name a subgraph, and then it joins the boxes. This is the
   way to draw a link between two groups. *)
let test_an_edge_may_name_a_subgraph () =
  Alcotest.check rows "between groups"
    [ {|┌─ Left ─┐|}
    ; {|│┌───┐   │|}
    ; {|││ A │   │|}
    ; {|│└───┘   │|}
    ; {|└────┬───┘|}
    ; {|     │|}
    ; {|     v|}
    ; {|┌─ Right ─┐|}
    ; {|│┌───┐    │|}
    ; {|││ B │    │|}
    ; {|│└───┘    │|}
    ; {|└─────────┘|}
    ]
    (render "graph TD\nsubgraph L [\"Left\"]\nA\nend\nsubgraph R [\"Right\"]\nB\nend\nL --> R")

(* [direction] inside a subgraph turns that box and nothing else. Mermaid
   ignores one at the top level, where the header already said which way
   the diagram reads, and so do we -- the outer graph here stays TD while
   its one subgraph reads across. *)
let test_direction_inside_a_subgraph_turns_that_box_only () =
  Alcotest.check rows "inner direction"
    [ {|┌─ Side ─────┐|}
    ; {|│┌───┐  ┌───┐│|}
    ; {|││ A ├─>┤ B ││|}
    ; {|│└───┘  └───┘│|}
    ; {|└────────────┘|}
    ]
    (render "graph TD\nsubgraph One [\"Side\"]\ndirection LR\nA --> B\nend")

(* The box is the item, so a line from outside to a member would have to
   cross a border the box owns. Rather than draw that, the refusal names
   both ends: naming the subgraph on one side is what draws the link. *)
let test_an_edge_that_crosses_a_subgraph_boundary_is_refused () =
  match failure "graph TD\nsubgraph One\nA --> B\nend\nB --> C" with
  | Mermaid.Unsupported what ->
      Alcotest.(check bool) "names the construct" true (contains "crosses a subgraph boundary" what);
      Alcotest.(check bool) "names both ends" true (contains "B to C" what)
  | Mermaid.Parse_error _ | Mermaid.Too_wide _ -> Alcotest.fail "not Unsupported"

let test_an_end_with_no_subgraph_is_refused () =
  match failure "graph TD\nA --> B\nend" with
  | Mermaid.Parse_error { line; what } ->
      Alcotest.(check int) "the end's own line" 3 line;
      Alcotest.(check string) "says which way round" "an end with no subgraph" what
  | Mermaid.Unsupported _ | Mermaid.Too_wide _ -> Alcotest.fail "not Parse_error"

let test_a_subgraph_with_no_end_is_refused () =
  match failure "graph TD\nsubgraph One\nA --> B" with
  | Mermaid.Unsupported what ->
      Alcotest.(check string) "names the subgraph left open" "subgraph One with no end" what
  | Mermaid.Parse_error _ | Mermaid.Too_wide _ -> Alcotest.fail "not Unsupported"

(* An empty subgraph is a title and nothing else. It draws rather than
   fails: the source says a group exists, and an empty group is a fact
   about the diagram, not a mistake in it. *)
let test_an_empty_subgraph_is_a_title_and_nothing_else () =
  Alcotest.check rows "empty"
    [ {|┌─ nothing here ─┐|}; {|└────────────────┘|} ]
    (render "graph TD\nsubgraph Empty [\"nothing here\"]\nend")

(* A subgraph is laid out inside a budget two cells smaller than the pane,
   for its own border. The reader has the pane, not the budget, so the
   refusal counts the border in and names the width they can see. *)
let test_a_subgraph_too_wide_counts_its_border_and_names_the_pane () =
  match
    failure ~cols:30
      "graph TD\nsubgraph Wide [\"w\"]\nA[\"a label that is far too wide for this pane\"]\nend"
  with
  | Mermaid.Too_wide { cells; cols; turning_it_fits = _ } ->
      Alcotest.(check int) "the pane the reader has" 30 cols;
      (* The node alone needs 46; the box around it needs two more. *)
      Alcotest.(check int) "the box, not the budget handed down" 48 cells
  | Mermaid.Unsupported _ | Mermaid.Parse_error _ -> Alcotest.fail "not Too_wide"

(* A quoted label runs to its quote, so a bracket inside it is text. The
   keeper diagram that prompted this work labels every node this way. *)
let test_a_quoted_label_may_hold_a_bracket () =
  Alcotest.check rows "bracket in a label"
    [ {|┌──────────────────────┐|}
    ; {|│ fixed [HOLD: see #1] │|}
    ; {|└──────────────────────┘|}
    ]
    (render "graph TD\nA[\"fixed [HOLD: see #1]\"]")

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
    ; ( "sequence"
      , [ Alcotest.test_case "messages run between lifelines" `Quick
            test_sequence_messages_run_between_lifelines
        ; Alcotest.test_case "frames, notes and a self message" `Quick
            test_sequence_frames_notes_and_a_self_message
        ; Alcotest.test_case "text widens the gap it crosses" `Quick
            test_sequence_text_widens_the_gap_it_crosses
        ; Alcotest.test_case "reads declarations and skips styling" `Quick
            test_sequence_reads_declarations_and_skips_styling
        ; Alcotest.test_case "refuses a line that is not a message" `Quick
            test_sequence_refuses_a_line_that_is_not_a_message
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
        ; Alcotest.test_case "too wide says which way would fit" `Quick
            test_a_chain_too_wide_says_which_way_would_fit
        ; Alcotest.test_case "turning is not offered when it does not help" `Quick
            test_turning_is_not_offered_when_it_does_not_help
        ; Alcotest.test_case "a self edge is refused" `Quick test_a_self_edge_is_refused
        ; Alcotest.test_case "an edge that crosses a subgraph boundary is refused" `Quick
            test_an_edge_that_crosses_a_subgraph_boundary_is_refused
        ; Alcotest.test_case "an end with no subgraph is refused" `Quick
            test_an_end_with_no_subgraph_is_refused
        ; Alcotest.test_case "a subgraph with no end is refused" `Quick
            test_a_subgraph_with_no_end_is_refused
        ] )
    ; ( "subgraphs"
      , [ Alcotest.test_case "a subgraph draws a titled box around its members" `Quick
            test_a_subgraph_draws_a_titled_box_around_its_members
        ; Alcotest.test_case "a nested subgraph is a box inside a box" `Quick
            test_a_nested_subgraph_is_a_box_inside_a_box
        ; Alcotest.test_case "an edge may name a subgraph" `Quick test_an_edge_may_name_a_subgraph
        ; Alcotest.test_case "direction inside a subgraph turns that box only" `Quick
            test_direction_inside_a_subgraph_turns_that_box_only
        ; Alcotest.test_case "an empty subgraph is a title and nothing else" `Quick
            test_an_empty_subgraph_is_a_title_and_nothing_else
        ; Alcotest.test_case "a subgraph too wide counts its border and names the pane" `Quick
            test_a_subgraph_too_wide_counts_its_border_and_names_the_pane
        ; Alcotest.test_case "a quoted label may hold a bracket" `Quick
            test_a_quoted_label_may_hold_a_bracket
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
