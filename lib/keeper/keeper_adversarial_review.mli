(** Keeper_adversarial_review — adversarial review of submitted work as an
    agentic verdict, with author wake-on-fail.

    Decoupled from [Verifier_oas] (the OAS per-tool gate) and from
    [Anti_rationalization] (the completion-notes judge): this module has its
    own prompt ([config/prompts/verification.adversarial_review.md]), its own
    entry point, and its own output. It shares only the generic judging engine
    ([Keeper_turn_driver_wrappers.run_named_with_masc_tools]) and the
    [Verifier_core] verdict surface.

    The verdict is the LLM's judgment. On the structured [report_verdict] path
    there is no rule, heuristic, or string match deciding pass/fail. The
    response fallback accepts only a strict JSON grounded verdict object; it
    does not extract JSON from prose or fences. The grounded entry point
    requires evidence for WARN/FAIL before wake-on-fail routing. The only
    deterministic parts are identity (which keeper authored the work, hence who
    to wake) and event-id dedup (a given task-level FAIL wakes the author at
    most once).

    This module is a proof-of-concept. It is not yet wired to a keeper
    lifecycle trigger; integration with the tool registration in #21357 is the
    next step. *)

type review_input = {
  task_id : string;
  task_title : string;
  task_description : string;
  author_keeper : string;
  evidence_refs : string;
}

val build_prompt : review_input -> (string, string) result
(** Render the adversarial review prompt from
    [config/prompts/verification.adversarial_review.md]. Returns [Error] if
    the prompt registry cannot replace one of the prompt's declared template
    variables. Literal [{{...}}] text inside substituted values is preserved. *)

val run_grounded_review :
  runtime_id:string ->
  review_input ->
  (Verifier_core.grounded_verdict, string) result
(** Run the adversarial reviewer agent and read its structured grounded verdict
    via the [report_verdict] tool. If the model answers without calling the
    tool, the fallback accepts only a strict JSON response object decoded with
    [Verifier_core.parse_grounded_verdict_from_json]. *)

val act_on_verdict :
  base_path:string -> input:review_input -> Verifier_core.verdict -> (unit, string) result
(** On [Fail], record an external-attention item waking [author_keeper] with
    the verdict reason so the author's next turn sees it. [Pass]/[Warn] do
    nothing and return [Ok ()]. Dedup is by (task_id, verdict-class), so a
    repeated FAIL for the same task wakes once even when the model phrases the
    reason differently. Returns [Error] if recording the attention item fails,
    so the caller can decide whether to fail-closed. *)

val act_on_grounded_verdict :
  base_path:string ->
  input:review_input ->
  Verifier_core.grounded_verdict ->
  (unit, string) result
(** Like {!act_on_verdict}, but failed verdict wake metadata includes the
    serialized grounded verdict so dashboard/turn surfaces can show the cited
    code evidence. *)

val review_and_wake_on_fail :
  base_path:string ->
  runtime_id:string ->
  review_input ->
  (Verifier_core.verdict, string) result
(** [run_grounded_review] followed by [act_on_grounded_verdict] on the resulting
    verdict, returning the compatibility [Verifier_core.verdict]. *)

module For_testing : sig
  val parse_grounded_verdict_from_response_text :
    string -> (Verifier_core.grounded_verdict, string) result
end
