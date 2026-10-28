(** Every date-split JSONL store, in one closed list.

    A store is a directory written as [YYYY-MM/DD.jsonl]. The list says where
    each one lives, so a writer, a reader and the retention pass all name the
    same directory, and a store cannot be opened at a path that no list knows
    about (RFC dated-stores-take-retention-from-one-list). *)

(** Stores directly under [<base>/.masc]. *)
module Root : sig
  type t =
    | Transition_audit
    | Audit_approvals
    | Tool_events
    | Keeper_wake_payload
    | Verdicts
    | Audit
    | Telemetry
    | Events
    | Activity_events
    | Tool_calls
    | Tool_usage
    | Agent_core_events
    | Costs
    | Provider_usage_history
    | Wire_capture
    | Schedule_signals
    | Telemetry_coverage_gaps

  val all : t list

  val relative_path : t -> string
  (** The store's path below [<base>/.masc]. One segment for every store but
      schedule signals, which sit beside the schedule ledger. *)
end

(** Stores under [<base>/.masc/keepers/<keeper>/], one per keeper. *)
module Keeper : sig
  type t =
    | Metrics
    | Execution_receipts
    | Turn_records
    | Provider_inputs
    | Memory_recall_artifacts
    | Crash_events
    | Continuity_requests

  val all : t list

  val dirname : t -> string
  (** The store's directory name under [keepers/<keeper>/]. *)
end

type t =
  | Root of Root.t
  | Keeper of Keeper.t
  | Reaction_ledger
      (** [<base>/.masc/keepers/<keeper>/reaction-ledger/<generation>/] *)
  | Decision_audit  (** [<base>/.masc/decision_audit/<keeper directory>/] *)

val all : t list
(** Every store, derived from the constructors. *)

type root
(** The workspace's state root, [<base>/.masc]. *)

val root_of_base_path : base_path:string -> root

val root_of_masc_dir : string -> root
(** The caller states that the directory is [<base>/.masc]:
    [Workspace.masc_dir config], or a [masc_root] string handed down from
    it. *)

type location
(** The directory of one store. Only the functions below make one. *)

val at : root -> Root.t -> location
val keeper : root -> keeper:string -> Keeper.t -> location

val reaction_ledger : root -> keeper:string -> generation:string -> location
(** [generation] is the storage generation directory the ledger's wire
    module owns. *)

val decision_audit : root -> keeper_dirname:string -> location
(** [keeper_dirname] is the keeper's name already made into a directory
    name by the decision audit's owner. *)

val dir : location -> string

val of_location : location -> t
(** The store the location was made for. *)

val pool_job_name : t -> string
(** The store's path below [<base>/.masc], with the keeper's directory
    written as [keeper/]: one name per store, whichever keeper it is. A pool
    job that reads the store carries it (RFC-0474 L4c). *)

(** How long a store's day files are kept. The prune pass reads it from
    here; a handle carries no retention of its own. *)
type retention =
  | Operator_window
      (** The workspace's window, which the prune pass is given. A window of
          zero or less keeps everything. *)
  | Fixed_days of int  (** A window the store's own reader depends on. *)
  | Own_days of (unit -> int)
      (** The store's own setting, read each time the pass runs. *)
  | Kept  (** Never removed by date. *)

val retention : t -> retention

val locations_on_disk : root -> t -> location list
(** Every directory of the store that exists now. A store kept per keeper
    yields one location for each keeper directory found on disk, so the
    files of a keeper that is gone are still found. The reaction ledger
    also yields one per generation directory. *)

val with_retention_root : root -> (Fs_compat.Retention_directory.t -> 'a) -> 'a option
(** Admit the physical BasePath (allowing its configured aliases), then bind
    the runtime-root entry without following it. No descendant is realpathed.
    This per-pass admission does not replace the server's boot lease. *)

val with_retention_location : location -> (Fs_compat.Retention_directory.t -> int) -> int

val fold_retention_directories :
  root -> Fs_compat.Retention_directory.t -> t ->
  f:(location -> Fs_compat.Retention_directory.t -> int) -> int
(** The same closed store geometry, traversed only through the held root.
    Location paths are labels/lock keys; they never authorize traversal. *)

(** A store's day file: [<dir>/YYYY-MM/DD.jsonl]. *)
type dated_path =
  { base_dir : string  (** The store's directory. *)
  ; month_dir : string  (** [YYYY-MM] *)
  ; day_file : string  (** [DD.jsonl] *)
  ; path : string
  }

val dated_path : location -> ts:float -> dated_path
(** The day file a row stamped [ts] belongs to, by the UTC calendar day
    [Jsonl_writer.utc_calendar_day] gives. *)

val dated_path_now : location -> dated_path
