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
    [Agent.options.summarizer] API added in OAS 0.152.0 (PR #973). *)

let scrub_text_blocks (msg : Agent_sdk.Types.message) : Agent_sdk.Types.message =
  let content' =
    List.map
      (function
        | Agent_sdk.Types.Text s ->
          Agent_sdk.Types.Text (Keeper_text_processing.strip_state_blocks_text s)
        | other -> other)
      msg.content
  in
  { msg with content = content' }

(** Re-implementation of OAS [Budget_strategy.default_summarizer], which
    is not exported in the .mli as of 0.152.0. Mirrors the original
    extractive logic: first Text block per message, truncated at 100
    chars, prefixed with role. Kept in sync with OAS contract; if OAS
    ever exports the function, this fallback can be deleted. *)
let default_extractive_summary (messages : Agent_sdk.Types.message list) : string =
  let lines =
    List.filter_map
      (fun (msg : Agent_sdk.Types.message) ->
        let role_str =
          match msg.role with
          | Agent_sdk.Types.User -> "User"
          | Agent_sdk.Types.Assistant -> "Assistant"
          | Agent_sdk.Types.System -> "System"
          | Agent_sdk.Types.Tool -> "Tool"
        in
        let first_text =
          List.find_map
            (function
              | Agent_sdk.Types.Text s when String.length s > 0 ->
                let truncated =
                  if String.length s > 100 then String.sub s 0 100 ^ "..." else s
                in
                Some truncated
              | _ -> None)
            msg.content
        in
        match first_text with
        | Some t -> Some (Printf.sprintf "[%s] %s" role_str t)
        | None -> None)
      messages
  in
  match lines with
  | [] -> "[No prior context]"
  | _ ->
    Printf.sprintf "[Summary of %d earlier messages]\n%s"
      (List.length messages)
      (String.concat "\n" lines)

(** Scrub [STATE] blocks from each message's Text before summarization.
    Callers pass this to [Agent_sdk.Builder.with_summarizer]. *)
let keeper_summarizer (messages : Agent_sdk.Types.message list) : string =
  let scrubbed = List.map scrub_text_blocks messages in
  default_extractive_summary scrubbed
