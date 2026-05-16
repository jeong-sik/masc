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
    it via [Agent_sdk.Builder.with_summarizer] on the agent they build.

    OAS/MASC boundary: OAS knows nothing about [STATE] markers (see
    feedback_oas-must-not-know-masc). This module lives on the MASC side
    and supplies the domain-aware callback through OAS's generic
    [Agent.options.summarizer] API added in OAS 0.152.0 (PR #973). OAS
    0.153.0 (PR #975) exported [Budget_strategy.default_summarizer] so we
    delegate to it directly instead of re-implementing the extractive
    logic here. *)

(* Observability for [STATE] block scrubbing.  The compaction-layer
   resonance-loop closure was previously silent — operators could
   not tell how often the summarizer was being asked to digest
   assistant turns that still carry [STATE] markers (the very
   condition PR #7647 closed at the prompt-injection layer).
   Closes the silent gap noted in
   .tmp/memory-compacting-analysis.html (summarizer STATE scrub
   visibility). *)
let () =
  Prometheus.register_counter
    ~name:Keeper_metrics.metric_keeper_summarizer_state_scrubs
    ~help:
      "Total [Keeper_summarizer.keeper_summarizer] invocations, \
       classified by label [outcome] (with_scrub | without_scrub).  \
       Rising [with_scrub] rate is the resonance-loop input \
       indicator at the compaction layer."
    ();
  Prometheus.register_counter
    ~name:Keeper_metrics.metric_keeper_summarizer_state_blocks_removed
    ~help:
      "Total [STATE] block start markers scrubbed across all \
       [keeper_summarizer] invocations.  Divide by the \
       with_scrub counter for blocks-per-scrub."
    ()
;;

(* Counting helper: number of [STATE] occurrences in a string.
   Bounds the count to non-overlapping matches — same semantics as
   the strip loop in [Keeper_text_processing]. *)
let re_state_start = Re.str "[STATE]" |> Re.compile

let count_state_blocks (s : string) : int =
  Re.all re_state_start s |> List.length

(* Counted variant: returns the scrubbed message and the number of
   [STATE] start markers removed.  Internal — used by
   [keeper_summarizer] for observability.  The public
   [scrub_text_blocks] preserves the original signature so external
   callers compile unchanged. *)
let scrub_text_blocks_counted (msg : Agent_sdk.Types.message)
  : Agent_sdk.Types.message * int =
  let removed = ref 0 in
  let content' =
    List.map
      (function
        | Agent_sdk.Types.Text s ->
          removed := !removed + count_state_blocks s;
          Agent_sdk.Types.Text
            (Keeper_text_processing.strip_state_blocks_text s)
        | other -> other)
      msg.content
  in
  { msg with content = content' }, !removed

let scrub_text_blocks (msg : Agent_sdk.Types.message)
  : Agent_sdk.Types.message =
  let msg', _ = scrub_text_blocks_counted msg in
  msg'

(** Scrub [STATE] blocks from each message's Text before summarization,
    then delegate to OAS's exported default summarizer. Callers pass
    this to [Agent_sdk.Builder.with_summarizer]. *)
let keeper_summarizer (messages : Agent_sdk.Types.message list) : string =
  let scrubbed, total_removed =
    List.fold_left
      (fun (acc_msgs, acc_removed) msg ->
        let msg', removed = scrub_text_blocks_counted msg in
        msg' :: acc_msgs, acc_removed + removed)
      ([], 0)
      messages
  in
  let scrubbed = List.rev scrubbed in
  let outcome =
    if total_removed > 0 then "with_scrub" else "without_scrub"
  in
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_summarizer_state_scrubs
    ~labels:[("outcome", outcome)]
    ();
  if total_removed > 0 then
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_summarizer_state_blocks_removed
      ~delta:(float_of_int total_removed)
      ();
  Agent_sdk.Budget_strategy.default_summarizer scrubbed
