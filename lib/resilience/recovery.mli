(** Recovery — failure-mode classification + recovery strategy selection.

    Cycle 23 / Tier B6 — first cut.

    {1 What this module is}

    A resilience-specific layer that maps {b what went wrong} into
    {b what to do next}. The classifier produces an {!error_mode}
    that encodes the recovery shape (retry, fallback, handoff,
    abort) rather than merely the originating fault.

    {1 Scope of this PR}

    - {!error_mode} variant: 6 failure modes with structured
      payloads (retries hint, fallback choice, resource budget,
      ambiguity branches, dissenters, recommended degradation level).
    - {!fallback} variant for the [PermanentError] branch.
    - {!strategy} GADT: 4 executable strategies in this Tier
      (Retry, Fallback, Handoff, Abort). [Degrade] and [Speculate]
      remain {b deferred} until Tier A11 lands the corresponding
      [Degradation.level] / [Speculative.budget_policy] types.
    - {!classify_string}: heuristic classifier for arbitrary
      exception or error strings; the primary fallback path when no
      structured error is available.
    - {!default_strategy}: pick the canonical strategy for an
      [error_mode]. Callers may override with a custom strategy.

    {1 Deferred to follow-up Tiers}

    - [classify_sdk_error]: bridge from OAS [Error.sdk_error] to
      [error_mode]. Requires importing the OAS error surface;
      deferred to keep this PR's dependency footprint inside
      [shared_types]. Tier A6 (resilience keeper_bridge) introduces
      this bridge as it actually consumes OAS errors at the seam.
    - [resolve] / [auto_resolve]: Eio-driven execution of the
      strategy. Deferred until Tier A11 binds [Resilience_audit]
      and [Speculative.execute].
    - [Degrade] / [Speculate] strategy constructors and the
      [DegradationRequired]'s [recommended_level] type are
      retained as plain ints here; Tier A11 retypes them with no
      constructor renaming.

    The phantom-tag pattern on {!strategy} (e.g. [\[> `Retry\]
    strategy]) follows the design doc to enable compile-time
    discrimination across strategy classes once consumers wire
    them in. *)

(** {1 Failure-mode classification} *)

(** A resilience-specific failure mode. Richer than OAS errors
    because it encodes the recovery shape. *)
type error_mode =
  | TransientError of {
      detail : string;
      max_retries : int;
      backoff_ms : int;
    }
      (** Retryable error: network timeout, rate limit, ephemeral
          file system issue. *)
  | PermanentError of { detail : string; fallback_strategy : fallback }
      (** Unrecoverable for this operation: invalid API key,
          contract violation, nonexistent file (when the path is
          known correct). *)
  | ResourceExhausted of {
      resource : [ `Tokens | `Time | `Cost | `Memory | `Disk ];
      consumed : float option;
      limit : float option;
      detail : string option;
    }
      (** Budget or capacity exhausted. [consumed] and [limit] are [None]
          when the classifier only has a free-form error string and no
          trustworthy numeric measurement. *)
  | AmbiguityError of { detail : string; branches : string list }
      (** Two or more equally plausible interpretations; speculative
          execution is the recommended response when available. *)
  | ConsensusError of { detail : string; dissenters : string list }
      (** CREW personas could not reach agreement. *)
  | DegradationRequired of {
      detail : string;
      recommended_level : int;
        (** Tier A11 retypes this as [Degradation.level]; for now,
            an integer in [\[1, 4\]]. *)
    }
      (** Current capability level is too ambitious; reduce scope. *)

(** What to do when a [PermanentError] occurs. *)
and fallback =
  | UseDefaultString of string
      (** Use the provided string as the fallback artifact text. *)
  | UsePlaceholder of string
      (** Insert a placeholder marker referencing this name. *)
  | SkipArtifact of string
      (** Skip the failed artifact id; downstream consumers note
          its absence. *)
  | HumanHandoff of string
      (** Escalate to operator with this message. *)

(** {1 Recovery strategy GADT}

    Phantom-tagged so callers may discriminate at compile time
    between strategy classes when needed. The current PR exposes
    Retry / Fallback / Handoff / Abort; Degrade and Speculate
    arrive in Tier A11. *)
type _ strategy =
  | Retry : {
      max_attempts : int;
      backoff : int -> float;
        (** [attempt index → delay seconds]. Caller supplies; the
            classifier's [TransientError.backoff_ms] is just a hint. *)
    }
      -> [> `Retry ] strategy
  | Fallback : { fallback_value : string; degrade_confidence_by : float }
      -> [> `Fallback ] strategy
      (** Substitute a default or placeholder string and reduce
          confidence. The follow-up Tier may parameterise the value
          type ('a fallback_value). *)
  | Handoff : { operator_message : string; preserve_state : bool }
      -> [> `Handoff ] strategy
  | Abort : { reason : string; cleanup : unit -> unit }
      -> [> `Abort ] strategy

(** TLA+ symbol for {!error_mode}, matching
    [specs/resilience/ResilienceDegradation.tla] [ErrorModes]. *)
val error_mode_to_tla_symbol : error_mode -> string

(** Complete TLA+ [ErrorModes] mirror for payload-bearing
    {!error_mode} constructors. *)
val all_error_mode_tla_symbols : string list

(** TLA+ symbol for {!strategy}, matching
    [specs/resilience/ResilienceDegradation.tla] [Strategies]. *)
val strategy_to_tla_symbol : 'a strategy -> string

(** Complete TLA+ [Strategies] mirror for {!strategy}. *)
val all_strategy_tla_symbols : string list

(** {1 Heuristic classification} *)

val classify_string : string -> error_mode
(** Best-effort classification of a free-form exception or error
    string. Returns [TransientError] for known retryable phrases
    (timeout, rate limit, connection reset, temporary),
    [ResourceExhausted] with unknown measurement for resource phrases, and
    [PermanentError { fallback_strategy = HumanHandoff _ }]
    otherwise. *)

(** {1 Default strategy selection} *)

val default_strategy : error_mode -> [ `Retry | `Fallback | `Handoff | `Abort ] strategy
(** Choose the canonical strategy for an [error_mode]:

    - [TransientError]              → [Retry]
    - [PermanentError { UseDefaultString | UsePlaceholder | SkipArtifact }]
                                    → [Fallback]
    - [PermanentError { HumanHandoff }]
                                    → [Handoff]
    - [ResourceExhausted]           → [Abort]
    - [AmbiguityError]              → [Handoff] (Speculate
                                        deferred until A11)
    - [ConsensusError]              → [Handoff]
    - [DegradationRequired]         → [Handoff] (Degrade deferred
                                        until A11) *)

(** {1 Convenience constructors for [error_mode]} *)

val transient :
  detail:string -> ?max_retries:int -> ?backoff_ms:int -> unit -> error_mode

val permanent : detail:string -> fallback:fallback -> error_mode

val resource_exhausted :
  resource:[ `Tokens | `Time | `Cost | `Memory | `Disk ] ->
  consumed:float ->
  limit:float ->
  error_mode

val resource_exhausted_unknown :
  resource:[ `Tokens | `Time | `Cost | `Memory | `Disk ] ->
  detail:string ->
  error_mode

val ambiguity : detail:string -> branches:string list -> error_mode

val consensus_failure :
  detail:string -> dissenters:string list -> error_mode

val degradation_required :
  detail:string -> recommended_level:int -> error_mode
