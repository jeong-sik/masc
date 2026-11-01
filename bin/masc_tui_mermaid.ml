module Layout = Masc_tui_message_layout

type direction = Masc_tui_mermaid_grammar.direction =
  | Top_down
  | Bottom_up
  | Left_right
  | Right_left

type shape = Masc_tui_mermaid_grammar.shape =
  | Rect
  | Round
  | Diamond
  | Database
  | Subroutine
  | Stadium
  | Circle
  | Bar

(* Where a state diagram's [[*]] was written: at the top of the diagram, or
   inside the composite state of that id. Each has a start and an end of
   its own. *)
type scope = Masc_tui_mermaid_grammar.scope =
  | Top_level
  | Inside of string

(* What names a node. [Named] is an id the source wrote. A state diagram's
   [[*]] names no state: on the left of a transition it is where its scope
   starts, on the right where it ends, and those are nodes of their own. *)
type node_id = Masc_tui_mermaid_grammar.node_id =
  | Named of string
  | Initial of scope
  | Final of scope

type node = Masc_tui_mermaid_grammar.node = {
  id : node_id;
  label : string;
  shape : shape;
}

type line_style = Masc_tui_mermaid_grammar.line_style =
  | Solid
  | Dotted
  | Thick

type edge = Masc_tui_mermaid_grammar.edge = {
  from_id : node_id;
  to_id : node_id;
  directed : bool;
  style : line_style;
  label : string option;
}

(* A [subgraph … end]. Its members are laid out on their own and the result
   is placed in the enclosing scope as one item, so nesting is the same
   thing one level down. [group_direction] is a [direction] statement
   inside the subgraph; Mermaid ignores one at the top level, and so do
   we. *)
type group = Masc_tui_mermaid_grammar.group = {
  group_id : string;
  group_label : string;
  group_direction : direction option;
  group_nodes : node_id list;  (* ids declared directly inside, source order *)
  group_children : group list;
}

type graph = Masc_tui_mermaid_grammar.graph = {
  direction : direction;
  nodes : node list;  (* every node of the diagram, source order *)
  edges : edge list;
  groups : group list;  (* the subgraphs at the top level *)
}

(* ── Sequence diagrams ─────────────────────────────────────────────────── *)

type head = Masc_tui_mermaid_grammar.head =
  | Head_arrow
  | Head_cross

type sequence_event = Masc_tui_mermaid_grammar.sequence_event =
  | Message of {
      m_from : string;
      m_to : string;
      m_text : string;
      m_style : line_style;
      m_head : head;
    }
  | Note of {
      n_over : string list;
      n_text : string;
    }
  | Block_open of {
      b_kind : string;
      b_label : string;
    }
  | Block_else of string
  | Block_close

type participant = Masc_tui_mermaid_grammar.participant = {
  pid : string;
  alias : string;
}

type sequence = Masc_tui_mermaid_grammar.sequence = {
  participants : participant list;
  events : sequence_event list;
}

type diagram = Masc_tui_mermaid_grammar.diagram =
  | Graph of graph
  | Sequence of sequence

type failure = Masc_tui_mermaid_grammar.failure =
  | Unsupported of string
  | Parse_error of {
      line : int;
      what : string;
    }
  | Too_wide of {
      cells : int;
      cols : int;
      turning_it_fits : direction option;
    }

type label_source_range = Masc_tui_mermaid_grammar.label_source_range = {
  start_byte : int;
  end_byte : int;
}

type mapped_label = Masc_tui_mermaid_grammar.mapped_label = {
  label_text : string;
  source_ranges : label_source_range array;
}

type label_identity = Masc_tui_mermaid_grammar.label_identity =
  | Node_label of node_id
  | Edge_label of int
  | Group_label of int
  | Participant_label of string
  | Event_label of int
  | Event_kind of int

type sourced_label = Masc_tui_mermaid_grammar.sourced_label = {
  identity : label_identity;
  text : string;
  ranges : label_source_range array;
}

type missing_label = Masc_tui_mermaid_grammar.missing_label = {
  identity : label_identity;
  text : string;
}

type source_mapping = Masc_tui_mermaid_grammar.source_mapping =
  | Complete of sourced_label list
  | Incomplete of { mapped : sourced_label list; missing : missing_label list }

type parsed_with_sources = Masc_tui_mermaid_grammar.parsed_with_sources = {
  diagram : diagram;
  source_mapping : source_mapping;
}

include
  (Masc_tui_mermaid_grammar :
    module type of Masc_tui_mermaid_grammar
      with type direction := direction
       and type shape := shape
       and type scope := scope
       and type node_id := node_id
       and type node := node
       and type line_style := line_style
       and type edge := edge
       and type group := group
       and type graph := graph
       and type head := head
       and type sequence_event := sequence_event
       and type participant := participant
       and type sequence := sequence
       and type diagram := diagram
       and type failure := failure
       and type label_source_range := label_source_range
       and type mapped_label := mapped_label
       and type label_identity := label_identity
       and type sourced_label := sourced_label
       and type missing_label := missing_label
       and type source_mapping := source_mapping
       and type parsed_with_sources := parsed_with_sources
)


let parse text = parse_internal text

let parse_with_source_labels_internal text =
  let known = Hashtbl.create 16 in
  let undrawn = ref [] in
  let* diagram = parse_internal
      ~on_label:(fun identity source -> Hashtbl.replace known identity source)
      ~on_undrawn:(fun span -> undrawn := span :: !undrawn) text in
  let labels = ref [] in
  let add identity text = if text <> "" then labels := (identity, text) :: !labels in
  (match diagram with
   | Graph graph ->
       List.iter (fun node -> match node.id, node.shape with
         | Named _, (Rect | Round | Diamond | Subroutine | Database | Stadium | Circle) ->
             add (Node_label node.id) node.label
         | Named _, Bar | (Initial _ | Final _), _ -> ()) graph.nodes;
       List.iteri (fun index edge -> Option.iter (add (Edge_label index)) edge.label) graph.edges;
       let group_index = ref 0 in
       let rec collect_group item =
         add (Group_label !group_index) item.group_label;
         incr group_index;
         List.iter collect_group item.group_children in
       List.iter collect_group graph.groups
   | Sequence sequence ->
       List.iter (fun participant -> add (Participant_label participant.pid) participant.alias) sequence.participants;
       List.iteri (fun index -> function
         | Message {m_text; _} -> add (Event_label index) m_text
         | Note {n_text; _} -> add (Event_label index) n_text
         | Block_open {b_kind; b_label} -> add (Event_kind index) b_kind; add (Event_label index) b_label
         | Block_else label -> add (Event_kind index) "else"; add (Event_label index) label
         | Block_close -> ()) sequence.events);
  let mapped, missing = List.fold_left (fun (mapped, missing) (identity, value) ->
    match Option.join (Hashtbl.find_opt known identity) with
    | Some source when String.equal source.label_text value ->
        ({identity; text=value; ranges=source.source_ranges} :: mapped), missing
    | Some _ | None -> mapped, ({identity; text=value} :: missing)) ([], []) (List.rev !labels) in
  let source_mapping = match missing with
    | [] -> Complete (List.rev mapped)
    | _ -> Incomplete {mapped=List.rev mapped; missing=List.rev missing} in
  Ok ({diagram; source_mapping}, List.rev !undrawn)

let parse_with_source_labels text =
  Result.map fst (parse_with_source_labels_internal text)

(* ── Canvas ────────────────────────────────────────────────────────────── *)

let up = 1
let down = 2
let left = 4
let right = 8

type border_style =
  | Border_solid
  | Border_dotted
  | Border_thick
  | Border_double
  | Border_cylinder

let border_of_line_style = function
  | Solid -> Border_solid
  | Dotted -> Border_dotted
  | Thick -> Border_thick

type cell =
  | Empty
  | Line of {
      mask : int;
      style : border_style;
      round : bool;  (* a rounded box corner *)
    }
  | Text of string
  | Skip  (* the second cell of a two-cell glyph *)

type semantic_position = { identity : label_identity; byte : int }

