(** Masc_context_injector — OAS context_injector for MASC agents.

    Writes temporal and tool metadata to {!Agent_sdk.Context.t} after each
    tool execution.  Shared between Keeper and Worker paths.

    The write path:
    {[
      context_injector (after tool exec)
        → Context.set key value  (via OAS Pipeline Stage 5)
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

val make : config:config -> unit -> Agent_sdk.Hooks.context_injector
(** Build an OAS [context_injector] function.

    Thread-safe: uses {!Atomic} counters internally.
    Returns [Some injection] for every tool call (never [None]). *)

val render_temporal_summary : Agent_sdk.Context.t -> string option
(** Read temporal keys from [Context.t] and render a one-line summary.

    Returns [None] when no tool has executed yet (turn 0).
    Format: [[Temporal] time=<ISO8601> elapsed=<N>s tools=<N> last=<name>(<outcome>)] *)

val iso8601_of_float : float -> string
(** Format a Unix timestamp as ISO 8601 UTC string. *)

(** {2 Context keys}

    Constants for the keys written by {!make} and read by
    {!render_temporal_summary}.  Useful for testing and
    [AppendInstruction.FromContext] wiring. *)

val key_wall_time : string
val key_elapsed_seconds : string
val key_tool_call_count : string
val key_last_tool_name : string
val key_last_tool_outcome : string
val key_tool_success_count : string
val key_tool_error_count : string
