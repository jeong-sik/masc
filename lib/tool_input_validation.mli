open Base

(** Tool_input_validation — Pre-dispatch validation via OAS Tool_middleware.

    Delegates to [Agent_sdk.Tool_middleware.make_validation_hook] for strict
    type coercion and structured error feedback.  The pre-hook preserves the
    MASC transport contract by stripping underscore-prefixed protocol markers
    before validation and by normalising [masc_transition] [to]/[note] aliases
    to [action]/[notes] without changing action vocabulary. *)

(** Register input validation as a Tool_dispatch pre-hook.
    Must be called after all tool schemas are registered (server init). *)
val register_pre_hook : unit -> unit
