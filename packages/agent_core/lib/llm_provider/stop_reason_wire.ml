type wire_finish =
  | Tool_calls
  | Length
  | Stop
  | Refusal
  | Content_filter
  | Repetition_truncation
  | Context_window_exceeded
  | Other of string

let wire_finish_of_string s =
  let normalized = String.lowercase_ascii s in
  match normalized with
  | "tool_calls" -> Tool_calls
  | "stop" -> Stop
  | other ->
    (* [Types.stop_reason_of_string] owns the canonical and provider-dialect
       tokens.  This boundary only translates that typed result into the
       smaller finish-reason vocabulary needed for tool-block reconciliation. *)
    (match Types.stop_reason_of_string other with
     | Types.StopToolUse -> Tool_calls
     | Types.EndTurn -> Stop
     | Types.MaxTokens -> Length
     | Types.Refusal -> Refusal
     | Types.ContentFilter -> Content_filter
     | Types.RepetitionTruncation -> Repetition_truncation
     | Types.ContextWindowExceeded -> Context_window_exceeded
     | Types.StopSequence
     | Types.PauseTurn
     | Types.Compaction
     | Types.UnmatchedToolCalls
     | Types.Unknown _ -> Other other)
;;

let of_finish (w : wire_finish) ~has_tool_blocks : Types.stop_reason =
  match w with
  | Tool_calls -> if has_tool_blocks then Types.StopToolUse else Types.UnmatchedToolCalls
  | Length -> Types.MaxTokens
  (* Parse-time parity with [reconcile]: a [Stop] (finish_reason=stop/end_turn)
     that nonetheless carried complete tool blocks is a provider mislabel of a
     tool-request turn, so trust the content and upgrade to [StopToolUse]. This
     keeps the streaming chain ([provisional_of_string] |> [reconcile]) and the
     non-streaming parser ([of_finish]) in agreement. Scoped to [Stop] only —
     [Length] stays [MaxTokens] because a length-truncated tool call may be
     incomplete and unsafe to auto-execute. *)
  | Stop -> if has_tool_blocks then Types.StopToolUse else Types.EndTurn
  | Refusal -> Types.Refusal
  | Content_filter -> Types.ContentFilter
  | Repetition_truncation -> Types.RepetitionTruncation
  | Context_window_exceeded -> Types.ContextWindowExceeded
  | Other other -> Types.stop_reason_of_string other
;;

let provisional_of_string s : Types.stop_reason =
  match wire_finish_of_string s with
  | Tool_calls -> Types.StopToolUse
  | Length -> Types.MaxTokens
  | Stop -> Types.EndTurn
  | Refusal -> Types.Refusal
  | Content_filter -> Types.ContentFilter
  | Repetition_truncation -> Types.RepetitionTruncation
  | Context_window_exceeded -> Types.ContextWindowExceeded
  | Other other -> Types.stop_reason_of_string other
;;

let reconcile (sr : Types.stop_reason) ~has_tool_blocks : Types.stop_reason =
  match sr with
  | Types.StopToolUse when not has_tool_blocks -> Types.UnmatchedToolCalls
  | Types.UnmatchedToolCalls when has_tool_blocks -> Types.StopToolUse
  (* "trust content over label" for normal completion: a provider that emitted
     complete tool_use blocks but labeled the turn [EndTurn]
     (OpenAI/GLM finish_reason=stop) is mislabeling a tool-request turn. The
     tool-block presence is authoritative, so upgrade to [StopToolUse] and let
     the driver execute the tools instead of ending the turn with dangling
     tool_uses (tool_use blocks with no tool_result). Mirrors the same upgrade
     already applied to [UnmatchedToolCalls] + blocks and [Unknown] + blocks.
     Deliberately scoped to [EndTurn] only. [MaxTokens] + blocks may be a
     TRUNCATED/incomplete tool call, so auto-executing it is unsafe;
     [Refusal]/[ContentFilter]/[RepetitionTruncation]/[StopSequence]/
     [PauseTurn]/[Compaction]/[ContextWindowExceeded] carry specific terminal
     meaning where executing a stray tool block is unsafe or ambiguous. Only
     normal completion + blocks is an unambiguous provider mislabel. *)
  | Types.EndTurn when has_tool_blocks -> Types.StopToolUse
  | Types.StopToolUse
  | Types.EndTurn
  | Types.MaxTokens
  | Types.StopSequence
  | Types.Refusal
  | Types.ContentFilter
  | Types.RepetitionTruncation
  | Types.PauseTurn
  | Types.Compaction
  | Types.ContextWindowExceeded
  | Types.UnmatchedToolCalls
  | Types.Unknown _ -> sr
