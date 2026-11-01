(** Durable composition evidence, partitioned by exact immutable Skill
    reference and appended per composition run: each run is stored under its
    own [composition_run_id], so concurrent runs never overwrite each other
    and [load_latest] selects the record with the greatest [recorded_at].
    The producer writes the typed executor settlement directly; readers never
    scan the fleet tool-call log or obsolete single-file layouts. *)

type t

module Node_execution_origin : sig
  (** Execution provenance shared by the executor and strict evidence codec.
      It is independent of the node's execution disposition. *)
  type t = Fresh_dispatch | Retained_completion | Dispatch_refused

  val to_string : t -> string
  val of_string : string -> (t, string) result
end

type error =
  | Invalid_record of string
  | Read_failed of Fs_compat.owned_regular_file_read_error
  | Directory_prepare_failed of Keeper_fs_durable_directory.failure
  | Lock_failed of File_lock_eio.durable_lock_error
  | Write_failed of Keeper_fs.durable_write_error

type save_outcome =
  | Saved
  | Saved_with_lock_release_error of File_lock_eio.durable_lock_error

val make :
  reference:Skill_reference.t ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  parent_invocation:Agent_core.Tool_contract.Invocation.t ->
  request_id:string option ->
  keeper_name:string ->
  composition_tool:string ->
  composition_execution:Keeper_tool_composition_catalog.execution_mode ->
  result:Tool_result.result ->
  executor_settlements:Yojson.Safe.t list ->
  (t, error) result
(** Every settlement requires a canonical [execution_origin] alongside the
    exact node identity, schedule and Tool_result projection. Missing,
    duplicated and unknown origin values are refused by both make and load. *)

val save_latest : Workspace.config -> t -> (save_outcome, error) result
type duration_statistics = private
  { samples : int
  ; mean_ms : float option
  ; min_ms : float option
  ; p50_ms : float option
  ; p95_ms : float option
  ; max_ms : float option
  }
type statistics = private
  { records : int
  ; completed : duration_statistics
  ; failed : duration_statistics
  ; deferred : int
  ; first_recorded_at : float option
  ; last_recorded_at : float option
  }
type run_summary = private
  { run_id : Keeper_tool_plan.Composition_run_id.t
  ; keeper : string
  ; execution : Keeper_tool_composition_catalog.execution_mode
  ; request_id : string option
  ; disposition : (unit, unit, unit) Tool_result.disposition
  ; duration_ms : float
  ; recorded_at : float
  }
val run_summary : t -> run_summary
val run_summary_to_yojson : run_summary -> Yojson.Safe.t
val run_summary_of_yojson : Yojson.Safe.t -> (run_summary, error) result
(** Payload-free observation metadata; disposition reuses Tool_result's closed
    sum. This does not admit or retry an execution. *)
type observation = private { latest : t option; runs : t list; statistics : statistics }

val statistics : t list -> statistics
(** One sample per original run id, selecting its most recently recorded
    result. Means describe the stored executor result duration, not
    end-to-end asynchronous queue, dependency wait or model latency. Deferred
    results are counted separately and never enter terminal duration statistics.
    Percentiles use the nearest-rank method on each outcome's exact samples.
    The window bounds describe when the selected results were recorded, not
    when executions started. Empty observations have null bounds and durations. *)
val statistics_to_yojson : statistics -> Yojson.Safe.t
val load_observation : Workspace.config -> Skill_reference.t -> (observation, error) result
(** Read the exact-reference partition once. [runs] is newest first, with the
    same deduplicated original runs used for latest selection and statistics.
    A read error refuses all three projections. *)
val load_latest : Workspace.config -> Skill_reference.t -> (t option, error) result
val reference : t -> Skill_reference.t
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, error) result
val error_to_string : error -> string
