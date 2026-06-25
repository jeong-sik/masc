(** OAS response helpers.

    Repo-local code should read SDK responses through this module rather than
    reaching into provider-specific helper namespaces. *)

type api_response = Agent_sdk.Types.api_response

let text_of_response (response : api_response) =
  Agent_sdk.Types.text_of_content response.content

let usage (response : api_response) = response.usage

let stop_reason_string (response : api_response) =
  (* Surface the provider's terminal reason as the agent_sdk canonical string,
     so repo-local code never reaches into provider-specific namespaces (this
     module's stated purpose). The SDK's own [Agent_tool.stop_reason_to_string]
     is not exported in its .mli, so we mirror its exact mapping here over the
     closed [Agent_sdk.Types.stop_reason] sum (no wildcard — a new SDK variant
     is a compile error here, forcing a deliberate string choice). Consumed by
     [Multimodal.Vision_analyze.done_reason_of_string], which maps "end_turn"
     -> Stop and "max_tokens" -> Length. *)
  match response.stop_reason with
  | Agent_sdk.Types.EndTurn -> "end_turn"
  | Agent_sdk.Types.StopToolUse -> "tool_use"
  | Agent_sdk.Types.MaxTokens -> "max_tokens"
  | Agent_sdk.Types.StopSequence -> "stop_sequence"
  | Agent_sdk.Types.Refusal -> "refusal"
  | Agent_sdk.Types.PauseTurn -> "pause_turn"
  | Agent_sdk.Types.Compaction -> "compaction"
  | Agent_sdk.Types.ContextWindowExceeded -> "model_context_window_exceeded"
  | Agent_sdk.Types.Unknown s -> s
