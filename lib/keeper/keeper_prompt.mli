(** Keeper_prompt — System prompts, personality evolution, and text processing
    for keeper agents. OAS-aligned: these functions define agent identity and
    text output. *)

val exact_direct_mention_present : targets:string list -> string -> bool

val keeper_constitution : unit -> string

val ensure_critical_prompt_anchors : string -> string
(** Append a minimal technical recovery block when the keeper system prompt
    lost critical continuity/world/policy anchors. Normal prompts are returned
    unchanged. *)

val build_keeper_system_prompt :
  instructions:string ->
  ?persona_extended:string ->
  ?keeper_name:string ->
  ?home_ground:string ->
  ?active_goals:(string * string) list ->
  unit ->
  string
(** RFC-0324 B-1: no repository list is injected. The prompt carries a
    constant [<repositories>] block instructing filesystem self-discovery —
    the catalog and a keeper's sandbox checkouts have no invariant linking
    them, so a catalog-fed list asserted resolvability for repos that were
    never cloned. *)

val append_direct_reply_mode_prompt :
  base_prompt:string ->
  string

val append_trait_clause : base:string -> clause:string -> string

(** {1 Text Processing}

    Re-exported from [Keeper_text_processing]. *)

include module type of Keeper_text_processing
