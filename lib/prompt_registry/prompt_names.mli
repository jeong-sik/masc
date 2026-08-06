(** Prompt_names — SSOT for Prompt_registry template keys.

    Each key names the reader it addresses, and every key here has exactly one
    asset in config/prompts. *)

val keeper : string
(** The Keeper's standing rules. *)

val judge_board : string
(** Relevance of one Board signal to one Keeper. *)

val judge_effect : string
(** Approve, deny, or escalate one exact Keeper external effect. *)

val judge_catchup : string
(** Assess a Keeper's recent activity digest for the operator. *)

val verification : string
(** Task completion review against the submitted evidence snapshot. *)

val librarian : string
(** Current-memory selection. *)

val worker : string
(** The local worker's standing rules. *)
