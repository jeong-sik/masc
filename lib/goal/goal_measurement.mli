(** Explicit, evidence-bearing observations of a Goal's declared metric.
    Observations never advance the Goal phase or certify its success. *)

type t = private {
  id : string;
  goal_id : string;
  criterion_revision : string;
  observed_value : string;
  evidence : string;
      (** An Evidence Reference that
          {!Workspace_verification_store.classify_evidence_reference} resolves
          ([artifact:], [note:], [board:] or [fusion:]), trimmed; an
          [artifact:] path also passes
          {!Workspace_verification_store.valid_producer_relative_path}. A row
          is built only after that check, on record and on load. *)
  actor : string;
  recorded_at : string;
}

type observation = (t option, string) result
(** [Ok None] means that the exact Goal and its current criterion revision
    have no recorded measurement. [Error reason] means the measurement source
    was unavailable, not that a measurement was absent or a target unmet. *)

type receipt = private {
  measurement : t;
  goal_at_recording : Goal_store.goal;
}
(** The observation and immutable Goal returned by the same locked
    transaction. The Goal is the lifecycle state at recording, not a later
    read or a completion judgment. Only the measurement is persisted. *)

type error =
  | Invalid_request of string
  | Conflict of string
  | Store_error of string

val error_to_string : error -> string

val to_yojson : t -> Yojson.Safe.t

val receipt_fields : receipt -> (string * Yojson.Safe.t) list
(** Shared MCP/HTTP success fields: [measurement_status = reported_only],
    [measurement], [goal_at_recording], and [completion_effect = unchanged].
    Transport success envelopes are supplied by their existing callers.
    Recording certifies no target, verifier proof, or human confirmation. *)

val path : Workspace_utils.config -> string
(** The measurement snapshot; its recovery mirror is this path with
    [.last-good] appended. *)

val load : Workspace_utils.config -> (t list, string) result
(** An unreadable primary is an error. A missing primary with an existing
    recovery mirror is an error, rather than an empty snapshot. There is at
    most one observation per Goal; a new one replaces its previous revision. *)

val latest_for_goal : (t list, string) result -> Goal_store.goal -> observation
(** Select from an already-read source by exact Goal ID and current criterion
    revision. A failed authoritative read stays [Error], independently of the
    Goal store. This pure observation performs no source read or state change. *)

val observation_to_yojson : observation -> Yojson.Safe.t
(** The existing reported, not_recorded, or unavailable wire projection of
    an observation. A reported value does not certify target attainment. *)

val projection :
  (t list, string) result -> Goal_store.goal -> Yojson.Safe.t
(** Observe a Goal and serialize that observation with
    {!observation_to_yojson}; the wire states and fields are unchanged. *)

val record :
  Workspace_utils.config ->
  goal_id:string ->
  criterion_revision:string ->
  observed_value:string ->
  evidence:string ->
  actor:string ->
  (receipt, error) result
(** Bind an explicit value and evidence to the exact current criterion under
    the Goal lock. The value is displayed verbatim; no numeric comparison or
    completion inference is performed. Evidence that is not a resolvable
    Evidence Reference is [Invalid_request]. The Goal phase is not consulted:
    a Completed or Dropped Goal still takes an observation, since recording
    one never moves the phase. The receipt names that unchanged Goal from
    the transaction that recorded the observation. *)

val remove_goal : Workspace_utils.config -> goal_id:string -> (unit, string) result
(** Drop the observation of a deleted Goal, so the snapshot stays bounded by
    the Goals that exist. [Ok ()] without a write when the Goal has none. *)

val record_json :
  Workspace_utils.config -> actor:string -> Yojson.Safe.t -> (receipt, error) result
(** Strict four-field request decoder shared by the operator and Keeper HTTP
    routes. The authenticated actor is supplied by the route. *)
