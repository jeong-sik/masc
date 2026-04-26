(** [STATE]-aware summarizer for OAS compaction.

    OAS [Budget_strategy.reduce_for_budget] calls its summarizer with the
    oldest-N messages when the context ratio crosses the Emergency
    threshold. The default summarizer takes the first 100 chars of each
    message's first Text block and prefixes `[role]`. If a message begins
    with `[STATE]\n...`, those characters land verbatim in the produced
    summary, which the LLM then re-reads the next turn as the prefix of
    `[Summary of N earlier messages]`. That is the compaction-layer half
    of the resonance loop that Gen3 (PR #7647) closed only at the prompt
    injection layer.

    This module wraps the default summarizer after scrubbing
    `[STATE]...[/STATE]` blocks from every Text block. Consumers register
    it via [Oas.Builder.with_summarizer] on the agent they build.

    OAS/MASC boundary: OAS knows nothing about [STATE] markers (see
    feedback_oas-must-not-know-masc). This module lives on the MASC side
    and supplies the domain-aware callback through OAS's generic
    [Agent.options.summarizer] API added in OAS 0.152.0 (PR #973). OAS
    0.153.0 (PR #975) exported [Budget_strategy.default_summarizer] so we
    delegate to it directly instead of re-implementing the extractive
    logic here. *)

let scrub_text_blocks (msg : Oas.Types.message) : Oas.Types.message =
  let content' =
    List.map
      (function
        | Oas.Types.Text s ->
          Oas.Types.Text (Keeper_text_processing.strip_state_blocks_text s)
        | other -> other)
      msg.content
  in
  { msg with content = content' }
;;

(** Scrub [STATE] blocks from each message's Text before summarization,
    then delegate to OAS's exported default summarizer. Callers pass
    this to [Oas.Builder.with_summarizer]. *)
let keeper_summarizer (messages : Oas.Types.message list) : string =
  let scrubbed = List.map scrub_text_blocks messages in
  Oas.Budget_strategy.default_summarizer scrubbed
;;
