type t = { mutable text : string; mutable cursor : int }

let create () = { text = ""; cursor = 0 }
let contents t = t.text
let length t = String.length t.text
let cursor t = t.cursor
let before_cursor t = String.sub t.text 0 t.cursor
let after_cursor t = String.sub t.text t.cursor (length t - t.cursor)
let clear t = t.text <- ""; t.cursor <- 0

let insert t text =
  t.text <- before_cursor t ^ text ^ after_cursor t;
  t.cursor <- t.cursor + String.length text

let insert_char t char = insert t (String.make 1 char)

let move_left t =
  t.cursor <- String.length
    (Masc_tui_message_layout.drop_last_utf8_scalar (before_cursor t))

let move_right t =
  if t.cursor < length t then
    t.cursor <- t.cursor
      + Uchar.utf_decode_length (String.get_utf_8_uchar t.text t.cursor)

let replace_prefix t prefix =
  t.text <- prefix ^ after_cursor t;
  t.cursor <- String.length prefix

let backspace t =
  replace_prefix t
    (Masc_tui_message_layout.drop_last_utf8_scalar (before_cursor t))

let delete_word t =
  replace_prefix t
    (Masc_tui_message_layout.drop_last_utf8_word (before_cursor t))

let can_leave_left t = length t = 0 && t.cursor = 0
