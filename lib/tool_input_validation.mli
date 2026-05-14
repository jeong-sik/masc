
(** Tool_input_validation — Pre-dispatch validation via OAS Tool_middleware.

    Delegates to [Agent_sdk.Tool_middleware.make_validation_hook] for strict
    type coercion and structured error feedback.  The pre-hook preserves the
    MASC transport contract by stripping underscore-prefixed protocol markers
    before validation and by normalising [masc_transition] [to]/[note] aliases
    to [action]/[notes] without changing action vocabulary. *)

(** Register input validation as a Tool_dispatch pre-hook.
    Must be called after all tool schemas are registered (server init). *)
val register_pre_hook : unit -> unit

(** Validate and normalize a tool argument object through the same OAS
    middleware used by [register_pre_hook].

    [?schema] lets direct OAS tool handlers validate against the schema they
    already hold, without depending on the global Tool_dispatch schema registry
    being populated in that execution path. When omitted, validation falls back
    to [Tool_dispatch.lookup_schema]. *)
val validate_args :
  ?schema:Yojson.Safe.t ->
  name:string ->
  args:Yojson.Safe.t ->
  unit ->
  (Yojson.Safe.t, Tool_result.t) result
