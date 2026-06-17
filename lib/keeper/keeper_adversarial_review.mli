(** Keeper_adversarial_review — adversarial review of submitted work as an
    agentic verdict, with author wake-on-fail.

    Decoupled from [Verifier_oas] (the OAS per-tool gate) and from
    [Anti_rationalization] (the completion-notes judge): this module has its
    own prompt ([config/prompts/verification.adversarial_review.md]), its own
    entry point, and its own output. It shares only the generic judging engine
    ([Keeper_turn_driver_wrappers.run_named_with_masc_tools]) and the
    [Verifier_core] verdict surface.

    The verdict is the LLM's judgment — there is no rule, heuristic, or string
    match deciding pass/fail here. The only deterministic parts are identity
    (which keeper authored the work, hence who to wake) and event-id dedup (a
    given verdict wakes the author at most once). *)

type review_input = {
  task_id : string;
  task_title : string;
  task_description : string;
  author_keeper : string;
  evidence_refs : string;
}

val build_prompt : review_input -> string
(** Render the adversarial review prompt from
    [config/prompts/verification.adversarial_review.md]. *)

val run_review :
  runtime_id:string -> review_input -> (Verifier_core.verdict, string) result
(** Run the adversarial reviewer agent and read its structured verdict via the
    [report_verdict] tool, falling back to text parsing if the model answers in
    free text. *)

val act_on_verdict :
  base_path:string -> input:review_input -> Verifier_core.verdict -> unit
(** On [Fail], record an external-attention item waking [author_keeper] with
    the verdict reason so the author's next turn sees it. [Pass]/[Warn] do
    nothing. Dedup is by (task_id, reason) so the same rejection wakes once. *)

val review_and_wake_on_fail :
  base_path:string ->
  runtime_id:string ->
  review_input ->
  (Verifier_core.verdict, string) result
(** [run_review] followed by [act_on_verdict] on the resulting verdict. *)
