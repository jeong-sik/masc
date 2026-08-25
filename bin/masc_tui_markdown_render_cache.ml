type 'identity source =
  | Stable_source of {
      identity : 'identity;
      text : string;
    }
  | Streaming_source of string

type 'identity key = {
  identity : 'identity;
  text : string;
  width : int;
  theme_revision : int;
  palette_generation : int;
}

type 'identity visual_key = {
  identity : 'identity;
  width : int;
  theme_revision : int;
  palette_generation : int;
}

type 'identity rendered = {
  key : 'identity key;
  rows : string list;
}

type 'identity growing = {
  key : 'identity visual_key;
  text : string;
  stable_source_len : int;
  stable_rows : string list;
  rows : string list;
}

type 'identity t = {
  capacity : int;
  equal : 'identity -> 'identity -> bool;
  mutable recent : 'identity rendered list;
  mutable growing_recent : 'identity growing list;
}

let create ~capacity ~equal =
  if capacity <= 0 then invalid_arg "Markdown render cache capacity must be positive";
  { capacity; equal; recent = []; growing_recent = [] }

(* [key] and [visual_key] share every field name but [text], and [rendered]
   and [growing] both carry a [key]. OCaml resolves a bare field to the last
   record that declares it, so the streaming pair defined below silently
   retypes every function up here. The annotations say which family each one
   belongs to rather than leaving it to definition order. *)
let same_key cache (left : 'identity key) (right : 'identity key) =
  cache.equal left.identity right.identity
  && String.equal left.text right.text
  && left.width = right.width
  && left.theme_revision = right.theme_revision
  && left.palette_generation = right.palette_generation

let take_matching cache key (entries : 'identity rendered list) =
  let rec loop before : 'identity rendered list -> _ = function
    | [] -> None
    | entry :: rest when same_key cache key entry.key ->
        Some (entry, List.rev_append before rest)
    | entry :: rest -> loop (entry :: before) rest
  in
  loop [] entries

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

let remember cache (rendered : 'identity rendered) =
  (* One width/source/revision tuple per completed entry. A resize or visual
     revision replaces that entry's old rows instead of accumulating variants. *)
  let other_identities =
    List.filter
      (fun (entry : 'identity rendered) ->
        not (cache.equal rendered.key.identity entry.key.identity))
      cache.recent
  in
  cache.recent <- take cache.capacity (rendered :: other_identities)

let render cache ~theme_revision ~palette_generation ~width ~renderer ~source =
  match source with
  | Streaming_source text -> renderer ~width text
  | Stable_source { identity; text } ->
      let key =
        { identity; text; width; theme_revision; palette_generation }
      in
      (match take_matching cache key cache.recent with
       | Some (rendered, others) ->
           (* A hit becomes the most recent entry, so the bound removes the
              completed messages the viewport has not touched for longest. *)
           cache.recent <- rendered :: others;
           rendered.rows
       | None ->
           let rows = renderer ~width text in
           remember cache { key; rows };
           rows)

let same_visual_key cache left right =
  cache.equal left.identity right.identity
  && left.width = right.width
  && left.theme_revision = right.theme_revision
  && left.palette_generation = right.palette_generation

let take_matching_growing cache key entries =
  let rec loop before = function
    | [] -> None
    | entry :: rest when same_visual_key cache key entry.key ->
        Some (entry, List.rev_append before rest)
    | entry :: rest -> loop (entry :: before) rest
  in
  loop [] entries

let remember_growing cache growing =
  let other_identities =
    List.filter
      (fun entry -> not (cache.equal growing.key.identity entry.key.identity))
      cache.growing_recent
  in
  cache.growing_recent <-
    take cache.capacity (growing :: other_identities)

let validate_streaming_render ~source_length
    (rendered : Masc_tui_markdown.streaming_render) =
  if
    rendered.mutable_source_start < 0
    || rendered.mutable_source_start > source_length
    || rendered.mutable_row_start < 0
    || rendered.mutable_row_start > List.length rendered.rows
  then invalid_arg "Markdown streaming renderer returned an invalid boundary"

let reset_growing cache ~key ~text ~renderer =
  let rendered = renderer ~width:key.width text in
  validate_streaming_render ~source_length:(String.length text) rendered;
  let growing =
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
  let key = { identity; width; theme_revision; palette_generation } in
  match take_matching_growing cache key cache.growing_recent with
  | Some (growing, others) when String.equal growing.text text ->
      cache.growing_recent <- growing :: others;
      growing.rows
  | Some (growing, others) when String.starts_with ~prefix:growing.text text ->
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
      let updated =
        { key;
          text;
          stable_source_len =
            growing.stable_source_len + rendered.mutable_source_start;
          stable_rows;
          rows;
        }
      in
      cache.growing_recent <- updated :: others;
      rows
  | Some (_, _) | None -> reset_growing cache ~key ~text ~renderer

module For_testing = struct
  let retained_entries cache = List.length cache.recent
  let retained_growing_entries cache = List.length cache.growing_recent
end