type canvas_issue =
  | Unattached_text
  | Overlapping_text
  | Text_outside_canvas
  | Adjacent_graphemes
  | Control_bytes

type canvas = {
  rows : int;
  cols : int;
  cells : cell array array;
  source_cells : semantic_position option array option array array option;
  boundary_cache : ((string * string), bool) Hashtbl.t;
  mutable issue : canvas_issue option;
}

let make_canvas ~trace ~rows ~cols =
  {rows; cols; cells=Array.make_matrix rows cols Empty;
   source_cells=(if trace then Some (Array.make_matrix rows cols None) else None);
   boundary_cache=Hashtbl.create 16;
   issue=None}

let inside canvas r c = r >= 0 && r < canvas.rows && c >= 0 && c < canvas.cols

let mark_issue canvas issue =
  if Option.is_none canvas.issue then canvas.issue <- Some issue

let canvas_failure = function
  | Unattached_text -> Unsupported "a standalone zero-width character in a label"
  | Overlapping_text -> Unsupported "overlapping text in a diagram"
  | Text_outside_canvas -> Unsupported "text outside the diagram canvas"
  | Adjacent_graphemes -> Unsupported "adjacent diagram text that combines across cells"
  | Control_bytes -> Unsupported "invalid UTF-8 or terminal control characters in a diagram"

let unsafe_canvas_text text =
  if not (String.is_valid_utf_8 text) then true
  else
    let length = String.length text in
    let rec scan at =
      if at >= length then false
      else
        let byte = Char.code text.[at] in
        byte < 0x20 || byte = 0x7f
        || (byte = 0xc2 && at + 1 < length
            && Char.code text.[at + 1] >= 0x80
            && Char.code text.[at + 1] <= 0x9f)
        || scan (at + 1)
    in
    scan 0

(* Bits merge: a line meeting a border turns the border cell into a
   junction. A text cell stays text: the head and the label win over the
   line under them. Two edges of different styles meeting draw solid. *)
let add_bits canvas r c ~style bits ~round =
  if inside canvas r c then
    canvas.cells.(r).(c) <-
      (match canvas.cells.(r).(c) with
       | Empty -> Line { mask = bits; style; round }
       | Line existing ->
           Line
             { mask = existing.mask lor bits
             ; style = (if existing.style = style then style else Border_solid)
             ; round = existing.round || round
             }
       | (Text _ | Skip) as kept -> kept)

let glyph_of_line ~mask ~(style : border_style) ~round =
  let vertical = mask land (up lor down) <> 0 and horizontal = mask land (left lor right) <> 0 in
  if vertical && not horizontal then
    match style with
    | Border_solid -> "\xe2\x94\x82"
    | Border_dotted -> "\xe2\x94\x86"
    | Border_thick -> "\xe2\x94\x83"
    | Border_double | Border_cylinder -> "\xe2\x95\x91"
  else if horizontal && not vertical then
    match style with
    | Border_solid -> "\xe2\x94\x80"
    | Border_dotted -> "\xe2\x94\x84"
    | Border_thick -> "\xe2\x94\x81"
    | Border_double -> "\xe2\x95\x90"
    | Border_cylinder -> "\xe2\x94\x80"
  else
    match style with
    | Border_double ->
        (match mask with
         | 5 -> "\xe2\x95\x9d" (* ╝ up left *)
         | 9 -> "\xe2\x95\x9a" (* ╚ up right *)
         | 6 -> "\xe2\x95\x97" (* ╗ down left *)
         | 10 -> "\xe2\x95\x94" (* ╔ down right *)
         | 7 -> "\xe2\x95\xa3" (* ╣ *)
         | 11 -> "\xe2\x95\xa0" (* ╠ *)
         | 13 -> "\xe2\x95\xa9" (* ╩ *)
         | 14 -> "\xe2\x95\xa6" (* ╦ *)
         | 15 -> "\xe2\x95\xac" (* ╬ *)
         | _ -> " ")
    | Border_cylinder ->
        (match mask with
         | 5 -> "\xe2\x95\x9c" (* ╜ up left *)
         | 9 -> "\xe2\x95\x99" (* ╙ up right *)
         | 6 -> "\xe2\x95\x96" (* ╖ down left *)
         | 10 -> "\xe2\x95\x93" (* ╓ down right *)
         | 7 -> "\xe2\x95\xa2" (* ╢ *)
         | 11 -> "\xe2\x95\x9f" (* ╟ *)
         | 13 -> "\xe2\x94\xb4"
         | 14 -> "\xe2\x94\xac"
         | 15 -> "\xe2\x94\xbc"
         | _ -> " ")
    | Border_solid | Border_dotted | Border_thick ->
        match mask with
        | 5 -> if round then "\xe2\x95\xaf" else "\xe2\x94\x98" (* up left *)
        | 9 -> if round then "\xe2\x95\xb0" else "\xe2\x94\x94" (* up right *)
        | 6 -> if round then "\xe2\x95\xae" else "\xe2\x94\x90" (* down left *)
        | 10 -> if round then "\xe2\x95\xad" else "\xe2\x94\x8c" (* down right *)
        | 7 -> "\xe2\x94\xa4"
        | 11 -> "\xe2\x94\x9c"
        | 13 -> "\xe2\x94\xb4"
        | 14 -> "\xe2\x94\xac"
        | 15 -> "\xe2\x94\xbc"
        | _ -> " "


(* Distinct placements must not combine into one grapheme after the canvas is
   serialized, even if the combined glyph happens to use the same cell count. *)
let joins_across_boundary canvas left right =
  match Hashtbl.find_opt canvas.boundary_cache (left, right) with
  | Some joins -> joins
  | None ->
      let boundary = String.length left in
      let joined = left ^ right in
      let joins = ref false in
      Layout.iter_display_pieces joined
        ~piece:(fun start stop _width _ansi ->
          if start < boundary && boundary < stop then joins := true)
        ~ascii:(fun _ _ -> ());
      Hashtbl.add canvas.boundary_cache (left, right) !joins;
      !joins

type text_placement = Reading_text | Generated_glyph

let put_text ?(placement = Reading_text) ?(boundaries = []) ?source canvas r c text =
  let exception Canvas_unrenderable in
  let reject issue = mark_issue canvas issue; raise Canvas_unrenderable in
  let generated = placement = Generated_glyph in
  let sources offset length = Array.init length (fun i ->
    Option.bind source (fun at -> at (offset + i))) in
  (* Canvas geometry is measured in graphemes. Store the same pieces in one
     text cell, including their original bytes for source mapping. *)
  let col = ref c in
  let rec prior_glyph at =
    if not (inside canvas r at) then None
    else match canvas.cells.(r).(at) with
      | Skip -> prior_glyph (at - 1)
      | Text glyph -> Some glyph
      | Empty -> Some " "
      | Line {mask; style; round} -> Some (glyph_of_line ~mask ~style ~round)
  in
  let put offset stop width =
      let length = stop - offset in
      let glyph = String.sub text offset length in
      if width = 0 then reject Unattached_text
      else (
        (* Several edges can share the same generated arrowhead. Keeping the
           existing cell also keeps any source identity already stored there. *)
        let duplicate_generated = generated && width = 1 && inside canvas r !col &&
          match canvas.cells.(r).(!col) with
          | Text existing -> String.equal existing glyph
          | Empty | Line _ | Skip -> false in
        let overlaps_text = ref false in
        for cell = !col to !col + width - 1 do
          if inside canvas r cell then
            match canvas.cells.(r).(cell) with
            | Text _ | Skip -> overlaps_text := true
            | Empty | Line _ -> ()
        done;
        let joins_left = offset = 0 &&
          Option.fold ~none:false ~some:(fun previous -> joins_across_boundary canvas previous glyph)
            (prior_glyph (!col - 1)) in
        let joins_right = stop = String.length text && inside canvas r (!col + width) &&
          match canvas.cells.(r).(!col + width) with
          | Text next -> joins_across_boundary canvas glyph next
          | Empty -> joins_across_boundary canvas glyph " "
          | Line {mask; style; round} ->
              joins_across_boundary canvas glyph (glyph_of_line ~mask ~style ~round)
          | Skip -> false in
        if not (inside canvas r !col) || width > canvas.cols - !col then
          reject Text_outside_canvas
        else if duplicate_generated then ()
        else if !overlaps_text then reject Overlapping_text
        else if joins_left || joins_right then reject Adjacent_graphemes
        else begin
          if inside canvas r !col then begin
            canvas.cells.(r).(!col) <- Text glyph;
            Option.iter (fun cells -> cells.(r).(!col) <- Some (sources offset length)) canvas.source_cells
          end;
          for extra = 1 to width - 1 do
            if inside canvas r (!col + extra) then begin
              canvas.cells.(r).(!col + extra) <- Skip;
              Option.iter (fun cells -> cells.(r).(!col + extra) <- None) canvas.source_cells
            end
          done
        end;
        col := !col + width)
  in
  if Option.is_some canvas.issue then ()
  else if unsafe_canvas_text text then
    mark_issue canvas Control_bytes
  (* These callers supply exactly one renderer-owned glyph. Reusing its
     measured width avoids re-segmenting every cell of a note border. *)
  else if generated then
    (try put 0 (String.length text) (Layout.display_width text)
     with Canvas_unrenderable -> ())
  else
    try
      Layout.iter_display_pieces text
        ~piece:(fun start stop width _ansi ->
          if List.exists (fun boundary -> start < boundary && boundary < stop) boundaries then
            reject Adjacent_graphemes;
          put start stop width)
        ~ascii:(fun start stop ->
          for offset = start to stop - 1 do put offset (offset + 1) 1 done)
    with Canvas_unrenderable -> ()

