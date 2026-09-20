(** TypeSafe AI configuration and opt-in control.

    The lane is off until a key is present. Every read goes through
    {!Env_config_core}, so a value seeded from [runtime.toml] into the boot
    override store answers the same as an exported variable. *)

val default_endpoint : string
val default_model : string

type unavailable_reason = Lane_disabled | Missing_api_key | Absorb_gate_disabled

val unavailable_reason_to_string : unavailable_reason -> string

val absorb_gate_api_key : unit -> (string, unavailable_reason) result
(** One snapshot for evaluation or its skip reason, in the existing precedence:
    global switch, trimmed key, then the absorb-gate switch. The lane defaults
    to on when a key is present; the absorb gate requires explicit opt-in. *)

val is_board_attention_enabled : unit -> bool
(** A key is present and neither [MASC_TYPESAFEAI_ENABLED] nor
    [MASC_TYPESAFEAI_BOARD_ATTENTION_ENABLED] turns it off: the Board judgment
    ({!Keeper_board_attention_exact_flow}). *)

val api_key : unit -> string option
(** [TYPESAFEAI_API_KEY], trimmed. [None] when unset or blank. *)

val endpoint : unit -> string
(** [MASC_TYPESAFEAI_ENDPOINT], else {!default_endpoint}. *)

val model : unit -> string
(** [MASC_TYPESAFEAI_MODEL], else {!default_model}. *)
