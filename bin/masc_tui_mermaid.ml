module Layout = Masc_tui_message_layout

type direction =
  | Top_down
  | Bottom_up
  | Left_right
  | Right_left

type shape =
  | Rect
  | Round
  | Diamond

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
  directed : bool;
  style : line_style;
  label : string option;
}

type graph = {
  direction : direction;
  nodes : node list;
  edges : edge list;
}

type diagram = Graph of graph

type failure =
  | Unsupported of string
  | Parse_error of {
      line : int;
      what : string;
    }
  | Too_wide of {
      cells : int;
      cols : int;
    }

let ( let* ) = Result.bind

(* ── Source ────────────────────────────────────────────────────────────── *)

let direction_of_word = function
  | "TD" | "TB" -> Some Top_down
  | "BT" -> Some Bottom_up
  | "LR" -> Some Left_right
  | "RL" -> Some Right_left
  | _ -> None

let strip_quotes text =
  let n = String.length text in
  if n >= 2 && text.[0] = '"' && text.[n - 1] = '"' then String.sub text 1 (n - 2)
  else text

(* [<br>], [<br/>] and [<br />] are Mermaid's line break inside a label; a
   box here is one row tall, so a break is a space. *)
let replace_breaks text =
  let out = Buffer.create (String.length text) in
  let n = String.length text in
  let rec walk i =
    if i >= n then ()
    else if i + 3 <= n && String.sub text i 3 = "<br" then (
      match String.index_from_opt text i '>' with
      | Some close ->
          Buffer.add_char out ' ';
          walk (close + 1)
      | None ->
          Buffer.add_substring out text i (n - i))
    else (
      Buffer.add_char out text.[i];
      walk (i + 1))
  in
  walk 0;
  Buffer.contents out

let label_text raw = replace_breaks (strip_quotes (String.trim raw))

(* An id is ASCII letters, digits and underscore, or any byte of a
   multi-byte UTF-8 scalar: a Korean id is an id. The dash is not, so an
   arrow never reads as part of the name before it. *)
let is_id_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '\128' .. '\255' -> true
  | _ -> false

let is_arrow_char = function
  | '-' | '.' | '=' | '>' -> true
  | _ -> false

