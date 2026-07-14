
(** Tool_input_validation — Pre-dispatch validation via OAS Tool_middleware.

    Delegates to [Agent_sdk.Tool_middleware.make_validation_hook] for strict
    validation and structured error feedback.  The pre-hook preserves the
    MASC transport contract by stripping underscore-prefixed protocol markers
    before validation. *)

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
  (Yojson.Safe.t, Tool_result.result) result

type schema_shape =
  { properties : string list
  ; required : string list
  ; one_of_required : string list list
  ; errors : string list
  }

val schema_shape : Yojson.Safe.t -> schema_shape
(** Validated JSON-schema shape projection used by dispatch diagnostics and
    descriptor discovery. Unexpected [properties], [required], or [oneOf]
    shapes are reported in [errors] instead of silently flattening to [[]]. *)

val schema_shape_json : Yojson.Safe.t -> Yojson.Safe.t
(** JSON form of {!schema_shape}. Omits [one_of_required] and [schema_errors]
    when empty. *)
