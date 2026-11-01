type revision = unit ref

(* Printable ASCII, LF and tab each form a one-byte input boundary. Other
   input, including escapes and CR, stays on the shared grapheme path. *)
type boundaries = One_byte | Graphemes | Unknown
type content = {
  text : string;
  revision : revision;
  boundaries : boundaries;
}

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
  {content = {text = ""; revision = ref (); boundaries = One_byte}; cursor = 0}
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
  edit t (fun _ _ revision -> {text = ""; revision; boundaries = One_byte}, 0)

let boundary_at_or_after text boundaries cursor =
  match boundaries with
  | One_byte -> min (String.length text) cursor
  | Graphemes | Unknown ->
      (match List.find_opt (fun offset -> offset >= cursor)
        (Masc_tui_message_layout.input_boundaries text) with
       | Some offset -> offset
       | None -> String.length text)

let previous_boundary content cursor =
  match content.boundaries with
  | One_byte -> max 0 (cursor - 1)
  | Graphemes | Unknown ->
      List.fold_left
        (fun previous offset -> if offset < cursor then offset else previous) 0
        (Masc_tui_message_layout.input_boundaries content.text)

let insert t text =
  edit t (fun content cursor revision ->
    let content = resolve content in
    let updated = before content cursor ^ text ^ after content cursor in
    let boundaries = match content.boundaries with
      | One_byte -> classify text
      | Graphemes -> Graphemes
      | Unknown -> classify updated in
    let cursor = boundary_at_or_after updated boundaries (cursor + String.length text) in
    {text = updated; revision; boundaries}, cursor)

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
    {text = updated; revision; boundaries}
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
    {text = updated; revision; boundaries}
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
  let cursor = boundary_at_or_after resolved.text resolved.boundaries
      (min (String.length resolved.text) (t.cursor + 1)) in
  if resolved != content then t.content <- resolved;
  t.cursor <- cursor

let replace_prefix t prefix =
  edit t (fun content cursor revision ->
    let updated = prefix ^ after content cursor in
    let boundaries = match content.boundaries with
      | One_byte -> classify prefix
      | Graphemes | Unknown -> Unknown in
    let cursor = boundary_at_or_after updated boundaries (String.length prefix) in
    {text = updated; revision; boundaries}, cursor)

let backspace t =
  edit t (fun content cursor revision ->
    let content = resolve content in
    let after = after content cursor in
    let cursor = previous_boundary content cursor in
    let updated = String.sub content.text 0 cursor ^ after in
    let boundaries = match content.boundaries with
      | One_byte -> One_byte
      | Graphemes | Unknown -> Unknown in
    let cursor = boundary_at_or_after updated boundaries cursor in
    {text = updated; revision; boundaries}, cursor)

let delete_word t =
  replace_prefix t
    (Masc_tui_message_layout.drop_last_utf8_word (before_cursor t))

let can_leave_left t = length t = 0 && t.cursor = 0