let put_parts canvas row col parts =
  let text = String.concat "" (List.map snd parts) in
  let _, boundaries = List.fold_left (fun (offset, boundaries) (_, part) ->
    let stop = offset + String.length part in
    stop, (if stop > 0 && stop < String.length text then stop :: boundaries else boundaries))
      (0, []) parts in
  let source = match canvas.source_cells with
    | None -> None
    | Some _ ->
        let positions = Array.concat (List.map (fun (identity, text) ->
          Array.init (String.length text) (fun byte -> Option.map (fun identity -> {identity; byte}) identity)) parts) in
        Some (fun byte -> positions.(byte)) in
  put_text ~boundaries ?source canvas row col text

let put_label canvas row col identity text =
  put_parts canvas row col [identity, text]

(* A straight run between two cells on one row or one column. Each cell
   gets the bits toward its neighbours on the run, so the ends carry one
   bit and merge into whatever they touch. *)
let draw_line canvas ~style (r1, c1) (r2, c2) =
  if r1 = r2 then (
    let lo = min c1 c2 and hi = max c1 c2 in
    for c = lo to hi do
      add_bits canvas r1 c ~style ~round:false
        ((if c > lo then left else 0) lor if c < hi then right else 0)
    done)
  else if c1 = c2 then (
    let lo = min r1 r2 and hi = max r1 r2 in
    for r = lo to hi do
      add_bits canvas r c1 ~style ~round:false
        ((if r > lo then up else 0) lor if r < hi then down else 0)
    done)
  else invalid_arg "Masc_tui_mermaid.draw_line: not a straight run"


let rows_of_canvas canvas =
  Array.to_list canvas.cells
  |> List.map (fun row ->
         let buffer = Buffer.create (Array.length row) in
         Array.iter
           (fun cell ->
             match cell with
             | Empty -> Buffer.add_char buffer ' '
             | Line { mask; style; round } -> Buffer.add_string buffer (glyph_of_line ~mask ~style ~round)
             | Text glyph -> Buffer.add_string buffer glyph
             | Skip -> ())
           row;
         let text = Buffer.contents buffer in
         (* No trailing spaces: the caller pads rows to its own width. *)
         let rec trim i = if i > 0 && text.[i - 1] = ' ' then trim (i - 1) else i in
         String.sub text 0 (trim (String.length text)))

let sources_of_canvas canvas rows =
  Option.map (fun sources ->
    Array.of_list (List.mapi (fun row text ->
      let pieces = Array.to_list (Array.mapi (fun col -> function
        | Empty -> [|None|]
        | Line {mask; style; round} -> Array.make (String.length (glyph_of_line ~mask ~style ~round)) None
        | Text _ -> (match sources.(row).(col) with
            | Some positions -> positions
            | None -> invalid_arg "Masc_tui_mermaid.sources_of_canvas: untraced text cell")
        | Skip -> [||]) canvas.cells.(row)) in
      let positions = Array.concat pieces in
      Array.sub positions 0 (String.length text)) rows)) canvas.source_cells

module Edge_sources = Hashtbl.Make (struct
  type t = edge
  let equal = ( == )
  let hash = Hashtbl.hash
end)
module Group_sources = Hashtbl.Make (struct
  type t = group
  let equal = ( == )
  let hash = Hashtbl.hash
end)

type graph_trace = {
  edge_identity : edge -> label_identity;
  group_identity : group -> label_identity;
}

(* Partitioning and DAG layering retain the original edge/group records. A
   segment carries its origin before dummy nodes or reversed routing are added.
   Strict lookups reject a future copied record instead of losing its source. *)
let graph_trace graph =
  let edges = Edge_sources.create (List.length graph.edges) in
  List.iteri (fun index edge -> Edge_sources.add edges edge (Edge_label index)) graph.edges;
  let groups = Group_sources.create 8 in
  let index = ref 0 in
  let rec collect group =
    Group_sources.add groups group (Group_label !index);
    incr index;
    List.iter collect group.group_children in
  List.iter collect graph.groups;
  {edge_identity=Edge_sources.find edges; group_identity=Group_sources.find groups}

type canvas_render = {
  canvas_rows : string list;
  canvas_sources : semantic_position option array array option;
}

(* ── Layout ────────────────────────────────────────────────────────────── *)

let box_height = 3
let box_pad = 2 (* one border and one space each side *)
let item_gap = 3 (* cells between two boxes of one layer *)
let ordering_sweeps = 4

(* A fork or a join is a bar across the flow. Mermaid draws it 70 by 10
   pixels with its label cleared (forkJoin.ts): one cell thick here, so
   seven cells long, in whichever axis crosses the flow. *)
let bar_length = 7
let bar_thickness = 1

let shown_label node =
  match node.shape with
  | Diamond -> "\xe2\x9f\xa8" ^ node.label ^ "\xe2\x9f\xa9"
  | Rect | Round | Database | Subroutine | Stadium | Circle -> node.label
  | Bar -> ""

let box_width node = Layout.display_width (shown_label node) + (2 * box_pad)

(* A subgraph already laid out: [c_rows] is its drawing, and the scope that
   holds it treats the whole thing as one box. *)
type cluster = {
  c_group : group;
  c_rows : string list;
  c_sources : semantic_position option array array option;
  c_width : int;
  c_height : int;
}

type item =
  | Real of node
  | Cluster of cluster
  | Dummy

let cluster_pad = 2 (* the border, one cell each side *)
let cluster_title_pad = 6 (* [(-- ] and [ --)] around the title, and both corners *)

let cluster_width c =
  max (c.c_width + cluster_pad) (Layout.display_width c.c_group.group_label + cluster_title_pad)

let cluster_height c = c.c_height + cluster_pad

