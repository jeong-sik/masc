(** Chain executor configuration — env-based overrides for chain node defaults. *)

val default_cascade_models : unit -> string list
(** Default LLM cascade for goal_driven and feedback_loop nodes.
    Env: [MASC_CHAIN_DEFAULT_CASCADE] (comma-separated).
    Default: [["gemini"; "claude"; "codex"]] *)

val default_judge_model : unit -> string
(** Model for LLM-based judgment/scoring in evaluator, MCTS, goal_driven,
    and feedback_loop nodes.
    Env: [MASC_CHAIN_JUDGE_MODEL].
    Default: ["gemini"] *)
