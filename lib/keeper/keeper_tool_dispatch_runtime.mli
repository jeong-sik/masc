open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val keeper_model_tool_names : unit -> string list
val keeper_model_tool_schemas : unit -> Masc_domain.tool_schema list

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

(** Deduplicate tool names, preserving order. *)
val dedupe_tool_names : string list -> string list

(** Test-only hooks for the global tool-call recorder and descriptor routing. *)
module For_testing : sig
  type descriptor_route_kind =
    | Output
    | Invariant
    | Registered_only

  val set_on_keeper_tool_call
    : (tool_name:string -> success:bool -> duration_ms:int -> unit) -> unit

  val record_keeper_tool_call
    : tool_name:string -> success:bool -> duration_ms:int -> unit

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

(** Bridge-facing execution outcome. *)
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

(** Tag-based dispatch callback for masc_* tools without handler registry entries.
    Set at server init to [Keeper_tag_dispatch.dispatch]. Default: returns None.
    See #4579. *)

val registered_handler_schema_names : unit -> string list

(** Compute the keeper's sender identity for broadcasts.
    Guards against double "keeper-" prefix. See #5104. *)

val execute_keeper_tool_call_with_outcome
  :  config:Workspace.config
  -> meta:keeper_meta
  -> ctx_work:working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> exec_cache:Masc_exec.Exec_cache.t option
  -> ?search_fn:(unit -> Yojson.Safe.t)
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?mcp_session_id:string
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
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
  -> ?search_fn:(unit -> Yojson.Safe.t)
  -> name:string
  -> input:Yojson.Safe.t
  -> unit
  -> string
