(** Keeper_text_processing — text processing functions shared by
    [Keeper_context_runtime] and [Keeper_prompt].

    Handles reply markup stripping, proactive text normalisation,
    quality checks, and fragment detection. *)

(** {1 Reply Markup} *)

(** Return a prefix that does not split a UTF-8 continuation byte, plus whether
    truncation happened. [max_bytes <= 0] yields [("", true)] for non-empty
    input. *)
val truncate_utf8_prefix : max_bytes:int -> string -> string * bool

(** Trim whitespace; return [None] for empty strings. *)

(** Strip skill-route lines from a reply. *)
val strip_internal_reply_markup : string -> string

(** Return user-visible reply text, stripping internal markup.
    Falls back through the optional [fallback] string. *)
val user_visible_reply_text : ?fallback:string -> string -> string

(** {1 Proactive Text} *)

(** Normalise proactive text: strip markup and collapse whitespace. *)
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
