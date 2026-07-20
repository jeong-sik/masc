(** UTF-8-safe Keeper text operations. *)

(** {1 Reply Markup} *)

(** Return a prefix that does not split a UTF-8 continuation byte, plus whether
    truncation happened. [max_bytes <= 0] yields [("", true)] for non-empty
    input. *)
val truncate_utf8_prefix : max_bytes:int -> string -> string * bool
