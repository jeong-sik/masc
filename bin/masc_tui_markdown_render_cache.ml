module Completed = struct
  type 'identity key = {
    identity : 'identity;
    text : string;
    width : int;
    theme_revision : int;
    palette_generation : int;
  }

  (* A renderer of rows alone does not say where its blocks start. *)
  type blocks = Not_kept | Kept of (int * int) array

  type 'identity rendered = {
    key : 'identity key;
    rows : string list;
    blocks : blocks;
  }
end

type grown = { closed : string Masc_tui_closed_rows.prefix; tail : string list }

type block_table = {
  closed_blocks : (int * int) Masc_tui_closed_rows.prefix;
  open_blocks : (int * int) array;
}

let block_count table = Masc_tui_closed_rows.length table.closed_blocks + Array.length table.open_blocks

let block table index =
  let closed = Masc_tui_closed_rows.length table.closed_blocks in
  if index < closed then Masc_tui_closed_rows.get table.closed_blocks index
  else table.open_blocks.(index - closed)

let block_table_of_array blocks =
  { closed_blocks = Masc_tui_closed_rows.of_array blocks; open_blocks = [||] }

let block_table_to_array table = Array.init (block_count table) (block table)

module Streaming = struct
  type 'identity key = {
    identity : 'identity;
    width : int;
    theme_revision : int;
    palette_generation : int;
  }

  type 'identity growing = {
    key : 'identity key;
    text : string;
    stable_source_len : int;
    stable_rows : string Masc_tui_closed_rows.t;
    (* The closed rows, in reading order. A frame appends the rows it closes
       and hands on the prefix and its own tail; copying the closed rows into
       one list cost every frame of a streaming reply what the reply had
       accumulated. *)
    stable_row_count : int;
    rows : grown;
    closed_blocks : (int * int) Masc_tui_closed_rows.t;
    (* The blocks before [stable_source_len], appended as they close. *)
    open_blocks : (int * int) array;
    settled : int;
    (* The first [settled] bytes of [text] are the same in every later text
       for this key, as the caller promised. *)
  }
end

type row_extent = { count : int; nonblank_end : int }

type measurement = { height : int; nonblank_lines : int }

type logical_lines = { nonblank : int; last_nonblank : bool }

let append_logical_lines held text start =
  let nonblank = ref held.nonblank and last_nonblank = ref held.last_nonblank in
  for at = start to String.length text - 1 do
    match text.[at] with
    | '\n' -> last_nonblank := false
    | ' ' | '\t' | '\r' | '\012' -> ()
    | _ -> if not !last_nonblank then (incr nonblank; last_nonblank := true)
  done;
  { nonblank = !nonblank; last_nonblank = !last_nonblank }

type 'identity measured = {
  measure_key : 'identity Streaming.key;
  measure_text : string;
  measure_stable_source_len : int;
  measure_stable_rows : row_extent;
  measure_height : int;
  measure_logical_lines : logical_lines;
}

(* One store per kind, each keyed by the identity that owns the result, so a
   lookup is a hash rather than a walk of everything retained. The pane looks
   one of these up for every message it walks, and a scrolled transcript walks
   hundreds: a list made the walk cost the capacity times its own length,
   which is why the bound used to be too small to hold a scrolled pane in the
   first place. *)
type 'identity t = {
  completed : ('identity, 'identity Completed.rendered) Masc_tui_lru.t;
  growing : ('identity, 'identity Streaming.growing) Masc_tui_lru.t;
  measured : ('identity, 'identity measured) Masc_tui_lru.t;
}

let create ~capacity =
  if capacity <= 0 then invalid_arg "Markdown render cache capacity must be positive";
  { completed = Masc_tui_lru.create ~capacity;
    growing = Masc_tui_lru.create ~capacity;
    measured = Masc_tui_lru.create ~capacity;
  }

(* The identity finds the entry; the rest of the key says whether what was
   found is still what this render would produce. Comparing the source text
   costs nothing when it is the same string the last frame rendered, which is
   what it is while the transcript sits still -- the physical check decides
   that case before [String.equal] walks any bytes. *)
let same_rest (left : _ Completed.key) (right : _ Completed.key) =
  (left.text == right.text || String.equal left.text right.text)
  && left.width = right.width
  && left.theme_revision = right.theme_revision
  && left.palette_generation = right.palette_generation

let take count entries =
  let rec loop kept reversed = function
    | _ when kept = count -> List.rev reversed
    | [] -> List.rev reversed
    | entry :: rest -> loop (kept + 1) (entry :: reversed) rest
  in
  loop 0 [] entries

