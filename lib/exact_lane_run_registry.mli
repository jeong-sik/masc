(** Durable observation records for model-driven Keeper exact-output lanes. *)

type lane =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Compaction

type outcome =
  | Succeeded
  | Cancelled
  | Failed of
      { code : string
      ; detail : string
      }

type run_status =
  | Running
  | Completed of
      { outcome : outcome
      ; elapsed_s : float
      ; output : Yojson.Safe.t
      }

type run =
  { run_id : string
  ; lane : lane
  ; subject_id : string
  ; actor : string
  ; started_at : float
  ; input : Yojson.Safe.t
  ; status : run_status
  }

type t

val create : ?path:string -> unit -> t
val replay : string -> t

val register_running
  :  t
  -> run_id:string
  -> lane:lane
  -> subject_id:string
  -> actor:string
  -> started_at:float
  -> input:Yojson.Safe.t
  -> unit

val mark_completed
  :  t
  -> run_id:string
  -> outcome:outcome
  -> elapsed_s:float
  -> output:Yojson.Safe.t
  -> unit

val list_runs : t -> run list
val get : t -> run_id:string -> run option
val lane_key : lane -> string
val outcome_label : outcome -> string
val status_label : run_status -> string
val run_to_yojson : run -> Yojson.Safe.t

(** Called after a registry mutation is durable/in-memory-visible. The server
    installs a WS invalidation broadcaster; tests and library-only users keep
    the no-op default. *)
val change_observer_fn : (unit -> unit) Atomic.t

type global_install_error = Already_installed

val global : unit -> t
val install_global : t -> (unit, global_install_error) result
val max_completed_retained : int
