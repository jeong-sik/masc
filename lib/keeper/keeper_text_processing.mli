(** Keeper_text_processing — text processing functions shared by
    [Keeper_exec_context] and [Keeper_prompt].

    Handles reply markup stripping, proactive text normalisation,
    quality checks, and fragment detection. *)

(** {1 Reply Markup} *)

(** Remove [[STATE]..[/STATE]] blocks from text. *)
val strip_state_blocks_text : string -> string

(** Trim whitespace; return [None] for empty strings. *)
val trim_to_option : string -> string option

(** Extract a fallback reply string from a state snapshot. *)
val state_snapshot_reply_fallback :
  Keeper_memory_policy.keeper_state_snapshot option -> string option

(** Strip skill-route lines and state blocks from a reply. *)
val strip_internal_reply_markup : string -> string

(** Return user-visible reply text, stripping internal markup.
    Falls back through the optional [fallback] string and then
    the parsed state snapshot. *)
val user_visible_reply_text : ?fallback:string -> string -> string

(** {1 Proactive Text} *)

(** Normalise proactive text: strip markup and collapse whitespace. *)
val normalize_proactive_text : string -> string

(** Extract check-in text from a proactive reply. *)
val extract_checkin_text : string -> string option

(** {1 Fragment Detection} *)

(** Check if history text appears fragmentary (for filtering). *)
val looks_fragmentary_history_text : string -> bool
