(** Durable Goal proof requests and verdicts bound to the exact success-criterion
    revision. Pending requests never expire. Mutations require the primary
    ledger; recovery mirrors may supply historical reads, never write authority.
    Callers hold the Goal lock before acquiring this ledger's lock when they
    bind or commit a request against the current Goal. *)

type verdict_outcome =
  | Proven
  | Refuted of { reason : string }

type verdict = {
  outcome : verdict_outcome;
  request_id : string;
  criterion : Goal_store.criterion;
  verification_run_id : string;
      (** Exact Goal-verifier attempt whose durable run record contains the
          evaluator and tool observations supporting this verdict. *)
  authority : Masc_domain.completion_authority;
      (** Typed provenance, reused from the Task completion protocol. The
          stage-2 verifier lane commits with its own run identity
          (RFC-0387 §4.3). *)
  evidence : string;
  recorded_at : string;
}

type confirmation = { operator_id : string; confirmed_at : string }

type completion_state =
  | Completion_idle
  | Proof_pending of { requested_at : string; request_id : string; criterion : Goal_store.criterion }
  | Proof_proven of verdict
  | Proof_refuted of verdict
  | Human_confirmed of verdict * confirmation

type record = {
  goal_id : string;
  completion : completion_state;
  submitted_evidence : Workspace_verification_store.submitted_evidence_item list;
  updated_at : string;
}

val default_record : goal_id:string -> record
(** The explicit pre-verification state: [Completion_idle]. Used to render
    goals that have no ledger row. *)

(** {1 Codecs} *)

val record_to_yojson : record -> Yojson.Safe.t
(** Historical record without a current-Goal comparison. *)

type criterion_relation = Current | Stale_criterion

val relation_for_goal : goal:Goal_store.goal -> record -> criterion_relation

val record_to_yojson_for_goal : goal:Goal_store.goal -> record -> Yojson.Safe.t
(** Current-Goal projection. A mismatched criterion is [stale_criterion], with
    its historical completion retained under [historical_completion]. It must
    not be rendered as a current proven verdict. *)

(** {1 Persistence} *)

val verifications_path : Workspace_utils.config -> string
(** [{!Workspace_utils.masc_dir} / "goal_verifications.json"]. *)

(** {1 Queries}

    Reads fail LOUD: a store that does not decode is an [Error], never a
    silent "not verified yet" — a corrupt ledger must be visible as a ledger
    error to every consumer. *)

val load_records :
  Workspace_utils.config -> (record list, string) result
(** Loads every ledger row once. Bulk consumers (dashboard endpoints, goal
    listings) call this once per request and join in memory rather than
    re-decoding the store per goal. *)

val get_record :
  Workspace_utils.config ->
  goal_id:string ->
  (record option, string) result
(** Single-row read: [Ok None] only when the store decoded and holds no row
    for [goal_id]. *)

val load_records_authoritative :
  Workspace_utils.config -> (record list, string) result
(** Bulk primary-only read for current Goal projections and mutation decisions. *)

val get_record_authoritative :
  Workspace_utils.config -> goal_id:string -> (record option, string) result
(** Primary-only read for transition and reconciliation decisions. A missing
    primary with an existing mirror is an error, not an empty ledger. *)

val ledger_error_to_yojson : string -> Yojson.Safe.t
(** The explicit "ledger could not be read" marker consumers render in place
    of a verification record: [{"state": "ledger_error", "detail": …}]. *)

(** {1 Mutations} *)

type reopen_outcome =
  | Proof_unchanged of record option
  | Proof_reset of record

val reopen_goal :
  Workspace_utils.config -> goal_id:string -> actor:string -> note:string option ->
  (Goal_store.goal * reopen_outcome * bool, string) result
(** Re-evaluates Reopen under the Goal lock, archives/resets proof under the
    ledger lock, then writes the phase before releasing the Goal lock. The bool
    reports an actual phase change. Archive failure leaves the prior phase.
    Already-Executing preserves every existing proof and pending request. Call outside an existing Goal transaction. Archive
    or ledger writes followed by later persistence failure may be retried; this
    is serialized across the two stores, not a cross-file atomic filesystem write. *)

val mark_proof_pending :
  ?submitted_evidence:Workspace_verification_store.submitted_evidence_item list ->
  Workspace_utils.config ->
  goal_id:string ->
  criterion:Goal_store.criterion ->
  (record, string) result
(** Persist before invoking a reviewer. The same pending criterion and exact
    submitted evidence return the identical request. Omitted evidence preserves
    the same criterion's prior snapshot, including after refutation; explicit
    evidence replaces it. A changed criterion does not inherit omitted evidence.
    Changed evidence, criterion, or refutation creates a new request identity. A proven current criterion refuses
    replacement; a historical proof for another criterion may be superseded. *)

val record_proof_verdict :
  Workspace_utils.config ->
  goal_id:string ->
  verdict ->
  (record, string) result
(** Requires the exact pending request identity and criterion. A replay of the
    identical proof/provenance payload returns the stored record without rewriting
    its original timestamp, even if delivered with a later observation time. Same-outcome verdicts from another request, run, criterion, or
    with changed evidence are conflicts. *)

val validate_state_json : Yojson.Safe.t -> (unit, string) result
(** Pure current-schema validation. Does not read, repair or write a store. *)

val record_human_confirmation : Workspace_utils.config -> goal_id:string -> verdict -> operator_id:string -> (record, string) result
(** Caller holds the Goal transaction and supplies token-bound operator identity. *)
