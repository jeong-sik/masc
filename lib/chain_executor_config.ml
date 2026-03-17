(** Chain executor configuration — env-based overrides for chain node defaults.

    All functions return sensible defaults when env vars are unset.
    Override via environment variables prefixed with MASC_CHAIN_*.

    @since v2.103.0 *)

(** Default LLM cascade for goal_driven and feedback_loop nodes.
    Env: MASC_CHAIN_DEFAULT_CASCADE (comma-separated model names).
    Default: ["gemini"; "claude"; "codex"] *)
let default_cascade_models () : string list =
  match Sys.getenv_opt "MASC_CHAIN_DEFAULT_CASCADE" with
  | Some v ->
      let models = String.split_on_char ',' v
        |> List.map String.trim
        |> List.filter (fun s -> s <> "") in
      if models = [] then ["gemini"; "claude"; "codex"] else models
  | None -> ["gemini"; "claude"; "codex"]

(** Model used for LLM-based judgment/scoring in evaluator, MCTS,
    goal_driven, and feedback_loop nodes.
    Env: MASC_CHAIN_JUDGE_MODEL.
    Default: "gemini" *)
let default_judge_model () : string =
  match Sys.getenv_opt "MASC_CHAIN_JUDGE_MODEL" with
  | Some v when String.trim v <> "" -> String.trim v
  | _ -> "gemini"
