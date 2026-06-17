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
    free-text fallback parses a JSON payload with
    [Verifier_core.parse_verdict_from_json]; it does not use string matching to
    decide pass/fail. The only deterministic parts are identity (which keeper
    authored the work, hence who to wake) and event-id dedup (a given verdict
    wakes the author at most once).

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
    template variables cannot be replaced or if any [{{...}}] placeholders
    remain after rendering (fail-closed). *)

val run_review :
  runtime_id:string -> review_input -> (Verifier_core.verdict, string) result
(** Run the adversarial reviewer agent and read its structured verdict via the
    [report_verdict] tool. If the model answers in free text, the fallback
    attempts to parse a JSON payload and decode it with
    [Verifier_core.parse_verdict_from_json]; it never uses string matching to
    decide pass/fail. *)

val act_on_verdict :
  base_path:string -> input:review_input -> Verifier_core.verdict -> (unit, string) result
(** On [Fail], record an external-attention item waking [author_keeper] with
    the verdict reason so the author's next turn sees it. [Pass]/[Warn] do
    nothing and return [Ok ()]. Dedup is by (task_id, reason) so the same
    rejection wakes once. Returns [Error] if recording the attention item
    fails, so the caller can decide whether to fail-closed. *)

val review_and_wake_on_fail :
  base_path:string ->
  runtime_id:string ->
  review_input ->
  (Verifier_core.verdict, string) result
(** [run_review] followed by [act_on_verdict] on the resulting verdict. *)
