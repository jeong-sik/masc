(** Observed application of one declaration. This is read-only: no state here
    authorizes starting or stopping a worker. A file save is a separate fact.
    Callers bind the result to the exact source revision they reconciled. *)
type activity = Starting | Running | Stopping | Stopped | Worker_failed of string
type worker = {
  instance_id : string;
  matches_desired : bool;
  activity : activity;
}
type t =
  | Starting_worker
  | Cleaning_workers
  | Applied of string
  | Inactive
  | Failed of string list
  | Unknown of string list

val observe : enabled:bool -> complete:bool -> issues:string list -> workers:worker list -> t
(** [workers] contains every live and retained owner of the installation ID or
    its declaration path, including old revisions. [complete=false] prevents
    both Applied and Inactive. Stopped means cleanup was confirmed and its
    completion persisted, not merely that a worker disappeared from memory.
    Applied names a running owner; it does not certify its output or a Goal. *)
val to_json : t -> Yojson.Safe.t
