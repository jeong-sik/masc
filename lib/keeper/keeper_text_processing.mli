(** Keeper text normalization and legacy fragment diagnostics. *)

(** {1 Reply Markup} *)

(** Return a prefix that does not split a UTF-8 continuation byte, plus whether
    truncation happened. [max_bytes <= 0] yields [("", true)] for non-empty
    input. *)
val truncate_utf8_prefix : max_bytes:int -> string -> string * bool

(** {1 Proactive Text} *)

(** Normalise proactive text by collapsing whitespace. *)
val normalize_proactive_text : string -> string

(** Extract check-in text from a proactive reply. *)
val extract_checkin_text : string -> string option

(** {1 Terminal Ending Detection} *)

(** Check for terminal punctuation ([.!?] or CJK equivalents). *)
val proactive_has_terminal_punct : string -> bool

(** Check for terminal Korean verb endings. *)
val proactive_has_terminal_korean_ending : string -> bool

(** Check for any terminal ending (punctuation or Korean). *)
val proactive_has_terminal_ending : string -> bool

(** {1 Fragment Detection} *)

(** Check if text looks like an incomplete fragment. *)
val proactive_looks_fragmentary : string -> bool

(** Check if history text appears fragmentary (for filtering). *)
val looks_fragmentary_history_text : string -> bool
