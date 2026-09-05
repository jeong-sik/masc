(** Mermaid diagrams drawn as text.

    A keeper writes ```` ```mermaid ```` fences into chat and posts, and the
    dashboard draws them in a browser. The TUI has no browser and starts no
    process, so this module reads the source and lays it out itself: nodes
    become boxes, edges become box-drawing lines with a one-cell head, and
    the whole comes back as rows the chat and the Code surface place like
    any other fenced block.

    What is drawn is a closed set. [graph] and [flowchart] in the four
    directions, with rectangular, rounded and diamond nodes, solid, dotted
    and thick edges, edge labels in both spellings, chains and [&] groups.
    A diagram of any other kind, or a line this grammar cannot read, comes
    back as a {!failure} naming the kind or the line, and the caller shows
    the source under that name. Nothing is guessed. [subgraph] blocks are
    read and their nodes drawn, but the grouping box itself is not
    (RFC-0429 §3.3); [classDef], [class], [style], [linkStyle] and [click]
    statements are accepted and change nothing on a text canvas.

    Layout is layered: back edges are turned around so the rest is a DAG,
    layers come from the longest path, an edge across several layers gets a
    pass-through cell in each layer between, and each layer is ordered by
    the barycenter of its neighbours in a fixed number of sweeps. Same
    source, same width: same bytes. Every glyph is one cell wide. *)

type direction =
  | Top_down
  | Bottom_up
  | Left_right
  | Right_left

type shape =
  | Rect  (** [id[label]], [id[[label]]], [id>label]] *)
  | Round  (** [id(label)], [id([label])], [id[(label)]], [id((label))] *)
  | Diamond  (** [id{label}], [id{{label}}]; drawn as a box whose label wears ⟨ ⟩ *)

type node = {
  id : string;
  label : string;
  shape : shape;
}

type line_style =
  | Solid
  | Dotted
  | Thick

type edge = {
  from_id : string;
  to_id : string;
  directed : bool;  (** [-->] against [---] *)
  style : line_style;
  label : string option;
}

type graph = {
  direction : direction;
  nodes : node list;  (** in order of first appearance *)
  edges : edge list;  (** in source order, one per source-target pair *)
}

type diagram = Graph of graph

type failure =
  | Unsupported of string
      (** the diagram's first word: [sequenceDiagram], [classDiagram], … *)
  | Parse_error of {
      line : int;  (** 1-based, in the source as given *)
      what : string;
    }
  | Too_wide of {
      cells : int;
      cols : int;
    }
      (** the drawing needs [cells] columns and the caller has [cols] *)

val parse : string -> (diagram, failure) result
(** The source of one fence, without the fence markers. Blank lines and
    [%%] comment lines are skipped; [;] separates statements on one line. *)

val render : cols:int -> string -> (string list, failure) result
(** {!parse}, then lay out and draw. Each row is at most [cols] cells and
    carries no trailing spaces; rows are not padded. *)

val render_graph : cols:int -> graph -> (string list, failure) result
(** The drawing half of {!render}, for a graph already read. *)
