(** Masc_context_injector — AGENT_CORE context_injector for MASC agents.

    Writes temporal and tool metadata to {!Agent_core.Context.t} after each
    tool execution.  Shared between Keeper and Worker paths.

    The write path:
    {[
      context_injector (after tool exec)
        → Context.set key value  (via AGENT_CORE Pipeline Stage 5)
    ]}
    [Context.set] overwrites by key, so repeated tool calls keep this
    metadata surface bounded to the keys declared below rather than
    appending a fresh token-bearing block per call.

    The read path (caller must wire):
    {[
      render_temporal_summary ctx
        → "[Temporal] time=... elapsed=... tools=... last=...(ok)"
        → append to extra_system_context in before_turn_params hook
    ]}

    @since context_injector integration *)

type config = {
  start_time : float;
  (** [Unix.gettimeofday ()] at agent creation.
      Used to compute elapsed seconds. *)
}

val default_config : unit -> config
(** Create a config with [start_time = Unix.gettimeofday ()]. *)

val make : config:config -> unit -> Agent_core.Hooks.context_injector
(** Build an AGENT_CORE [context_injector] function.

    Thread-safe: uses {!Atomic} counters internally.
    Returns [Some injection] for every tool call (never [None]). *)

val render_temporal_summary : ?now:float -> Agent_core.Context.t -> string
(** Render a one-line temporal summary from [Context.t]. Total: the
    [time=] clock always renders (#32199 — a turn before any tool
    execution used to carry no clock at all, and hand-typed prose
    timestamps drifted by whole hours), while [elapsed=] appears only
    when the [key_session_start] anchor exists and [tools=]/[last=]
    only when the tool metadata keys exist.

    [time=] and [elapsed=] are recomputed from [now] (defaulting to
    {!Time_compat.now}) at render time — i.e. turn start — rather than
    read from the stored [key_wall_time], which reflects the last tool
    call and goes stale across idle turns. A keeper
    waking after an idle gap therefore sees the current wall clock, not a
    past tool-call timestamp. For current contexts, [elapsed] is
    [now - key_session_start] (seconds since the injector/session
    started). A retired-shape context (tools ran, no current anchor)
    renders without [elapsed=] rather than repairing it from any legacy
    key.

    [now] is a Unix timestamp in seconds; pass it to inject a fixed clock
    in tests.

    Returns [None] when no tool has executed yet (turn 0).
    Format: [[Temporal] time=<ISO8601> elapsed=<N>s tools=<N> last=<name>(<outcome>)] *)

val iso8601_of_float : float -> string
(** Format a Unix timestamp as ISO 8601 UTC string.
    Delegates to {!Masc_domain.iso8601_of_unix_seconds}. *)

(** {2 Context keys}

    Constants for the keys written by {!make} and read by
    {!render_temporal_summary}.  Useful for testing and
    [AppendInstruction.FromContext] wiring. *)

val key_wall_time : string
val key_session_start : string
val key_tool_call_count : string
val key_last_tool_name : string
val key_last_tool_outcome : string
val key_tool_success_count : string
val key_tool_error_count : string
