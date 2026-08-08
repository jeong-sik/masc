(** Tool definition and execution.

    @stability Stable
    @since 0.93.1 *)

type tool_handler = Yojson.Safe.t -> Types.tool_result
type context_tool_handler = Context.t -> Yojson.Safe.t -> Types.tool_result

(** Explicit resources available at one tool execution occurrence.
    Context and invocation are orthogonal optional capabilities rather than
    mutually exclusive handler variants.

    @since 0.215.0 *)
module Execution_env : sig
  type t

  val create : ?context:Context.t -> ?invocation:Tool_contract.Invocation.t -> unit -> t
  val context : t -> Context.t option
  val invocation : t -> Tool_contract.Invocation.t option
end

type execution_env_tool_handler = Execution_env.t -> Yojson.Safe.t -> Types.tool_result

(** Immutable execution metadata. A terminal tool is serial by construction,
    so [Terminal + Concurrent] is not representable. *)
type descriptor

val ordinary_descriptor : Tool_contract.execution_mode -> descriptor
val terminal_descriptor : Tool_contract.failure_effect_disposition -> descriptor
val descriptor_execution_mode : descriptor -> Tool_contract.execution_mode
val descriptor_completion : descriptor -> Tool_contract.completion

type t =
  { schema : Types.tool_schema
  ; descriptor : descriptor option
  ; handler : execution_env_tool_handler
  }

(** Adapt a handler that does not read the execution environment. *)
val ignoring_execution_env : tool_handler -> execution_env_tool_handler

(** Adapt a context-aware handler. Executing it without a context returns a
    non-recoverable [Deterministic] error rather than substituting one. *)
val requiring_context : context_tool_handler -> execution_env_tool_handler

(** Pair a schema with a handler.

    Where the schema comes from and what the handler reads are independent
    axes, and this is the only function that joins them. A [Types.tool_schema]
    can only come from [Types.tool_schema_of_params] or
    [Types.tool_schema_of_input_schema] — the type is [private] and each
    constructor derives one argument view from the other — so the two views
    cannot disagree here.

    Combinations are expressed by composition, not by new constructors:

    {[
      (* authoritative schema, execution-environment handler *)
      Result.map
        (fun schema -> Tool.of_schema schema handler)
        (Types.tool_schema_of_input_schema ~name ~description ~input_schema ())

      (* parameter view, context handler *)
      Tool.of_schema
        (Types.tool_schema_of_params ~name ~description ~parameters ())
        (Tool.requiring_context handler)
    ]}

    Do not add a [create_with_*] variant for a new combination: one function
    per (source, kind) pair makes this surface their product, and that product
    is how the authoritative source came to be reachable from only one of the
    three handler kinds.

    @since 0.232.0 *)
val of_schema
  :  ?descriptor:descriptor
  -> Types.tool_schema
  -> execution_env_tool_handler
  -> t

(** The (parameter view, plain handler) corner. {!schema_to_json} derives the
    wire form with [Types.params_to_input_schema], which keeps only type,
    description and required; when the caller holds a JSON Schema, compose
    {!of_schema} with [Types.tool_schema_of_input_schema] instead so it reaches
    providers verbatim. *)
val create
  :  ?descriptor:descriptor
  -> ?strict:bool
  -> name:string
  -> description:string
  -> parameters:Types.tool_param list
  -> tool_handler
  -> t

val execute
  :  ?context:Context.t
  -> ?invocation:Tool_contract.Invocation.t
  -> t
  -> Yojson.Safe.t
  -> Types.tool_result

val descriptor : t -> descriptor option

(** Exact declared execution mode, or [Serial] when no descriptor exists. *)
val execution_mode : t -> Tool_contract.execution_mode

(** Exact completion policy, or [Continue_after_success] when no descriptor
    exists. *)
val completion : t -> Tool_contract.completion

val descriptor_to_yojson : descriptor option -> Yojson.Safe.t

(** Provider-facing tool definition. ["input_schema"] is the authoritative
    schema verbatim when the tool carries one, and
    [Types.params_to_input_schema] of the parameters otherwise. *)
val schema_to_json : t -> Yojson.Safe.t

(** Wrap a tool to inject default arguments when not provided.
    Defaults are merged into the input JSON before the handler runs. *)
val with_defaults : (string * Yojson.Safe.t) list -> t -> t
