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
(** Goal completion proof review (RFC-0387 B3): does the linked-task rollup
    prove the declared success criterion? *)

val verification_lookup_none : string
val verification_lookup_producer_tree : string
val verification_lookup_producer_forest : string
val verification_contract : string
val verification_required_evidence : string
val keeper_observation_recovered_current_task : string
val keeper_observation_current_task_absent : string
val keeper_observation_current_task_absent_in_recovery : string
val keeper_observation_current_task_unobservable : string
(** Goal success-criterion viability review (RFC-0387 B2): is the declared
    metric/target reachable in principle? *)

val librarian : string
(** Current-memory selection. *)
