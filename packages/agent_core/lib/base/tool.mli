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

type scoped_call

val scoped_call
  :  scope:Tool_contract.Resource_scope.t
  -> ?additional_scopes:Tool_contract.Resource_scope.t list
  -> execution_env_tool_handler
  -> scoped_call
(** A producer's resolved occupied resources and the handler that consumes
    that resolution. A scope is neither execution permission nor safe-retry
    evidence. The handler must still perform its ordinary authorization and
    verify that its resolved authority remains bound to these resources. *)

(** How an ordinary tool is admitted to a concurrent batch.

    [Static] fixes the mode for every call. [Concurrent_when] carries a
    predicate over the call input that must {e prove} the call reads only:
    an input it cannot prove is scheduled [Serial], so an unclassified input
    never widens admission. [Resource_scoped] prepares a bound call using
    producer-owned resource identities; it does not prove the call read-only.

    @since 0.233.0 *)
type ordinary_admission =
  | Static of Tool_contract.execution_mode
  | Concurrent_when of (Yojson.Safe.t -> bool)
  | Resource_scoped of
      (sw:Eio.Switch.t -> Yojson.Safe.t -> (scoped_call option, Types.tool_error) result)

type call_effect = Read_only | Effect_possible
(** The tool producer's contract for one input. [Read_only] proves that
    invoking the handler cannot mutate the work it observes, including when
    the handler fails or is cancelled. Logging and result storage do not
    change that work. Missing declarations remain
    [Effect_possible]; execution concurrency is not effect evidence. *)

(** Immutable execution metadata. A terminal tool is serial by construction,
    so [Terminal + Concurrent] is not representable. *)
type descriptor

val ordinary_descriptor :
  ?call_effect:(Yojson.Safe.t -> call_effect) -> Tool_contract.execution_mode -> descriptor

(** An ordinary tool whose admission is decided per call input. The
    predicate proves the input read-only, so the same predicate is the tool's
    {!call_effect}: an input it accepts is [Read_only], every other input
    [Effect_possible].

    @since 0.233.0 *)
val ordinary_descriptor_concurrent_when : (Yojson.Safe.t -> bool) -> descriptor

val ordinary_descriptor_scoped
  :  call_effect:(Yojson.Safe.t -> call_effect)
  -> prepare:(sw:Eio.Switch.t -> Yojson.Safe.t -> (scoped_call option, Types.tool_error) result)
  -> descriptor
(** An ordinary call with independent resource and effect contracts. The
    producer's [call_effect] must cover both its prepared and fallback handlers;
    resource Read claims alone do not prove the whole call read-only.
    Its pure execution mode remains Serial.
    Batch preparation may resolve a scope, then schedule disjoint calls in
    parallel while preserving the order of conflicting calls.

    Preparation may inspect and pin resources on [sw], but must not perform
    the tool's effect or grant permission. [Ok None] is a Serial fallback and
    [Error error] returns that unavailable result without invoking the original
    handler. Before either return, the producer must release any partial
    preparation it cannot transfer to a scoped call. Cancellation propagates;
    [sw] bounds the lifetime of transferred resources. Pair through [of_schema]
    (or [create]), which binds the descriptor to that exact handler. Replacing
    the public record's handler invalidates scoped admission and its original
    read-only declaration; the replacement is Serial and [Effect_possible]. *)

val terminal_descriptor : Tool_contract.failure_effect_disposition -> descriptor

val descriptor_execution_mode
  :  descriptor
  -> input:Yojson.Safe.t
  -> Tool_contract.execution_mode

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

val map_handler : (execution_env_tool_handler -> execution_env_tool_handler) -> t -> t
(** Wrap the ordinary handler and every valid producer-prepared handler with
    the same instrumentation. The wrapper must forward the exact execution
    environment and input; argument transformation belongs in [with_defaults]
    or the producer's preparation contract. A stale binding invalidated by a
    record handler replacement stays invalid; this function cannot revive it. *)

type prepared_call

val prepare_call : sw:Eio.Switch.t -> t -> input:Yojson.Safe.t -> prepared_call
val has_scoped_admission : t -> bool
(** Whether the descriptor opts into preparation. Ordinary execution paths
    without any such calls need no additional preparation scope. *)
val prepared_call_scopes : prepared_call -> Tool_contract.Resource_scope.t list option
val execute_prepared
  :  ?context:Context.t
  -> ?invocation:Tool_contract.Invocation.t
  -> prepared_call
  -> Types.tool_result
(** Execute the exact input and handler frozen together by [prepare_call].
    There is no replacement-input argument. The batch owner must validate the
    original schema and retain [sw] until all executions and observers finish.
    Direct {!execute} retains its ordinary handler and admission behavior. *)

val descriptor : t -> descriptor option

(** Execution mode for this call, or [Serial] when no descriptor exists.

    The input is required because a descriptor may decide admission from it;
    a caller that does not hold the input cannot answer this question. *)
val execution_mode : t -> input:Yojson.Safe.t -> Tool_contract.execution_mode

(** Exact completion policy, or [Continue_after_success] when no descriptor
    exists. *)
val completion : t -> Tool_contract.completion

val call_effect : t -> Yojson.Safe.t -> call_effect
(** Read the producer's contract before entering the handler. A terminal,
    undescribed or unpaired resource-scoped tool is [Effect_possible].
    The producer callback must be pure,
    total, and return the same classification for the same input: transports
    may evaluate it more than once before execution. This does not authorize
    execution. *)

val descriptor_to_yojson : descriptor option -> Yojson.Safe.t

(** Provider-facing tool definition for a schema that has no handler yet.

    Distinct from {!Types.tool_schema_to_json}, which is the storage encoding:
    that one always emits ["parameters"] and additionally emits
    ["input_schema"] when the schema carries one, and a definition holding both
    is rejected on the way out
    ([Backend_openai_serialize.tool_definition_of_json]). Callers that build a
    request rather than a checkpoint need this function.

    Memoized on physical schema identity: a schema is immutable, so two calls
    on the same schema return the same value — the second call does not
    rebuild the tree. The cache holds schemas weakly. Dead bindings are
    cleaned by the table's automatic resizing rather than an explicit
    whole-table sweep on each cache miss. *)
val wire_json_of_schema : Types.tool_schema -> Yojson.Safe.t

val wire_bytes_of_schema : Types.tool_schema -> int
(** Compact byte length of {!wire_json_of_schema}: what this one tool costs
    every request that carries it.

    The shared weak cache retains the measured length alongside the JSON.
    Repeated measurements reuse that integer without retaining a serialized
    string. Concurrent first measurements may serialize independently before
    publishing the same length; serialization runs outside the cache mutex.

    Named here so a caller measuring the tool surface has a right answer
    within reach. Measuring {!Types.tool_schema_to_yojson} instead counts
    ["parameters"] too — the derived validation view that no provider
    receives — and reports a surface nobody is charged for. *)

(** Provider-facing tool definition. ["input_schema"] is the authoritative
    schema verbatim when the tool carries one, and
    [Types.params_to_input_schema] of the parameters otherwise. *)
val schema_to_json : t -> Yojson.Safe.t

(** Wrap a tool to inject default arguments when not provided.
    Effect classification, conditional scheduling, scoped preparation and the
    handler all see the same merged input. Original wire input remains the
    hook/transcript input. This does not rebind an unpaired scoped handler. *)
val with_defaults : (string * Yojson.Safe.t) list -> t -> t
