(** Every date-split JSONL store, in one closed list.

    A store is a directory written as [YYYY-MM/DD.jsonl]. The list says where
    each one lives, so a writer, a reader and the retention pass all name the
    same directory, and a store cannot be opened at a path that no list knows
    about (RFC dated-stores-take-retention-from-one-list).

    Which root a store sits under is part of its entry. In the default
    cluster the two roots are one directory. Under [MASC_CLUSTER_NAME] they
    differ, and a store written under one root and read or pruned under the
    other is lost to its reader. *)

(** Stores under [<base>/.masc], whichever cluster the process runs in. *)
module Base : sig
  type t =
    | Transition_audit
    | Audit_approvals
    | Tool_events
    | Keeper_wake_payload
    | Verdicts

  val all : t list

  val dirname : t -> string
  (** The store's directory name under [<base>/.masc]. *)
end

(** Stores under the cluster's root. *)
module Cluster : sig
  type t =
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
  (** The store's path below the cluster root. One segment for every store
      but schedule signals, which sit beside the schedule ledger. *)
end

(** Stores under [<cluster root>/keepers/<keeper>/], one per keeper. *)
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
  | Base of Base.t
  | Cluster of Cluster.t
  | Keeper of Keeper.t
  | Reaction_ledger
      (** [<base>/.masc/keepers/<keeper>/reaction-ledger/<generation>/] *)
  | Decision_audit  (** [<base>/.masc/decision_audit/<keeper directory>/] *)

val all : t list
(** Every store, derived from the constructors. *)

type location
(** The directory of one store. Only the functions below make one. *)

val base : base_path:string -> Base.t -> location
(** Under [<base_path>/.masc]. The root is worked out here, so a base store
    cannot be opened under a cluster's root. *)

val reaction_ledger :
  base_path:string -> keeper:string -> generation:string -> location
(** [generation] is the storage generation directory the ledger's wire
    module owns. *)

val decision_audit : base_path:string -> keeper_dirname:string -> location
(** [keeper_dirname] is the keeper's name already made into a directory
    name by the decision audit's owner. *)

type cluster_root
(** The root of the cluster this process runs in. *)

val cluster_root : string -> cluster_root
(** The caller states that the directory is the cluster's root:
    [Workspace.masc_dir config], or a [masc_root] string handed down from
    it. [<base>/.masc] is that directory only in the default cluster. *)

val cluster : cluster_root -> Cluster.t -> location
val keeper : cluster_root -> keeper:string -> Keeper.t -> location

val dir : location -> string

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

val locations_on_disk : base_path:string -> cluster_root -> t -> location list
(** Every directory of the store that exists now. A store kept per keeper
    yields one location for each keeper directory found on disk, so the
    files of a keeper that is gone are still found. The reaction ledger
    also yields one per generation directory. *)

val dated_path : location -> ts:float -> Jsonl_writer.dated_path
(** The day file a row stamped [ts] belongs to. *)

val dated_path_now : location -> Jsonl_writer.dated_path
