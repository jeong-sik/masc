open Keeper_types

val keeper_allowed_tool_names : ?write_done:bool -> keeper_meta -> string list
val keeper_allowed_model_tools :
  ?write_done:bool -> keeper_meta -> Types.tool_schema list

(** Universe tool names: candidates minus denied, no policy filter.
    Superset of [keeper_allowed_tool_names].  Used as the BM25 retrieval
    scope so progressive disclosure can surface tools beyond the preset. *)
val keeper_universe_tool_names : keeper_meta -> string list

(** Keeper-facing runtime candidate names before policy filtering. *)
val keeper_internal_candidate_tool_names : string list

(** Universe model tool schemas.  Returns schemas for all universe tools
    so [make_tools] can build Agent_sdk.Tool.t for the full search scope. *)
val keeper_universe_model_tools : keeper_meta -> Types.tool_schema list

(** Preset-scoped universe: preset allowlist + core_always - denied.
    Strict subset of [keeper_universe_tool_names].  Used for BM25 indexing
    to reduce candidate pool size per keeper preset.  See #4637. *)
val keeper_preset_universe_tool_names : keeper_meta -> string list

(** Preset-scoped model tool schemas for BM25 indexing. *)
val keeper_preset_universe_model_tools : keeper_meta -> Types.tool_schema list

(** Core tools that are always executable and visible regardless of preset.
    E.g. masc_status, masc_tool_help, extend_turns. *)
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
    Keeper-local fast-path (no mutex), then Tool_dispatch.is_read_only,
    then Tool_dispatch.is_idempotent. Prefer {!has_mutating_side_effect}
    at call sites for positive-sense readability. *)
val is_effectively_read_only_tool : string -> bool

(** [true] when calling [name] may produce non-idempotent side effects.
    Used by the side-effect observer to block retry after committed mutations. *)
val has_mutating_side_effect : string -> bool

(** Schema for the keeper_tool_search tool. *)
val keeper_tool_search_schema : Types.tool_schema

(** Injected masc_* tool schemas (populated at startup by [inject_masc_schemas]). *)
val masc_schemas_ref : Types.tool_schema list ref

(** Injected masc_* tool names (populated at startup by [inject_masc_schemas]). *)
val injected_masc_tool_names : unit -> string list

(** [is_core_always_tool name] — true if [name] bypasses policy restrictions. *)
val is_core_always_tool : string -> bool

(** Drop boring observation tools when a turn already has actionable work.
    Returns the original set when every tool is boring so callers do not end
    up with an empty allowlist. *)
val prune_boring_tools_for_actionable_turn : string list -> string list

(** Deduplicate tool names, preserving order. *)
val dedupe_tool_names : string list -> string list

(** Inject all masc_* schemas for keeper allowlist/denylist filtering.
    Must be called once during server initialization.
    Keeper_denied tools are excluded at injection time. *)
val inject_masc_schemas : Types.tool_schema list -> unit

(** Load preset definitions from [config/tool_policy.toml].
    Must be called once during server initialization.
    Raises [Failure] if the config file is missing or malformed.
    For preset-scoped allowlist filtering to include injected [masc_*]
    schemas, call [inject_masc_schemas] before the first preset resolution. *)
val init_policy_config : base_path:string -> (unit, string) result

(** Check if a tool name is in the Keeper_denied surface (Tool_catalog).
    Denied tools are excluded from both the schema list sent to the LLM
    and blocked at execution time by the pre_tool_use hook. *)
val is_keeper_denied : string -> bool

(** Callback for recording keeper-internal tool calls.
    Set at server initialization to avoid Config dependency cycle. *)
val on_keeper_tool_call :
  (tool_name:string -> success:bool -> duration_ms:int -> unit) ref

(** Register a per-turn observer for tool call events.
    Observers are independent — concurrent keepers do not interfere. *)
val add_tool_call_observer :
  (tool_name:string -> success:bool -> unit) -> unit

(** Remove a previously registered observer (physical equality). *)
val remove_tool_call_observer :
  (tool_name:string -> success:bool -> unit) -> unit

(** Notify all registered observers of a tool call event. *)
val notify_tool_call_observers :
  tool_name:string -> success:bool -> unit

(** Callback for keeper_tool_search BM25 search.
    Process-global fallback; prefer passing [~search_fn] to
    [execute_keeper_tool_call] for session-scoped, race-free search. *)
val tool_search_fn :
  (query:string -> max_results:int -> Yojson.Safe.t) ref

(** Tag-based dispatch callback for masc_* tools without handler registry entries.
    Set at server init to [Keeper_tag_dispatch.dispatch]. Default: returns None.
    See #4579. *)

(** masc_* tool names available for a keeper (filtered by allowlist/denylist). *)
val keeper_masc_tool_names : keeper_meta -> string list

(** masc_* tool schemas available for a keeper (filtered by allowlist/denylist). *)
val keeper_masc_tool_schemas : keeper_meta -> Types.tool_schema list

(** Compute the keeper's sender identity for portals and broadcasts.
    Guards against double "keeper-" prefix. See #5104. *)

val execute_keeper_tool_call :
  config:Room.config ->
  meta:keeper_meta ->
  ctx_work:working_context ->
  ?search_fn:(query:string -> max_results:int -> Yojson.Safe.t) ->
  name:string ->
  input:Yojson.Safe.t ->
  unit ->
  string