(* The shape openers, longest first so [[[] is read before [[]. *)
let openers =
  [ ("[[", "]]", Rect)
  ; ("[(", ")]", Round)
  ; ("([", "])", Round)
  ; ("((", "))", Round)
  ; ("{{", "}}", Diamond)
  ; ("[", "]", Rect)
  ; ("(", ")", Round)
  ; ("{", "}", Diamond)
  ; (">", "]", Rect)
  ]

type cursor = {
  text : string;
  mutable pos : int;
}

let at_end c = c.pos >= String.length c.text

let peek c = if at_end c then None else Some c.text.[c.pos]

let skip_spaces c =
  while
    match peek c with
    | Some (' ' | '\t') -> true
    | Some _ | None -> false
  do
    c.pos <- c.pos + 1
  done

let starts c prefix =
  let n = String.length prefix in
  c.pos + n <= String.length c.text && String.sub c.text c.pos n = prefix

let read_while c keep =
  let start = c.pos in
  while
    match peek c with
    | Some ch -> keep ch
    | None -> false
  do
    c.pos <- c.pos + 1
  done;
  String.sub c.text start (c.pos - start)

let find_from text from needle =
  let n = String.length text and m = String.length needle in
  let rec go i =
    if i + m > n then None else if String.sub text i m = needle then Some i else go (i + 1)
  in
  go from

(* The statements that style a diagram in a browser and change nothing on a
   text canvas, and the two that fence a subgraph. Read and skipped. *)
type statement_kind =
  | Skipped
  | Statement

let statement_kind line =
  let word =
    match String.index_opt line ' ' with
    | Some i -> String.sub line 0 i
    | None -> line
  in
  match word with
  | "subgraph" | "end" | "classDef" | "class" | "style" | "linkStyle" | "click"
  | "direction" ->
      Skipped
  | _ -> Statement

type declared = {
  mutable order : string list;  (* ids, newest first *)
  table : (string, node) Hashtbl.t;
}

let declare declared id ~label ~shape ~explicit =
  match Hashtbl.find_opt declared.table id with
  | Some _ when not explicit -> ()
  | Some _ | None ->
      if not (Hashtbl.mem declared.table id) then declared.order <- id :: declared.order;
      Hashtbl.replace declared.table id { id; label; shape }

let parse_node c declared =
  skip_spaces c;
  let id = read_while c is_id_char in
  if id = "" then Error "expected a node id"
  else
    let rec try_openers = function
      | [] ->
          declare declared id ~label:id ~shape:Rect ~explicit:false;
          Ok id
      | (opener, closer, shape) :: rest ->
          if starts c opener then (
            let start = c.pos + String.length opener in
            match find_from c.text start closer with
            | None -> Error (Printf.sprintf "%s after %s is never closed" opener id)
            | Some stop ->
                let raw = String.sub c.text start (stop - start) in
                declare declared id ~label:(label_text raw) ~shape ~explicit:true;
                c.pos <- stop + String.length closer;
                Ok id)
          else try_openers rest
    in
    try_openers openers

type arrow = {
  arrow_style : line_style;
  arrow_directed : bool;
  arrow_label : string option;
}

let style_of_run run =
  if String.contains run '.' then Dotted else if run.[0] = '=' then Thick else Solid

(* [-->], [---], [-.->], [==>], [-->|text|], and [-- text -->]: a two-cell
   run without a head opens a text label that the next run closes. *)
let parse_arrow c =
  skip_spaces c;
  let run = read_while c is_arrow_char in
  let length = String.length run in
  if length < 2 then Error (if run = "" then "expected an arrow" else "not an arrow: " ^ run)
  else
    let head = run.[length - 1] = '>' in
    let body = String.sub run 0 (length - 1) in
    if String.contains body '>' then Error ("not an arrow: " ^ run)
    else
      let arrow_style = style_of_run run in
      skip_spaces c;
      if starts c "|" then (
        let start = c.pos + 1 in
        match String.index_from_opt c.text start '|' with
        | None -> Error "|label| is never closed"
        | Some stop ->
            let raw = String.sub c.text start (stop - start) in
            c.pos <- stop + 1;
            Ok { arrow_style; arrow_directed = head; arrow_label = Some (label_text raw) })
      else if (not head) && length = 2 then (
        (* "-- text -->": the label runs to the next arrow run. *)
        let start = c.pos in
        let rec find i =
          if i >= String.length c.text then None
          else if is_arrow_char c.text.[i] then Some i
          else find (i + 1)
        in
        match find start with
        | None -> Error ("text after " ^ run ^ " is never closed by an arrow")
        | Some stop ->
            let raw = String.sub c.text start (stop - start) in
            c.pos <- stop;
            let closing = read_while c is_arrow_char in
            let closing_length = String.length closing in
            if closing_length < 2 then Error ("not an arrow: " ^ closing)
            else
              Ok
                { arrow_style
                ; arrow_directed = closing.[closing_length - 1] = '>'
                ; arrow_label = Some (label_text raw)
                })
      else Ok { arrow_style; arrow_directed = head; arrow_label = None }

let rec parse_group c declared =
  let* first = parse_node c declared in
  skip_spaces c;
  if starts c "&" then (
    c.pos <- c.pos + 1;
    let* rest = parse_group c declared in
    Ok (first :: rest))
  else Ok [ first ]

let parse_statement text declared edges =
  let c = { text; pos = 0 } in
  let* sources = parse_group c declared in
  let rec chain sources =
    skip_spaces c;
    if at_end c then Ok ()
    else
      let* arrow = parse_arrow c in
      let* targets = parse_group c declared in
      List.iter
        (fun from_id ->
          List.iter
            (fun to_id ->
              edges :=
                { from_id
                ; to_id
                ; directed = arrow.arrow_directed
                ; style = arrow.arrow_style
                ; label = arrow.arrow_label
                }
                :: !edges)
            targets)
        sources;
      chain targets
  in
  chain sources

let source_statements text =
  (* (line number, statement) with comments, blanks and [;] handled. *)
  String.split_on_char '\n' text
  |> List.mapi (fun index line -> (index + 1, line))
  |> List.concat_map (fun (number, line) ->
         let line =
           match String.index_opt line '\r' with
           | Some i -> String.sub line 0 i
           | None -> line
         in
         let trimmed = String.trim line in
         if trimmed = "" || (String.length trimmed >= 2 && String.sub trimmed 0 2 = "%%") then []
         else
           String.split_on_char ';' trimmed
           |> List.map String.trim
           |> List.filter (fun s -> s <> "")
           |> List.map (fun s -> (number, s)))

let parse text =
  match source_statements text with
  | [] -> Error (Parse_error { line = 1; what = "empty diagram" })
  | (header_line, header) :: rest -> (
      let words = String.split_on_char ' ' header |> List.filter (fun w -> w <> "") in
      match words with
      | ("graph" | "flowchart") :: tail ->
          let* direction =
            match tail with
            | [] -> Ok Top_down
            | [ word ] -> (
                match direction_of_word word with
                | Some direction -> Ok direction
                | None ->
                    Error
                      (Parse_error
                         { line = header_line; what = "unknown direction " ^ word }))
            | _ ->
                Error (Parse_error { line = header_line; what = "unreadable header " ^ header })
          in
          let declared = { order = []; table = Hashtbl.create 16 } in
          let edges = ref [] in
          let rec statements = function
            | [] -> Ok ()
            | (number, statement) :: more -> (
                match statement_kind statement with
                | Skipped -> statements more
                | Statement -> (
                    match parse_statement statement declared edges with
                    | Ok () -> statements more
                    | Error what -> Error (Parse_error { line = number; what })))
          in
          let* () = statements rest in
          let nodes =
            List.rev declared.order |> List.map (fun id -> Hashtbl.find declared.table id)
          in
          Ok (Graph { direction; nodes; edges = List.rev !edges })
      | word :: _ -> Error (Unsupported word)
      | [] -> Error (Parse_error { line = header_line; what = "empty header" }))

(* ── Canvas ────────────────────────────────────────────────────────────── *)

let up = 1
let down = 2
let left = 4
let right = 8

type cell =
  | Empty
  | Line of {
      mask : int;
      style : line_style;
      round : bool;  (* a rounded box corner *)
    }
  | Text of string
  | Skip  (* the second cell of a two-cell glyph *)

type canvas = {
  rows : int;
  cols : int;
  cells : cell array array;
}

let make_canvas ~rows ~cols = { rows; cols; cells = Array.make_matrix rows cols Empty }

let inside canvas r c = r >= 0 && r < canvas.rows && c >= 0 && c < canvas.cols

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
             ; style = (if existing.style = style then style else Solid)
             ; round = existing.round || round
             }
       | (Text _ | Skip) as kept -> kept)

let put_text canvas r c text =
  let n = String.length text in
  let rec walk offset col =
    if offset < n then (
      let decoded = String.get_utf_8_uchar text offset in
      let length = Uchar.utf_decode_length decoded in
      let glyph = String.sub text offset length in
      let width = Layout.display_width glyph in
      if width = 0 then (
        (* A combining mark joins the cell before it. *)
        (if inside canvas r (col - 1) then
           match canvas.cells.(r).(col - 1) with
           | Text previous -> canvas.cells.(r).(col - 1) <- Text (previous ^ glyph)
           | Empty | Line _ | Skip -> ());
        walk (offset + length) col)
      else (
        if inside canvas r col then canvas.cells.(r).(col) <- Text glyph;
        for extra = 1 to width - 1 do
          if inside canvas r (col + extra) then canvas.cells.(r).(col + extra) <- Skip
        done;
        walk (offset + length) (col + width)))
  in
  walk 0 c

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

let glyph_of_line ~mask ~style ~round =
  let vertical = mask land (up lor down) <> 0 and horizontal = mask land (left lor right) <> 0 in
  if vertical && not horizontal then
    match style with
    | Solid -> "\xe2\x94\x82"
    | Dotted -> "\xe2\x94\x86"
    | Thick -> "\xe2\x94\x83"
  else if horizontal && not vertical then
    match style with
    | Solid -> "\xe2\x94\x80"
    | Dotted -> "\xe2\x94\x84"
    | Thick -> "\xe2\x94\x81"
  else
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

(* ── Layout ────────────────────────────────────────────────────────────── *)

let box_height = 3
let box_pad = 2 (* one border and one space each side *)
let item_gap = 3 (* cells between two boxes of one layer *)
let ordering_sweeps = 4

let shown_label node =
  match node.shape with
  | Diamond -> "\xe2\x9f\xa8" ^ node.label ^ "\xe2\x9f\xa9"
  | Rect | Round -> node.label

let box_width node = Layout.display_width (shown_label node) + (2 * box_pad)

type item =
  | Real of node
  | Dummy

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
}

