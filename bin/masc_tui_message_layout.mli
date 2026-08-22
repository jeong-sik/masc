type style =
  | User
  | Keeper
  | Status
  | Error

type entry = {
  style : style;
  timestamp : string;
  role_label : string;
  request_label : string;
  body : string;
}

type row = {
  style : style;
  text : string;
}

val utf8_scalar_byte_length : char -> int option
(** Expected byte length for one well-formed UTF-8 lead byte. Invalid leads and
    isolated continuation bytes return [None]. *)

val is_printable_utf8_scalar : string -> bool
(** Whether the text is exactly one valid scalar outside C0, DEL, and C1
    control ranges. *)

val drop_last_utf8_scalar : string -> string
(** Remove one complete scalar from valid UTF-8 text. Empty or invalid text is
    preserved rather than truncated into a different malformed value. *)

val display_width : string -> int
(** Approximate xterm Unicode-11 display cells while preserving extended
    grapheme clusters as indivisible layout pieces. Renderer-owned ANSI CSI,
    combining marks, variation selectors, and joiners have zero width. *)

val fit_width : string -> int -> string
(** Fit UTF-8 text to an exact terminal-cell budget without splitting a scalar
    or renderer-owned ANSI CSI sequence. *)

val input_viewport : max_cells:int -> string -> string
(** Keep the complete input when it fits. Overflow uses a leading [~] and the
    newest complete-scalar suffix that fits in the remaining cells. *)

val input_cursor_row :
  terminal_rows:int -> history_height:int -> status_rows:int -> int
(** One-based input row clamped to the terminal viewport. *)

val input_cursor_column : terminal_cols:int -> input:string -> int
(** One-based cursor column after the visible input, clamped to the spacer
    immediately before the right border. *)

val message_viewport_supported :
  terminal_rows:int -> terminal_cols:int -> status_rows:int -> bool
(** Whether the full chat frame plus its final newline fits without terminal
    scrolling. Unsupported viewports render a compact resize gate and suppress
    message editing. *)

val wrap_words : max_cells:int -> string -> string list
(** Wrap a plain single-line string at spaces using a terminal-cell budget.
    Words wider than the budget are split between complete UTF-8 scalars. *)

val visible_rows : inner_width:int -> height:int -> entry list -> row list
(** Render chat entries into cell-bounded, UTF-8-safe physical rows and retain
    the newest rows. The newest entry always keeps its metadata row. *)