;;

let is_unmatched_tool_calls = function
  | Types.UnmatchedToolCalls -> true
  | Types.Unknown _ -> false
  | Types.StopToolUse
  | Types.EndTurn
  | Types.MaxTokens
  | Types.StopSequence
  | Types.Refusal
  | Types.ContentFilter
  | Types.RepetitionTruncation
  | Types.PauseTurn
  | Types.Compaction
  | Types.ContextWindowExceeded -> false
;;

[@@@coverage off]

(* === Inline drift-guard tests ===
   Pin the StopToolUse => has-tool-block invariant across the parse-time
   ([of_finish]) and streaming ([provisional_of_string] |> [reconcile]) paths.
   Reverting either the [of_finish] guard or the [reconcile] downgrade turns
   these RED (non-vacuous regression guard). Gemini/Ollama use a different wire
   vocabulary and already guard at their own (accumulating) finish chunk; their
   coverage belongs with the pipeline no-reissue test. *)

let%test "of_finish tool_calls without tools fails closed to typed outcome" =
  of_finish Tool_calls ~has_tool_blocks:false = Types.UnmatchedToolCalls
;;

let%test "of_finish tool_calls with tools is StopToolUse" =
  of_finish Tool_calls ~has_tool_blocks:true = Types.StopToolUse
;;

let%test "reconcile downgrades StopToolUse without tools" =
  reconcile Types.StopToolUse ~has_tool_blocks:false = Types.UnmatchedToolCalls
;;

let%test "reconcile preserves StopToolUse with tools" =
  reconcile Types.StopToolUse ~has_tool_blocks:true = Types.StopToolUse
;;

(* EndTurn + tool blocks is a provider mislabel (finish_reason=stop alongside
   complete tool_calls): upgrade to StopToolUse so the driver executes the tools
   instead of persisting dangling tool_uses. Reverting the new [reconcile] arm
   turns this RED. *)
let%test "reconcile upgrades EndTurn with tools to StopToolUse" =
  reconcile Types.EndTurn ~has_tool_blocks:true = Types.StopToolUse
;;

(* A normal completion with no tool blocks still ends the turn. *)
let%test "reconcile preserves EndTurn without tools" =
  reconcile Types.EndTurn ~has_tool_blocks:false = Types.EndTurn
;;

let%test "reconcile preserves Unknown with tools as non-executable" =
  reconcile (Types.Unknown "provider_terminal") ~has_tool_blocks:true
  = Types.Unknown "provider_terminal"
;;

let%test "of_finish restores canonical reason outside wire vocabulary" =
  of_finish (Other "stop_sequence") ~has_tool_blocks:true = Types.StopSequence
;;

let%test "provisional restores canonical reason outside wire vocabulary" =
  provisional_of_string "pause_turn" = Types.PauseTurn
;;

(* Truncation safety: MaxTokens + tool blocks is NOT upgraded, because a
   length-truncated tool call may be incomplete and unsafe to auto-execute.
   Reverting the [EndTurn]-scoping (e.g. widening the guard to MaxTokens) turns
   this RED. *)
let%test "reconcile preserves MaxTokens with tools (truncation not upgraded)" =
  reconcile Types.MaxTokens ~has_tool_blocks:true = Types.MaxTokens
;;

(* Parse-time counterpart of the upgrade for the non-streaming OpenAI parser,
   which calls [of_finish] directly (no [reconcile]). Reverting the [of_finish]
   [Stop] guard turns this RED. *)
