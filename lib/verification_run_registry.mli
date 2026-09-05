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
  | Raised of { detail : string }
  | Review_cancelled of { detail : string }
      (** The review fiber was cancelled mid-flight (shutdown, owner stop).
          Before this constructor a cancelled review left no completion at
          all — the run stayed Running in memory and vanished on the next
          replay (lane audit W6). *)
  | Operator_routed
      (** The claim's verdict belongs to the operator (RFC-0415 §4.1): a
          cancel claim reached the system lane and was handed on without a
          review. No evaluator ran, so this is neither a verdict nor a lane
          failure; the Task waits on the operator's click. *)

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
      }

type run =
  { verification_id : string
  ; task_id : string
  ; producer : string
  ; authority_kind : string
  ; authority_actor : string
  ; started_at : float
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

val list_runs : t -> run list
val get : t -> verification_id:string -> run option
val outcome_label : outcome -> string
val status_label : run_status -> string
val run_to_yojson : run -> Yojson.Safe.t
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
