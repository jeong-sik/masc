type 'identity source =
  | Stable_source of {
      identity : 'identity;
      text : string;
    }
  | Streaming_source of string

module Completed = struct
  type 'identity key = {
    identity : 'identity;
    text : string;
    width : int;
    theme_revision : int;
    palette_generation : int;
  }

  type 'identity rendered = {
    key : 'identity key;
    rows : string list;
  }
end

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
    stable_rows : string list;
    rows : string list;
  }
end

(* One store per kind, each keyed by the identity that owns the result, so a
   lookup is a hash rather than a walk of everything retained. The pane looks
   one of these up for every message it walks, and a scrolled transcript walks
   hundreds: a list made the walk cost the capacity times its own length,
   which is why the bound used to be too small to hold a scrolled pane in the
   first place. *)
type 'identity t = {
  completed : ('identity, 'identity Completed.rendered) Masc_tui_lru.t;
  growing : ('identity, 'identity Streaming.growing) Masc_tui_lru.t;
}

let create ~capacity =
  if capacity <= 0 then invalid_arg "Markdown render cache capacity must be positive";
  { completed = Masc_tui_lru.create ~capacity;
    growing = Masc_tui_lru.create ~capacity;
  }

(* The identity finds the entry; the rest of the key says whether what was
   found is still what this render would produce. Comparing the source text
   costs nothing when it is the same string the last frame rendered, which is
   what it is while the transcript sits still. *)
let same_rest (left : _ Completed.key) (right : _ Completed.key) =
  String.equal left.text right.text
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

let drop count entries =
  let rec loop remaining = function
    | entries when remaining <= 0 -> entries
    | [] -> []
    | _ :: rest -> loop (remaining - 1) rest
  in
  loop count entries

(* One width/source/revision tuple per completed entry. A resize or visual
   revision replaces that entry's old rows instead of accumulating variants. *)
let remember cache (rendered : _ Completed.rendered) =
  Masc_tui_lru.set cache.completed rendered.key.identity rendered

let render cache ~theme_revision ~palette_generation ~width ~renderer ~source =
  match source with
  | Streaming_source text -> renderer ~width text
  | Stable_source { identity; text } ->
      let key : _ Completed.key =
        { identity; text; width; theme_revision; palette_generation }
      in
      (match Masc_tui_lru.find cache.completed identity with
       (* A hit is already the most recent entry, so the bound removes the
          completed messages the viewport has not touched for longest. *)
       | Some (rendered : _ Completed.rendered) when same_rest key rendered.key ->
           rendered.rows
       | Some _ | None ->
           let rows = renderer ~width text in
           remember cache { key; rows };
           rows)

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

let validate_streaming_render ~source_length
    (rendered : Masc_tui_markdown.streaming_render) =
  if
    rendered.mutable_source_start < 0
    || rendered.mutable_source_start > source_length
    || rendered.mutable_row_start < 0
    || rendered.mutable_row_start > List.length rendered.rows
  then invalid_arg "Markdown streaming renderer returned an invalid boundary"

let reset_growing cache ~(key : _ Streaming.key) ~text ~renderer =
  let rendered = renderer ~width:key.width text in
  validate_streaming_render ~source_length:(String.length text) rendered;
  let growing : _ Streaming.growing =
    { key;
      text;
      stable_source_len = rendered.mutable_source_start;
      stable_rows = take rendered.mutable_row_start rendered.rows;
      rows = rendered.rows;
    }
  in
  remember_growing cache growing;
  rendered.rows

let render_growing cache ~theme_revision ~palette_generation ~width ~renderer
    ~identity ~text =
  let key : _ Streaming.key =
    { identity; width; theme_revision; palette_generation }
  in
  match find_growing cache key with
  | Some growing when String.equal growing.text text -> growing.rows
  | Some growing when String.starts_with ~prefix:growing.text text ->
      let pending =
        String.sub text growing.stable_source_len
          (String.length text - growing.stable_source_len)
      in
      let rendered = renderer ~width pending in
      validate_streaming_render ~source_length:(String.length pending) rendered;
      let newly_stable_rows =
        take rendered.mutable_row_start rendered.rows
      in
      let stable_rows = growing.stable_rows @ newly_stable_rows in
      let rows = stable_rows @ drop rendered.mutable_row_start rendered.rows in
      let updated : _ Streaming.growing =
        { key;
          text;
          stable_source_len =
            growing.stable_source_len + rendered.mutable_source_start;
          stable_rows;
          rows;
        }
      in
      remember_growing cache updated;
      rows
  | Some _ | None -> reset_growing cache ~key ~text ~renderer

module For_testing = struct
  let retained_entries cache = Masc_tui_lru.size cache.completed
  let retained_growing_entries cache = Masc_tui_lru.size cache.growing
end
