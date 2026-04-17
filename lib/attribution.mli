(** Structured attribution envelope for gate decisions.

    Carries "who/where/what/why" for each pass/fail decision emitted
    by the 8 verification gates (cdal_verdict, verification,
    accountability, keeper_fsm, oas_completion, agent_lifecycle,
    task_transition, worker_dev_tools). Propagates through SSE as an
    optional field on every event so the dashboard can trace causality.

    The existing [reason] / [reason_code] SSE fields remain untouched
    for backward compatibility. Emitters MAY additionally attach this
    typed envelope; consumers that don't understand it skip the field.

    See [memory/audits/gate-attribution-baseline-2026-04-17.md] for
    the per-gate evidence schema inventory this envelope targets.

    @since 2.261.0 *)

type origin = Det | NonDet
(** Decision nature. [Det] is rule-based logic whose verdict follows
    mechanically from the input (variant pattern matching, threshold
    comparison). [NonDet] is model-based judgment (LLM scoring, human
    verdict). The boundary is typed here because downstream consumers
    treat them differently — Det verdicts are idempotent, NonDet
    verdicts may vary across replays.

    See MEMORY [deterministic-nondeterministic-boundary]. *)

type verdict = Pass | Fail | Partial
(** Decision outcome. [Partial] indicates a score-based gate where the
    subject met some but not all criteria (score between fail and pass
    thresholds). Detail lives in [evidence] and optionally [rationale]. *)

type t = {
  origin: origin;
  gate: string;
      (** Gate identifier. One of [cdal_verdict], [verification],
          [accountability], [keeper_fsm], [oas_completion],
          [agent_lifecycle], [task_transition], [worker_dev_tools].
          Future gates append to this list. *)
  verdict: verdict;
  evidence: Yojson.Safe.t;
      (** Gate-specific structured evidence. Schema per gate defined in
          the emitter; consumers treat as opaque JSON. *)
  blocked_from: string option;
      (** When [verdict = Fail] on a transition: the state the subject
          was in before the block. [None] for non-transition gates. *)
  blocked_to: string option;
      (** When [verdict = Fail] on a transition: the state the subject
          was trying to reach. [None] for non-transition gates. *)
  rationale: string option;
      (** Human-readable explanation. Primarily populated for
          [NonDet] verdicts where the [evidence] alone is insufficient
          to explain the decision. *)
}

val to_yojson : t -> Yojson.Safe.t
(** Serialize to JSON for SSE emission. Optional fields are omitted
    (not emitted as [null]) to keep the wire format compact. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Parse from JSON. Returns [Error] with a human-readable message on
    malformed input. Missing [evidence] defaults to [`Null]; other
    required fields ([origin], [gate], [verdict]) must be present. *)

val show : t -> string
(** Single-line representation for debug logs. Elides [evidence] and
    [rationale] to keep logs scannable. *)

val pass : origin:origin -> gate:string -> evidence:Yojson.Safe.t -> t
(** Smart constructor for a passing verdict. [blocked_from],
    [blocked_to], [rationale] are [None]. *)

val fail :
  origin:origin ->
  gate:string ->
  evidence:Yojson.Safe.t ->
  ?blocked_from:string ->
  ?blocked_to:string ->
  ?rationale:string ->
  unit ->
  t
(** Smart constructor for a failing verdict. All "why" fields are
    optional — supply whichever apply to the gate in question. *)

val partial :
  origin:origin ->
  gate:string ->
  evidence:Yojson.Safe.t ->
  ?rationale:string ->
  unit ->
  t
(** Smart constructor for a partial verdict (score-based gates).
    [blocked_from] / [blocked_to] are [None] — partial verdicts don't
    fit the block-on-transition model. *)
