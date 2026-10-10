(* Mermaid drawn as text. The goldens were produced by the renderer and
   read by eye before they were pinned: the point of pinning them is that a
   change to the layout is a change to what a reader sees, and has to say so
   here. Every glyph is one cell wide, so a row's byte length is not its
   width; the width checks go through the layout module. *)

module Mermaid = Masc_tui_mermaid

let rows = Alcotest.(list string)

let node_id =
  let scope_text = function
    | Mermaid.Top_level -> ""
    | Mermaid.Inside id -> " of " ^ id
  in
  let scope_equal a b =
    match (a, b) with
    | Mermaid.Top_level, Mermaid.Top_level -> true
    | Mermaid.Inside a, Mermaid.Inside b -> String.equal a b
    | (Mermaid.Top_level | Mermaid.Inside _), _ -> false
  in
  Alcotest.testable
    (fun formatter id ->
      Format.pp_print_string formatter
        (match id with
         | Mermaid.Named name -> name
         | Mermaid.Initial scope -> "[*] start" ^ scope_text scope
         | Mermaid.Final scope -> "[*] end" ^ scope_text scope))
    (fun a b ->
      match (a, b) with
      | Mermaid.Named a, Mermaid.Named b -> String.equal a b
      | Mermaid.Initial a, Mermaid.Initial b | Mermaid.Final a, Mermaid.Final b -> scope_equal a b
      | (Mermaid.Named _ | Mermaid.Initial _ | Mermaid.Final _), _ -> false)

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
  Alcotest.(check (list node_id)) "nodes in order of appearance"
    Mermaid.[ Named "A"; Named "B"; Named "C"; Named "D" ]
    (List.map (fun (node : Mermaid.node) -> node.id) graph.nodes);
  Alcotest.(check (list (pair node_id node_id))) "one edge per pair"
    Mermaid.[ (Named "A", Named "C"); (Named "B", Named "C"); (Named "C", Named "D") ]
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
  Alcotest.(check bool) "round, diamond, subroutine" true
    (shapes = [ Mermaid.Round; Mermaid.Diamond; Mermaid.Subroutine ]);
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

let test_node_shapes_database_subroutine_stadium () =
  let g =
    parsed "flowchart TD\nDB[(Postgres)]\nSUB[[Worker]]\nST([Pill])\nCIR((Ring))\nREC[Box]"
  in
  let shapes = List.map (fun (n : Mermaid.node) -> n.shape) g.nodes in
  Alcotest.(check bool) "all shapes recognized" true
    (shapes = [ Mermaid.Database; Mermaid.Subroutine; Mermaid.Stadium; Mermaid.Circle; Mermaid.Rect ])

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

let test_state_diagram_keeper_fsm_parses () =
  let src =
    "stateDiagram-v2\n\
     [*] --> Offline\n\
     Offline --> Running : Fiber_started\n\
     Offline --> Stopped : stop while not started\n\
     Running --> Stopped : stop requested\n\
     Stopped --> [*]\n\
     classDef active fill:#22c55e\n\
     class Offline active"
  in
  match Mermaid.parse src with
  | Ok (Mermaid.Graph g) ->
      Alcotest.(check int) "5 distinct states" 5 (List.length g.nodes);
      Alcotest.(check int) "5 transitions" 5 (List.length g.edges);
      Alcotest.(check (list node_id)) "the start and the end are nodes of their own"
        Mermaid.
          [ Initial Top_level
          ; Named "Offline"
          ; Named "Running"
          ; Named "Stopped"
          ; Final Top_level
          ]
        (List.map (fun (n : Mermaid.node) -> n.id) g.nodes)
  | Ok (Mermaid.Sequence _) -> Alcotest.fail "parsed as sequence instead of graph"
  | Error (Mermaid.Unsupported what) -> Alcotest.failf "unsupported: %s" what
  | Error (Mermaid.Parse_error { line; what }) -> Alcotest.failf "line %d: %s" line what
  | Error (Mermaid.Too_wide _) -> Alcotest.fail "too wide"

