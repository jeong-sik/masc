(** TypeSafe AI configuration and opt-in control.

    The lane is off until a key is present. Every read goes through
    {!Env_config_core}, so a value seeded from [runtime.toml] into the boot
    override store answers the same as an exported variable. *)

val default_endpoint : string
val default_model : string

type unavailable_reason = Lane_disabled | Missing_api_key | Absorb_gate_disabled

val absorb_gate_api_key : unit -> (string, unavailable_reason) result
(** One snapshot for evaluation or its skip reason, in the existing precedence:
    global switch, trimmed key, then the absorb-gate switch. *)

val is_enabled : unit -> bool
(** [true] when [TYPESAFEAI_API_KEY] holds a non-blank value and
    [MASC_TYPESAFEAI_ENABLED] does not say otherwise. The variable can turn the
    lane off; it cannot turn it on without a key. Absent, blank, or malformed
    values leave the lane on, and a malformed one is reported by the config
    layer. *)

val is_board_attention_enabled : unit -> bool
(** {!is_enabled} and [MASC_TYPESAFEAI_BOARD_ATTENTION_ENABLED] does not say
    otherwise: the Board attention judgment
    ({!Keeper_board_attention_exact_flow}). *)

val is_absorb_gate_enabled : unit -> bool
(** {!is_enabled} and [MASC_TYPESAFEAI_ABSORB_GATE_ENABLED] says so: the
    librarian absorb gate ({!Keeper_librarian_absorb_gate}) is off unless the
    operator turns it on, because it sends the librarian's memories to the
    vendor. Each gate has its own switch so that a key, which turns the lane
    on, does not turn on a gate that was not reviewed with it. *)

val api_key : unit -> string option
(** [TYPESAFEAI_API_KEY], trimmed. [None] when unset or blank. *)

val endpoint : unit -> string
(** [MASC_TYPESAFEAI_ENDPOINT], else {!default_endpoint}. *)

val model : unit -> string
(** [MASC_TYPESAFEAI_MODEL], else {!default_model}. *)
