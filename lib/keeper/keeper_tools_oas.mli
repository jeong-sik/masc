(** Keeper_tools_oas — Wrap keeper tools as [Agent_sdk.Tool.t] for [Agent.run].

    Bridges [Keeper_tool_dispatch_runtime.execute_keeper_tool_call] dispatch
    to [Agent_sdk.Tool.t list] via [Tool_bridge.oas_tool_of_masc]. Tool
    execution reads the current context from [ctx_snapshot]
    (immutable), enabling [Agent.run] to manage messages while
    keeper tools access the working context for status/metrics.

    @since Phase 4 — Keeper → Agent.run() migration *)

(** Bundle returned by [make_tool_bundle]: the [Agent_sdk.Tool.t list]
    plus a [cleanup] thunk that releases the per-turn sandbox
    runtimes. *)
type tool_bundle =
  { tools : Agent_sdk.Tool.t list
  ; cleanup : unit -> unit
  }

(** Per-keeper tool usage view from [Keeper_registry]. *)
val tool_usage_for_keeper : string -> (string * Keeper_types.tool_call_entry) list

(** Project [tool_usage_for_keeper] to a JSON array. *)
val tool_usage_json : string -> Yojson.Safe.t

(** Most-recently-used tool names for a keeper, capped to [limit]
    (default 5). *)
val recent_tools_for_keeper : ?limit:int -> string -> string list

(** Record an internal keeper tool call in the telemetry registry. *)
val record_keeper_internal_tool_call
  :  tool_name:string
  -> success:bool
  -> duration_ms:int
  -> unit

(** Normalize a raw tool result string into the canonical JSON
    envelope. Success → [{"ok":true,"result":...}]; failure →
    [{"ok":false,"error":...,"detail":...}], preserving structured
    [failure_class]/[recoverable]/[error_class] fields when present.
    Plain text is wrapped as a string under [result] / [error]. *)
val normalize_tool_result : success:bool -> string -> string

(* Handlers moved to [Keeper_tools_oas_handler] — see
   keeper_tools_oas_handler.mli for [make_keeper_tool_handler],
   [make_tool_bundle], and [make_tools]. *)


(** Build the per-tool handler closure used by both internal and
    alias tool entries. The closure dispatches via
    [execute_keeper_tool_call_with_outcome] using [~name] as the
    INTERNAL tool name (telemetry SSOT). [~input_schema] is the
    internal tool schema used for pre-execution validation. Public aliases
    validate their LLM-facing payload before translation to the internal
    payload. *)

(** Build the keeper's full [tool_bundle]: internal tools +
    alias-registered (public name) tools that translate input to
    internal payloads. The cleanup thunk releases per-turn sandbox
    runtimes (Docker case). *)

(** Convenience over [make_tool_bundle] returning only [.tools]. *)
