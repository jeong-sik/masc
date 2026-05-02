(** Keeper_tools_oas — Wrap keeper tools as [Agent_sdk.Tool.t] for [Agent.run].

    Bridges [Keeper_exec_tools.execute_keeper_tool_call] dispatch
    to [Agent_sdk.Tool.t list] via [Tool_bridge.oas_tool_of_masc]. Tool
    execution reads the current context from [ctx_snapshot]
    (immutable), enabling [Agent.run] to manage messages while
    keeper tools access the working context for status/metrics.

    @since Phase 4 — Keeper → Agent.run() migration *)

(** Re-export of [Keeper_types.tool_call_entry] so dashboard code
    using [e.Keeper_tools_oas.count] keeps compiling. *)
type tool_call_entry = Keeper_types.tool_call_entry =
  { count : int
  ; successes : int
  ; failures : int
  ; last_used_at : float
  }

(** Bundle returned by [make_tool_bundle]: the [Agent_sdk.Tool.t list]
    plus a [cleanup] thunk that releases the per-turn sandbox
    runtimes. *)
type tool_bundle =
  { tools : Agent_sdk.Tool.t list
  ; cleanup : unit -> unit
  }

(** Per-keeper tool usage view from [Keeper_registry]. *)
val tool_usage_for_keeper : string -> (string * tool_call_entry) list

(** Project [tool_usage_for_keeper] to a JSON array. *)
val tool_usage_json : string -> Yojson.Safe.t

(** Most-recently-used tool names for a keeper, capped to [limit]
    (default 5). *)
val recent_tools_for_keeper : ?limit:int -> string -> string list

(** Repeated-failure guardrail threshold sourced from
    [Env_config.KeeperToolExec.max_consecutive_tool_failures].
    A tool is blocked after this many consecutive failures with the
    same (tool_name, args_hash) key; resets on success. *)
val max_consecutive_failures : int

(** Normalize a raw tool result string into the canonical JSON
    envelope. Success → [{"ok":true,"result":...}]; failure →
    [{"ok":false,"error":...,"detail":...}]. Plain text is wrapped
    as a string under [result] / [error]. *)
val normalize_tool_result : success:bool -> string -> string

(** Build the structured, recoverable envelope used when a keeper tool
    raises mutex EDEADLK / "Resource deadlock avoided". *)
val transient_mutex_contention_tool_error :
  tool_name:string ->
  error_text:string ->
  ?backtrace:string ->
  unit ->
  string

(** Max chars for the SSE error preview rendered to dashboards. *)
val sse_error_preview_max_chars : int

(** Build the per-tool handler closure used by both internal and
    alias tool entries. The closure dispatches via
    [execute_keeper_tool_call_with_outcome] using [~name] as the
    INTERNAL tool name (telemetry SSOT). [?translate_input]
    reshapes incoming JSON from a public alias schema to the
    internal payload (identity by default). *)
val make_keeper_tool_handler :
  name:string ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ctx_snapshot:Keeper_types.working_context ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  ?turn_sandbox_factory_git:Keeper_sandbox_factory.t ->
  exec_cache:Masc_exec.Exec_cache.t option ->
  ?search_fn:(query:string -> max_results:int -> Yojson.Safe.t) ->
  ?on_tool_called:(string -> unit) ->
  ?translate_input:(Yojson.Safe.t -> Yojson.Safe.t) ->
  failure_counts:(string, int) Hashtbl.t ->
  unit ->
  Yojson.Safe.t -> bool * string

(** Build the keeper's full [tool_bundle]: internal tools +
    alias-registered (public name) tools that translate input to
    internal payloads. The cleanup thunk releases per-turn sandbox
    runtimes (Docker case). *)
val make_tool_bundle :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ctx_snapshot:Keeper_types.working_context ->
  ?search_fn:(query:string -> max_results:int -> Yojson.Safe.t) ->
  ?on_tool_called:(string -> unit) ->
  unit ->
  tool_bundle

(** Convenience over [make_tool_bundle] returning only [.tools]. *)
val make_tools :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ctx_snapshot:Keeper_types.working_context ->
  ?search_fn:(query:string -> max_results:int -> Yojson.Safe.t) ->
  ?on_tool_called:(string -> unit) ->
  unit ->
  Agent_sdk.Tool.t list
