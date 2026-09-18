(** TypeSafe AI configuration and opt-in control.
    By default, TypeSafe AI is disabled unless explicitly enabled via
    environment or configuration. *)

val default_endpoint : string
val default_model : string

val is_enabled : unit -> bool
(** Whether TypeSafe AI is opted-in and active.
    Returns true only if:
    - [MASC_TYPESAFE_ENABLED] is set to "1" or "true", or
    - [TYPESAFE_API_KEY] is set and [MASC_TYPESAFE_ENABLED] is not "0" / "false". *)

val api_key : unit -> string option
(** Reads [TYPESAFE_API_KEY] from environment. *)

val endpoint : unit -> string
(** Returns [MASC_TYPESAFE_ENDPOINT] if set, else [default_endpoint]. *)

val model : unit -> string
(** Returns [MASC_TYPESAFE_MODEL] if set, else [default_model]. *)
