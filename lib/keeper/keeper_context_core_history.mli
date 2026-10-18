(** History JSONL persistence for keeper context.

    Every line carries the [turn_ref] of the turn that wrote it and a [kind]:
    ["message"] for a conversation message, ["tool_observation"] for the name
    and outcome of a tool the turn called. Appends are locked and durable; a
    line that cannot be written is logged, counted
    ([masc_keeper_history_fragment_failures_total]) and never fails the turn.
    Only a cancellation escapes. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type history_line_action =
  | Keep_main
  | Move_internal
  | Drop_line

(** {1 Wire vocabulary} *)

val key_ts_unix : string
val key_turn_ref : string
val key_kind : string
val key_source : string
val key_tool_name : string
val key_outcome : string
val kind_message : string
val kind_tool_observation : string

(** {1 Paths} *)

val main_history_path : session_dir:string -> string
val internal_history_path : session_dir:string -> string

(** {1 Writers}

    Both writers acquire the stable checkpoint session lock before the
    history file's append lock. An official-turn publisher can retain that
    same session lock while rereading fragments and publishing Memory.
    The append retains the configured history pathname so existing readers
    share the same per-path file mutex even through a symlinked session root.
    Callers must not already hold this session lock or acquire it after
    Memory's aggregate/snapshot locks. No inference runs under the lock.
    A completed append remains committed if settling the session lock fails;
    that failure is logged separately rather than reported as a lost line. *)

(** Append a conversation message, choosing [history.jsonl] /
    [history.internal.jsonl] from [source]. A prompt-only source writes
    nothing. *)
val persist_message :
  keeper_name:string ->
  turn_ref:Ids.Turn_ref.t ->
  ?source:string ->
  session_context ->
  Agent_core.Types.message ->
  unit

(** Append one tool observation to [history.internal.jsonl]: the canonical
    tool name and how the call ended. No arguments, no result body. *)
val persist_tool_observation :
  keeper_name:string ->
  turn_ref:Ids.Turn_ref.t ->
  session_context ->
  tool_name:string ->
  outcome:Tool_result.tool_call_outcome ->
  unit
