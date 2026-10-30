(** UTF-8 prefix truncation for bounded previews. *)

(** Return a prefix that does not split a UTF-8 continuation byte, plus whether
    truncation happened. [max_bytes <= 0] yields [("", true)] for non-empty
    input. *)
val truncate_utf8_prefix : max_bytes:int -> string -> string * bool
