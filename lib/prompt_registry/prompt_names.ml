(** Prompt_names — SSOT for Prompt_registry template keys
    used by keeper modules.

    All keeper prompt lookups must reference these constants
    instead of string literals. *)

let keeper = "keeper"
let judge_board = "judge.board"
let judge_effect = "judge.effect"
let verification = "verification"
let goal_verification_proof = "goal_verification.proof"
let goal_verification_lookup = "goal_verification.lookup"

(* Review sections rendered as their own templates and injected into the review
   prompt. They live as files so the prose is editable and overridable through
   the operator layer, and so a code change cannot leave the instructions
   stale: [Anti_rationalization] supplies the data and picks the key, and holds
   no review prose of its own. *)
let verification_lookup_none = "verification.lookup.none"
let verification_lookup_producer_tree = "verification.lookup.producer_tree"
let verification_contract = "verification.contract"
let verification_required_evidence = "verification.required_evidence"

(* One key per typed degraded-observation state. Each names what the Keeper may
   and may not conclude from that state, which is prose about a data condition
   and belongs beside the other prompt text rather than inside the projection
   that detects it. *)
let keeper_observation_recovered_current_task =
  "keeper.observation.recovered_current_task"
;;

let keeper_observation_current_task_absent = "keeper.observation.current_task_absent"

let keeper_observation_current_task_absent_in_recovery =
  "keeper.observation.current_task_absent_in_recovery"
;;

let keeper_observation_current_task_unobservable =
  "keeper.observation.current_task_unobservable"
;;

let keeper_current_task_skills = "keeper.current_task.skills"
let librarian = "librarian"
