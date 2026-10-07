(** The editable chat draft. Cursor positions are UTF-8 byte offsets; every
    mutation keeps the cursor at a grapheme boundary. Restored drafts start at
    their end, while typed and pasted text is inserted at the current cursor. *)
type t

val create : unit -> t
val contents : t -> string
val length : t -> int
val cursor : t -> int
val before_cursor : t -> string
val clear : t -> unit
val insert : t -> string -> unit
val insert_char : t -> char -> unit
val append : t -> string -> unit
(** Add text at the end of the whole draft and leave the cursor there.
    Voice transcripts keep this append contract even after cursor movement. *)
val move_left : t -> unit
val move_right : t -> unit
val backspace : t -> unit
val delete_word : t -> unit
val can_leave_left : t -> bool
(** Only an empty draft at its start can hand Left to the Keeper navigator. *)
