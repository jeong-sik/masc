(** TypeSafe AI configuration and opt-in control.

    The lane is off until a key is present. Every read goes through
    {!Env_config_core}, so a value seeded from [runtime.toml] into the boot
    override store answers the same as an exported variable. *)

val default_endpoint : string
val default_model : string

val is_enabled : unit -> bool
(** [true] when [TYPESAFEAI_API_KEY] holds a non-blank value and
    [MASC_TYPESAFEAI_ENABLED] does not say otherwise. The variable can turn the
    lane off; it cannot turn it on without a key. Absent, blank, or malformed
    values leave the lane on, and a malformed one is reported by the config
    layer. *)

val api_key : unit -> string option
(** [TYPESAFEAI_API_KEY], trimmed. [None] when unset or blank. *)

val endpoint : unit -> string
(** [MASC_TYPESAFEAI_ENDPOINT], else {!default_endpoint}. *)

val model : unit -> string
(** [MASC_TYPESAFEAI_MODEL], else {!default_model}. *)
