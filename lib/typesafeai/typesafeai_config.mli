(** TypeSafe AI configuration and opt-in control.

    The lane's settings are the [\[typesafeai\]] table of runtime.toml
    ({!Runtime_schema.typesafeai}), published on load by {!Runtime.set_loaded}
    into {!Runtime_typesafeai_policy}. Only the key, [TYPESAFEAI_API_KEY], is
    read from the environment, because it is a secret. The lane is off until
    a key is present. *)

val default_endpoint : string
val default_model : string

type unavailable_reason =
  | Lane_disabled  (** [\[typesafeai\] enabled = false] *)
  | Missing_api_key  (** no [TYPESAFEAI_API_KEY] *)
  | Absorb_gate_disabled  (** [\[typesafeai\] absorb_gate = false], the default *)
  | Board_attention_disabled  (** [\[typesafeai\] board_attention = false] *)
  | Context_review_disabled
  | Keeper_excluded
      (** the keeper is named in [\[typesafeai\] excluded_keepers]: nothing of
          it reaches the vendor, whichever gate asks *)

val unavailable_reason_to_string : unavailable_reason -> string

val absorb_gate_api_key : keeper_id:string -> (string, unavailable_reason) result
(** One snapshot for evaluation or its skip reason, in this precedence: the
    lane switch, the key, the absorb gate's own switch, then the keeper's
    exclusion. The lane defaults to on when a key is present; the absorb gate
    requires explicit opt-in because it sends the librarian's memories to the
    vendor. *)

val board_attention_api_key : keeper_id:string -> (string, unavailable_reason) result
(** The same for the Board attention judgment
    ({!Keeper_board_attention_exact_flow}), whose switch defaults to on. *)

val context_review_api_key : keeper_id:string -> (string, unavailable_reason) result
(** Opt-in preservation review of source Context and its proposed summary.
    Disabled by default; lane, key and keeper exclusions still apply. *)

val is_enabled : unit -> bool
(** Whether the lane has a key and [\[typesafeai\].enabled] permits use. Also
    used by the continuity measurement CLI, independently of either gate. *)

val is_board_attention_enabled : unit -> bool
(** {!is_enabled} and [\[typesafeai\].board_attention] does not say
    otherwise, before any keeper's exclusion. *)

val is_absorb_gate_enabled : unit -> bool
(** {!is_enabled} and [\[typesafeai\].absorb_gate] says so, before any
    keeper's exclusion. *)

val is_excluded : keeper_id:string -> bool
(** The keeper is named in [\[typesafeai\].excluded_keepers]. *)

val unknown_excluded_keepers : known:string list -> string list
(** The names in [\[typesafeai\].excluded_keepers] that are not in [known],
    the keepers of the base path: each excludes nobody and is reported at
    boot. *)

type readiness =
  | Off
  | Configured of { model : string }

val readiness : unit -> readiness
(** Credential-free Board attention readiness for operator projections. [Off]
    covers a disabled Board gate or lane and a missing key; [Configured] carries
    only the configured model, never the API key. *)

val api_key : unit -> string option
(** [TYPESAFEAI_API_KEY], trimmed. [None] when unset or blank. *)

val endpoint : unit -> string
(** [\[typesafeai\].endpoint], else {!default_endpoint}. This is the endpoint
    used by the HTTP client. *)

val model : unit -> string
(** [\[typesafeai\].model], else {!default_model}. *)
