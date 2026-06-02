(** [STATE]-aware summarizer for OAS compaction.

    Wraps OAS's default summarizer with [STATE]...[/STATE] block
    scrubbing on every Text content block, closing the compaction-layer
    half of the resonance loop that Gen3 (PR #7647) closed only at the
    prompt injection layer.

    OAS/MASC boundary: OAS knows nothing about [STATE] markers
    (feedback_oas-must-not-know-masc). This module supplies the
    domain-aware callback through OAS's generic
    [Agent.options.summarizer] API (OAS 0.152.0, PR #973), delegating
    to [Agent_sdk.Budget_strategy.default_summarizer] (OAS 0.153.0, PR #975). *)

(** Scrub [STATE]...[/STATE] from every Text block in a message. *)
val scrub_text_blocks : Agent_sdk.Types.message -> Agent_sdk.Types.message

(** Scrub [STATE] blocks then delegate to OAS's default summarizer.
    Pass this to [Agent_sdk.Builder.with_summarizer]. *)
val keeper_summarizer : Agent_sdk.Types.message list -> string
