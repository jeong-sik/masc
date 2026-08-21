(** Prompt_names — SSOT for Prompt_registry template keys
    used by keeper modules.

    All keeper prompt lookups must reference these constants
    instead of string literals. *)

let keeper = "keeper"
let judge_board = "judge.board"
let judge_effect = "judge.effect"
let judge_catchup = "judge.catchup"
let verification = "verification"
let goal_verification_proof = "goal_verification.proof"
let goal_verification_criterion = "goal_verification.criterion"

(* Review sections rendered as their own templates and injected into the review
   prompt. They live as files so the prose is editable and overridable through
   the operator layer, and so a code change cannot leave the instructions
   stale: [Anti_rationalization] supplies the data and picks the key, and holds
   no review prose of its own. *)
let verification_lookup_none = "verification.lookup.none"
let verification_lookup_producer_tree = "verification.lookup.producer_tree"
let verification_lookup_producer_forest = "verification.lookup.producer_forest"
let verification_contract = "verification.contract"
let verification_required_evidence = "verification.required_evidence"
let librarian = "librarian"
