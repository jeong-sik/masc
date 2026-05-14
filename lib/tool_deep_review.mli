(** Tool_deep_review — Adversarial code review with isolated context.

    PR#814 Gap 2. Spawns a review pass via a different model
    perspective. Context is deliberately stripped — only target file
    contents and the reviewer's question are provided; no JIRA,
    Slack, memory, or institutional knowledge.

    This forces structural evaluation rather than relying on domain
    context that might mask bugs. Uses the same
    [Keeper_turn_driver.run_named] pattern as {!Verifier_oas}. *)

(** [handle_deep_review ~tool_name ~start_time config args] runs a deep
    review as described by [args]. Returns [Tool_result.t] — error on
    validation or dispatch failure, ok with the review output otherwise. *)
val handle_deep_review :
  tool_name:string -> start_time:float -> Coord.config -> Yojson.Safe.t -> Tool_result.t

(** Build the isolated review prompt. Returns [Ok prompt] or
    [Error reason] when no target files could be read or inputs
    fail {!Adversarial_eval.validate_inputs}. *)
val build_prompt :
  target_files:string list ->
  question:string ->
  base_path:string ->
  (string, string) Result.t