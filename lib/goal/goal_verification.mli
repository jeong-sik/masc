(** Goal_verification — per-goal success-condition verification ledger
    (RFC-0387).

    Persists under [<base>/.masc/goal_verifications.json], separate from
    [goals.json] the way [Workspace_goal_index] keeps goal-task links separate:
    the [Goal_store.goal] record is constructed by literal in external callers,
    so verification state gets its own store.

    RFC-0387 stage 1 ships this module as a RECORD-ONLY evidence store: the
    dashboard read paths render it, but no workflow reads it for control and
    no caller writes it yet. Stage 2 (the verifier gate) adds the writers —
    the durable [*_pending] requests and the verifier-lane verdict commits.

    Two state machines per goal, both closed sum types:

    - [criterion_state] (B2) — the creation-time feasibility check of the
      declared success condition. [Criterion_unchecked] is the explicit
      default for pre-RFC-0387 goals, not a silent fallback.
    - [completion_state] (B3) — the completion-time proof chain. A gated
      [Completed] goal carries [Human_confirmed { proof; … }], so "verifier
      proof plus human confirmation" reads back as one durable record.

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
  authority : Masc_domain.completion_authority;
      (** Typed provenance, reused from the Task completion protocol. The
          stage-2 verifier lane commits with its own run identity
          (RFC-0387 §4.3). *)
  evidence : string;
  recorded_at : string;
}

type criterion_state =
  | Criterion_unchecked
  | Criterion_pending of { requested_at : string }
  | Criterion_viable of verdict
  | Criterion_unreachable of verdict

type completion_state =
  | Completion_idle
  | Proof_pending of { requested_at : string }
  | Proof_proven of verdict
  | Proof_refuted of verdict
  | Human_confirmed of {
      proof : verdict;
      confirmed_by : string;
      confirmed_at : string;
    }

type record = {
  goal_id : string;
  criterion : criterion_state;
  completion : completion_state;
  updated_at : string;
}

val default_record : goal_id:string -> record
(** The explicit pre-verification state: [Criterion_unchecked] /
    [Completion_idle]. Used to render goals that have no ledger row. *)

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
    Stage 1 wires no caller; these are the surface the stage-2 verifier gate
    commits through. *)

val record_criterion_verdict :
  Workspace_utils.config ->
  goal_id:string ->
  verdict ->
  (record, string) result
(** Commits the verifier's creation-time feasibility judgment (B2). [Proven]
    lands as [Criterion_viable], [Refuted] as [Criterion_unreachable]. *)

val record_proof_verdict :
  Workspace_utils.config ->
  goal_id:string ->
  verdict ->
  (record, string) result
(** Commits the verifier's completion proof (B3). Requires [Proof_pending] —
    the durable request the stage-2 gate persists before entering its
    verifying phase — or the same outcome already committed (the
    crash-between-writes retry); anything else is an [Error], not a silent
    overwrite. *)

val record_human_confirmation :
  Workspace_utils.config ->
  goal_id:string ->
  confirmed_by:string ->
  (record, string) result
(** Commits the human's final confirmation (B3). Requires [Proof_proven]; the
    proof is carried into [Human_confirmed] so the completed goal retains the
    whole chain. *)
