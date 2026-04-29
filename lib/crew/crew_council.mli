(** Crew_council — council state + 6-phase deliberation machine.

    Cycle 26 / Tier A9.

    {1 What this module is}

    The 6-phase deliberation machine that drives a CREW council
    from an initial proposal through critique, research, debate,
    vote, and final decision. The phases are encoded as phantom
    witness types and the transition GADT excludes invalid
    [phase → phase] sequences at compile time, mirroring the B5
    autonomous_phase pattern.

    {1 The 6-phase lattice}

    - {!Propose}: a member submits the initial claim or plan.
    - {!Critique}: analyst (and others) surface assumptions /
      flag rationalisation.
    - {!Research}: scholar pulls prior art / docs to inform the
      next round.
    - {!Debate}: every persona offers a position with reasoning.
    - {!Vote}: every persona registers a {!Crew_types.vote}.
    - {!Decide}: consensus aggregator emits the final outcome.

    {1 Transitions}

    Linear by design — Propose → Critique → Research → Debate →
    Vote → Decide. Tier A10 (consensus + audit) wires the actual
    transition driver and the timeout policy that may force a
    Vote → Decide rollover. This module owns the phase taxonomy
    + transition GADT + a record carrying the runtime council
    snapshot, and leaves the dispatch loop to A10.

    {1 Timeout policy}

    {!timeout_policy} is the per-phase deadline budget; A10
    consumes [time_cap_per_phase_ms] alongside a global ceiling
    in {!global_deadline_ms}. The default policy mirrors the
    reasoning in
    [feedback_keeper-deliberation-timeout-budget.md] —
    Vote should not exceed half the global ceiling.

    @stability Evolving
    @since 0.18.10 *)

(** {1 Phase phantom witnesses} *)

type propose
type critique
type research
type debate
type vote_phase
type decide

(** {1 Phase GADT} *)

type _ phase =
  | Propose : propose phase
  | Critique : critique phase
  | Research : research phase
  | Debate : debate phase
  | Vote : vote_phase phase
  | Decide : decide phase

(** Existential capture for runtime indexing. *)
type any_phase = Any_phase : 'a phase -> any_phase

(** {1 Tag mirror (ppx_tla derivable)} *)

type phase_tag =
  | Tag_propose
  | Tag_critique
  | Tag_research
  | Tag_debate
  | Tag_vote
  | Tag_decide

val all_phase_tags : phase_tag list

val phase_tag_to_string : phase_tag -> string

val phase_to_tag : 'a phase -> phase_tag

val any_phase_to_tag : any_phase -> phase_tag

val phase_to_string : 'a phase -> string

val any_phase_to_string : any_phase -> string

(** {1 Transition GADT} *)

(** [(\`from, \`to) transition] encodes the legal phase advances.
    Rolling back, skipping, or repeating a phase is not
    representable. *)
type ('from_phase, 'to_phase) transition =
  | Propose_to_critique : (propose, critique) transition
  | Critique_to_research : (critique, research) transition
  | Research_to_debate : (research, debate) transition
  | Debate_to_vote : (debate, vote_phase) transition
  | Vote_to_decide : (vote_phase, decide) transition

type any_transition =
  | Any_transition : ('from_phase, 'to_phase) transition -> any_transition

val all_transitions : any_transition list
(** All five legal transitions in declaration order. *)

val transition_from : ('a, 'b) transition -> 'a phase

val transition_to : ('a, 'b) transition -> 'b phase

val transition_to_string : ('a, 'b) transition -> string
(** [Propose_to_critique → "propose->critique"] etc. *)

val any_transition_to_string : any_transition -> string

(** {1 Timeout policy} *)

type timeout_policy = {
  time_cap_per_phase_ms : int;
      (** Per-phase deadline. A10 enforces by elapsing the
          phase clock and forcing the next transition. *)
  global_deadline_ms : int;
      (** Hard ceiling on total deliberation time. Vote → Decide
          may be forced before per-phase budget elapses if
          global is reached. Per the timeout-budget feedback
          rule, Vote should not exceed [global / 2]. *)
}

val default_timeout : timeout_policy
(** [{ time_cap_per_phase_ms = 30_000; global_deadline_ms = 180_000 }]. *)

(** {1 Council snapshot} *)

(** Runtime council state. Phantom-tagged so the snapshot
    carries the current phase at the type level — handlers
    specialised on a phase cannot operate on a council in a
    different phase. *)
type 'phase t

val create :
  council_id:Crew_types.council_id ->
  members:Persona_contract.any_persona list ->
  timeout:timeout_policy ->
  now:float ->
  propose t
(** Construct a fresh council in {!Propose} phase. *)

val council_id : 'phase t -> Crew_types.council_id

val members : 'phase t -> Persona_contract.any_persona list

val current_phase : 'phase t -> 'phase phase

val any_phase_of : 'phase t -> any_phase

val started_at : 'phase t -> float
(** Wall-clock timestamp captured at [create]. *)

val timeout : 'phase t -> timeout_policy

val advance :
  ('from_phase, 'to_phase) transition -> 'from_phase t -> 'to_phase t
(** Transition the council to the next phase. The GADT enforces
    that only legal transitions are admissible — illegal
    advances do not type-check. *)

(** {1 JSON} *)

val to_json : 'phase t -> Yojson.Safe.t

(** Existential wrapper for storing councils of any phase. *)
type any_council = Any_council : 'phase t -> any_council

val any_council_to_json : any_council -> Yojson.Safe.t

val any_council_id : any_council -> Crew_types.council_id
