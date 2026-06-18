type error_class =
  | Transient
  | Policy
  | Runtime
[@@deriving yojson, show, eq]

type artifact_ref = Yojson.Safe.t [@@deriving yojson, show]

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

let job_id = function
  | Batch_created _ | Batch_finished _ -> None
  | Job_scheduled id
  | Job_started id
  | Job_succeeded (id, _)
  | Job_failed (id, _, _)
  | Job_cancelled (id, _) -> Some id
  | Job_progress (id, _) -> Some id

let batch_id = function
  | Batch_created b -> Some b.batch_id
  | Batch_finished (id, _) -> Some id
  | _ -> None
