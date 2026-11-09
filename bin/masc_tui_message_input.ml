type revision = unit ref
type owner = unit ref
type source_range = { offset : int; length : int }
type owned_extent = { owner : owner; range : source_range }
type owned_view = { source : string; range : source_range; revision : revision }

(* Printable ASCII, LF and tab each form a one-byte input boundary. Other
   input, including escapes and CR, stays on the shared grapheme path. *)
type boundaries = One_byte | Graphemes | Unknown
type boundary_index = { offsets : int array; count : int; prefix_stable : bool }

let fresh_index text = lazy (
  let offsets = Masc_tui_message_layout.input_boundary_index text in
  { offsets; count = Array.length offsets;
    (* Invalid UTF-8 changes the display segmenter's whole-range fallback;
       deleting an ANSI suffix can also change an earlier escape's extent. *)
    prefix_stable = String.is_valid_utf_8 text && not (String.contains text '\x1b') })

type content = {
  text : string;
  revision : revision;
  boundaries : boundaries;
  index : boundary_index Lazy.t;
  owned : owned_extent option;
}
type snapshot = content

type t = { mutable content : content; mutable cursor : int }

let classify text =
  let rec loop offset =
    if offset = String.length text then One_byte
    else
      match text.[offset] with
      | ' '..'~' | '\n' | '\t' -> loop (offset + 1)
      | _ -> Graphemes
  in
  loop 0

let revision t = t.content.revision
let has_revision t revision = t.content.revision == revision
let invalidate_revision t =
  let content = t.content in
  t.content <- {content with revision = ref ()}

let create () =
  {content = {text = ""; revision = ref (); boundaries = One_byte; index = fresh_index ""; owned = None}; cursor = 0}
let contents t = t.content.text
let length t = String.length t.content.text
let cursor t = t.cursor
let before content cursor = String.sub content.text 0 cursor
let after content cursor =
  String.sub content.text cursor (String.length content.text - cursor)
let before_cursor t = before t.content t.cursor

let resolve content =
  match content.boundaries with
  | One_byte | Graphemes -> content
  | Unknown -> {content with boundaries = classify content.text}

(* An edit still invalidates its identity if computing the replacement fails.
   Text and cursor are changed only after the replacement is ready. *)
let edit t transition =
  let content = t.content and cursor = t.cursor in
  let revision = ref () in
  match transition content cursor revision with
  | next, cursor -> t.content <- next; t.cursor <- cursor
  | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      t.content <- {content with revision};
      Printexc.raise_with_backtrace exn backtrace

let clear t =
  edit t (fun _ _ revision -> {text = ""; revision; boundaries = One_byte; index = fresh_index ""; owned = None}, 0)

let after_edit (owned : owned_extent option) ~offset ~removed ~inserted =
  match owned with
  | None -> None
  | Some extent ->
      let { offset = start; length } = extent.range in
      if removed = 0 && inserted = 0 then owned
      else if offset + removed <= start then
        Some { extent with range = { offset = start + inserted - removed; length } }
      else if offset >= start + length then owned
      else None

(* Lower-bound search within the retained prefix; suffix offsets may belong
   to earlier text after a tail deletion and are never consulted. *)
let boundary_position index cursor =
  let rec find first after =
    if first >= after then first
    else
      let middle = first + (after - first) / 2 in
      if index.offsets.(middle) < cursor then find (middle + 1) after
      else find first middle in
  find 0 index.count

let boundary_at_or_after content cursor =
  let length = String.length content.text in
  if cursor >= length then length
  else match content.boundaries with
  | One_byte -> cursor
  | Graphemes | Unknown ->
      let index = Lazy.force content.index in
      let at = boundary_position index cursor in
      if at < index.count then index.offsets.(at) else length

let previous_boundary content cursor =
  match content.boundaries with
  | One_byte -> max 0 (cursor - 1)
  | Graphemes | Unknown ->
      let index = Lazy.force content.index in
      index.offsets.(max 0 (boundary_position index cursor - 1))

let index_after_deletion content ~cursor ~previous updated =
  if cursor = previous then content.index
  else if cursor = String.length content.text && Lazy.is_val content.index then
    let index = Lazy.force content.index in
    if index.prefix_stable then
      (* UAX #29 grapheme boundaries before this complete tail cluster do not
         change. Keep an immutable view of the array, without copying it. *)
      lazy { index with count = boundary_position index previous + 1 }
    else fresh_index updated
  else fresh_index updated

let insert t text =
  edit t (fun content cursor revision ->
    let content = resolve content in
    let updated = before content cursor ^ text ^ after content cursor in
    let boundaries = match content.boundaries with
      | One_byte -> classify text
      | Graphemes -> Graphemes
      | Unknown -> classify updated in
    let owned = after_edit content.owned ~offset:cursor ~removed:0 ~inserted:(String.length text) in
    let next = {text = updated; revision; boundaries; index = fresh_index updated; owned} in
    let cursor = boundary_at_or_after next (cursor + String.length text) in
    next, cursor)

let insert_owned t text =
  let owner = ref () and offset = t.cursor in
  insert t text;
  let length = String.length text in
  let owned = if length = 0 then None else Some { owner; range = { offset; length } } in
  t.content <- { t.content with owned };
  owner

let snapshot t = t.content
let snapshot_text snapshot = snapshot.text

let snapshot_owned_view snapshot owner =
  match snapshot.owned with
  | Some extent when extent.owner == owner ->
      Some { source = snapshot.text; range = extent.range; revision = snapshot.revision }
  | Some _ | None -> None

let owned_is_current t (view : owned_view) = has_revision t view.revision

let replace_owned view ~replacement =
  let { offset; length } = view.range in
  String.sub view.source 0 offset ^ replacement
  ^ String.sub view.source (offset + length) (String.length view.source - offset - length)

let project_owned view ranges =
  let source_length = String.length view.source in
  let rec project previous_end output_length pieces owned = function
    | [] ->
        Option.map (fun range -> { view with source = String.concat "" (List.rev pieces); range }) owned
    | ({ offset; length } as range) :: rest ->
        if offset < previous_end || length < 0 || offset > source_length || length > source_length - offset
        then None
        else
          let contains = offset <= view.range.offset
            && view.range.offset + view.range.length <= offset + length in
          let owned = if contains then
              Some { view.range with offset = output_length + view.range.offset - offset }
            else owned in
          project (range.offset + range.length) (output_length + length)
            (String.sub view.source offset length :: pieces) owned rest
  in
  project 0 0 [] None ranges

let insert_char t char = insert t (String.make 1 char)

let append t text =
  let content = t.content in
  let revision = ref () in
  match
    let updated = content.text ^ text in
    let boundaries = if String.equal text "" then content.boundaries else
      match content.boundaries with
      | One_byte | Unknown -> Unknown
      | Graphemes -> Graphemes in
    {text = updated; revision; boundaries; index = fresh_index updated; owned = content.owned}
  with
  | next ->
    let cursor = String.length next.text in
    t.content <- next;
    t.cursor <- cursor
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    t.content <- {content with revision};
    Printexc.raise_with_backtrace exn backtrace

let append_separated t ~separator text =
  let content = t.content in
  let revision = ref () in
  match
    let prefix_length = String.length content.text in
    let separator = if prefix_length = 0 then "" else separator in
    let separator_length = String.length separator and text_length = String.length text in
    let bytes = Bytes.create (prefix_length + separator_length + text_length) in
    Bytes.blit_string content.text 0 bytes 0 prefix_length;
    Bytes.blit_string separator 0 bytes prefix_length separator_length;
    Bytes.blit_string text 0 bytes (prefix_length + separator_length) text_length;
    let updated = Bytes.unsafe_to_string bytes in
    let boundaries = if separator_length = 0 && text_length = 0 then content.boundaries else
      match content.boundaries with
      | One_byte | Unknown -> Unknown
      | Graphemes -> Graphemes in
    {text = updated; revision; boundaries; index = fresh_index updated; owned = content.owned}
  with
  | next ->
    let cursor = String.length next.text in
    t.content <- next;
    t.cursor <- cursor
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    t.content <- {content with revision};
    Printexc.raise_with_backtrace exn backtrace

let move_left t =
  let content = t.content in
  let resolved = resolve content in
  let cursor = previous_boundary resolved t.cursor in
  if resolved != content then t.content <- resolved;
  t.cursor <- cursor

let move_right t =
  let content = t.content in
  let resolved = resolve content in
  let cursor = boundary_at_or_after resolved
      (min (String.length resolved.text) (t.cursor + 1)) in
  if resolved != content then t.content <- resolved;
  t.cursor <- cursor

let replace_prefix t prefix =
  edit t (fun content cursor revision ->
    let updated = prefix ^ after content cursor in
    let boundaries = match content.boundaries with
      | One_byte -> classify prefix
      | Graphemes | Unknown -> Unknown in
    let owned = after_edit content.owned ~offset:(String.length prefix)
        ~removed:(cursor - String.length prefix) ~inserted:0 in
    let next = {text = updated; revision; boundaries; index = fresh_index updated; owned} in
    let cursor = boundary_at_or_after next (String.length prefix) in
    next, cursor)

let backspace t =
  edit t (fun content cursor revision ->
    let content = resolve content in
    let after = after content cursor in
    let previous = previous_boundary content cursor in
    let updated = String.sub content.text 0 previous ^ after in
    let boundaries = match content.boundaries with
      | One_byte -> One_byte
      | Graphemes | Unknown -> Unknown in
    let owned = after_edit content.owned ~offset:previous ~removed:(cursor - previous) ~inserted:0 in
    let index = index_after_deletion content ~cursor ~previous updated in
    let next = {text = updated; revision; boundaries; index; owned} in
    let cursor = boundary_at_or_after next previous in
    next, cursor)

let delete_word t =
  replace_prefix t
    (Masc_tui_message_layout.drop_last_utf8_word (before_cursor t))

let can_leave_left t = length t = 0 && t.cursor = 0
