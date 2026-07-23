(** Structured attribution envelope for gate decisions.

    Carries "who/where/what/why" for each pass/fail decision emitted
    by the verification gates (verification,
    accountability, keeper_fsm, oas_completion, agent_lifecycle,
    task_transition, exec_policy). Propagates through SSE as an
    optional field on every event so the dashboard can trace causality.

    The existing [reason] / [reason_code] SSE fields remain untouched
    for backward compatibility. Emitters MAY additionally attach this
    typed envelope; consumers that don't understand it skip the field.

    Design note — sum types over products:
    The outcome is a proper sum. Each case carries exactly the fields
    relevant to that outcome (no optional / unused fields). A [Passed]
    verdict cannot carry a [reason]; a [Transition_blocked] cannot omit
    the from/to states. Illegal states are unrepresentable. See MEMORY
    `parse-dont-validate`.

    @since 2.261.0 *)

type origin = Det | NonDet
(** Decision nature. [Det] is rule-based logic whose verdict follows
    mechanically from the input (variant pattern matching, threshold
    comparison). [NonDet] is model-based judgment (LLM scoring, human
    verdict). The boundary is typed here because downstream consumers
    treat them differently — Det verdicts are idempotent, NonDet
    verdicts may vary across replays.

    See MEMORY [deterministic-nondeterministic-boundary]. *)

type outcome =
  | Passed
      (** Gate allowed the subject through. [evidence] on the envelope
          still captures what was checked (for audit). *)
  | Policy_failed of { reason : string }
      (** Non-transition gate rejection (content check, claim validity,
          policy violation). The subject was not attempting a state
          transition — it was proposing an action that got denied. *)
  | Transition_blocked of {
      from_state : string;
      to_state : string;
      reason : string;
    }
      (** Transition gate: the subject tried to move from [from_state]
          to [to_state] and was blocked. Used by keeper_fsm,
          agent_lifecycle, task_transition. *)
  | Partial_pass of { score : float; rationale : string }
      (** Score-based gate: the subject met some but not all criteria.
          [score] is the gate's own scale (typically [[0.0, 1.0]]),
          not normalized here. [rationale] explains the partial in
          human-readable form. *)

type t = {
  origin : origin;
  gate : string;
      (** Gate identifier. One of [verification],
          [accountability], [keeper_fsm], [oas_completion],
          [agent_lifecycle], [task_transition], [exec_policy].
          Future gates append to this list.

          Kept as [string] rather than a variant so new gates can emit
          without a library-wide code change. Consumers that care about
          the closed set should match on known values. *)
  evidence : Yojson.Safe.t;
      (** Gate-specific structured input data, always present regardless
          of outcome (the gate saw something to decide on). Schema per
          gate is defined in the emitter; consumers treat as opaque JSON
          unless they know the gate. *)
  outcome : outcome;
}

val to_yojson : t -> Yojson.Safe.t
(** Serialize to JSON for SSE emission.

    Wire format: [outcome] is tagged by a ["kind"] field inside a nested
    object:
    - [Passed]             → [{"kind":"passed"}]
    - [Policy_failed]      → [{"kind":"policy_failed","reason":"..."}]
    - [Transition_blocked] → [{"kind":"transition_blocked",
                               "from_state":"...","to_state":"...","reason":"..."}]
    - [Partial_pass]       → [{"kind":"partial_pass",
                               "score":0.85,"rationale":"..."}] *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Deserialize a current attribution envelope from JSON. Inverse of
    {!to_yojson}; rejects envelopes that omit required fields, including
    [evidence]. *)

val of_legacy_yojson : Yojson.Safe.t -> (t, string) result
(** Explicit compatibility decoder for historical attribution rows that
    predate the required [evidence] field. Missing [evidence] is decoded as
    JSON null only through this legacy entry point. *)

val show : t -> string
(** Concise debug representation. Long fields (evidence, reason,
    rationale) are elided to […] so the string is safe for logs and
    test assertions. *)

(** {1 Smart constructors}

    Prefer these over the raw record — they enforce the sum invariant
    by construction (no way to build an illegal combination). *)

val passed : origin:origin -> gate:string -> evidence:Yojson.Safe.t -> t

val policy_failed :
  origin:origin -> gate:string -> evidence:Yojson.Safe.t -> reason:string -> t

val transition_blocked :
  origin:origin ->
  gate:string ->
  evidence:Yojson.Safe.t ->
  from_state:string ->
  to_state:string ->
  reason:string ->
  t

val partial_pass :
  origin:origin ->
  gate:string ->
  evidence:Yojson.Safe.t ->
  score:float ->
  rationale:string ->
  t
