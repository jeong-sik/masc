(** Bounded observation registry for completion-authority reviews. *)

type outcome =
  | Approved
  | Rejected of { reason : string }
  | Contract_rejected of { detail : string }
  | Not_reviewed of
      { gate : string
      ; detail : string
      }
  | Commit_failed of { detail : string }
  | Raised of { detail : string }

type tool_observation =
  { tool_name : string
  ; input : Yojson.Safe.t
  ; disposition : (unit, unit, unit) Tool_result.disposition
  ; output_excerpt : string
  ; output_truncated : bool
  ; duration_ms : float
  }

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
val observe_tool_result : input:Yojson.Safe.t -> Tool_result.result -> tool_observation

(** Called after a registry mutation is visible. The server installs a WS
    invalidation broadcaster; library-only users keep the no-op default. *)
val change_observer_fn : (unit -> unit) Atomic.t
type global_install_error = Already_installed

val global : unit -> t
val install_global : t -> (unit, global_install_error) result
val max_completed_retained : int
