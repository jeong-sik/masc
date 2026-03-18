(** Context_compact_oas — Thin adapter bridging MASC compaction to OAS Context_reducer.

    Converts MASC messages to OAS messages, applies OAS Context_reducer strategies,
    and converts back. This is Phase 1 of migrating MASC to use OAS properly.

    This module is deliberately independent of Context_manager to avoid circular
    dependency. It operates on [Llm_client.message list] directly and uses its own
    strategy enum that mirrors Context_manager.compaction_strategy.

    MASC has 4 roles (System, User, Assistant, Tool) while OAS has the same 4.
    OAS Context_reducer strategies operate on OAS message lists and respect
    ToolUse/ToolResult pairing. We use sentinel-tagged text to preserve MASC
    role semantics through the OAS pipeline.

    @since Phase 1 — OAS Context_reducer integration *)

open Printf

(* ================================================================ *)
(* Strategy Type (mirrors Context_manager.compaction_strategy)       *)
(* ================================================================ *)

(** Local copy of compaction strategies to avoid Context_manager dependency.
    Must stay in sync with Context_manager.compaction_strategy. *)
type strategy =
  | PruneToolOutputs
  | MergeContiguous
  | DropLowImportance
  | SummarizeOld

(* ================================================================ *)
(* Role Tag Sentinels                                               *)
(* ================================================================ *)

(** \x00-prefixed sentinels prevent collision with user content.
    No valid UTF-8 user text starts with a null byte. *)
let system_role_tag = "\x00__MASC_ROLE:system__\x00"
let tool_role_tag = "\x00__MASC_ROLE:tool__\x00"

let starts_with ~prefix s =
  let lp = String.length prefix in
  String.length s >= lp && String.sub s 0 lp = prefix

(* ================================================================ *)
(* MASC <-> OAS Message Conversion                                  *)
(* ================================================================ *)

(** Convert a MASC message to an OAS message with role tags for lossless roundtrip.
    System and Tool roles are mapped to User with a sentinel prefix so OAS
    strategies (which expect User/Assistant alternation) handle them correctly. *)
let masc_msg_to_oas (m : Llm_client.message) : Agent_sdk.Types.message =
  let text = Llm_client.text_of_message m in
  let role, tagged_text = match m.role with
    | Llm_client.System -> Agent_sdk.Types.User, system_role_tag ^ text
    | Llm_client.Tool -> Agent_sdk.Types.User, tool_role_tag ^ text
    | Llm_client.User -> Agent_sdk.Types.User, text
    | Llm_client.Assistant -> Agent_sdk.Types.Assistant, text
  in
  let content = match m.role with
    | Llm_client.Tool ->
      let tool_use_id = Option.value ~default:"masc-tool" m.tool_call_id in
      [Agent_sdk.Types.ToolResult { tool_use_id; content = tagged_text; is_error = false }]
    | _ -> [Agent_sdk.Types.Text tagged_text]
  in
  { Agent_sdk.Types.role; content }

(** Recover a MASC message from a tagged OAS message.
    Strips sentinel prefixes and restores the original MASC role. *)
let oas_msg_to_masc (m : Agent_sdk.Types.message) : Llm_client.message =
  let text, tool_id =
    let parts = List.filter_map (fun (block : Agent_sdk.Types.content_block) ->
      match block with
      | Agent_sdk.Types.Text s -> Some (s, None)
      | Agent_sdk.Types.ToolResult { tool_use_id; content; _ } ->
        Some (content, Some tool_use_id)
      | _ -> None
    ) m.content in
    let texts = List.map fst parts in
    let ids = List.filter_map snd parts in
    (String.concat "\n" texts, List.nth_opt ids 0)
  in
  let role, content =
    if starts_with ~prefix:system_role_tag text then
      Llm_client.System,
      String.sub text (String.length system_role_tag)
        (String.length text - String.length system_role_tag)
    else if starts_with ~prefix:tool_role_tag text then
      Llm_client.Tool,
      String.sub text (String.length tool_role_tag)
        (String.length text - String.length tool_role_tag)
    else
      (match m.role with
       | Agent_sdk.Types.User -> Llm_client.User
       | Agent_sdk.Types.Assistant -> Llm_client.Assistant
       | Agent_sdk.Types.System -> Llm_client.System
       | Agent_sdk.Types.Tool -> Llm_client.Tool),
      text
  in
  let tool_call_id = match role with
    | Llm_client.Tool -> tool_id
    | _ -> None
  in
  { Llm_client.role; content = [Agent_sdk.Types.Text content]; name = None; tool_call_id }

(* ================================================================ *)
(* Importance Scoring (standalone — no Context_manager dependency)   *)
(* ================================================================ *)

(** Stanford Generative Agents adapted scoring (standalone version).
    Duplicated from Context_manager to avoid circular module dependency.
    TODO: Extract shared scoring into a separate module to avoid duplication. *)

let memory_summary_prefix = "[MASC_MEMORY_SUMMARY v1]"
let goal_prefix = "[MASC_GOAL]"

