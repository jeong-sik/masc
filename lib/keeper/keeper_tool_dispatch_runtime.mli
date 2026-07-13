open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val keeper_allowed_tool_names
  :  ?write_done:bool
  -> ?phase:Keeper_state_machine.phase
  -> keeper_meta
  -> string list

(** Universe tool names: candidates minus denied, no policy filter.
    Superset of [keeper_allowed_tool_names].  Used as the BM25 retrieval
    scope so progressive disclosure can surface tools beyond the active
    [tool_access] list. *)
val keeper_universe_tool_names : keeper_meta -> string list

(** Keeper-facing runtime candidate names before policy filtering. *)
val keeper_internal_candidate_tool_names : string list

(** Descriptor-projected universe model schemas. [make_tools] consumes the
    same closed surface; non-descriptor schema fallback is forbidden. *)
val keeper_universe_model_tools : keeper_meta -> Masc_domain.tool_schema list

(** Tool-access scoped universe: configured candidate profile list + core_always - denied.
    Strict subset of [keeper_universe_tool_names].  Used for BM25 indexing
    to reduce candidate pool size per keeper.  See #4637. *)
val keeper_tool_search_scope : keeper_meta -> string list

(** Tool-access scoped model tool schemas for BM25 indexing. *)
val keeper_model_tool_schemas : keeper_meta -> Masc_domain.tool_schema list

(** Core tools that bypass [tool_access] candidate profile filtering and seed the disclosure floor.
    Runtime gating/pruning can still narrow their visibility on a given turn. *)
val core_always_tools : string list

(** Expanded core set for tool-discovery mode (MASC_KEEPER_TOOL_DISCOVERY). *)
val core_discovery_tools : string list

(** Returns [core_discovery_tools].  Discovery mode is the default. *)
val effective_core_tools : unit -> string list

(** Keeper-local read-only tools that do not always flow through Tool_spec. *)
val keeper_read_only_tools : string list

(** [true] when a keeper-only tool is inherently read-only. *)
val is_keeper_read_only_tool : string -> bool

(** [true] when [name] is read-only or idempotent (safe to retry).
    Keeper-local fast-path (no mutex), then descriptor-aware capability
    projection. Prefer {!has_mutating_side_effect}
    at call sites for positive-sense readability. *)
val is_effectively_read_only_tool : string -> bool

(** [true] when calling [name] may produce non-idempotent side effects.
    Used by the side-effect observer to block retry after committed mutations. *)
val has_mutating_side_effect : string -> bool

(** Input-aware mutation check for mixed tools where read-only and mutating
    subcommands share the same tool name. *)
val has_mutating_side_effect_with_input : tool_name:string -> input:Yojson.Safe.t -> bool

(** Schema for the keeper_tool_search tool. *)
val keeper_tool_search_schema : Masc_domain.tool_schema

(** Replace injected MASC tool schemas.
    Startup calls this through [inject_masc_schemas]; runtime readers should
    use [masc_schemas_snapshot] rather than holding mutable state. *)
val set_masc_schemas : Masc_domain.tool_schema list -> unit

(** Immutable snapshot of injected MASC tool schemas. *)
val masc_schemas_snapshot : unit -> Masc_domain.tool_schema list

(** Injected masc_* tool names (populated at startup by [inject_masc_schemas]). *)
val injected_masc_tool_names : unit -> string list

(** [is_core_always_tool name] — true if [name] bypasses policy restrictions. *)
val is_core_always_tool : string -> bool

(** Deduplicate tool names, preserving order. *)
val dedupe_tool_names : string list -> string list

(** Test-only hooks for the global recorder/searcher refs converted to Atomic.t. *)
module For_testing : sig
  type descriptor_route_kind =
    | Output
    | Invariant
    | Registered_only

  val set_on_keeper_tool_call
    : (tool_name:string -> success:bool -> duration_ms:int -> unit) -> unit

  val record_keeper_tool_call
    : tool_name:string -> success:bool -> duration_ms:int -> unit

  val set_tool_search_fn
    : (query:string -> max_results:int -> Yojson.Safe.t) -> unit

  val search_tools : query:string -> max_results:int -> Yojson.Safe.t

  val descriptor_route_invariant_payload
    :  tool_name:string
    -> Keeper_tool_descriptor.t
    -> Yojson.Safe.t

  val descriptor_route_kind
    :  descriptor:Keeper_tool_descriptor.t
    -> output:string option
    -> descriptor_route_kind
end

(** Inject all masc_* schemas for keeper descriptor/registry surface filtering.
    Must be called once during server initialization. *)
val inject_masc_schemas : Masc_domain.tool_schema list -> unit

(** Classification of a keeper tool result payload for circuit-breaker
    bookkeeping.

    Plain text is treated as a valid success path because some keeper tools
    intentionally return markdown/text on success. JSON-looking payloads
    (leading [{] or [[] after whitespace) are parsed so malformed structured
    output does not silently reset the breaker. *)
type tool_result_payload =
  | Structured_success
  | Structured_error
  | Plain_text
  | Malformed_structured of string

(** Bridge-facing execution outcome.
    Structured tool errors, including [tool_not_allowed], are failures so
    candidate/policy rejections cannot silently end a keeper turn as success. *)
type execution_outcome =
  [ `Success
  | `Failure
  ]

(** Typed keeper tool execution result.
    [raw_output] preserves the original payload, [outcome] is the
    authoritative success/failure decision for bridge consumers, and
    [payload_shape] captures the post-execution wire shape for telemetry
    and malformed-payload handling. *)
type executed_tool_result =
  { raw_output : string
  ; outcome : execution_outcome
  ; payload_shape : tool_result_payload
  }

(** Inspect a keeper tool result payload without applying side effects. *)
val classify_tool_result_payload : string -> tool_result_payload

(** Extract the optional [failure_class] field from a structured keeper
    tool payload. Returns [None] on success, [Some Runtime_failure] on
    plain text or malformed JSON. *)
val failure_class_of_tool_result_payload : string -> Tool_result.tool_failure_class option

(** [false] for [Policy_rejection] and [Workflow_rejection] — deterministic,
    caller-visible rejections (permission/guardrail/validation denials and
    business-rule refusals) surface as their own typed error/alternatives
    instead of a loop-breaker hint, and repetition handling belongs to the
    OAS-side episode detector at the LLM boundary. [true] (breaker applies)
    for [Transient_error], [Runtime_failure], and [None] (undeclared,
    conservatively treated as counting). Execute's own failure/blocked/
    validation payloads declare [Policy_rejection] as of the sangsu
    Ambiguous_failure_signature fix (masc#24314) and are routed by this same
    predicate — no Execute-specific branch exists or is needed. *)
val should_apply_circuit_breaker_to_failure_payload : Tool_result.tool_failure_class option -> bool

(** Tag-based dispatch callback for masc_* tools without handler registry entries.
    Set at server init to [Keeper_tag_dispatch.dispatch]. Default: returns None.
    See #4579. *)

(** masc_* tool names available for a keeper (filtered by allowlist/denylist). *)
val keeper_masc_tool_names : keeper_meta -> string list

(** Compute the keeper's sender identity for broadcasts.
    Guards against double "keeper-" prefix. See #5104. *)

val execute_keeper_tool_call_with_outcome
  :  config:Workspace.config
  -> meta:keeper_meta
  -> ctx_work:working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> exec_cache:Masc_exec.Exec_cache.t option
  -> ?search_fn:(query:string -> max_results:int -> Yojson.Safe.t)
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?mcp_session_id:string
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> name:string
  -> input:Yojson.Safe.t
  -> unit
  -> executed_tool_result

val execute_keeper_tool_call
  :  config:Workspace.config
  -> meta:keeper_meta
  -> ctx_work:working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> exec_cache:Masc_exec.Exec_cache.t option
  -> ?search_fn:(query:string -> max_results:int -> Yojson.Safe.t)
  -> name:string
  -> input:Yojson.Safe.t
  -> unit
  -> string