let test_state_diagram_skips_classdef_and_notes () =
  let src =
    "stateDiagram-v2\n\
     [*] --> Active\n\
     note right of Active : this is skipped\n\
     note left of Active\n\
     Waiting\n\
     }\n\
     end note\n\
     classDef c1 fill:#fff\n\
     class Active c1\n\
     Active --> [*]"
  in
  match Mermaid.parse src with
  | Ok (Mermaid.Graph g) ->
      Alcotest.(check (list node_id)) "a note's text is not a state"
        Mermaid.[ Initial Top_level; Named "Active"; Final Top_level ]
        (List.map (fun (n : Mermaid.node) -> n.id) g.nodes);
      Alcotest.(check int) "2 edges" 2 (List.length g.edges)
  | _ -> Alcotest.fail "expected Ok Graph"

let count_rows_with needle drawn = List.length (List.filter (contains needle) drawn)

(* Mermaid's first composite example (stateDiagram.md, "Composite states"):
   both composite states are named before their block opens, one of them
   with a description. The block takes the id over, so the box is that
   state and no box of the same name stands beside it. *)
let official_composite_example =
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
        namedSimple: Another simple
    }|}

let test_a_composite_state_may_open_on_a_state_already_named () =
  let graph = parsed official_composite_example in
  let first = Mermaid.Inside "First" and named = Mermaid.Inside "NamedComposite" in
  Alcotest.(check (list (triple string string (list node_id)))) "the two boxes"
    Mermaid.
      [ ("First", "First", [ Initial first; Named "second"; Final first ])
      ; ( "NamedComposite"
        , "Another Composite"
        , [ Initial named; Named "namedSimple"; Final named ] )
      ]
    (List.map
       (fun (g : Mermaid.group) -> (g.group_id, g.group_label, g.group_nodes))
       graph.groups);
  Alcotest.(check (list node_id)) "no node carries a composite state's id"
    Mermaid.
      [ Initial Top_level
      ; Initial first
      ; Named "second"
      ; Final first
      ; Initial named
      ; Named "namedSimple"
      ; Final named
      ]
    (List.map (fun (n : Mermaid.node) -> n.id) graph.nodes);
  let drawn = render official_composite_example in
  Alcotest.(check int) "First is written once, on its box" 1 (count_rows_with "First" drawn);
  Alcotest.(check int) "the description titles the other box" 1
    (count_rows_with "Another Composite" drawn)

(* Each composite state with the one it is drawn in and its own members. *)
let rec placements parent (g : Mermaid.group) =
  (g.group_id, parent, g.group_nodes)
  :: List.concat_map (placements (Some g.group_id)) g.group_children

(* Mermaid gives each id one state and sets its parent every time a
   composite state names it, never back to the top (dataFetcher.ts). So a
   composite state named inside another is drawn in it, whichever block
   comes first in the source. *)
let test_a_state_named_in_a_composite_state_is_drawn_in_it () =
  let expected =
    Mermaid.
      [ ("Outer", None, [ Initial (Inside "Outer") ])
      ; ("Inner", Some "Outer", [ Initial (Inside "Inner"); Named "Deep" ])
      ]
  in
  List.iter
    (fun source ->
      Alcotest.(check (list (triple string (option string) (list node_id)))) source expected
        (List.concat_map (placements None) (parsed source).groups);
      Alcotest.(check int) "Inner is drawn once" 1 (count_rows_with "Inner" (render source)))
    [ "stateDiagram-v2\n\
       state Outer {\n\
       [*] --> Inner\n\
       }\n\
       state Inner {\n\
       [*] --> Deep\n\
       }"
    ; "stateDiagram-v2\n\
       state Inner {\n\
       [*] --> Deep\n\
       }\n\
       state Outer {\n\
       [*] --> Inner\n\
       }"
    ]

let test_a_composite_state_drawn_inside_itself_is_refused () =
  match
    failure
      "stateDiagram-v2\n\
       state A {\n\
       [*] --> B\n\
       }\n\
       state B {\n\
       [*] --> A\n\
       }"
  with
  | Mermaid.Unsupported what ->
      Alcotest.(check string) "names the state" "state A would be drawn inside itself" what
  | Mermaid.Parse_error _ | Mermaid.Too_wide _ -> Alcotest.fail "not Unsupported"