let score_messages (msgs : Llm_client.message list) : (int * float) list =
  let n = List.length msgs in
  List.mapi (fun i (m : Llm_client.message) ->
    let recency = if n <= 1 then 1.0
      else let t = float_of_int i /. float_of_int (n - 1) in
           t *. t
    in
    let role_w = match m.role with
      | Llm_client.System -> 1.0
      | Llm_client.Tool -> 0.7
      | Llm_client.User -> 0.6
      | Llm_client.Assistant -> 0.4
    in
    let msg_text = Llm_client.text_of_message m in
    let len = String.length msg_text in
    let content_w = if len < 20 then 0.3
      else if len < 100 then 0.6
      else if len < 500 then 0.8
      else 0.7
    in
    let tool_w = match m.tool_call_id with Some _ -> 0.8 | None -> 0.5 in
    let score = 0.4 *. recency +. 0.25 *. role_w +. 0.2 *. content_w +. 0.15 *. tool_w in
    let score =
      if starts_with ~prefix:memory_summary_prefix msg_text
         || starts_with ~prefix:goal_prefix msg_text then
        Float.max score 0.95
      else score
    in
    (i, Float.min 1.0 (Float.max 0.0 score))
  ) msgs

(* ================================================================ *)
(* Token Estimation                                                 *)
(* ================================================================ *)

let msg_tokens (m : Llm_client.message) =
  (String.length (Llm_client.text_of_message m) / 4) + 4

let count_tokens (system_prompt : string) (msgs : Llm_client.message list) =
  let sys_tokens = (String.length system_prompt / 4) + 4 in
  List.fold_left (fun acc m -> acc + msg_tokens m) sys_tokens msgs

(* ================================================================ *)
(* Strategy Mapping: Local -> OAS                                   *)
(* ================================================================ *)

(** Map a local strategy to an OAS Context_reducer strategy.

    - PruneToolOutputs and MergeContiguous map directly to OAS built-in strategies.
    - DropLowImportance uses OAS Custom strategy with inline scoring.
    - SummarizeOld uses OAS Custom strategy with heuristic summarization.

    TODO: SummarizeOld currently uses heuristic truncation, not LLM summarization.
    A proper implementation would accept a summarizer function parameter. *)
let oas_strategy_of (s : strategy) : Agent_sdk.Context_reducer.strategy =
  match s with
  | PruneToolOutputs ->
    Agent_sdk.Context_reducer.Prune_tool_outputs { max_output_len = 500 }
  | MergeContiguous ->
    Agent_sdk.Context_reducer.Merge_contiguous
  | DropLowImportance ->
    Agent_sdk.Context_reducer.Custom (fun oas_msgs ->
      let masc_msgs = List.map oas_msg_to_masc oas_msgs in
      let scores = score_messages masc_msgs in
      let threshold = 0.3 in
      let filtered = List.filteri (fun i _m ->
        match List.assoc_opt i scores with
        | Some score -> score >= threshold
        | None -> true
      ) masc_msgs in
      List.map masc_msg_to_oas filtered)
  | SummarizeOld ->
    Agent_sdk.Context_reducer.Custom (fun oas_msgs ->
      let masc_msgs = List.map oas_msg_to_masc oas_msgs in
      let n = List.length masc_msgs in
      let oldest_pct = 0.3 in
      let split_at = max 1 (int_of_float (float_of_int n *. oldest_pct)) in
      if n <= 2 then oas_msgs
      else
        let old_msgs = List.filteri (fun i _ -> i < split_at) masc_msgs in
        let recent_msgs = List.filteri (fun i _ -> i >= split_at) masc_msgs in
        let summary_parts = List.map (fun (m : Llm_client.message) ->
          let role_str = match m.role with
            | Llm_client.System -> "SYS" | Llm_client.User -> "USR"
            | Llm_client.Assistant -> "AST" | Llm_client.Tool -> "TOOL"
          in
          let mc = Llm_client.text_of_message m in
          let truncated = if String.length mc > 80
            then String.sub mc 0 80 ^ "..."
            else mc in
          sprintf "[%s] %s" role_str truncated
        ) old_msgs in
        let summary_text = sprintf "%s\n(Fallback summary of %d earlier messages; reference only.)\n%s"
          memory_summary_prefix (List.length old_msgs) (String.concat "\n" summary_parts) in
        let summary_msg = Llm_client.assistant_msg summary_text in
        List.map masc_msg_to_oas (summary_msg :: recent_msgs))

(* ================================================================ *)
(* Public API                                                       *)
(* ================================================================ *)

(** Apply compaction via the OAS Context_reducer pipeline.

    Takes MASC messages, system prompt, and strategies. Converts to OAS messages,
    builds a composed OAS reducer, runs the reduction, and converts back.

    Returns the compacted message list and new token count.

    This function is functionally equivalent to [Context_manager.compact]
    but routes through OAS Context_reducer, enabling A/B comparison. *)
let compact
    ~(system_prompt : string)
    ~(messages : Llm_client.message list)
    ~(strategies : strategy list)
  : Llm_client.message list * int =
  let oas_strategies = List.map oas_strategy_of strategies in
  let reducer = Agent_sdk.Context_reducer.compose
    (List.map (fun s -> { Agent_sdk.Context_reducer.strategy = s }) oas_strategies) in
  let oas_msgs = List.map masc_msg_to_oas messages in
  let reduced = Agent_sdk.Context_reducer.reduce reducer oas_msgs in
  let result_messages = List.map oas_msg_to_masc reduced in
  let token_count = count_tokens system_prompt result_messages in
  (result_messages, token_count)
