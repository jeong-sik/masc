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
  | Structured_response_failure

(** Who prunes an artifact and by which rule. *)
type retention =
  | Dated_jsonl_operator_window
  | Startup_flat_file_mtime
  | Raw_trace_reachability_window
  | Operator_owned_evidence

type entry =
  { producer : string
  ; authority_source : string
  ; truth_role : truth_role
  ; consumers : string list
  ; retention : retention
  }

val entry : artifact -> entry
(** The registry row of [artifact]. A match over the variant, so every
    artifact has exactly one row and a new artifact does not compile until it
    has one. *)

val validate : unit -> string list
(** Empty means every artifact names a producer, an authority source and at
    least one consumer. *)

val to_yojson : unit -> Yojson.Safe.t
