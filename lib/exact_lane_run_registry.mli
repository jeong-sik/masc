(** Admin-only durable execution records for model-driven Keeper exact-output
    lanes. Input/output values are exact. *)

type lane =
  | Librarian
  | Hitl_auto_judge
  | Board_attention

val all_lanes : lane list
(** Every registry lane, for consumers that enumerate the wire vocabulary
    (the standalone-lane projection and the TUI decoder). An independent
    constructor oracle pins this enumeration; replay exercises every exported
    lane, and language-boundary parity tests pin the wire keys. *)

val lane_key : lane -> string
(** The lane's wire identifier — the spelling the standalone-lane projection
    serves and the TUI decoder and dashboard TS parse. This is the one
    definition; a consumer that restates these strings drifts silently when
    a lane is added or renamed. *)

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
      ; selected_slot : string option
      }
  | Completion_persistence_failed of
      { intended_outcome : outcome
      ; elapsed_s : float
      ; output : Yojson.Safe.t
      ; selected_slot : string option
      ; failure : persistence_failure
      }

type run_input = Exact_input of Yojson.Safe.t

type run =
  { run_id : string
  ; lane : lane
  ; actor : string
  ; started_at : float
  ; input : run_input
  ; status : run_status
  }

type t

type completion_error =
  | Unknown_run
  | Invalid_selected_slot
  | Persistence_failed of persistence_failure

val completion_error_to_string : completion_error -> string

(** Current-only durable registry with the closed [run_input] contract. *)
val storage_filename : string

val max_completed_retained : int
(** How many completed runs survive a replay, PER LANE. Running entries are
    kept regardless, so this bounds finished work only; the bound is applied
    within each lane so the busiest lane (librarian) cannot evict the
    quietest lane's history (compaction fires only on a capacity refusal —
    lane audit W8).

    Derived from the page size of the surface that reads this store rather than
    copied from the sibling registries, which retain 64 and have no paging UI.
    A test pins that relation. *)

val cut_replay_log : execute:bool -> string -> Run_registry_core.cut_report
(** Deployment-time store cut for {!storage_filename}. See
    {!Run_registry_core.Make.cut_replay_log}. *)

val create : ?path:string -> unit -> t
val replay : string -> t

val register_running
  :  t
  -> run_id:string
  -> lane:lane
  -> actor:string
  -> started_at:float
  -> input:run_input
  -> unit

val mark_completed
  :  t
  -> run_id:string
  -> outcome:outcome
  -> elapsed_s:float
  -> selected_slot:string option
  -> output:Yojson.Safe.t
  -> (unit, completion_error) result
(** Record an observation-plane completion without taking ownership of the
    caller's primary lifecycle. Persistence failures are returned rather than
    raised. The durable core entry remains [Running], while [get]/[list_runs]
    expose [Completion_persistence_failed] with an explicit durability state;
    callers never silently present a terminal run as still executing. The
    labelled [selected_slot] argument forces every producer to state whether it
    owns an accepted exact-flow receipt. Blank slot identities are rejected. *)

val list_runs : t -> run list

(** A page of retained runs, newest first. [total] counts every retained run so
    a caller can report "50 of 5,908" without asking for the rest. *)
type run_page =
  { runs : run list
  ; total : int
  ; has_more : bool
  }

(** At most [limit] runs strictly older than [before] in the (started_at
    descending, run_id descending) order. [before] is the caller's own
    (started_at, run_id) from the previous page, never server state: the server
    remembers nothing between calls, and the run_id tie-break means two runs
    recorded in the same float second cannot straddle a page boundary.

    Listing everything was what made this surface unusable — 5,908 runs
    serialized to 246 MB on every load, and again on every refresh event. *)
val recent_runs : t -> limit:int -> before:(float * string) option -> run_page
val get : t -> run_id:string -> run option
val status_label : run_status -> string
(** Identity and outcome without either exact payload. A lane run embeds the
    captured template and actual input material needed to reconstruct its
    rendered prompt, so a list that carried payloads shipped hundreds of
    megabytes to draw a table of timestamps. *)
val run_summary_to_yojson : run -> Yojson.Safe.t

(** The whole record, exact payloads included. For one run at a time. *)
val run_to_yojson : run -> Yojson.Safe.t

(** Called after a registry mutation is durable/in-memory-visible. The server
    installs a WS invalidation broadcaster; tests and library-only users keep
    the no-op default. *)
val change_observer_fn : (unit -> unit) Atomic.t

type global_install_error = Already_installed

val global : unit -> t
val install_global : t -> (unit, global_install_error) result
