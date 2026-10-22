(** Host-owned facts about one retained request. Recording a fact does not
    dispatch a worker, validate a model answer, authorize an effect or save a
    domain state. The original host adapter owns all of those boundaries. *)
type observation = Waiting of Yojson.Safe.t | Outcome_unknown of Yojson.Safe.t
  | Absent of Yojson.Safe.t
type refusal_stage = Before_dispatch | Execution
type refusal = { stage : refusal_stage; evidence : Yojson.Safe.t }
type change = { before : Yojson.Safe.t; after : Yojson.Safe.t }
type commit = { judgment : Yojson.Safe.t; change : change }
type event =
  | Dispatch_intended
  | Admission_declined of Yojson.Safe.t
  | Execution_observed of observation
  | Judgment_retained of Yojson.Safe.t
  | Commit_intended of change
  | Commit_uncertain of Yojson.Safe.t
  | Commit_retry_observed of Yojson.Safe.t
  | Commit_observed of Yojson.Safe.t
  | Commit_conflicted of Yojson.Safe.t
  | Refused of refusal
type phase = Captured | Admission_wait of Yojson.Safe.t | Dispatch_pending of observation option
  | Judged of Yojson.Safe.t | Committing of commit
  | Commit_unknown of commit * Yojson.Safe.t | Finished of commit
  | Conflicted of commit * Yojson.Safe.t | Rejected of refusal
type t
val captured : t
val phase : t -> phase
val events : t -> event list
val append : t -> event -> (t, string) result
(** Canonicalize payloads and validate the next transition. Dispatch is recorded
    before each admission RPC. Only an explicit pre-admission capacity refusal
    allows a later admission of the same captured request. Waiting, unknown and
    worker absence never permit redispatch. A capacity refusal is accepted only
    immediately after dispatch intent, before any execution observation.
    A late original judgment preserves earlier observations in the history.
    Commit retry requires a fresh exact before-state observation; confirmation
    requires the exact captured after-state. Neither observation performs I/O. *)
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Strictly decode and fold the complete ordered history from Captured.
    Unknown fields/events, invalid JSON and invalid transitions are errors. *)
