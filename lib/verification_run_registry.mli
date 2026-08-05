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

type run_status =
  | Running
  | Completed of
      { outcome : outcome
      ; evaluator_runtime : string option
      ; elapsed_s : float
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
val global : unit -> t
val set_global : t -> unit
val max_completed_retained : int