type placed = {
  item : item;
  layer : int;
  cross_extent : int;
  flow_extent : int;  (* the box's own; a dummy takes its band *)
  mutable cross_start : int;
  mutable flow_start : int;
}

(* One drawn run between two items of adjacent layers. A long edge is a
   chain of these through its dummies; the head and the label sit on the
   segments that touch the real ends. *)
type segment = {
  seg_from : int;
  seg_to : int;
  seg_style : line_style;
  head_at_to : bool;
  head_at_from : bool;
  seg_label : string option;
  seg_identity : label_identity option;
}

let along_flow direction =
  match direction with
  | Top_down | Bottom_up -> `Rows
  | Left_right | Right_left -> `Cols

let item_id = function
  | Real node -> Some node.id
  | Cluster c -> Some (Named c.c_group.group_id)
  | Dummy -> None

let rec map_result f = function
  | [] -> Ok []
  | x :: rest ->
      let* y = f x in
      let* ys = map_result f rest in
      Ok (y :: ys)

(* Every id a subgraph holds, itself included. *)
let rec ids_beneath group =
  Named group.group_id
  :: (group.group_nodes @ List.concat_map ids_beneath group.group_children)

(* Which item of a scope stands for [id]: the item itself when it is
   declared right here, otherwise the subgraph that has it somewhere below. *)
let owner_table ~nodes ~groups =
  let table = Hashtbl.create 16 in
  List.iter (fun node -> Hashtbl.replace table node.id node.id) nodes;
  List.iter
    (fun group ->
      List.iter (fun id -> Hashtbl.replace table id (Named group.group_id)) (ids_beneath group))
    groups;
  table

(* An edge either joins two items of this scope, or lives entirely inside
   one subgraph and belongs to that scope instead. An edge with one end
   inside a subgraph and the other outside has no drawing here: the box is
   the item, and a line to a member would have to cross a border the box
   owns. Naming the subgraph on that side draws the link between boxes. *)
let partition_edges ~nodes ~groups ~edges =
  let owner = owner_table ~nodes ~groups in
  let inside_a_group = Hashtbl.create 8 in
  List.iter (fun group -> Hashtbl.replace inside_a_group (Named group.group_id) []) groups;
  let rec walk here = function
    | [] ->
        (* Both lists were built by consing; source order is what the layout
           breaks ties on, so both go back the way they were written. *)
        Hashtbl.iter (fun id edges -> Hashtbl.replace inside_a_group id (List.rev edges))
          (Hashtbl.copy inside_a_group);
        Ok (List.rev here, inside_a_group)
    | edge :: more -> (
        match Hashtbl.find_opt owner edge.from_id, Hashtbl.find_opt owner edge.to_id with
        | None, _ ->
            Error
              (Unsupported
                 ("an edge from a node no statement declared: " ^ node_id_text edge.from_id))
        | _, None ->
            Error
              (Unsupported ("an edge to a node no statement declared: " ^ node_id_text edge.to_id))
        | Some from_owner, Some to_owner ->
            if node_id_equal edge.from_id from_owner && node_id_equal edge.to_id to_owner then
              walk (edge :: here) more
            else if node_id_equal from_owner to_owner then (
              Hashtbl.replace inside_a_group from_owner
                (edge :: Option.value (Hashtbl.find_opt inside_a_group from_owner) ~default:[]);
              walk here more)
            else
              Error
                (Unsupported
                   (Printf.sprintf "an edge that crosses a subgraph boundary, %s to %s"
                      (node_id_text edge.from_id) (node_id_text edge.to_id))))
  in
  walk [] edges

(* One scope: the nodes and subgraphs declared directly in it, and the edges
   that join them. A subgraph is laid out by this same function one level
   down, and its drawing then stands in the scope above as a single box.
   Returns the rows and the size they take, which is what the scope above
   needs in order to place that box. *)
let rec layout_scope ~trace ~cols ~direction ~node_of ~nodes ~groups ~edges =
  let* here, inner_edges = partition_edges ~nodes ~groups ~edges in
  let* clusters =
    map_result
      (fun group ->
        let* members = map_result node_of group.group_nodes in
        let* rows, source_rows, width, height =
          match
            layout_scope ~trace
              ~cols:(max 1 (cols - cluster_pad))
              ~direction:(Option.value group.group_direction ~default:direction)
              ~node_of ~nodes:members ~groups:group.group_children
              ~edges:
                (Option.value (Hashtbl.find_opt inner_edges (Named group.group_id)) ~default:[])
          with
          (* The box is the border plus what it holds, and the pane that
             cannot take it is this one, not the budget handed down. *)
          | Error (Too_wide { cells; cols = _; turning_it_fits }) ->
              Error (Too_wide { cells = cells + cluster_pad; cols; turning_it_fits })
          | (Ok _ | Error (Unsupported _ | Parse_error _)) as answer -> answer
        in
        Ok (Cluster { c_group = group; c_rows = rows; c_sources=source_rows; c_width = width; c_height = height }))
      groups
  in
  (* Source order within each kind, nodes before subgraphs. The ordering
     sweeps are stable, so ties fall back to this and the same source draws
     the same rows every run. *)
  let entries = Array.of_list (List.map (fun node -> Real node) nodes @ clusters) in
  let node_count = Array.length entries in
  let index_of = Hashtbl.create 16 in
  Array.iteri
    (fun i entry -> Option.iter (fun id -> Hashtbl.replace index_of id i) (item_id entry))
    entries;
  let nodes = entries in
  (* Back edges are turned around for layering: a DFS in source order marks
     an edge whose target is still on the stack. *)
  let successors = Array.make node_count [] in
  List.iteri
    (fun edge_index edge ->
      match Hashtbl.find_opt index_of edge.from_id, Hashtbl.find_opt index_of edge.to_id with
      | Some s, Some t -> successors.(s) <- (t, edge_index) :: successors.(s)
      | None, _ | _, None -> ())
    here;
  Array.iteri (fun i list -> successors.(i) <- List.rev list) successors;
  let reversed = Array.make (List.length here) false in
  let colour = Array.make node_count 0 in
  (* 0 unseen, 1 on the stack, 2 done *)
  let rec visit v =
    colour.(v) <- 1;
    List.iter
      (fun (t, edge_index) ->
        if colour.(t) = 1 then reversed.(edge_index) <- true
        else if colour.(t) = 0 then visit t)
      successors.(v);
    colour.(v) <- 2
  in
  for v = 0 to node_count - 1 do
    if colour.(v) = 0 then visit v
  done;
  let refused =
    List.find_map
      (fun edge ->
        if not (Hashtbl.mem index_of edge.from_id) then
          Some ("an edge from a node no statement declared: " ^ node_id_text edge.from_id)
        else if not (Hashtbl.mem index_of edge.to_id) then
          Some ("an edge to a node no statement declared: " ^ node_id_text edge.to_id)
        else if node_id_equal edge.from_id edge.to_id then
          Some ("an edge from " ^ node_id_text edge.from_id ^ " to itself")
        else None)
      here
  in
  match refused with
  | Some what -> Error (Unsupported what)
  | None ->
      (* DAG edges as (source, target) after reversal. *)
      let dag =
        List.mapi
          (fun edge_index edge ->
            let s = Hashtbl.find index_of edge.from_id and t = Hashtbl.find index_of edge.to_id in
            if reversed.(edge_index) then (t, s) else (s, t))
          here
      in
      (* Longest-path layers over a Kahn order, nodes in source order. *)
      let indegree = Array.make node_count 0 in
      List.iter (fun (_, t) -> indegree.(t) <- indegree.(t) + 1) dag;
      let layer = Array.make node_count 0 in
      let queue = Queue.create () in
      for v = 0 to node_count - 1 do
        if indegree.(v) = 0 then Queue.add v queue
      done;
      let dag_successors = Array.make node_count [] in
      List.iter (fun (s, t) -> dag_successors.(s) <- t :: dag_successors.(s)) dag;
      Array.iteri (fun i list -> dag_successors.(i) <- List.rev list) dag_successors;
      while not (Queue.is_empty queue) do
        let v = Queue.pop queue in
        List.iter
          (fun t ->
            if layer.(t) < layer.(v) + 1 then layer.(t) <- layer.(v) + 1;
            indegree.(t) <- indegree.(t) - 1;
            if indegree.(t) = 0 then Queue.add t queue)
          dag_successors.(v)
      done;
      let flow_axis = along_flow direction in
      let extents item =
        let across_and_along (width, height) =
          match flow_axis with `Rows -> (width, height) | `Cols -> (height, width)
        in
        match item with
        | Real node -> (
            match node.shape with
            (* Across the flow whichever way the flow runs. *)
            | Bar -> (bar_length, bar_thickness)
            | Rect | Round | Diamond | Database | Subroutine | Stadium | Circle ->
                across_and_along (box_width node, box_height))
        | Cluster c -> across_and_along (cluster_width c, cluster_height c)
        | Dummy -> across_and_along (1, 0)
      in
      let items = ref [] in
      let item_count = ref 0 in
      let push_item item ~layer ~cross_extent ~flow_extent =
        items :=
          { item; layer; cross_extent; flow_extent; cross_start = 0; flow_start = 0 } :: !items;
        incr item_count
      in
      Array.iteri
        (fun i entry ->
          let cross_extent, flow_extent = extents entry in
          push_item entry ~layer:layer.(i) ~cross_extent ~flow_extent)
        nodes;
      (* A dummy's index is the count before it is pushed: the real nodes
         took 0 .. n-1 in source order, dummies follow in creation order. *)
      let add_dummy ~layer =
        let index = !item_count in
        push_item Dummy ~layer ~cross_extent:1 ~flow_extent:0;
        index
      in
      (* Segments, with dummies for the layers an edge crosses. *)
      let segments = ref [] in
      List.iteri
        (fun edge_index edge ->
          let s, t = List.nth dag edge_index in
          let head_forward = edge.directed && not reversed.(edge_index) in
          let head_backward = edge.directed && reversed.(edge_index) in
          let span = layer.(t) - layer.(s) in
          let chain =
            (* the item indices from s to t through the dummies *)
            let dummies =
              List.init (max 0 (span - 1)) (fun k -> add_dummy ~layer:(layer.(s) + k + 1))
            in
            (s :: dummies) @ [ t ]
          in
          let rec pairs = function
            | a :: (b :: _ as rest) -> (a, b) :: pairs rest
            | [ _ ] | [] -> []
          in
          let steps = pairs chain in
          let last = List.length steps - 1 in
          List.iteri
            (fun k (a, b) ->
              segments :=
                { seg_from = a
                ; seg_to = b
                ; seg_style = edge.style
                ; head_at_to = head_forward && k = last
                ; head_at_from = head_backward && k = 0
                ; seg_label = (if k = 0 then edge.label else None)
                ; seg_identity = Option.map (fun trace -> trace.edge_identity edge) trace
                }
                :: !segments)
            steps)
        here;
      let segments = List.rev !segments in
      let items = Array.of_list (List.rev !items) in
      let layer_count = 1 + Array.fold_left (fun acc p -> max acc p.layer) 0 items in
      (* Ordering: barycenter sweeps down then up, a fixed number of times,
         stable so ties keep source order. *)
      let layers = Array.make layer_count [] in
      Array.iteri (fun i p -> layers.(p.layer) <- i :: layers.(p.layer)) items;
      Array.iteri (fun l list -> layers.(l) <- List.rev list) layers;
      let preds = Array.make (Array.length items) [] and succs = Array.make (Array.length items) [] in
      List.iter
        (fun seg ->
          preds.(seg.seg_to) <- seg.seg_from :: preds.(seg.seg_to);
          succs.(seg.seg_from) <- seg.seg_to :: succs.(seg.seg_from))
        segments;
      let position = Array.make (Array.length items) 0 in
      let renumber l = List.iteri (fun k i -> position.(i) <- k) layers.(l) in
      for l = 0 to layer_count - 1 do
        renumber l
      done;
      let sweep l neighbours =
        let key i =
          match neighbours.(i) with
          | [] -> float_of_int position.(i)
          | list ->
              List.fold_left (fun acc n -> acc +. float_of_int position.(n)) 0. list
              /. float_of_int (List.length list)
        in
        let keyed = List.map (fun i -> (key i, i)) layers.(l) in
        layers.(l) <- List.stable_sort (fun (a, _) (b, _) -> Float.compare a b) keyed |> List.map snd;
        renumber l
      in
      for _ = 1 to ordering_sweeps do
        for l = 1 to layer_count - 1 do
          sweep l preds
        done;
        for l = layer_count - 2 downto 0 do
          sweep l succs
        done
      done;
      (* Cross coordinates: pack each layer, then centre it on the widest. *)
      let layer_width l =
        let extents = List.map (fun i -> items.(i).cross_extent) layers.(l) in
        List.fold_left ( + ) 0 extents + (item_gap * max 0 (List.length extents - 1))
      in
      let widest = Array.fold_left max 0 (Array.init layer_count layer_width) in
      for l = 0 to layer_count - 1 do
        let cursor = ref ((widest - layer_width l) / 2) in
        List.iter
          (fun i ->
            items.(i).cross_start <- !cursor;
            cursor := !cursor + items.(i).cross_extent + item_gap)
          layers.(l)
      done;
      let centre i = items.(i).cross_start + (items.(i).cross_extent / 2) in
      (* Flow coordinates: a band per layer, a channel between bands sized
         by the jogs it carries and, along the flow axis, the labels. *)
      let band_extent l =
        List.fold_left (fun acc i -> max acc items.(i).flow_extent) 0 layers.(l)
      in
      let jogs = Array.make layer_count 0 and label_cells = Array.make layer_count 0 in
      let bus = Array.make (List.length segments) (-1) in
      List.iteri
        (fun k seg ->
          let l = items.(seg.seg_from).layer in
          if centre seg.seg_from <> centre seg.seg_to then (
            bus.(k) <- jogs.(l);
            jogs.(l) <- jogs.(l) + 1);
          match seg.seg_label with
          | Some label -> label_cells.(l) <- max label_cells.(l) (Layout.display_width label)
          | None -> ())
        segments;
      (* Along rows a label sits beside the drop and takes no flow; along
         columns it lies in the channel after one cell of gap. *)
      let label_region l =
        match flow_axis with
        | `Rows -> 1
        | `Cols -> if label_cells.(l) > 0 then label_cells.(l) + 2 else 1
      in
      let channel_extent l = if l = layer_count - 1 then 0 else label_region l + jogs.(l) + 1 in
      let band_start = Array.make layer_count 0 in
      let total_flow =
        let cursor = ref 0 in
        for l = 0 to layer_count - 1 do
          band_start.(l) <- !cursor;
          cursor := !cursor + band_extent l + channel_extent l
        done;
        !cursor
      in
      Array.iter
        (fun p ->
          let band = band_extent p.layer in
          p.flow_start <-
            (match p.item with
             | Real _ | Cluster _ -> band_start.(p.layer) + ((band - p.flow_extent) / 2)
             | Dummy -> band_start.(p.layer)))
        items;
      let flow_end i =
        match items.(i).item with
        | Real _ | Cluster _ -> items.(i).flow_start + items.(i).flow_extent - 1
        | Dummy -> items.(i).flow_start + band_extent items.(i).layer - 1
      in
      (* Along rows a label reaches past its layer's boxes; the canvas is as
         wide as the widest layer or the farthest label, whichever is more. *)
      let cross_total =
        match flow_axis with
        | `Rows ->
            List.fold_left
              (fun acc seg ->
                match seg.seg_label with
                | Some label -> max acc (centre seg.seg_from + 2 + Layout.display_width label)
                | None -> acc)
              widest segments
        | `Cols -> widest
      in
      let rows, cols_needed =
        match flow_axis with
        | `Rows -> (total_flow, cross_total)
        | `Cols -> (cross_total, total_flow)
      in
      if cols_needed > cols then Error (Too_wide { cells = cols_needed; cols; turning_it_fits = None })
      else
        let canvas = make_canvas ~trace:(Option.is_some trace) ~rows ~cols:cols_needed in
        (* (flow, cross) to (row, col), the flow axis reversed for the two
           directions that read against it. *)
        let rc (f, c) =
          match direction with
          | Top_down -> (f, c)
          | Bottom_up -> (total_flow - 1 - f, c)
          | Left_right -> (c, f)
          | Right_left -> (c, total_flow - 1 - f)
        in
        let head_glyph ~forward =
          match direction, forward with
          | Top_down, true | Bottom_up, false -> "v"
          | Top_down, false | Bottom_up, true -> "^"
          | Left_right, true | Right_left, false -> ">"
          | Left_right, false | Right_left, true -> "<"
        in
        (* Boxes. *)
        Array.iter
          (fun p ->
            match p.item with
            | Dummy -> ()
            | Real node -> (
                let r0, c0 = rc (p.flow_start, p.cross_start) in
                let r1, c1 = rc (p.flow_start + p.flow_extent - 1, p.cross_start + p.cross_extent - 1) in
                let top = min r0 r1 and bottom = max r0 r1 and lft = min c0 c1 and rgt = max c0 c1 in
                let box ~line ~round =
                  add_bits canvas top lft ~style:line ~round (down lor right);
                  add_bits canvas top rgt ~style:line ~round (down lor left);
                  add_bits canvas bottom lft ~style:line ~round (up lor right);
                  add_bits canvas bottom rgt ~style:line ~round (up lor left);
                  for c = lft + 1 to rgt - 1 do
                    add_bits canvas top c ~style:line ~round:false (left lor right);
                    add_bits canvas bottom c ~style:line ~round:false (left lor right)
                  done;
                  for r = top + 1 to bottom - 1 do
                    add_bits canvas r lft ~style:line ~round:false (up lor down);
                    add_bits canvas r rgt ~style:line ~round:false (up lor down)
                  done;
                  let identity = match node.id with Named _ -> Some (Node_label node.id)
                    | Initial _ | Final _ -> None in
                  let prefix, suffix = if node.shape=Diamond then "⟨", "⟩" else "", "" in
                  put_parts canvas (top + 1) (lft + 2) [None,prefix;identity,node.label;None,suffix]
                in
                match node.shape with
                (* One thick run, one cell deep, in the stroke a thick edge
                   uses; the edges meet it as they meet a border. *)
                | Bar -> draw_line canvas ~style:Border_thick (r0, c0) (r1, c1)
                | Round | Stadium | Circle -> box ~line:Border_solid ~round:true
                | Rect | Diamond -> box ~line:Border_solid ~round:false
                | Subroutine -> box ~line:Border_double ~round:false
                | Database -> box ~line:Border_cylinder ~round:false)
            | Cluster c ->
                let r0, c0 = rc (p.flow_start, p.cross_start) in
                let r1, c1 =
                  rc (p.flow_start + p.flow_extent - 1, p.cross_start + p.cross_extent - 1)
                in
                let top = min r0 r1 and bottom = max r0 r1 and lft = min c0 c1 and rgt = max c0 c1 in
                let line = Border_solid in
                add_bits canvas top lft ~style:line ~round:false (down lor right);
                add_bits canvas top rgt ~style:line ~round:false (down lor left);
                add_bits canvas bottom lft ~style:line ~round:false (up lor right);
                add_bits canvas bottom rgt ~style:line ~round:false (up lor left);
                for c = lft + 1 to rgt - 1 do
                  add_bits canvas top c ~style:line ~round:false (left lor right);
                  add_bits canvas bottom c ~style:line ~round:false (left lor right)
                done;
                for r = top + 1 to bottom - 1 do
                  add_bits canvas r lft ~style:line ~round:false (up lor down);
                  add_bits canvas r rgt ~style:line ~round:false (up lor down)
                done;
                (* The title rides the top edge, which is what tells a box
                   holding other boxes apart from a node's box. *)
                let identity = Option.map (fun trace -> trace.group_identity c.c_group) trace in
                put_parts canvas top (lft + 2) [None," ";identity,c.c_group.group_label;None," "];
                (* The drawing was laid out already; it goes in whole. *)
                List.iteri (fun i row ->
                  let source = Option.map (fun rows byte -> rows.(i).(byte)) c.c_sources in
                  put_text ?source canvas (top + 1 + i) (lft + 1) row) c.c_rows)
          items;
        (* Dummies: a straight run through their band. *)
        Array.iteri
          (fun i p ->
            match p.item with
            | Dummy ->
                let c = centre i in
                draw_line canvas ~style:Border_solid (rc (p.flow_start, c)) (rc (flow_end i, c))
            | Real _ | Cluster _ -> ())
          items;
        (* Segments. *)
        List.iteri
          (fun k seg ->
            let l = items.(seg.seg_from).layer in
            let cs = centre seg.seg_from and ct = centre seg.seg_to in
            let fs = flow_end seg.seg_from and ft = items.(seg.seg_to).flow_start in
            let style = border_of_line_style seg.seg_style in
            (if cs = ct then draw_line canvas ~style (rc (fs, cs)) (rc (ft, ct))
             else
               let f_bus = band_start.(l) + band_extent l + label_region l + bus.(k) in
               draw_line canvas ~style (rc (fs, cs)) (rc (f_bus, cs));
               draw_line canvas ~style (rc (f_bus, cs)) (rc (f_bus, ct));
               draw_line canvas ~style (rc (f_bus, ct)) (rc (ft, ct)));
            if seg.head_at_to then (
              let r, c = rc (ft - 1, ct) in
              put_text ~placement:Generated_glyph canvas r c (head_glyph ~forward:true));
            if seg.head_at_from then (
              let r, c = rc (fs + 1, cs) in
              put_text ~placement:Generated_glyph canvas r c (head_glyph ~forward:false));
            match seg.seg_label with
            | None -> ()
            | Some label -> (
                match flow_axis with
                | `Rows ->
                    let r, c = rc (fs + 1, cs + 2) in
                    put_label canvas r c seg.seg_identity label
                | `Cols ->
                    let width = Layout.display_width label in
                    let f_start =
                      match direction with
                      | Left_right | Top_down | Bottom_up -> fs + 2
                      | Right_left -> fs + 1 + width
                    in
                    let r, c = rc (f_start, cs - 1) in
                    put_label canvas r c seg.seg_identity label))
          segments;
        let rendered = rows_of_canvas canvas in
        (match canvas.issue with
         | Some issue -> Error (canvas_failure issue)
         | None -> Ok (rendered, sources_of_canvas canvas rendered, cols_needed, rows))

let render_graph_internal ~trace ~cols graph =
  let trace = if trace then Some (graph_trace graph) else None in
  let node_of_table = Hashtbl.create 16 in
  List.iter (fun node -> Hashtbl.replace node_of_table node.id node) graph.nodes;
  let grouped = Hashtbl.create 16 in
  List.iter
    (fun group -> List.iter (fun id -> Hashtbl.replace grouped id ()) (ids_beneath group))
    graph.groups;
  (* An edge may name a node or a subgraph; anything else names nothing. *)
  let known id = Hashtbl.mem node_of_table id || Hashtbl.mem grouped id in
  let refused =
    List.find_map
      (fun edge ->
        if not (known edge.from_id) then
          Some ("an edge from a node no statement declared: " ^ node_id_text edge.from_id)
        else if not (known edge.to_id) then
          Some ("an edge to a node no statement declared: " ^ node_id_text edge.to_id)
        else None)
      graph.edges
  in
  match refused with
  | Some what -> Error (Unsupported what)
  | None ->
      let free =
        List.filter (fun node -> not (Hashtbl.mem grouped node.id)) graph.nodes
      in
      let node_of id =
        match Hashtbl.find_opt node_of_table id with
        | Some node -> Ok node
        | None ->
            Error (Unsupported ("a subgraph member no statement declared: " ^ node_id_text id))
      in
      let* rows, source_rows, _, _ =
        layout_scope ~trace ~cols ~direction:graph.direction ~node_of ~nodes:free ~groups:graph.groups
          ~edges:graph.edges
      in
      Ok {canvas_rows=rows;canvas_sources=source_rows}

(* ── Sequence layout ───────────────────────────────────────────────────── *)

(* A self message loops out to the right of its lifeline: the arrow row
   reaches three cells out and back, the text sits one cell past that. *)
let self_loop_cells = 4
let message_text_margin = 3 (* text starts two cells past the near lifeline, one before the far *)

let event_rows = function
  | Message { m_from; m_to; _ } -> if String.equal m_from m_to then 3 else 2
  | Note _ -> 3
  | Block_open _ | Block_else _ | Block_close -> 1

let render_sequence_internal ~trace ~cols (seq : sequence) =
  let participants = Array.of_list seq.participants in
  let n = Array.length participants in
  if n = 0 then
    (match seq.events with
     | [] -> Ok {canvas_rows=[]; canvas_sources=(if trace then Some [||] else None)}
     | _ :: _ -> Error (Unsupported "a sequence diagram with events but no participants"))
  else
    let index_of =
      let table = Hashtbl.create 8 in
      Array.iteri (fun i p -> Hashtbl.replace table p.pid i) participants;
      fun pid -> Hashtbl.find table pid
    in
    let widths = Array.map (fun p -> Layout.display_width p.alias + (2 * box_pad)) participants in
    (* Frames nest inward from both edges, one cell per depth. A [box] groups
       participants in a browser and is not drawn here, so it takes no depth. *)
    let frame_depth, frame_min_width =
      let depth = ref 0 and deepest = ref 0 and minimum = ref 0 in
      let frames = ref [] in
      let reserve depth kind label =
        let text = " " ^ kind ^ (if label = "" then "" else " " ^ label) ^ " " in
        (* An overwide title still needs an exact refusal width, but its
           grapheme list must not remain in the frame cache after refusal. *)
        let cells = ref 0 in
        Layout.iter_display_pieces text
          ~piece:(fun _ _ width _ -> cells := !cells + width)
          ~ascii:(fun start stop -> cells := !cells + stop - start);
        minimum := max !minimum ((2 * depth) + 3 + !cells)
      in
      List.iter
        (function
          | Block_open { b_kind; b_label } when not (String.equal b_kind "box") ->
              reserve !depth b_kind b_label;
              frames := Some !depth :: !frames;
              incr depth;
              deepest := max !deepest !depth
          | Block_open _ -> frames := None :: !frames
          | Block_else label ->
              (match !frames with Some d :: _ -> reserve d "else" label
               | None :: _ | [] -> ())
          | Block_close ->
              (match !frames with
               | Some _ :: rest -> frames := rest; decr depth
               | None :: rest -> frames := rest
               | [] -> ())
          | Message _ | Note _ -> ())
        seq.events;
      !deepest, !minimum
    in
    let gaps = Array.make (max 1 n) item_gap in
    let extra_right = ref 0 in
    let positions () =
      let x = Array.make n 0 in
      for i = 1 to n - 1 do
        x.(i) <- x.(i - 1) + widths.(i - 1) + gaps.(i - 1)
      done;
      x
    in
    let centre x i = x.(i) + (widths.(i) / 2) in
    (* Each message and note asks for the room its text needs between the
       lifelines it touches; the gap before the far lifeline grows to give
       it, the canvas grows past the last lifeline for the rest. *)
    List.iter
      (fun event ->
        let x = positions () in
        match event with
        | Message { m_from; m_to; m_text; _ } ->
            let a = index_of m_from and b = index_of m_to in
            let text = Layout.display_width m_text in
            if a = b then (
              let needed = self_loop_cells + text + 1 in
              if a = n - 1 then
                extra_right := max !extra_right (centre x a + needed - (x.(a) + widths.(a)))
              else
                let room = x.(a + 1) - centre x a in
                if room < needed then gaps.(a) <- gaps.(a) + (needed - room))
            else
              let lo = min a b and hi = max a b in
              let span = centre x hi - centre x lo in
              let needed = text + message_text_margin in
              if span < needed then gaps.(hi - 1) <- gaps.(hi - 1) + (needed - span)
        | Note { n_over; n_text } ->
            let indices = List.map index_of n_over in
            let lo = List.fold_left min (n - 1) indices and hi = List.fold_left max 0 indices in
            let needed = Layout.display_width n_text + (2 * box_pad) in
            let span = x.(hi) + widths.(hi) - x.(lo) in
            if span < needed then
              if hi = n - 1 then extra_right := max !extra_right (needed - span)
              else gaps.(hi) <- gaps.(hi) + (needed - span)
        | Block_open _ | Block_else _ | Block_close -> ())
      seq.events;
    let x = positions () in
    let margin = frame_depth in
    let width = max frame_min_width
        (margin + x.(n - 1) + widths.(n - 1) + !extra_right + margin) in
    let header_rows = box_height + 1 in
    let body_rows = List.fold_left (fun acc event -> acc + event_rows event) 0 seq.events in
    let rows = header_rows + body_rows + 1 in
    if width > cols then Error (Too_wide { cells = width; cols; turning_it_fits = None })
    else
      let canvas = make_canvas ~trace ~rows ~cols:width in
      let col i = margin + centre x i in
      (* Participant boxes. *)
      Array.iteri
        (fun i p ->
          let lft = margin + x.(i) and w = widths.(i) in
          let rgt = lft + w - 1 in
          add_bits canvas 0 lft ~style:Border_solid ~round:false (down lor right);
          add_bits canvas 0 rgt ~style:Border_solid ~round:false (down lor left);
          add_bits canvas 2 lft ~style:Border_solid ~round:false (up lor right);
          add_bits canvas 2 rgt ~style:Border_solid ~round:false (up lor left);
          for c = lft + 1 to rgt - 1 do
            add_bits canvas 0 c ~style:Border_solid ~round:false (left lor right);
            add_bits canvas 2 c ~style:Border_solid ~round:false (left lor right)
          done;
          add_bits canvas 1 lft ~style:Border_solid ~round:false (up lor down);
          add_bits canvas 1 rgt ~style:Border_solid ~round:false (up lor down);
          put_label canvas 1 (lft + 2) (Some (Participant_label p.pid)) p.alias)
        participants;
      (* Lifelines, from under each box to the last row. *)
      for i = 0 to n - 1 do
        draw_line canvas ~style:Border_solid (2, col i) (rows - 1, col i)
      done;
      (* Events, top to bottom. Frames remember the row they opened on. *)
      let frames = ref [] in
      let depth = ref 0 in
      let head_glyph head ~rightward =
        match head, rightward with
        | Head_arrow, true -> ">"
        | Head_arrow, false -> "<"
        | Head_cross, _ -> "x"
      in
      let row = ref header_rows in
      List.iteri
        (fun event_index event ->
          let r = !row in
          (match event with
           | Message { m_from; m_to; m_text; m_style; m_head } ->
               let a = index_of m_from and b = index_of m_to in
               let m_bstyle = border_of_line_style m_style in
               if a = b then (
                 let c = col a in
                 put_label canvas r (c + self_loop_cells) (Some (Event_label event_index)) m_text;
                 draw_line canvas ~style:m_bstyle (r + 1, c) (r + 1, c + 3);
                 draw_line canvas ~style:m_bstyle (r + 1, c + 3) (r + 2, c + 3);
                 draw_line canvas ~style:m_bstyle (r + 2, c + 1) (r + 2, c + 3);
                 put_text ~placement:Generated_glyph canvas (r + 2) (c + 1) (head_glyph m_head ~rightward:false))
               else (
                 let cf = col a and ct = col b in
                 put_label canvas r (min cf ct + 2) (Some (Event_label event_index)) m_text;
                 draw_line canvas ~style:m_bstyle (r + 1, cf) (r + 1, ct);
                 if ct > cf then put_text ~placement:Generated_glyph canvas (r + 1) (ct - 1) (head_glyph m_head ~rightward:true)
                 else put_text ~placement:Generated_glyph canvas (r + 1) (ct + 1) (head_glyph m_head ~rightward:false))
           | Note { n_over; n_text } ->
               let indices = List.map index_of n_over in
               let lo = List.fold_left min (n - 1) indices and hi = List.fold_left max 0 indices in
               let lft = margin + x.(lo) in
               let rgt =
                 max (margin + x.(hi) + widths.(hi) - 1)
                   (lft + Layout.display_width n_text + (2 * box_pad) - 1)
               in
               (* A note covers the lifelines it sits over, so its border is
                  text rather than line bits that would merge with them. *)
               let border_row ~label_cells rr l m rgt_glyph =
                 put_text ~placement:Generated_glyph canvas rr lft l;
                 for c = lft + 1 to rgt - 1 do
                   let in_label = match label_cells with
                     | None -> false
                     | Some cells -> c >= lft + 2 && c - (lft + 2) < cells in
                   if not in_label then put_text ~placement:Generated_glyph canvas rr c m
                 done;
                 put_text ~placement:Generated_glyph canvas rr rgt rgt_glyph
               in
               border_row ~label_cells:None r "\xe2\x94\x8c" "\xe2\x94\x80" "\xe2\x94\x90";
               border_row ~label_cells:(Some (Layout.display_width n_text))
                 (r + 1) "\xe2\x94\x82" " " "\xe2\x94\x82";
               border_row ~label_cells:None (r + 2) "\xe2\x94\x94" "\xe2\x94\x80" "\xe2\x94\x98";
               put_label canvas (r + 1) (lft + 2) (Some (Event_label event_index)) n_text
           | Block_open { b_kind; b_label } ->
               if not (String.equal b_kind "box") then (
                 let d = !depth in
                 incr depth;
                 frames := (d, r) :: !frames;
                 let l = d and rt = width - 1 - d in
                 draw_line canvas ~style:Border_solid (r, l) (r, rt);
                 add_bits canvas r l ~style:Border_solid ~round:false down;
                 add_bits canvas r rt ~style:Border_solid ~round:false down;
                 put_parts canvas r (l + 2)
                   ([None, " "; Some (Event_kind event_index), b_kind]
                    @ (if b_label = "" then [] else [None, " "; Some (Event_label event_index), b_label])
                    @ [None, " "]))
               else frames := (-1, r) :: !frames
           | Block_else label -> (
               match !frames with
               | (d, _) :: _ when d >= 0 ->
                   let l = d and rt = width - 1 - d in
                   draw_line canvas ~style:Border_dotted (r, l) (r, rt);
                   put_parts canvas r (l + 2)
                     ([None, " "; Some (Event_kind event_index), "else"]
                      @ (if label = "" then [] else [None, " "; Some (Event_label event_index), label])
                      @ [None, " "])
               | (_, _) :: _ | [] -> ())
           | Block_close -> (
               match !frames with
               | (d, opened) :: outer ->
                   frames := outer;
                   if d >= 0 then (
                     decr depth;
                     let l = d and rt = width - 1 - d in
                     draw_line canvas ~style:Border_solid (opened, l) (r, l);
                     draw_line canvas ~style:Border_solid (opened, rt) (r, rt);
                     draw_line canvas ~style:Border_solid (r, l) (r, rt))
               | [] -> ()));
          row := r + event_rows event)
        seq.events;
      let rows = rows_of_canvas canvas in
      (match canvas.issue with
       | Some issue -> Error (canvas_failure issue)
       | None -> Ok {canvas_rows=rows; canvas_sources=sources_of_canvas canvas rows})

let render_diagram_internal ~trace ~cols diagram =
  match diagram with
  | Graph graph -> (
    (* render_graph reports the width it needed; only here, holding the graph,
       can we also answer whether the other axis would have fit. One extra
       layout, on the refusal path only. *)
    match render_graph_internal ~trace ~cols graph with
    | Error (Too_wide { cells; cols; turning_it_fits = _ }) ->
      let turning_it_fits =
        match turned graph.direction with
        | None -> None
        | Some direction -> (
          match render_graph_internal ~trace:false ~cols { graph with direction } with
          | Ok _ -> Some direction
          | Error (Too_wide _ | Unsupported _ | Parse_error _) -> None)
      in
      Error (Too_wide { cells; cols; turning_it_fits })
    | (Ok _ | Error (Unsupported _ | Parse_error _)) as answer -> answer)
  | Sequence sequence -> render_sequence_internal ~trace ~cols sequence


type source_placement = Before_diagram | After_diagram
type undrawn_source = { source_start : int; source_end : int; placement : source_placement }

(* Source beside a drawing has to be wholly before or after its labels.
   Otherwise search and scroll would give the two sections inconsistent
   identities or reading order, so the full source is the safe fallback. *)
let ordered_undrawn_sources text mapping spans =
  match spans with
  | [] -> Ok []
  | _ ->
      let* spans = List.fold_left (fun result span ->
        let* accumulated = result in
        match span with
        | Source_fragment (start_byte, end_byte) -> Ok ((start_byte, end_byte) :: accumulated)
        | Requires_source -> Error (Unsupported "some diagram content")) (Ok []) spans in
      let* labels = match mapping with
        | Complete labels -> Ok labels
        | Incomplete _ -> Error (Unsupported "some diagram content") in
      let first_label, last_label = List.fold_left (fun (first, last) (label : sourced_label) ->
        Array.fold_left (fun (first, last) (range : label_source_range) ->
          min first range.start_byte, max last range.end_byte) (first, last) label.ranges)
          (max_int, 0) labels in
      if List.exists (fun (start_byte, end_byte) ->
        start_byte < 0 || end_byte < start_byte || end_byte > String.length text) spans
      then Error (Unsupported "some diagram content")
      else
        let horizontal = function ' ' | '\t' -> true | _ -> false in
        let extend (start_byte, end_byte) =
          let rec left at = if at > 0 && horizontal text.[at-1] then left (at-1) else at in
          let rec right at = if at < String.length text && horizontal text.[at] then right (at+1) else at in
          let l = left start_byte and r = right end_byte in
          let source_start = if l = 0 || text.[l-1] = '\n' then l else start_byte in
          let source_end =
            if r = String.length text || text.[r] = '\n'
               || (text.[r] = '\r' && r+1 < String.length text && text.[r+1] = '\n')
            then r else end_byte in
          source_start, source_end in
        let spans = List.map extend spans |> List.sort compare in
        (match spans with
         | [] -> Ok []
         | (source_start, source_end) :: rest ->
             (* Keep every byte between omissions. Deleting a separator or an
                empty line would make the visible text and search disagree. *)
             let source_end = List.fold_left (fun last (_, stop) -> max last stop) source_end rest in
             let placement =
               if first_label <> max_int && source_end <= first_label then Some Before_diagram
               else if source_start >= last_label then Some After_diagram
               else None in
             (match placement with
              | Some placement -> Ok [{source_start; source_end; placement}]
              | None -> Error (Unsupported "some diagram content")))

type rendered_with_status = {
  rows : string list;
  undrawn_sources : undrawn_source list;
}

let render_with_status ~cols text =
  let undrawn = ref [] in
  let* diagram = parse_internal ~on_undrawn:(fun span -> undrawn := span :: !undrawn) text in
  let* rendered = render_diagram_internal ~trace:false ~cols diagram in
  let* undrawn_sources = match !undrawn with
    | [] -> Ok []
    | spans when List.exists (function Requires_source -> true | Source_fragment _ -> false) spans ->
        Error (Unsupported "some diagram content")
    | _ ->
        let* parsed, traced_undrawn = parse_with_source_labels_internal text in
        ordered_undrawn_sources text parsed.source_mapping traced_undrawn in
  Ok {rows=rendered.canvas_rows; undrawn_sources}

let render ~cols text =
  Result.map (fun rendered -> rendered.rows) (render_with_status ~cols text)

type rendered_with_sources = {
  rendered_rows : string list;
  rendered_positions : semantic_position option array array;
  labels : source_mapping;
  undrawn_sources : undrawn_source list;
}

let render_with_source_labels ~cols text =
  let* parsed, undrawn = parse_with_source_labels_internal text in
  let* rendered = render_diagram_internal ~trace:true ~cols parsed.diagram in
  let* undrawn_sources = ordered_undrawn_sources text parsed.source_mapping undrawn in
  match rendered.canvas_sources with
  | None -> invalid_arg "Masc_tui_mermaid.render_with_source_labels: tracing disabled"
  | Some rendered_positions ->
      Ok {rendered_rows=rendered.canvas_rows; rendered_positions; labels=parsed.source_mapping;
          undrawn_sources}
