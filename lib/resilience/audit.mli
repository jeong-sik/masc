(** Resilience_audit — typed category enum lifted onto Shared_audit.Envelope.

    Cycle 28 / Tier A12 — first cut.

    {1 What this module is}

    A thin resilience-specific layer on top of {!Shared_audit.Envelope}.
    The shared envelope leaves [category] as a free string; this module
    pins the resilience domain to a closed variant ({!category}) so
    that:

    - producers cannot emit a typo'd category by accident,
    - downstream consumers (filters, dashboards, replay) can pattern-match
      exhaustively, and
    - the canonical string form is the {b only} string allowed to land
      in the underlying envelope.

    The Merkle [prev_hash] chain, [id] generation, [ts], and canonical
    JSON serialization are entirely delegated to {!Shared_audit.Envelope}.
    No separate entry record is introduced.

    {1 Scope of this PR}

    - {!category} variant: 12 resilience categories from the design doc
      (resilience_KEY_INTERFACES.mli §6 Audit) covering outcomes,
      confidence, degradation, speculative branches, recovery, and
      budget events.
    - {!category_to_string} / {!category_of_string}: total ⇄ partial
      string bijection; unknown strings yield [None].
    - {!category_to_json}: convenience for embedding the category as
      a JSON string node in payloads.
    - {!make_entry}: build a {!Shared_audit.Envelope.t} from a typed
      category plus optional [keeper_name] / [session_id] (which are
      threaded into the payload, not the envelope, since the shared
      envelope has no such fields).
    - {!entry_to_json} / {!entry_of_json}: lossless round-trip through
      JSON via [Envelope.to_json] / [Envelope.of_json]. Re-parsing
      preserves the typed category iff the wire string is recognised.
    - {!category_of_entry}: lift the envelope's [category : string]
      back to a typed {!category}.

    {1 Deferred to follow-up Tiers}

    - {b Cycle 29}: in-memory queue + dated JSONL drain (built on
      {!Shared_audit.Store}, gated by category filter).
    - {b Cycle 30}: live SSE stream + [verify_chain] integrity check
      surfaced through dashboard.

    @stability Evolving
    @since 0.18.10 *)

(** {1 Resilience audit categories} *)

(** Closed variant of resilience-specific audit categories.

    Mapped 1:1 with the design doc (resilience_KEY_INTERFACES.mli §6
    Audit). The string form (see {!category_to_string}) is the
    canonical wire representation that lands in
    [Shared_audit.Envelope.category]. *)
type category =
  | OutcomeRecorded
      (** A {!Shared_types.Resilience_outcome.t} was emitted by a
          keeper turn (FullSuccess / PartialSuccess / GracefulFailure). *)
  | ConfidenceEvaluated
      (** A composite confidence score was computed for an artifact. *)
  | DegradationTriggered
      (** Capability level was lowered (e.g. L1 → L2). *)
  | DegradationRecovered
      (** Capability level was restored upward. *)
  | SpeculativeBranchStarted
      (** A speculative branch was forked. *)
  | SpeculativeBranchCompleted
      (** A speculative branch finished (won, lost, or aborted). *)
  | SpeculativeWinnerSelected
      (** A winning branch was committed and losers reaped. *)
  | RecoveryClassified
      (** A failure was classified and a default recovery strategy was
          selected, but no concrete executor was configured. *)
  | RecoveryAttempted
      (** A {!Recovery.strategy} was selected and dispatched. *)
  | RecoverySucceeded
      (** The dispatched strategy resolved successfully. *)
  | RecoveryFailed
      (** The dispatched strategy itself failed. *)
  | BudgetChecked
      (** A budget probe was issued (no exhaustion yet). *)
  | BudgetExceeded
      (** A budget threshold was crossed. *)

val category_to_string : category -> string
(** Canonical wire string. The shared envelope stores this. *)

val category_of_string : string -> category option
(** Inverse of {!category_to_string}. Returns [None] for unrecognised
    strings (including legacy / cross-domain categories such as
    CREW's [["DeliberationTransition"]]). *)

val category_to_json : category -> Yojson.Safe.t
(** [`String (category_to_string c)]. Convenience for embedding the
    category inside a payload sub-tree. *)

(** {1 Entry construction (envelope wrap)} *)

val make_entry :
  category:category ->
  ?keeper_name:string ->
  ?session_id:string ->
  payload:Yojson.Safe.t ->
  prev_hash:string option ->
  unit ->
  Shared_audit.Envelope.t
(** Build a {!Shared_audit.Envelope.t} for a resilience event.

    [keeper_name] and [session_id], if provided, are wrapped into the
    final payload as [_keeper_name] / [_session_id] sibling fields
    next to the caller's [payload]. This keeps the envelope schema
    untouched while letting resilience-specific consumers filter on
    these dimensions.

    If [payload] is not a JSON object, it is wrapped under a
    [["payload"]] field so the envelope receives a well-formed
    [`Assoc].

    [ts] is taken from {!Shared_audit.Envelope.make}'s wall clock
    (no override exposed; tests can compare round-trip semantics
    instead of literal timestamps). *)

val entry_to_json : Shared_audit.Envelope.t -> Yojson.Safe.t
(** Alias of {!Shared_audit.Envelope.to_json}, exposed so resilience
    callers do not have to reach across the [Shared_audit] module
    boundary for a trivial passthrough. *)

val entry_of_json :
  Yojson.Safe.t -> (Shared_audit.Envelope.t, string) result
(** Alias of {!Shared_audit.Envelope.of_json}. The resulting envelope
    keeps [category] as a string; use {!category_of_entry} to lift
    it back to a typed {!category}. *)

val category_of_entry : Shared_audit.Envelope.t -> category option
(** Read [envelope.category] back into the typed variant. Returns
    [None] when the envelope was emitted by a different domain or
    contains an unknown category string. *)
