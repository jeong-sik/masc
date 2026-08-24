(** Prompt_names — SSOT for Prompt_registry template keys.

    Each key names the reader it addresses, and every key here has exactly one
    asset in config/prompts. *)

val keeper : string
(** The Keeper's standing rules. *)

val judge_board : string
(** Relevance of one Board signal to one Keeper. *)

val judge_effect : string
(** Approve, deny, or escalate one exact Keeper external effect. *)

val verification : string
(** Task completion review against the submitted evidence snapshot. *)

val goal_verification_proof : string

val goal_verification_lookup : string
(** The read-only surface the Goal proof judge holds, described to it. A
    surface the judge is never told about is a surface it never uses. *)
(** Goal completion proof review (RFC-0387 B3): did the goal's declared
    metric reach its declared target value? *)

val verification_lookup_none : string
val verification_lookup_producer_tree : string
val verification_contract : string
val verification_required_evidence : string
val keeper_observation_recovered_current_task : string
val keeper_observation_current_task_absent : string
val keeper_observation_current_task_absent_in_recovery : string
val keeper_observation_current_task_unobservable : string
val keeper_current_task_skills : string
(** The instruction attached to the skills named by the current task. *)

(** Goal success-criterion viability review (RFC-0387 B2): is the declared
    metric/target reachable in principle? *)

val librarian : string
(** Current-memory selection. *)
