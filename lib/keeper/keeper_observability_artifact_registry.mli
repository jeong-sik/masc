(** Keeper observability artifact authority/consumer/retention registry.

    These stores explain execution; none is a command authority.  Keeping the
    inventory typed prevents a new JSONL projection from shipping without a
    reader and lifecycle owner. *)

type truth_role =
  | Execution_evidence
  | Derived_projection

type artifact =
  | Execution_receipt
  | Turn_record
  | Runtime_manifest
  | Activity_event
  | Metrics_snapshot
  | Raw_trace

type entry =
  { artifact : artifact
  ; producer : string
  ; authority_source : string
  ; truth_role : truth_role
  ; consumers : string list
  ; retention_owner : string
  ; retention_policy : string
  }

val entries : entry list

val validate : unit -> string list
(** Empty means every artifact has one unique identity, at least one consumer,
    and an explicit retention owner/policy. *)

val to_yojson : unit -> Yojson.Safe.t
