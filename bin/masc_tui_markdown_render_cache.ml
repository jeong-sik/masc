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

type 'identity rendered = {
  key : 'identity key;
  rows : string list;
}

type 'identity t = {
  capacity : int;
  equal : 'identity -> 'identity -> bool;
  mutable recent : 'identity rendered list;
}

let create ~capacity ~equal =
  if capacity <= 0 then invalid_arg "Markdown render cache capacity must be positive";
  { capacity; equal; recent = [] }

let same_key cache left right =
  cache.equal left.identity right.identity
  && String.equal left.text right.text
  && left.width = right.width
  && left.theme_revision = right.theme_revision
  && left.palette_generation = right.palette_generation

let take_matching cache key entries =
  let rec loop before = function
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

let remember cache rendered =
  (* One width/source/revision tuple per completed entry. A resize or visual
     revision replaces that entry's old rows instead of accumulating variants. *)
  let other_identities =
    List.filter
      (fun entry -> not (cache.equal rendered.key.identity entry.key.identity))
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

module For_testing = struct
  let retained_entries cache = List.length cache.recent
end
