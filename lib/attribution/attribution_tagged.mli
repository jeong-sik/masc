(** Origin-tagged attribution — compile-time Det/NonDet boundary.

    Wraps [Attribution.t] with a phantom type parameter encoding the
    decision origin. The runtime representation is identical (pure type
    alias internally), so there is zero overhead; the value add is that
    functions can demand a specific origin in their signatures and the
    compiler rejects mismatches.

    Why: MEMORY [deterministic-nondeterministic-boundary] — "Det 동작을
    NonDet 출력에 의존 금지". Without the phantom tag, this was a
    docstring/comment convention. With the tag, code that reads
    [det Attribution_tagged.t] cannot accidentally consume a NonDet-
    origin value.

    Domain allowance matrix:

    |                    | Passed | Policy_failed | Transition_blocked | Partial_pass |
    |--------------------|--------|---------------|--------------------|--------------|
    | Det (rule-based)   |   ✓    |      ✓        |        ✓           |      ✓       |
    | NonDet (judged)    |   ✓    |      ✓        |       ✗            |      ✓       |

    NonDet cannot produce [Transition_blocked]: a state transition
    requires a deterministic decision about legal source/target
    pairs. A model-based judge does not decide transitions — it scores
    or classifies.

    @since 2.262.0 *)

(** Phantom tag for deterministic (rule-based) origin. *)
type det

(** Phantom tag for non-deterministic (LLM or human-judged) origin. *)
type nondet

(** Origin-tagged attribution envelope. Abstract — construct only
    through the smart constructors in this module. *)
type 'origin t

(** {1 Det smart constructors} *)

val det_passed : gate:string -> evidence:Yojson.Safe.t -> det t

val det_policy_failed :
  gate:string -> evidence:Yojson.Safe.t -> reason:string -> det t

val det_transition_blocked :
  gate:string ->
  evidence:Yojson.Safe.t ->
  from_state:string ->
  to_state:string ->
  reason:string ->
  det t

val det_partial_pass :
  gate:string ->
  evidence:Yojson.Safe.t ->
  score:float ->
  rationale:string ->
  det t
(** Score-based rule (e.g. coverage threshold). Deterministic because the
    score is a pure function of the input, not a model judgment. *)

(** {1 NonDet smart constructors} *)

val nondet_passed :
  gate:string -> evidence:Yojson.Safe.t -> rationale:string -> nondet t
(** NonDet [Passed] requires a [rationale] because the judge's reasoning
    is not derivable from the gate logic. Stored inside the underlying
    [Attribution.evidence] as [{"rationale": ...}] so the serialization
    round-trips through the erased [Attribution.t]. *)

val nondet_policy_failed :
  gate:string ->
  evidence:Yojson.Safe.t ->
  reason:string ->
  rationale:string ->
  nondet t
(** NonDet [Policy_failed] carries both [reason] (serialized to outcome)
    and [rationale] (embedded in evidence), because the model's reasoning
    is an additional signal beyond the one-line reason. *)

val nondet_partial_pass :
  gate:string ->
  evidence:Yojson.Safe.t ->
  score:float ->
  rationale:string ->
  nondet t

(** {1 Erasure} *)

val to_attribution : 'a t -> Attribution.t
(** Erase the phantom tag, producing the runtime [Attribution.t] for SSE
    emission. After erasure, downstream code sees only [origin: Det |
    NonDet] as a runtime field. *)

(** {1 Origin witness} *)

val origin_of : 'a t -> Attribution.origin
(** Runtime introspection for logging/metrics. Prefer the phantom tag in
    function signatures; use this only when dispatching on origin at run
    time (e.g. in a registry that handles both Det and NonDet gates). *)
