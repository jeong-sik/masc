type t = { mutable text : string; mutable cursor : int }

let create () = { text = ""; cursor = 0 }
let contents t = t.text
let length t = String.length t.text
let cursor t = t.cursor
let before_cursor t = String.sub t.text 0 t.cursor
let after_cursor t = String.sub t.text t.cursor (length t - t.cursor)
let clear t = t.text <- ""; t.cursor <- 0

let boundary_at_or_after t cursor =
  match List.find_opt (fun offset -> offset >= cursor)
    (Masc_tui_message_layout.input_boundaries t.text) with
  | Some offset -> offset
  | None -> length t

let insert t text =
  t.text <- before_cursor t ^ text ^ after_cursor t;
  t.cursor <- boundary_at_or_after t (t.cursor + String.length text)

let insert_char t char = insert t (String.make 1 char)

let move_left t =
  t.cursor <- List.fold_left
    (fun previous offset -> if offset < t.cursor then offset else previous) 0
    (Masc_tui_message_layout.input_boundaries t.text)

let move_right t =
  t.cursor <- boundary_at_or_after t (min (length t) (t.cursor + 1))

let replace_prefix t prefix =
  t.text <- prefix ^ after_cursor t;
  t.cursor <- boundary_at_or_after t (String.length prefix)

let backspace t =
  let after = after_cursor t in
  move_left t;
  t.text <- before_cursor t ^ after;
  t.cursor <- boundary_at_or_after t t.cursor

let delete_word t =
  replace_prefix t
    (Masc_tui_message_layout.drop_last_utf8_word (before_cursor t))

let can_leave_left t = length t = 0 && t.cursor = 0
