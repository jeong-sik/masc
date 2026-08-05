(** Prompt_names — SSOT for Prompt_registry template keys
    used by keeper modules.

    All keeper prompt lookups must reference these constants
    instead of string literals. *)

let keeper = "keeper"
let judge_board = "judge.board"
let judge_effect = "judge.effect"
let judge_catchup = "judge.catchup"
let verification = "verification"
let librarian = "librarian"
let worker = "worker"