(* One width/source/revision tuple per completed entry. A resize or visual
   revision replaces that entry's old rows instead of accumulating variants. *)
let remember cache (rendered : _ Completed.rendered) =
  Masc_tui_lru.set cache.completed rendered.key.identity rendered

let render cache ~theme_revision ~palette_generation ~width ~renderer ~identity
    ~text =
  let key : _ Completed.key =
    { identity; text; width; theme_revision; palette_generation }
  in
  match Masc_tui_lru.find cache.completed identity with
  (* A hit is already the most recent entry, so the bound removes the
     completed messages the viewport has not touched for longest. *)
  | Some (rendered : _ Completed.rendered) when same_rest key rendered.key ->
      rendered.rows
  | Some _ | None ->
      let rows = renderer ~width text in
      remember cache { key; rows; blocks = Not_kept };
      rows

let completed_blocks cache ~theme_revision ~palette_generation ~width ~identity
    ~text =
  let key : _ Completed.key =
    { identity; text; width; theme_revision; palette_generation }
  in
  match Masc_tui_lru.find cache.completed identity with
  | Some (rendered : _ Completed.rendered) when same_rest key rendered.key ->
      (match rendered.blocks with
       | Completed.Kept blocks -> Some (block_table_of_array blocks)
       | Completed.Not_kept -> None)
  | Some _ | None -> None

let same_visual_rest (left : _ Streaming.key) (right : _ Streaming.key) =
  left.width = right.width
  && left.theme_revision = right.theme_revision
  && left.palette_generation = right.palette_generation

let find_growing cache (key : _ Streaming.key) =
  match Masc_tui_lru.find cache.growing key.identity with
  | Some (growing : _ Streaming.growing) when same_visual_rest key growing.key ->
      Some growing
  | Some _ | None -> None

let remember_growing cache (growing : _ Streaming.growing) =
  Masc_tui_lru.set cache.growing growing.key.identity growing

(* Block starts in source order, each inside the source and the rows. *)
let valid_blocks ~source_length ~row_count blocks =
  let rec from index previous_source previous_row =
    index >= Array.length blocks
    || (let source_start, row_start = blocks.(index) in
        source_start > previous_source && source_start <= source_length
        && row_start >= previous_row && row_start <= row_count
        && from (index + 1) source_start row_start)
  in
  from 0 (-1) 0

let validate_streaming_render ~source_length
    (rendered : Masc_tui_markdown.streaming_render) =
  if
    rendered.mutable_source_start < 0
    || rendered.mutable_source_start > source_length
    || rendered.mutable_row_start < 0
    || rendered.mutable_row_start > List.length rendered.rows
    || not (valid_blocks ~source_length ~row_count:(List.length rendered.rows)
              rendered.blocks)
  then invalid_arg "Markdown streaming renderer returned an invalid boundary"

let render_keeping_blocks cache ~theme_revision ~palette_generation ~width ~renderer
    ~identity ~text =
  let key : _ Completed.key =
    { identity; text; width; theme_revision; palette_generation }
  in
  let kept = match Masc_tui_lru.find cache.completed identity with
    | Some (rendered : _ Completed.rendered) when same_rest key rendered.key ->
        (match rendered.blocks with
         | Completed.Kept _ -> Some rendered.rows
         | Completed.Not_kept -> None)
    | Some _ | None -> None in
  match kept with
  | Some rows -> rows
  | None ->
      let (rendered : Masc_tui_markdown.streaming_render) = renderer ~width text in
      validate_streaming_render ~source_length:(String.length text) rendered;
      remember cache { key; rows = rendered.rows; blocks = Kept rendered.blocks };
      rendered.rows

(* Whether [text] goes on from [kept], whose first [settled] bytes the caller
   promised are the same in [text]: only the bytes after them are compared.
   A streaming 1 MB reply compared its whole text byte by byte on every
   frame. *)
let bytes_compared = Atomic.make 0

let extends ~settled ~kept text =
  let kept_length = String.length kept in
  kept_length <= String.length text
  && (let start = Int.max 0 (Int.min settled kept_length) in
      ignore (Atomic.fetch_and_add bytes_compared (kept_length - start) : int);
      let rec from index =
        index >= kept_length || (Char.equal kept.[index] text.[index] && from (index + 1))
      in
      from start)

(* Appends to [closed] the blocks of a render of the text from
   [source_offset] that start before [before] in it, at the place they have
   in the whole text, and answers the others there. *)
let split_blocks closed ~before ~source_offset ~row_offset blocks =
  let placed (source_start, row_start) = source_offset + source_start, row_offset + row_start in
  let opened = ref [] in
  Array.iter (fun ((source_start, _) as block) ->
    if source_start < before then Masc_tui_closed_rows.append closed (placed block)
    else opened := placed block :: !opened) blocks;
  Array.of_list (List.rev !opened)

(* Appends the first [count] of [rows] to [closed] and answers the rest. *)
let append_closed closed count rows =
  let rec loop remaining = function
    | rows when remaining <= 0 -> rows
    | [] -> []
    | row :: rest -> Masc_tui_closed_rows.append closed row; loop (remaining - 1) rest
  in
  loop count rows

let reset_growing cache ~(key : _ Streaming.key) ~settled ~text ~renderer =
  let rendered = renderer ~width:key.width text in
  validate_streaming_render ~source_length:(String.length text) rendered;
  let stable_rows = Masc_tui_closed_rows.create () in
  let tail = append_closed stable_rows rendered.mutable_row_start rendered.rows in
  let rows = { closed = Masc_tui_closed_rows.prefix stable_rows; tail } in
  let closed_blocks = Masc_tui_closed_rows.create () in
  let open_blocks =
    split_blocks closed_blocks ~before:rendered.mutable_source_start ~source_offset:0 ~row_offset:0
      rendered.blocks
  in
  let growing : _ Streaming.growing =
    { key;
      text;
      stable_source_len = rendered.mutable_source_start;
      stable_rows;
      stable_row_count = rendered.mutable_row_start;
      rows;
      closed_blocks;
      open_blocks;
      settled;
    }
  in
  remember_growing cache growing;
  rows

let render_growing cache ~theme_revision ~palette_generation ~width ~renderer
    ~identity ~settled ~text =
  let key : _ Streaming.key =
    { identity; width; theme_revision; palette_generation }
  in
  match find_growing cache key with
  | Some growing when String.equal growing.text text -> growing.rows
  | Some growing when extends ~settled:growing.settled ~kept:growing.text text ->
      let pending =
        String.sub text growing.stable_source_len
          (String.length text - growing.stable_source_len)
      in
      let rendered = renderer ~width pending in
      validate_streaming_render ~source_length:(String.length pending) rendered;
      let tail = append_closed growing.stable_rows rendered.mutable_row_start rendered.rows in
      let rows = { closed = Masc_tui_closed_rows.prefix growing.stable_rows; tail } in
      (* The blocks before the pending text are closed; the pending render
         numbers its own from zero. Those it closes join them. *)
      let open_blocks =
        split_blocks growing.closed_blocks ~before:rendered.mutable_source_start
          ~source_offset:growing.stable_source_len ~row_offset:growing.stable_row_count
          rendered.blocks
      in
      let updated : _ Streaming.growing =
        { key;
          text;
          stable_source_len =
            growing.stable_source_len + rendered.mutable_source_start;
          stable_rows = growing.stable_rows;
          stable_row_count = growing.stable_row_count + rendered.mutable_row_start;
          rows;
          closed_blocks = growing.closed_blocks;
          open_blocks;
          settled;
        }
      in
      remember_growing cache updated;
      rows
  | Some _ | None -> reset_growing cache ~key ~settled ~text ~renderer

let growing_blocks cache ~theme_revision ~palette_generation ~width ~identity
    ~text =
  let key : _ Streaming.key =
    { identity; width; theme_revision; palette_generation }
  in
  match find_growing cache key with
  | Some growing when String.equal growing.text text ->
      Some { closed_blocks = Masc_tui_closed_rows.prefix growing.closed_blocks;
             open_blocks = growing.open_blocks }
  | Some _ | None -> None

let row_extent rows =
  List.fold_left (fun extent row ->
    let count = extent.count + 1 in
    { count;
      nonblank_end = if String.trim row = "" then extent.nonblank_end else count })
    { count = 0; nonblank_end = 0 } rows

let append_extent left right =
  { count = left.count + right.count;
    nonblank_end = if right.nonblank_end = 0 then left.nonblank_end
      else left.count + right.nonblank_end }

let measure_growing_details cache ~theme_revision ~palette_generation ~width ~renderer
    ~identity ~text =
  let key : _ Streaming.key =
    { identity; width; theme_revision; palette_generation } in
  let previous = match Masc_tui_lru.find cache.measured identity with
    | Some measured when same_visual_rest key measured.measure_key -> Some measured
    | Some _ | None -> None in
  match previous with
  | Some measured when String.equal measured.measure_text text ->
      {height=measured.measure_height; nonblank_lines=measured.measure_logical_lines.nonblank}
  | Some _ | None ->
    let source_start, stable, logical_start, logical = match previous with
      | Some measured when String.starts_with ~prefix:measured.measure_text text ->
        measured.measure_stable_source_len, measured.measure_stable_rows,
        String.length measured.measure_text, measured.measure_logical_lines
      | Some _ | None -> 0, { count = 0; nonblank_end = 0 }, 0,
          {nonblank=0; last_nonblank=false} in
    let measure_logical_lines = append_logical_lines logical text logical_start in
    let pending = String.sub text source_start (String.length text - source_start) in
    let rendered = renderer ~width pending in
    validate_streaming_render ~source_length:(String.length pending) rendered;
    let extent = append_extent stable (row_extent rendered.rows) in
    let measure_height = Int.max 1 extent.nonblank_end in
    let newly_stable = row_extent (take rendered.mutable_row_start rendered.rows) in
    Masc_tui_lru.set cache.measured identity
      { measure_key = key; measure_text = text;
        measure_stable_source_len = source_start + rendered.mutable_source_start;
        measure_stable_rows = append_extent stable newly_stable;
        measure_height; measure_logical_lines };
    {height=measure_height; nonblank_lines=measure_logical_lines.nonblank}

module For_testing = struct
  let retained_entries cache = Masc_tui_lru.size cache.completed
  let retained_growing_entries cache = Masc_tui_lru.size cache.growing
  let bytes_compared () = Atomic.get bytes_compared
end
