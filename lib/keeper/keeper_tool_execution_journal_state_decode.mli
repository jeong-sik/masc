(** The events the journal appends, and how a journal file and a node's replay
    are read back.

    [event] builds an event record of one kind for a source hash, and [row]
    writes a JSON value as one line. [source_event],
    [source_observation_event] and [attempt_event] build the events that
    record a source, its observation and an attempt. [dependency_wait_json]
    encodes the dependency a deferred result waits on, and
    [result_read_dependency] says which dependency a result read waits on.
    [valid_dependency_wait] tells whether a deferred result recorded before
    its effect waits on the dependency its occurrence reads, and
    [owned_job_launch] tells whether an occurrence starts an owned job.
    [replay_for] decides what a retry of a node does, or refuses with
    [Replay_not_proven]. [decode_state] reads the text of a journal file into
    a [state].
    [Keeper_tool_execution_journal] includes this module. *)

open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_model

val event :
  string ->
  string ->
  (string * Yojson.Safe.t) list ->
  Yojson.Safe.t

val row : Yojson.Safe.t -> string

val source_event :
  source ->
  Yojson.Safe.t

val source_observation_event :
  string ->
  source_observation ->
  Yojson.Safe.t

val attempt_event :
  string ->
  occurrence ->
  Yojson.Safe.t

val dependency_wait_json :
  Keeper_composition_dependency.t option -> Yojson.Safe.t

val result_read_dependency :
  child_link Map.Make(String).t ->
  occurrence -> Keeper_composition_dependency.t option

val valid_dependency_wait :
  child_link Map.Make(String).t ->
  occurrence ->
  ('a, 'b, 'c) Tool_result.disposition ->
  Tool_result.failure_effect_disposition option -> Keeper_composition_dependency.t -> bool

val owned_job_launch :
  occurrence -> bool

val replay_for :
  child_link Map.Make(String).t ->
  binding ->
  Keeper_tool_plan.Node_id.t ->
  node_record option ->
  (replay,
   error)
  result

val decode_state :
  string -> (state, string) result
