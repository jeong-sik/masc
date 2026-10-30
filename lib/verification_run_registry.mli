(** Bounded observation registry for completion-authority reviews. *)

type infrastructure_stage =
  | Review_preparation
  | Lookup_surface

(** [Approved] carries the reviewer's stated reason, the same way [Rejected]
    does. It may be empty: rows written before the reviewer channel carried it
    read back that way, and the reviewer is not refused for omitting it. *)
type outcome =
  | Approved of { reason : string }
  | Rejected of { reason : string }
  | Infrastructure_unavailable of
      { stage : infrastructure_stage
      ; detail : string
      }
  | Not_reviewed of
      { gate : string
      ; detail : string
      }
  | Commit_failed of { detail : string }
  | Execution_pending of { detail : string }
  | Execution_repair_required of { detail : string }
  | Raised of { detail : string }
  | Review_cancelled of { detail : string }
      (** The review fiber was cancelled mid-flight (shutdown, owner stop).
          Before this constructor a cancelled review left no completion at
          all — the run stayed Running in memory and vanished on the next
          replay (lane audit W6). *)
  | Superseded_by of { authority : string }
      (** The reviewer's verdict arrived after another authority — typically a
          HITL human confirmation — had already closed the Task. The late
          verdict is recorded as superseded rather than committed, so the run
          does not read as a commit failure and no [Stalled] board post is
          raised for it. *)

type tool_observation =
  { tool_name : string
  ; input : Yojson.Safe.t
  ; disposition : (unit, unit, unit) Tool_result.disposition
  ; output_excerpt : string
  ; output_truncated : bool
  ; duration_ms : float
  ; finished_at : float
  }

val tool_observation_to_yojson : tool_observation -> Yojson.Safe.t

val tool_observation_of_yojson :
  Yojson.Safe.t -> (tool_observation, string) result

type run_status =
  | Running
  | Completed of
      { outcome : outcome
      ; evaluator_runtime : string option
      ; elapsed_s : float
      ; tools : tool_observation list
          (** Observations collected by this host attempt. A reconciliation
              wake does not reconstruct the original model's lookup history. *)
      }

type run =
  { verification_id : string
  ; task_id : string
  ; producer : string
  ; authority_kind : string
  ; authority_actor : string
  ; started_at : float (** Host attempt start, including a reconciliation wake. *)
  ; status : run_status
  }

type t

val create : ?path:string -> unit -> t
val replay : string -> t

val register_running
  :  t
  -> verification_id:string
  -> task_id:string
  -> producer:string
  -> authority_kind:string
  -> authority_actor:string
  -> started_at:float
  -> unit

val mark_completed
  :  t
  -> verification_id:string
  -> outcome:outcome
  -> tools:tool_observation list
  -> ?evaluator_runtime:string
  -> elapsed_s:float
  -> unit
  -> unit
(** Complete a registered review. An unknown [verification_id] is logged and is
    not written to the append-only log. *)

type publication_source_error
(** The original current-history error from the canonical registry transaction.
    Its typed cause is retained; {!publication_error_to_string} renders it for
    diagnostics. *)

type publication_error =
  | Expected_not_completed
  | Conflict
  | Current_source_unavailable of publication_source_error
  | Invalid_change of string
  | Publication_failed of Run_registry_core.persistence_failure

val publication_error_to_string : publication_error -> string

val publish_terminal_confirmed
  :  t
  -> expected:run
  -> (unit, publication_error) result
(** Confirm the supplied immutable terminal row in one durable current-history
    transaction. An absent row is registered and completed with its original
    fields; an identical running registration receives that completion; an
    identical completed row is confirmed without appending. Every differing
    registration, start time or completion conflicts. A running [expected] is
    refused.

    Success confirms historical durable publication even if display retention
    immediately removes the row. Volatile, uninitialized, malformed or incomplete
    history is refused through the canonical transaction. Change notification
    runs only after confirmation and is separate from that transaction.
    Cancellation propagates. *)

val list_runs : t -> run list
val get : t -> verification_id:string -> run option
val outcome_label : outcome -> string
val infrastructure_stage_label : infrastructure_stage -> string
val status_label : run_status -> string
val run_to_yojson : run -> Yojson.Safe.t
val completed_run_of_yojson : Yojson.Safe.t -> (run, string) result
(** Decode a terminal {!run_to_yojson} payload using the canonical registration
    and completion codecs. Running status, unknown fields and duplicate fields
    are refused; the original tool observations and runtime are retained. *)
val observe_tool_result
  :  input:Yojson.Safe.t
  -> finished_at:float
  -> Tool_result.result
  -> tool_observation

(** Called after a registry mutation is visible. The server installs a WS
    invalidation broadcaster; library-only users keep the no-op default. *)
val change_observer_fn : (unit -> unit) Atomic.t
type global_install_error = Already_installed

val global : unit -> t
val install_global : t -> (unit, global_install_error) result
val storage_filename : string
val max_completed_retained : int

val cut_replay_log : execute:bool -> string -> Run_registry_core.cut_report
(** Deployment-time store cut for {!storage_filename}. See
    {!Run_registry_core.Make.cut_replay_log}. *)