let%test "of_finish Stop with tools is StopToolUse" =
  of_finish Stop ~has_tool_blocks:true = Types.StopToolUse
;;

let%test "of_finish Stop without tools is EndTurn" =
  of_finish Stop ~has_tool_blocks:false = Types.EndTurn
;;

(* of_finish Length (finish_reason=length) keeps MaxTokens even with tools —
   truncation is preserved on the parse-time path too. *)
let%test "of_finish Length with tools stays MaxTokens" =
  of_finish Length ~has_tool_blocks:true = Types.MaxTokens
;;

(* Streaming (provisional |> reconcile) and parse-time (of_finish) must agree
   for finish_reason=stop with tools. Reverting EITHER the reconcile arm OR the
   of_finish guard breaks parity here (one side changes, the other does not). *)
let%test "streaming chain matches parse-time of_finish for stop + tools" =
  let chain hb =
    reconcile (provisional_of_string "stop") ~has_tool_blocks:hb
    = of_finish (wire_finish_of_string "stop") ~has_tool_blocks:hb
  in
  chain true && chain false
;;

let%test "streaming chain matches parse-time of_finish for end_turn + tools" =
  reconcile (provisional_of_string "end_turn") ~has_tool_blocks:true
  = of_finish (wire_finish_of_string "end_turn") ~has_tool_blocks:true
;;

let%test "is_unmatched_tool_calls recognizes only canonical fail-closed value" =
  is_unmatched_tool_calls Types.UnmatchedToolCalls
  && (not (is_unmatched_tool_calls (Types.Unknown "tool_calls")))
  && (not (is_unmatched_tool_calls (Types.Unknown "other")))
  && not (is_unmatched_tool_calls Types.StopToolUse)
;;

let%test "provisional tool_calls is StopToolUse (faithful wire claim)" =
  provisional_of_string "tool_calls" = Types.StopToolUse
;;

let%test "streaming chain (provisional |> reconcile) matches parse-time of_finish" =
  let chain hb =
    reconcile (provisional_of_string "tool_calls") ~has_tool_blocks:hb
    = of_finish (wire_finish_of_string "tool_calls") ~has_tool_blocks:hb
  in
  chain true && chain false
;;

let%test
    "streaming chain (provisional |> reconcile) matches parse-time of_finish for Other + \
     tools"
  =
  let s = "function_call" in
  reconcile (provisional_of_string s) ~has_tool_blocks:true
  = of_finish (wire_finish_of_string s) ~has_tool_blocks:true
;;

let%test "known terminal reasons map identically on both paths" =
  let same s =
    provisional_of_string s = of_finish (wire_finish_of_string s) ~has_tool_blocks:false
  in
  same "stop"
  && same "end_turn"
  && same "length"
  && same "refusal"
  && same "content_filter"
  && same "repetition_truncation"
  && same "model_context_window_exceeded"
;;

(* oas#2621 wire-root regression guard: the overflow finish-reason token must
   decode to [ContextWindowExceeded] on BOTH the parse-time ([of_finish]) and
   streaming ([provisional_of_string]) paths, and the guard must ignore
   [has_tool_blocks] (an overflow turn is terminal regardless of any block set).
   Reverting the [Context_window_exceeded] wire branch turns these RED. *)
let%test "overflow token decodes to ContextWindowExceeded (parse-time, no tools)" =
  of_finish (wire_finish_of_string "model_context_window_exceeded") ~has_tool_blocks:false
  = Types.ContextWindowExceeded
;;

let%test "overflow token decodes to ContextWindowExceeded (parse-time, with tools)" =
  of_finish (wire_finish_of_string "model_context_window_exceeded") ~has_tool_blocks:true
  = Types.ContextWindowExceeded
;;

let%test "overflow token decodes to ContextWindowExceeded (streaming provisional)" =
  provisional_of_string "model_context_window_exceeded" = Types.ContextWindowExceeded
;;

let%test "overflow token decode is case-insensitive" =
  provisional_of_string "MODEL_CONTEXT_WINDOW_EXCEEDED" = Types.ContextWindowExceeded
;;
