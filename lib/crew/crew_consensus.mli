(** Crew consensus — Cycle 26 / Tier A10a.

    Tally a list of [Crew_types.vote]s against a [quorum_policy]
    and derive a phantom-tagged [outcome] capturing the council's
    collective decision.

    A10 plan §2.2 splits this work into three pieces:
      - A10a: this module (vote tally + outcome GADT, A9-independent)
      - A10b: Multimodal review record (artifact evaluation contract)
      - A10c: crew_audit + Crew_critique bridge functor (A9-dependent)

    A10a depends on [Crew_types.vote] only and is buildable on any
    main HEAD that has Tier A8 (#11838) merged. *)

(* ── Tally ──────────────────────────────────────────────────────── *)

type tally = {
  approve : int;
  dissent : int;
  abstain : int;
}

val empty_tally : tally

val tally_of_votes : Crew_types.vote list -> tally

val tally_total : tally -> int

(* ── Quorum policy ──────────────────────────────────────────────── *)

type quorum_policy = {
  min_voters : int;
      (** Minimum number of total ballots (incl. abstain) required
          before any positive verdict is permitted. *)
  approve_threshold : float;
      (** Approval fraction over non-abstaining ballots required for
          [Approved]. Must be in [0.0, 1.0]. *)
}

val default_policy : quorum_policy
(** [{ min_voters = 1; approve_threshold = 0.5 }]. *)

(* ── Outcome ────────────────────────────────────────────────────── *)

type deadlock_kind =
  | Tied [@tla.symbol "tied"]
  | Below_quorum [@tla.symbol "below_quorum"]
  | All_abstain [@tla.symbol "all_abstain"]
[@@deriving tla]

val all_deadlock_kinds : deadlock_kind list

(** Phantom witnesses for outcome states. *)
type approved = |
type rejected = |
type stalemate = |

(** GADT-tagged consensus outcome. [Approved] carries only the tally;
    [Rejected] also collects dissent reasons; [Stalemate] explains
    the deadlock kind. *)
type 'state outcome =
  | Approved : tally -> approved outcome
  | Rejected : { tally : tally; reasons : string list } -> rejected outcome
  | Stalemate : { tally : tally; kind : deadlock_kind } -> stalemate outcome

(** Existential capture for storing heterogeneous outcomes
    (e.g. council_audit log entries). *)
type any_outcome = Any_outcome : 'a outcome -> any_outcome

(* ── Tag mirror ─────────────────────────────────────────────────── *)

(** Plain variant mirror of [outcome] for ppx_tla derivation. The
    GADT constructors specialise their [outcome] type parameter, so
    ppx_tla cannot derive directly on [outcome]; we mirror the three
    branches as a flat enum and project via [outcome_to_tag]. *)
type outcome_tag =
  | Approved_tag [@tla.symbol "approved"]
  | Rejected_tag [@tla.symbol "rejected"]
  | Stalemate_tag [@tla.symbol "stalemate"]
[@@deriving tla]

val all_outcome_tags : outcome_tag list

val outcome_to_tag : 'a outcome -> outcome_tag

val any_outcome_to_tag : any_outcome -> outcome_tag

(* ── JSON serialisation ─────────────────────────────────────────── *)

val tally_to_json : tally -> Yojson.Safe.t

val outcome_to_json : 'a outcome -> Yojson.Safe.t

val any_outcome_to_json : any_outcome -> Yojson.Safe.t

(* ── Evaluation ─────────────────────────────────────────────────── *)

val evaluate :
  policy:quorum_policy -> Crew_types.vote list -> any_outcome
(** [evaluate ~policy votes] derives the consensus [outcome]:

    - [tally_total < policy.min_voters] → [Stalemate Below_quorum]
    - All votes are [Abstain] → [Stalemate All_abstain]
    - [tally.approve = tally.dissent] (both non-zero) → [Stalemate Tied]
    - approve fraction (over non-abstain ballots) ≥ [approve_threshold]
      → [Approved tally]
    - otherwise → [Rejected] with collected dissent reasons.

    Order matters: [Below_quorum] is checked first to avoid a
    deceptive "Approved with one vote" verdict. *)
