(** Context_compact_oas — direct delegation to OAS Context_reducer.

    MASC messages are [Agent_sdk.Types.message] — the same type OAS uses.
    No role conversion or sentinel tagging is needed; OAS Context_reducer
    natively supports all 4 roles (System, User, Assistant, Tool) and
    preserves ToolUse/ToolResult pairing.

    MASC-specific strategies (DropLowImportance, SummarizeOld) use OAS
    Custom closures to inject domain logic that OAS does not provide.

    @since Phase 1 — OAS Context_reducer integration
    @since Phase B — Sentinel removal (roles are natively compatible) *)

(* ================================================================ *)
(* Strategy Type                                                     *)
(* ================================================================ *)

type strategy =
  | PruneToolOutputs
  | MergeContiguous
  | DropLowImportance
  | SummarizeOld

(* ================================================================ *)
(* Token Estimation                                                  *)
(* ================================================================ *)

let msg_tokens (m : Agent_sdk.Types.message) =
  let text = Agent_sdk.Types.text_of_message m in
  (String.length text / 4) + 4

let count_tokens (system_prompt : string) (msgs : Agent_sdk.Types.message list) =
  let sys_tokens = (String.length system_prompt / 4) + 4 in
  List.fold_left (fun acc m -> acc + msg_tokens m) sys_tokens msgs

(* ================================================================ *)
(* Importance Scoring (inlined from Context_scoring)                 *)
(* ================================================================ *)

let memory_summary_prefix = "[MASC_MEMORY_SUMMARY v1]"

let goal_prefix = "[MASC_GOAL]"

let starts_with ~prefix s =
  let lp = String.length prefix in
  String.length s >= lp && String.sub s 0 lp = prefix

(** Score a list of messages by importance.
    Returns [(index, score)] pairs where score is in [0.0, 1.0]. *)
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

(* ================================================================ *)
(* Strategy Mapping: Local -> OAS                                   *)
(* ================================================================ *)

(** Map a local strategy to an OAS Context_reducer strategy.

    - PruneToolOutputs and MergeContiguous use OAS built-in strategies directly.
    - DropLowImportance uses OAS Custom with importance scoring (OAS has no scoring).
    - SummarizeOld uses OAS Custom with extractive summarization (deterministic, no model call). *)
let oas_strategy_of (s : strategy) : Agent_sdk.Context_reducer.strategy =
  match s with
  | PruneToolOutputs ->
    Agent_sdk.Context_reducer.Prune_tool_outputs { max_output_len = 500 }
  | MergeContiguous ->
    Agent_sdk.Context_reducer.Merge_contiguous
  | DropLowImportance ->
    Agent_sdk.Context_reducer.Custom (fun msgs ->
      let scores = score_messages msgs in
      let threshold = 0.3 in
      List.filteri (fun i _m ->
        match List.assoc_opt i scores with
        | Some score -> score >= threshold
        | None -> true
      ) msgs)
  | SummarizeOld ->
    Agent_sdk.Context_reducer.Summarize_old {
      keep_recent = 5;
      summarizer = (fun old_msgs ->
        let first_sentence (s : string) =
          let s = String.trim s in
          let max_len = 120 in
          let cut_at =
            let period = try Some (String.index s '.') with Not_found -> None in
            let newline = try Some (String.index s '\n') with Not_found -> None in
            match period, newline with
            | Some p, Some n -> Some (min p n + 1)
            | Some p, None -> Some (p + 1)
            | None, Some n -> Some n
            | None, None -> None
          in
          match cut_at with
          | Some pos when pos <= max_len -> String.sub s 0 pos
          | _ -> if String.length s > max_len then String.sub s 0 max_len ^ "..." else s
        in
        let lines = old_msgs |> List.mapi (fun i m ->
          let role_str = match m.Agent_sdk.Types.role with
            | Agent_sdk.Types.User -> "user"
            | Agent_sdk.Types.Assistant -> "assistant"
            | Agent_sdk.Types.System -> "system"
            | Agent_sdk.Types.Tool -> "tool"
          in
          let text = String.trim (Agent_sdk.Types.text_of_message m) in
          if text = "" then None
          else Some (Printf.sprintf "[%d] %s: %s" (i + 1) role_str (first_sentence text))
        ) |> List.filter_map Fun.id in
        Printf.sprintf "[Compacted %d messages into summary]\n%s"
          (List.length old_msgs) (String.concat "\n" lines)
      );
    }

(* ================================================================ *)
(* Public API                                                       *)
(* ================================================================ *)

(** Apply compaction via OAS Context_reducer.

    Messages are passed directly — no role conversion needed since
    MASC and OAS share the same [Agent_sdk.Types.message] type with
    the same 4 roles (System, User, Assistant, Tool). *)
let compact
    ~(system_prompt : string)
    ~(messages : Agent_sdk.Types.message list)
    ~(strategies : strategy list)
  : Agent_sdk.Types.message list * int =
  let oas_strategies = List.map oas_strategy_of strategies in
  let reducer = Agent_sdk.Context_reducer.compose
    (List.map (fun s -> { Agent_sdk.Context_reducer.strategy = s }) oas_strategies) in
  let reduced = Agent_sdk.Context_reducer.reduce reducer messages in
  let token_count = count_tokens system_prompt reduced in
  (reduced, token_count)