let along_flow direction =
  match direction with
  | Top_down | Bottom_up -> `Rows
  | Left_right | Right_left -> `Cols

let render_graph ~cols graph =
  let node_count = List.length graph.nodes in
  let index_of = Hashtbl.create 16 in
  List.iteri (fun i node -> Hashtbl.replace index_of node.id i) graph.nodes;
  let nodes = Array.of_list graph.nodes in
  (* Back edges are turned around for layering: a DFS in source order marks
     an edge whose target is still on the stack. *)
  let successors = Array.make node_count [] in
  List.iteri
    (fun edge_index edge ->
      match Hashtbl.find_opt index_of edge.from_id, Hashtbl.find_opt index_of edge.to_id with
      | Some s, Some t -> successors.(s) <- (t, edge_index) :: successors.(s)
      | None, _ | _, None -> ())
    graph.edges;
  Array.iteri (fun i list -> successors.(i) <- List.rev list) successors;
  let reversed = Array.make (List.length graph.edges) false in
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
          Some ("an edge from a node no statement declared: " ^ edge.from_id)
        else if not (Hashtbl.mem index_of edge.to_id) then
          Some ("an edge to a node no statement declared: " ^ edge.to_id)
        else if String.equal edge.from_id edge.to_id then
          Some ("an edge from " ^ edge.from_id ^ " to itself")
        else None)
      graph.edges
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
          graph.edges
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
      let flow_axis = along_flow graph.direction in
      let extents node =
        match flow_axis with
        | `Rows -> (box_width node, box_height)
        | `Cols -> (box_height, box_width node)
      in
      let items = ref [] in
      let item_count = ref 0 in
      let add_item item ~layer ~cross_extent ~flow_extent =
        let index = !item_count in
        items :=
          { item; layer; cross_extent; flow_extent; cross_start = 0; flow_start = 0 } :: !items;
        incr item_count;
        index
      in
      Array.iteri
        (fun i node ->
          let cross_extent, flow_extent = extents node in
          ignore (add_item (Real node) ~layer:layer.(i) ~cross_extent ~flow_extent : int))
        nodes;
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
              List.init (max 0 (span - 1)) (fun k ->
                  add_item Dummy ~layer:(layer.(s) + k + 1) ~cross_extent:1 ~flow_extent:0)
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
                }
                :: !segments)
            steps)
        graph.edges;
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
        let offset = (widest - layer_width l) / 2 in
        ignore
          (List.fold_left
             (fun cursor i ->
               items.(i).cross_start <- cursor;
               cursor + items.(i).cross_extent + item_gap)
             offset layers.(l)
            : int)
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
             | Real _ -> band_start.(p.layer) + ((band - p.flow_extent) / 2)
             | Dummy -> band_start.(p.layer)))
        items;
      let flow_end i =
        match items.(i).item with
        | Real _ -> items.(i).flow_start + items.(i).flow_extent - 1
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
      if cols_needed > cols then Error (Too_wide { cells = cols_needed; cols })
      else
        let canvas = make_canvas ~rows ~cols:cols_needed in
        (* (flow, cross) to (row, col), the flow axis reversed for the two
           directions that read against it. *)
        let rc (f, c) =
          match graph.direction with
          | Top_down -> (f, c)
          | Bottom_up -> (total_flow - 1 - f, c)
          | Left_right -> (c, f)
          | Right_left -> (c, total_flow - 1 - f)
        in
        let head_glyph ~forward =
          match graph.direction, forward with
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
            | Real node ->
                let r0, c0 = rc (p.flow_start, p.cross_start) in
                let r1, c1 = rc (p.flow_start + p.flow_extent - 1, p.cross_start + p.cross_extent - 1) in
                let top = min r0 r1 and bottom = max r0 r1 and lft = min c0 c1 and rgt = max c0 c1 in
                let round = node.shape = Round in
                let line = Solid in
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
                put_text canvas (top + 1) (lft + 2) (shown_label node))
          items;
        (* Dummies: a straight run through their band. *)
        Array.iteri
          (fun i p ->
            match p.item with
            | Dummy ->
                let c = centre i in
                draw_line canvas ~style:Solid (rc (p.flow_start, c)) (rc (flow_end i, c))
            | Real _ -> ())
          items;
        (* Segments. *)
        List.iteri
          (fun k seg ->
            let l = items.(seg.seg_from).layer in
            let cs = centre seg.seg_from and ct = centre seg.seg_to in
            let fs = flow_end seg.seg_from and ft = items.(seg.seg_to).flow_start in
            let style = seg.seg_style in
            (if cs = ct then draw_line canvas ~style (rc (fs, cs)) (rc (ft, ct))
             else
               let f_bus = band_start.(l) + band_extent l + label_region l + bus.(k) in
               draw_line canvas ~style (rc (fs, cs)) (rc (f_bus, cs));
               draw_line canvas ~style (rc (f_bus, cs)) (rc (f_bus, ct));
               draw_line canvas ~style (rc (f_bus, ct)) (rc (ft, ct)));
            if seg.head_at_to then (
              let r, c = rc (ft - 1, ct) in
              put_text canvas r c (head_glyph ~forward:true));
            if seg.head_at_from then (
              let r, c = rc (fs + 1, cs) in
              put_text canvas r c (head_glyph ~forward:false));
            match seg.seg_label with
            | None -> ()
            | Some label -> (
                match flow_axis with
                | `Rows ->
                    let r, c = rc (fs + 1, cs + 2) in
                    put_text canvas r c label
                | `Cols ->
                    let width = Layout.display_width label in
                    let f_start =
                      match graph.direction with
                      | Left_right | Top_down | Bottom_up -> fs + 2
                      | Right_left -> fs + 1 + width
                    in
                    let r, c = rc (f_start, cs - 1) in
                    put_text canvas r c label))
          segments;
        Ok (rows_of_canvas canvas)

let render ~cols text =
  let* diagram = parse text in
  match diagram with
  | Graph graph -> render_graph ~cols graph
