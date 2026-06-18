(** Durable ledger events for ToolBatch execution and replay.

    Events are append-only, JSON-serializable, and intentionally minimal:
    they record what happened to a job or batch so that a restarted runtime
    can skip already-completed work. A future phase will add event history
    compaction and snapshotting; this module only defines the event grammar. *)

(** Classification of a job failure for replay policy. *)
type error_class =
  | Transient
  | Policy
  | Runtime
[@@deriving yojson, show, eq]

(** Opaque artifact reference carried by [Job_succeeded].

    In Phase 1 this is a JSON value; later phases may introduce a structured
    reference with storage backend URI, hash, and provenance. *)
type artifact_ref = Yojson.Safe.t [@@deriving yojson, show]

(** Snapshot of a batch at creation time. *)
type batch_created = {
  batch_id : string;
  parent_turn_id : string option;
  parent_goal_id : string option;
}
[@@deriving yojson, show, eq]

type t =
  | Batch_created of batch_created
  | Job_scheduled of string
  | Job_started of string
  | Job_progress of string * Yojson.Safe.t
  | Job_succeeded of string * artifact_ref
  | Job_failed of string * error_class * string
  | Job_cancelled of string * string
  | Batch_finished of string * string
[@@deriving yojson, show]

val job_id : t -> string option
(** Return the affected job id, if any. [Batch_created] and [Batch_finished]
    carry no job id. *)

val batch_id : t -> string option
(** Return the affected batch id, if the event carries one. *)
