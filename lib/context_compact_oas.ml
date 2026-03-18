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
      let tool_use_id =
        List.find_map (function Agent_sdk.Types.ToolResult { tool_use_id; _ } -> Some tool_use_id | _ -> None) m.content
        |> Option.value ~default:"masc-tool"
      in
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
  let content_blocks = match role with
    | Llm_client.Tool ->
      let tool_use_id = Option.value ~default:"masc-tool" tool_id in
      [Agent_sdk.Types.ToolResult { tool_use_id; content; is_error = false }]
    | _ -> [Agent_sdk.Types.Text content]
  in
  { Agent_sdk.Types.role; content = content_blocks }

(* ================================================================ *)
(* Importance Scoring — delegated to Context_scoring (shared SSOT)  *)
(* ================================================================ *)

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
    (* Cannot delegate to OAS Merge_contiguous directly — it would merge
       consecutive User messages that carry different sentinel tags (System
       mapped to User, Tool mapped to User), corrupting role recovery.
       Use Custom wrapper that skips sentinel-tagged messages from merging. *)
    Agent_sdk.Context_reducer.Custom (fun oas_msgs ->
      let has_sentinel (m : Agent_sdk.Types.message) =
        List.exists (function
          | Agent_sdk.Types.Text s -> String.length s > 0 && s.[0] = '\x00'
          | Agent_sdk.Types.ToolResult { content; _ } ->
            String.length content > 0 && content.[0] = '\x00'
          | _ -> false
        ) m.content
      in
      (* Split into sentinel-protected and mergeable segments, merge only
         the mergeable ones via OAS, then reassemble in order. *)
      let reducer = { Agent_sdk.Context_reducer.strategy =
        Agent_sdk.Context_reducer.Merge_contiguous } in
      let rec process acc buf = function
        | [] ->
          let merged = if buf = [] then [] else
            Agent_sdk.Context_reducer.reduce reducer (List.rev buf) in
          List.rev_append acc merged
        | m :: rest when has_sentinel m ->
          let merged = if buf = [] then [] else
            Agent_sdk.Context_reducer.reduce reducer (List.rev buf) in
          process (m :: List.rev_append merged acc) [] rest
        | m :: rest ->
          process acc (m :: buf) rest
      in
      process [] [] oas_msgs)
  | DropLowImportance ->
    Agent_sdk.Context_reducer.Custom (fun oas_msgs ->
      let masc_msgs = List.map oas_msg_to_masc oas_msgs in
      let scores = Context_scoring.score_messages masc_msgs in
      let threshold = 0.3 in
      let filtered = List.filteri (fun i _m ->
        match List.assoc_opt i scores with
        | Some score -> score >= threshold
        | None -> true
      ) masc_msgs in
      List.map masc_msg_to_oas filtered)
  | SummarizeOld ->
    (* STUB: requires LLM call for real summarization.
       Falls back to Keep_first_and_last { first_n = 2; last_n = 5 }
       to preserve conversation boundaries without pretending to summarize. *)
    Agent_sdk.Context_reducer.Custom (fun oas_msgs ->
      let n = List.length oas_msgs in
      let first_n = 2 in
      let last_n = 5 in
      if n <= first_n + last_n then oas_msgs
      else
        let first = List.filteri (fun i _ -> i < first_n) oas_msgs in
        let last = List.filteri (fun i _ -> i >= n - last_n) oas_msgs in
        first @ last)

(* ================================================================ *)
(* Sentinel Roundtrip Validation                                    *)
(* ================================================================ *)

(** Validate that sentinel-tagged messages survive OAS reduction intact.
    Returns [true] if all sentinel tags in the original messages can be
    correctly recovered from the reduced messages. Detects corruption
    from strategies like Merge_contiguous or Summarize_old that may
    concatenate or truncate content containing \x00 sentinel bytes. *)
let validate_roundtrip
    ~(original : Llm_client.message list)
    ~(reduced : Llm_client.message list)
  : bool =
  (* Count sentinel-tagged messages (System and Tool roles) in original *)
  let count_sentinels msgs =
    List.fold_left (fun acc (m : Llm_client.message) ->
      match m.role with
      | Llm_client.System | Llm_client.Tool -> acc + 1
      | _ -> acc
    ) 0 msgs
  in
  let original_sentinel_count = count_sentinels original in
  (* If no sentinel-tagged messages, nothing to validate *)
  if original_sentinel_count = 0 then true
  else begin
    (* Verify each reduced message with a sentinel tag can be cleanly parsed *)
    let valid = List.for_all (fun (m : Llm_client.message) ->
      let text = Llm_client.text_of_message m in
      (* Check for corrupted sentinels: \x00 present but not as valid prefix *)
      if String.contains text '\x00' then
        starts_with ~prefix:system_role_tag text
        || starts_with ~prefix:tool_role_tag text
        (* Also allow text that has no sentinel at all — it was a plain message *)
      else true
    ) reduced in
    valid
  end

(* ================================================================ *)
(* Public API                                                       *)
(* ================================================================ *)

(** Apply compaction via the OAS Context_reducer pipeline.

    Takes MASC messages, system prompt, and strategies. Converts to OAS messages,
    builds a composed OAS reducer, runs the reduction, and converts back.

    Returns the compacted message list and new token count.

    After reduction, validates sentinel integrity. If corruption is detected
    (e.g., from Merge_contiguous joining sentinel-tagged content), falls back
    to returning the original messages with a warning log.

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
  (* Validate sentinel integrity after reduction *)
  if validate_roundtrip ~original:messages ~reduced:result_messages then begin
    let token_count = count_tokens system_prompt result_messages in
    (result_messages, token_count)
  end else begin
    eprintf "[context_compact_oas] WARNING: sentinel corruption detected after \
             reduction with strategies [%s], falling back to original messages\n%!"
      (String.concat ", " (List.map (fun s -> match s with
        | PruneToolOutputs -> "PruneToolOutputs"
        | MergeContiguous -> "MergeContiguous"
        | DropLowImportance -> "DropLowImportance"
        | SummarizeOld -> "SummarizeOld"
      ) strategies));
    let token_count = count_tokens system_prompt messages in
    (messages, token_count)
  end
