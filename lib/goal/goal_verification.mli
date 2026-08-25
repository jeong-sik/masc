(** Goal_verification — per-goal success-condition verification ledger
    (RFC-0387).

    Persists under [<base>/.masc/goal_verifications.json], separate from
    [goals.json] the way [Workspace_goal_index] keeps goal-task links separate:
    the [Goal_store.goal] record is constructed by literal in external callers,
    so verification state gets its own store.

    The store answers one question: did this goal reach its target? A
    [Completed] goal carries [Proof_proven verdict], so the verifier's exact
    run, authority, evidence, and timestamp read back as one durable record.

    Nothing here refuses a transition or a write because some other fact is
    not in the state it wants. A goal's force comes from what its verdict
    says, not from a branch that declines to record one.

    Mutation discipline mirrors [Goal_store]: locked read-modify-write, strict
    decode, and a store that does not decode refuses every mutation (the
    [Undecodable] path), recovery mirror included. Pending states have no
    wall-clock expiry; a refuted verdict stays on the record as preserved
    evidence until the next request supersedes it. *)

type verdict_outcome =
  | Proven
  | Refuted of { reason : string }

type verdict = {
  outcome : verdict_outcome;
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

type completion_state =
  | Completion_idle
  | Proof_pending of { requested_at : string }
  | Proof_proven of verdict
  | Proof_refuted of verdict

type record = {
  goal_id : string;
  completion : completion_state;
  updated_at : string;
}

val default_record : goal_id:string -> record
(** The explicit pre-verification state: [Completion_idle]. Used to render
    goals that have no ledger row. *)

(** {1 Codecs} *)

val record_to_yojson : record -> Yojson.Safe.t

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

val ledger_error_to_yojson : string -> Yojson.Safe.t
(** The explicit "ledger could not be read" marker consumers render in place
    of a verification record: [{"state": "ledger_error", "detail": …}]. *)

(** {1 Mutations}

    All are locked read-modify-writes that refuse an undecodable store.
    Stage 2 wires them: [mark_*_pending] are the durable requests the gate
    persists before any model call, and the verdict commits are what the
    verifier lane (or a manual [masc_goal_transition] with evidence) writes. *)

val mark_proof_pending :
  Workspace_utils.config ->
  goal_id:string ->
  (record, string) result
(** Records the durable completion-proof request (RFC-0387 §4.1, B3):
    [Completion_idle -> Proof_pending], persisted BEFORE the phase enters
    [Verifying] (persist-before-model-call). Idempotent when already pending —
    a repeated [request_complete] re-arms the request. A standing
    [Proof_refuted] is superseded by the new request; a committed
    [Proof_proven] verdict is never overwritten. *)

val record_proof_verdict :
  Workspace_utils.config ->
  goal_id:string ->
  verdict ->
  (record, string) result
(** Commits the verifier's completion proof (B3). Requires [Proof_pending] —
    the request persisted before the phase enters [Verifying] — or the same
    proof outcome already committed (the crash-between-writes retry). A commit
    in the opposite direction of a standing verdict is a stale verifier answer
    and stays an [Error]: that guards what the record says about itself, which
    is the only thing this commit refuses. *)