let test_composite_state_has_its_own_start_and_end () =
  let graph =
    parsed
      "stateDiagram-v2\n\
       state Parent {\n\
       [*] --> Child\n\
       Child --> [*]\n\
       }\n\
       [*] --> Parent\n\
       Parent --> [*]"
  in
  let inside = Mermaid.Inside "Parent" in
  Alcotest.(check (list (list node_id))) "the members of Parent"
    Mermaid.[ [ Initial inside; Named "Child"; Final inside ] ]
    (List.map (fun (g : Mermaid.group) -> g.group_nodes) graph.groups);
  Alcotest.(check (list (pair node_id node_id))) "four transitions, two scopes"
    Mermaid.
      [ (Initial inside, Named "Child")
      ; (Named "Child", Final inside)
      ; (Initial Top_level, Named "Parent")
      ; (Named "Parent", Final Top_level)
      ]
    (List.map (fun (e : Mermaid.edge) -> (e.from_id, e.to_id)) graph.edges)

let test_unclosed_composite_state_is_refused () =
  match failure "stateDiagram-v2\nstate OpenBlock {\n[*] --> S1" with
  | Mermaid.Unsupported what ->
      Alcotest.(check bool) "mentions open state" true (contains "state OpenBlock with no }" what)
  | Mermaid.Parse_error _ | Mermaid.Too_wide _ -> Alcotest.fail "not Unsupported"

let test_state_diagram_note_with_no_end_is_refused () =
  match failure "stateDiagram-v2\n[*] --> Idle\nnote right of Idle\nwaits here" with
  | Mermaid.Parse_error { line; _ } -> Alcotest.(check int) "the line the note opened on" 3 line
  | Mermaid.Unsupported _ | Mermaid.Too_wide _ -> Alcotest.fail "not a Parse_error"

(* An arrow inside a quoted description or after the colon is text. The
   colon ends the names, and [state] is read before any arrow is looked
   for. *)
let test_state_diagram_arrow_in_text_is_text () =
  let graph =
    parsed
      "stateDiagram-v2\n\
       state \"retry --> giveup\" as Backoff\n\
       Waiting : retry->giveup\n\
       Backoff --> Waiting : x-->y"
  in
  Alcotest.(check (list (pair node_id string))) "two states, each with its description"
    Mermaid.[ (Named "Backoff", "retry --> giveup"); (Named "Waiting", "retry->giveup") ]
    (List.map (fun (n : Mermaid.node) -> (n.id, n.label)) graph.nodes);
  Alcotest.(check (list (option string))) "the label keeps its arrow" [ Some "x-->y" ]
    (List.map (fun (e : Mermaid.edge) -> e.label) graph.edges)

(* A line whose names are not one state id each is refused on its own line,
   not drawn as a box of whatever it held. [->] is not a state transition in
   Mermaid. *)
let test_state_diagram_line_that_names_no_state_is_refused () =
  List.iter
    (fun line ->
      match failure ("stateDiagram-v2\n" ^ line ^ "\n[*] --> A") with
      | Mermaid.Parse_error { line = number; _ } -> Alcotest.(check int) line 2 number
      | Mermaid.Unsupported _ | Mermaid.Too_wide _ -> Alcotest.failf "%s: not a Parse_error" line)
    [ "}"
    ; "end note"
    ; "--"
    ; "A B"
    ; "A -> B"
    ; "state A B"
    ; "A --> B C : go"
    ; "[*] : a start takes no description"
    ; "Class --> X"
    ; "Style --> X"
    ; "Click --> X"
    ; "classDef"
    ; "title Keeper phases"
    ; "state A <<nope>>"
    ; "A {"
    ]

(* What Mermaid itself does with these lines, read from its stateDb: a line
   that is only [[*]] is a start; naming a state again with no description
   keeps the one it has; a note about a state no other line names declares
   it. Styling, [hide empty description] and [scale] change nothing. The
   state grammar has no [linkStyle], so a line that starts with it is a
   transition from a state of that name. *)
