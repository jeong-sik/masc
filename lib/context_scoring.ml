(** Context_scoring — Shared importance scoring for MASC messages.

    Single source of truth for message importance scoring used by both
    [Context_manager] and [Context_compact_oas]. Extracted to prevent
    divergence between the two compaction paths (legacy and OAS adapter).

    Based on Stanford Generative Agents adapted scoring:
    - Recency: quadratic decay from most recent
    - Role weight: system > tool results > user > assistant
    - Content length: longer messages tend to be more important
    - Tool calls: messages with tool actions are important
    - Sticky memory: compacted summaries and goal injections are never dropped

    @since 2.111.0 — Extracted from Context_manager + Context_compact_oas *)

(** Prefix for compacted memory summaries. Messages with this prefix
    receive a minimum importance score of 0.95. *)
let memory_summary_prefix = "[MASC_MEMORY_SUMMARY v1]"

(** Prefix for goal injection messages. Messages with this prefix
    receive a minimum importance score of 0.95. *)
let goal_prefix = "[MASC_GOAL]"

(** Check if [s] starts with [prefix]. *)
let starts_with ~prefix s =
  let lp = String.length prefix in
  String.length s >= lp && String.sub s 0 lp = prefix

(** Score a list of messages by importance.

    Returns [(index, score)] pairs where score is in [0.0, 1.0].
    Higher scores indicate more important messages.

    Weights: recency 0.4, role 0.25, content 0.2, tool 0.15.

    Messages starting with [memory_summary_prefix] or [goal_prefix]
    receive a minimum score of 0.95 (sticky memory). *)
let score_messages (msgs : Agent_sdk.Types.message list) : (int * float) list =
  let n = List.length msgs in
  List.mapi (fun i (m : Agent_sdk.Types.message) ->
    let recency = if n <= 1 then 1.0
      else let t = float_of_int i /. float_of_int (n - 1) in
           t *. t
    in
    let role_w = match m.role with
      | Agent_sdk.Types.System -> 1.0
      | Agent_sdk.Types.Tool -> 0.7
      | Agent_sdk.Types.User -> 0.6
      | Agent_sdk.Types.Assistant -> 0.4
    in
    let msg_text = Agent_sdk.Types.text_of_message m in
    let len = String.length msg_text in
    let content_w = if len < 20 then 0.3
      else if len < 100 then 0.6
      else if len < 500 then 0.8
      else 0.7
    in
    let has_tool_content = List.exists (function
      | Agent_sdk.Types.ToolUse _ | Agent_sdk.Types.ToolResult _ -> true
      | _ -> false) m.content
    in
    let tool_w = if has_tool_content then 0.8 else 0.5 in
    let score = 0.4 *. recency +. 0.25 *. role_w +. 0.2 *. content_w +. 0.15 *. tool_w in
    let score =
      if starts_with ~prefix:memory_summary_prefix msg_text
         || starts_with ~prefix:goal_prefix msg_text then
        Float.max score 0.95
      else score
    in
    (i, Float.min 1.0 (Float.max 0.0 score))
  ) msgs
