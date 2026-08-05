(** Keeper_prompt_names — SSOT for Prompt_registry template keys
    used by keeper modules.

    All keeper prompt lookups must reference these constants
    instead of string literals. *)

val system : string
(** Shared keeper system prompt. Merged from the former [constitution],
    [world], [capabilities], and [core_behavior] keys, which each restated
    the same rule families in a different wording. *)

val judge_board : string
val judge_effect : string
val verification : string
(** The only recall asset. A turn whose recall is empty or failed injects no
    block at all — there is no counterpart key naming the absence. *)

val librarian : string