let test_state_diagram_reads_lines_as_mermaid_does () =
  let graph =
    parsed
      "stateDiagram-v2\n\
       [*]\n\
       \"Quoted\" --> B --> C\n\
       linkStyle --> C\n\
       note right of Lonely : about a state no other line names\n\
       C : described\n\
       state C\n\
       C\n\
       hide empty description\n\
       scale 350 width\n\
       class B,C highlighted"
  in
  Alcotest.(check (list (pair node_id string))) "states and their labels"
    Mermaid.
      [ (Initial Top_level, "[*]")
      ; (Named "Quoted", "Quoted")
      ; (Named "B", "B")
      ; (Named "C", "described")
      ; (Named "linkStyle", "linkStyle")
      ; (Named "Lonely", "Lonely")
      ]
    (List.map (fun (n : Mermaid.node) -> (n.id, n.label)) graph.nodes);
  Alcotest.(check (list (pair node_id node_id))) "a chain is one transition per arrow"
    Mermaid.
      [ (Named "Quoted", Named "B"); (Named "B", Named "C"); (Named "linkStyle", Named "C") ]
    (List.map (fun (e : Mermaid.edge) -> (e.from_id, e.to_id)) graph.edges)

let () =
  Alcotest.run "tui mermaid"
    [ ( "goldens"
      , [] )
    ; ( "sequence"
      , [ Alcotest.test_case "reads declarations and skips styling" `Quick
            test_sequence_reads_declarations_and_skips_styling
        ; Alcotest.test_case "refuses a line that is not a message" `Quick
            test_sequence_refuses_a_line_that_is_not_a_message
        ] )
    ; ( "shape"
      , [] )
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
      , [ Alcotest.test_case "a subgraph too wide counts its border and names the pane" `Quick
            test_a_subgraph_too_wide_counts_its_border_and_names_the_pane
        ;] )
    ; ( "reading"
      , [ Alcotest.test_case "statements split on semicolons and skip comments" `Quick
            test_statements_split_on_semicolons_and_skip_comments
        ; Alcotest.test_case "both label spellings read the same" `Quick
            test_both_label_spellings_read_the_same
        ; Alcotest.test_case "strokes, heads and shapes are read" `Quick
            test_strokes_heads_and_shapes_are_read
        ; Alcotest.test_case "styling statements change nothing" `Quick
            test_styling_statements_change_nothing
        ; Alcotest.test_case "node shapes database subroutine stadium recognized" `Quick
            test_node_shapes_database_subroutine_stadium
        ;] )
    ; ( "state"
      , [ Alcotest.test_case "keeper fsm parses" `Quick test_state_diagram_keeper_fsm_parses
        ; Alcotest.test_case "skips classdef and notes" `Quick
            test_state_diagram_skips_classdef_and_notes
        ; Alcotest.test_case "a composite state may open on a state already named" `Quick
            test_a_composite_state_may_open_on_a_state_already_named
        ; Alcotest.test_case "a state named in a composite state is drawn in it" `Quick
            test_a_state_named_in_a_composite_state_is_drawn_in_it
        ; Alcotest.test_case "a composite state drawn inside itself is refused" `Quick
            test_a_composite_state_drawn_inside_itself_is_refused
        ; Alcotest.test_case "composite state has its own start and end" `Quick
            test_composite_state_has_its_own_start_and_end
        ; Alcotest.test_case "unclosed composite state is refused" `Quick
            test_unclosed_composite_state_is_refused
        ; Alcotest.test_case "a note with no end note is refused" `Quick
            test_state_diagram_note_with_no_end_is_refused
        ; Alcotest.test_case "an arrow in text is text" `Quick
            test_state_diagram_arrow_in_text_is_text
        ; Alcotest.test_case "a line that names no state is refused" `Quick
            test_state_diagram_line_that_names_no_state_is_refused
        ; Alcotest.test_case "reads lines as mermaid does" `Quick
            test_state_diagram_reads_lines_as_mermaid_does
        ] )
    ]
