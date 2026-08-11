(** Admin-only durable execution records for model-driven Keeper exact-output
    lanes. Input/output values are exact. *)

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

type persistence_state =
  | Not_persisted
  | Durability_unknown

type persistence_failure =
  { detail : string
  ; state : persistence_state
  }

type run_status =
  | Running
  | Completed of
      { outcome : outcome
      ; elapsed_s : float
      ; output : Yojson.Safe.t
      }
  | Completion_persistence_failed of
      { intended_outcome : outcome
      ; elapsed_s : float
      ; output : Yojson.Safe.t
      ; failure : persistence_failure
      }

type run_input = Exact_input of Yojson.Safe.t

type run =
  { run_id : string
  ; lane : lane
  ; subject_id : string
  ; actor : string
  ; started_at : float
  ; input : run_input
  ; status : run_status
  }

type t

type completion_error =
  | Unknown_run
  | Persistence_failed of persistence_failure

val completion_error_to_string : completion_error -> string

(** Current-only durable registry with the closed [run_input] contract. *)
val storage_filename : string

val create : ?path:string -> unit -> t
val replay : string -> t

val register_running
  :  t
  -> run_id:string
  -> lane:lane
  -> subject_id:string
  -> actor:string
  -> started_at:float
  -> input:run_input
  -> unit

val mark_completed
  :  t
  -> run_id:string
  -> outcome:outcome
  -> elapsed_s:float
  -> output:Yojson.Safe.t
  -> (unit, completion_error) result
(** Record an observation-plane completion without taking ownership of the
    caller's primary lifecycle. Persistence failures are returned rather than
    raised. The durable core entry remains [Running], while [get]/[list_runs]
    expose [Completion_persistence_failed] with an explicit durability state;
    callers never silently present a terminal run as still executing. *)

val list_runs : t -> run list
val get : t -> run_id:string -> run option
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
