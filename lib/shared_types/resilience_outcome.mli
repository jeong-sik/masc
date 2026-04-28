(** Resilience_outcome — Ternary outcome GADT (stub).

    Replaces the binary [('a, 'e) result] with a three-class outcome that
    treats partial success as a first-class citizen, not a silent coercion
    of [Ok]. This is the type Autonomous returns from [tick] and that
    Resilience adapters wrap in higher tiers.

    Three classes:
    - [FullSuccess]: everything completed; all declared artifacts produced.
    - [PartialSuccess]: primary value usable; some artifacts failed.
      Carries which succeeded, which failed, and the degradation level.
    - [GracefulFailure]: operation could not complete, but a fallback or
      handoff path exists. Optional [fallback] payload.

    {b STUB STATUS (Tier I5, Cycle 19)}: the [recovery_strategy] field of
    [GracefulFailure] is a placeholder [string] (the strategy name like
    ["Retry"], ["Fallback"], ["Handoff"], ["Abort"]). The eventual GADT
    [Recovery.strategy] is introduced in Tier B6. Callers must treat this
    string as opaque — structural pattern matching on the strategy is
    deferred. The migration plan: B6 introduces [Recovery.strategy], and
    a follow-up PR replaces this field's type with no API breakage at
    the constructor name level.

    INTEGRATED §3.1 Decision 6: Resilience wraps outer outcomes; this
    type lives in [shared_types] precisely so that Autonomous can return
    it from day 1 without depending on Resilience itself.

    @stability Evolving (stub)
    @since 0.18.9 *)

(** {1 Phantom witnesses for outcome classes} *)

type full
type partial
type graceful

(** {1 The ternary outcome GADT} *)

type ('a, 'e) t =
  | FullSuccess : {
      value : 'a;
      confidence : Confidence.t;
      artifacts : Artifact_id.t list;
    } -> ('a, 'e) t
    (** All declared artifacts produced. *)

  | PartialSuccess : {
      value : 'a;
      completed : Artifact_id.t list;
      failed : (Artifact_id.t * 'e) list;
      confidence : Confidence.t;
      degradation_level : int;
        (** [1..4] corresponding to L1..L4 (Resilience.Degradation.level
            in Tier A11). [1] = highest capability, [4] = lowest. *)
    } -> ('a, 'e) t
    (** Primary value usable; some artifacts failed. *)

  | GracefulFailure : {
      fallback : 'a option;
      reason : string;
      recovery_strategy : string;
        (** STUB (I5): placeholder for [Recovery.strategy] (Tier B6).
            Treat as opaque; common values: ["Retry"], ["Fallback"],
            ["Degrade"], ["Speculate"], ["Handoff"], ["Abort"]. *)
      confidence : Confidence.t;
    } -> ('a, 'e) t
    (** Operation failed; fallback or handoff available. *)

(** {1 Constructors} *)

val full :
  value:'a ->
  confidence:Confidence.t ->
  artifacts:Artifact_id.t list ->
  ('a, 'e) t

val partial :
  value:'a ->
  completed:Artifact_id.t list ->
  failed:(Artifact_id.t * 'e) list ->
  confidence:Confidence.t ->
  degradation_level:int ->
  ('a, 'e) t
(** [degradation_level] is clamped to [[1, 4]] at construction time
    (defensive normalization mirroring [Confidence.make]). *)

val graceful :
  ?fallback:'a ->
  reason:string ->
  recovery_strategy:string ->
  confidence:Confidence.t ->
  unit ->
  ('a, 'e) t

(** {1 Predicates} *)

val is_full : ('a, 'e) t -> bool

val is_partial : ('a, 'e) t -> bool

val is_graceful : ('a, 'e) t -> bool

(** {1 Extraction} *)

val value_opt : ('a, 'e) t -> 'a option
(** [Some] for [FullSuccess] and [PartialSuccess].
    For [GracefulFailure], returns [fallback]. *)

val confidence : ('a, 'e) t -> Confidence.t
(** Embedded confidence regardless of outcome class. *)

(** {1 Combinators} *)

val map : ('a -> 'b) -> ('a, 'e) t -> ('b, 'e) t
(** Map the payload. Class is preserved. *)

val cata :
  full:('a -> Confidence.t -> Artifact_id.t list -> 'r) ->
  partial:('a -> Artifact_id.t list -> (Artifact_id.t * 'e) list ->
           Confidence.t -> int -> 'r) ->
  graceful:('a option -> string -> string -> Confidence.t -> 'r) ->
  ('a, 'e) t -> 'r
(** Catamorphism: case-analyze all three constructors with continuations.
    Useful for serialization or rendering without exposing the GADT. *)

(** {1 Lifting from [result]} *)

val lift_result :
  ?confidence:Confidence.t ->
  ?artifacts:Artifact_id.t list ->
  ('a, 'e) result ->
  ('a, 'e) t
(** [Ok v] → [FullSuccess] with the given [confidence] (default
    [Confidence.one]) and [artifacts] (default [[]]).
    [Error e] → [GracefulFailure] with no fallback, [reason] = ["lifted from Error"],
    [recovery_strategy] = ["Abort"], confidence = [Confidence.zero]. *)

(** {1 Class identification} *)

val class_to_string : ('a, 'e) t -> string
(** ["FullSuccess"], ["PartialSuccess"], or ["GracefulFailure"]. *)
