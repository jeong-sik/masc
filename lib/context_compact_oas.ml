(** Context_compact_oas — direct delegation to OAS Context_reducer.

    MASC messages are [Agent_sdk.Types.message] — the same type OAS uses.
    No role conversion or extra tagging is needed; OAS Context_reducer
    natively supports all 4 roles (System, User, Assistant, Tool) and
    preserves ToolUse/ToolResult pairing.

    MASC-specific strategies (DropLowImportance, SummarizeOld) use OAS
    Custom closures to inject domain logic that OAS does not provide.

    @since Phase 1 — OAS Context_reducer integration
    @since Phase B — legacy tag removal (roles are natively compatible) *)

(* ================================================================ *)
(* Strategy Type                                                     *)
(* ================================================================ *)

(** Observation context for dynamic strategy selection (#3070).
    Mirrors key fields from [Keeper_world_observation.world_observation]
    but without the module dependency — callers map their observation
    into this lightweight record. *)
type observation_context = {
  context_ratio : float;          (** [0.0, 1.0] — current context window utilization *)
  active_agent_count : int;       (** Agents currently active in the room *)
  unclaimed_task_count : int;     (** Pending tasks in the backlog *)
  is_single_focused_task : bool;  (** Keeper working on exactly one task *)
  context_window : int;           (** Model context window in tokens *)
  is_local_model : bool;          (** Whether model runs locally *)
}

type strategy =
  | PruneToolOutputs
  | MergeContiguous
  | DropLowImportance
  | SummarizeOld
  | Dynamic of (observation_context -> strategy list)
  (** Select strategies at runtime based on observation context.
      Resolves to a list of concrete strategies (no nested Dynamic).
      @since #3070 *)

(* Token estimation lives in [Keeper_context_core] (authoritative, with 15%
   safety buffer).  This module previously had its own msg_tokens/count_tokens
   without the buffer, but they were only used by [compact]'s dead return value.
   Removed in #5281 follow-up to consolidate to single estimation path. *)

(* ================================================================ *)
(* Importance Scoring (inlined from Context_scoring)                 *)
(* ================================================================ *)

let memory_summary_prefix = "[MEMORY_SUMMARY]"
let _legacy_memory_summary_prefix = "[MASC_MEMORY_SUMMARY v1]"

let goal_prefix = "[GOAL]"
let _legacy_goal_prefix = "[MASC_GOAL]"

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
  | _ -> String_util.utf8_safe ~max_bytes:(max_len + 3) ~suffix:"..." s |> String_util.to_string

let tool_names_by_id (msgs : Agent_sdk.Types.message list) : (string * string) list =
  let add_tool_name acc (m : Agent_sdk.Types.message) =
    List.fold_left (fun acc -> function
      | Agent_sdk.Types.ToolUse { id; name; _ } ->
        if List.mem_assoc id acc then acc else (id, name) :: acc
      | _ -> acc
    ) acc m.content
  in
  List.fold_left add_tool_name [] msgs

let summarize_chunk (msgs : Agent_sdk.Types.message list) : Agent_sdk.Types.message option =
  if List.length msgs < 2 then
    None
  else
  let lines =
    msgs
    |> List.mapi (fun i (m : Agent_sdk.Types.message) ->
      let role_str = match m.role with
        | Agent_sdk.Types.User -> "user"
        | Agent_sdk.Types.Assistant -> "assistant"
        | Agent_sdk.Types.System -> "system"
        | Agent_sdk.Types.Tool -> "tool"
      in
      let text = String.trim (Agent_sdk.Types.text_of_message m) in
      if text = "" then None
      else Some (Printf.sprintf "[%d] %s: %s" (i + 1) role_str (first_sentence text))
    )
    |> List.filter_map Fun.id
  in
  match lines with
  | [] -> None
  | _ ->
    Some {
      Agent_sdk.Types.role = Agent_sdk.Types.Assistant;
      content = [
        Agent_sdk.Types.Text
          (Printf.sprintf "[Compacted %d messages into summary]\n%s"
             (List.length msgs) (String.concat "\n" lines))
      ];
      name = None;
      tool_call_id = None;
    }

let mask_tool_result_content ~(tool_name : string option) ~(tool_use_id : string)
    ~(content : string) : string =
  let lines =
    if content = "" then 0
    else 1 + String.fold_left (fun acc ch -> if ch = '\n' then acc + 1 else acc) 0 content
  in
  let preview = first_sentence content in
  let name = Option.value tool_name ~default:"unknown" in
  Printf.sprintf "[tool:%s id:%s lines:%d chars:%d summary:%S]"
    name tool_use_id lines (String.length content) preview

let mask_tool_result_message ~(tool_names : (string * string) list)
    (m : Agent_sdk.Types.message) : Agent_sdk.Types.message =
  let content = List.map (function
    | Agent_sdk.Types.ToolResult { tool_use_id; content; is_error; _ } ->
      let tool_name = List.assoc_opt tool_use_id tool_names in
      Agent_sdk.Types.ToolResult {
        tool_use_id;
        content = mask_tool_result_content ~tool_name ~tool_use_id ~content;
        is_error;
        (* Compaction keeps only a small textual stub plus the tool/result
           pairing. Preserving structured payloads here would bypass the size
           reduction and leak the full tool output through [json]. *)
        json = None;
      }
    | other -> other
  ) m.content in
  { m with content }

let summarize_old_messages ~(keep_recent : int)
    (msgs : Agent_sdk.Types.message list) : Agent_sdk.Types.message list =
  let total = List.length msgs in
  if total <= keep_recent then msgs
  else
    let tool_names = tool_names_by_id msgs in
    let old_count = total - keep_recent in
    let rec split i acc rest =
      if i <= 0 then (List.rev acc, rest)
      else match rest with
        | [] -> (List.rev acc, [])
        | x :: xs -> split (i - 1) (x :: acc) xs
    in
    let old_msgs, recent_msgs = split old_count [] msgs in
    let flush_chunk chunk acc =
      match summarize_chunk (List.rev chunk) with
      | Some summary -> summary :: acc
      | None -> acc
    in
    let rec compact_old (old : Agent_sdk.Types.message list) chunk acc =
      match old with
      | [] -> List.rev (flush_chunk chunk acc)
      | m :: tl ->
        let has_tool_use = List.exists (function Agent_sdk.Types.ToolUse _ -> true | _ -> false) m.content in
        let has_tool_result = List.exists (function Agent_sdk.Types.ToolResult _ -> true | _ -> false) m.content in
        if has_tool_use then
          compact_old tl [] (m :: flush_chunk chunk acc)
        else if has_tool_result then
          let masked = mask_tool_result_message ~tool_names m in
          compact_old tl [] (masked :: flush_chunk chunk acc)
        else
          compact_old tl (m :: chunk) acc
    in
    compact_old old_msgs [] [] @ recent_msgs

(** Score a list of messages by importance for context compaction.
    Returns [(index, score)] pairs where score is in [0.0, 1.0].

    The score is a weighted sum of 3 factors:

    - recency (0.50): Quadratic decay from newest (1.0) to oldest (0.0).
      Quadratic rather than linear because recent context is disproportionately
      important — the keeper's current task depends on the last few turns,
      while early context is often superseded.

    - role_weight (0.35): System (1.0) > Tool (0.7) > User (0.6) > Assistant (0.4).
      System prompts are never dropped. Tool results contain ground truth.
      User messages carry intent. Assistant messages are reproducible via re-inference.

    - tool_weight (0.15): Messages with ToolUse/ToolResult (0.8) vs plain text (0.5).
      Tool interactions represent actions taken and should be preserved for
      trajectory coherence.

    Special cases: Memory summaries and goal messages are boosted to
    [anchor_boost] regardless of computed score — they anchor the keeper's purpose.

    Memory summaries and goal messages use MASC-specific prefix matching. *)

(** Importance scoring weights. See rationale in comment block above. *)
let w_recency = Env_config_core.get_float ~default:0.50 "MASC_COMPACT_W_RECENCY"
let w_role    = Env_config_core.get_float ~default:0.35 "MASC_COMPACT_W_ROLE"
let w_tool    = Env_config_core.get_float ~default:0.15 "MASC_COMPACT_W_TOOL"

(** Role importance values. *)
let role_system    = Env_config_core.get_float ~default:1.0 "MASC_COMPACT_ROLE_SYSTEM"
let role_tool      = Env_config_core.get_float ~default:0.7 "MASC_COMPACT_ROLE_TOOL"
let role_user      = Env_config_core.get_float ~default:0.6 "MASC_COMPACT_ROLE_USER"
let role_assistant = Env_config_core.get_float ~default:0.4 "MASC_COMPACT_ROLE_ASSISTANT"

(** Tool content presence weight. *)
let tool_present = Env_config_core.get_float ~default:0.8 "MASC_COMPACT_TOOL_PRESENT"
let tool_absent  = Env_config_core.get_float ~default:0.5 "MASC_COMPACT_TOOL_ABSENT"

(** Minimum score for memory/goal anchor messages. *)
let anchor_boost = Env_config_core.get_float ~default:0.95 "MASC_COMPACT_ANCHOR_BOOST"

(** Score threshold below which messages are dropped by [DropLowImportance]. *)
let drop_importance_threshold = Env_config_core.get_float ~default:0.3 "MASC_COMPACT_DROP_THRESHOLD"

(** Number of recent messages to keep in [SummarizeOld] strategy. *)
let summarize_keep_recent = Env_config_core.get_int ~default:5 "MASC_COMPACT_KEEP_RECENT"

let score_messages (msgs : Agent_sdk.Types.message list) : (int * float) list =
  let n = List.length msgs in
  List.mapi (fun i (m : Agent_sdk.Types.message) ->
    let recency = if n <= 1 then 1.0
      else let t = float_of_int i /. float_of_int (n - 1) in
           t *. t
    in
    let role_w = match m.role with
      | Agent_sdk.Types.System -> role_system
      | Agent_sdk.Types.Tool -> role_tool
      | Agent_sdk.Types.User -> role_user
      | Agent_sdk.Types.Assistant -> role_assistant
    in
    let msg_text = Agent_sdk.Types.text_of_message m in
    let has_tool_content = List.exists (function
      | Agent_sdk.Types.ToolUse _ | Agent_sdk.Types.ToolResult _ -> true
      | _ -> false) m.content
    in
    let tool_w = if has_tool_content then tool_present else tool_absent in
    let score = w_recency *. recency +. w_role *. role_w +. w_tool *. tool_w in
    let score =
      if String.starts_with ~prefix:memory_summary_prefix msg_text
         || String.starts_with ~prefix:_legacy_memory_summary_prefix msg_text
         || String.starts_with ~prefix:goal_prefix msg_text
         || String.starts_with ~prefix:_legacy_goal_prefix msg_text then
        Float.max score anchor_boost
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
    - SummarizeOld uses OAS Custom with extractive summaries plus ToolResult
      structured stubs so ToolUse/ToolResult pairing survives compaction. *)
(** Max length for tool output before pruning. Shared with keeper_agent_run. *)
let tool_output_prune_limit = Env_config.ContextCompact.tool_output_prune_limit

let oas_strategy_of (s : strategy) : Agent_sdk.Context_reducer.strategy =
  match s with
  | PruneToolOutputs ->
    Agent_sdk.Context_reducer.Prune_tool_outputs { max_output_len = tool_output_prune_limit }
  | MergeContiguous ->
    Agent_sdk.Context_reducer.Merge_contiguous
  | DropLowImportance ->
    Agent_sdk.Context_reducer.Custom (fun msgs ->
      let scores = score_messages msgs in
      let threshold = drop_importance_threshold in
      List.filteri (fun i _m ->
        match List.assoc_opt i scores with
        | Some score -> score >= threshold
        | None -> true
      ) msgs)
  | Dynamic _ ->
    (* Dynamic is resolved before reaching oas_strategy_of.
       If it leaks here, fall back to DropLowImportance. *)
    Agent_sdk.Context_reducer.Custom (fun msgs ->
      let scores = score_messages msgs in
      let threshold = drop_importance_threshold in
      List.filteri (fun i _m ->
        match List.assoc_opt i scores with
        | Some score -> score >= threshold
        | None -> true
      ) msgs)
  | SummarizeOld ->
    Agent_sdk.Context_reducer.Custom (summarize_old_messages ~keep_recent:summarize_keep_recent)

(* ================================================================ *)
(* Public API                                                       *)
(* ================================================================ *)

(** Apply compaction via OAS Context_reducer.

    Messages are passed directly — no role conversion needed since
    MASC and OAS share the same [Agent_sdk.Types.message] type with
    the same 4 roles (System, User, Assistant, Tool). *)
(* ================================================================ *)
(* MASC Dynamic vs OAS Dynamic — Complementary, NOT Duplicated       *)
(* ================================================================ *)

(** {2 OAS [Context_reducer.Dynamic]}

    OAS defines [Dynamic of (turn:int -> messages:message list -> strategy)].
    It selects a {i single} OAS strategy per reduction pass based on
    conversation-level inputs (turn index, message list).  The reducer
    invokes the selector once per [reduce] call.

    {2 MASC [Dynamic of (observation_context -> strategy list)]}

    MASC's Dynamic takes a {i world-state} observation (context ratio,
    active agent count, model family, task topology) and returns a
    {i composed} list of MASC strategies.  Each strategy is then mapped
    to an OAS [Custom] closure and applied in sequence.

    {2 Why both exist}

    OAS Dynamic is turn-scoped and message-scoped — it answers
    "given this conversation state, which single reduction to apply?".
    MASC Dynamic is world-scoped — it answers "given the multi-agent
    room state, which {i combination} of reductions is appropriate?".

    They operate at different abstraction levels:
    - OAS Dynamic:  per-conversation, single strategy, inside [reduce]
    - MASC Dynamic: per-keeper-turn, strategy list, before [compact]

    MASC Dynamic resolves to concrete MASC strategies, which are then
    mapped to OAS [Custom] closures.  OAS Dynamic is not called.
    The two do not interact at runtime. *)

(* ================================================================ *)
(* Dynamic strategy resolution (#3070)                               *)
(* ================================================================ *)

(** Resolve Dynamic strategies into concrete strategy lists.
    Non-Dynamic strategies pass through unchanged. *)
let resolve_strategies
    ~(obs : observation_context option)
    (strategies : strategy list) : strategy list =
  List.concat_map (fun s ->
    match s with
    | Dynamic selector ->
      let obs_val = match obs with
        | Some o -> o
        | None ->
          (* Fallback: minimal observation when none provided. *)
          { context_ratio = 0.5; active_agent_count = 1;
            unclaimed_task_count = 0; is_single_focused_task = true;
            context_window = Cascade_runtime.fallback_context_window;
            is_local_model = false }
      in
      (* Resolve once — no recursive Dynamic *)
      selector obs_val
      |> List.filter (function Dynamic _ -> false | _ -> true)
    | other -> [other]
  ) strategies

let strategy_name = function
  | PruneToolOutputs -> "PruneToolOutputs"
  | MergeContiguous -> "MergeContiguous"
  | DropLowImportance -> "DropLowImportance"
  | SummarizeOld -> "SummarizeOld"
  | Dynamic _ -> "Dynamic(unresolved)"

let observation_summary = function
  | None -> "obs=none"
  | Some obs ->
      Printf.sprintf
        "obs=ratio=%.2f agents=%d unclaimed=%d single_task=%b ctx=%dk local=%b"
        obs.context_ratio obs.active_agent_count obs.unclaimed_task_count
        obs.is_single_focused_task (obs.context_window / 1000) obs.is_local_model

(** Default dynamic strategy selector.
    Chooses strategies based on observation context:
    - High context + multi-agent: aggressive compaction (preserve coordination)
    - High context + single task: summarize old + drop low importance
    - Small local model: prefer pruning (cheaper, faster)
    - Large-context cloud (>= 500K): quality-preserving with summarization
    - Normal: standard DropLowImportance *)

(** {1 Dynamic Strategy Selection}

    @boundary-contract
    - MASC owns: world-aware strategy resolution (which strategies to apply
      based on agent count, task focus, model class, context ratio).
      All thresholds are env-configurable, not hardcoded.
    - OAS owns: strategy execution (PruneToolOutputs, MergeContiguous are
      OAS built-ins), context_reducer pipeline, compaction algorithm.
    - Neither may: MASC must not execute compaction directly (only select
      strategies); OAS must not select strategies based on world state
      (it has no world awareness).

    Context ratio thresholds for dynamic strategy selection.
    Distinct from Dashboard.ctx_* (display) — these drive compaction behavior. *)
let dynamic_multi_agent_ctx = Env_config.ContextCompact.dynamic_multi_agent_ratio
let dynamic_focused_ctx = Env_config.ContextCompact.dynamic_focused_ratio

(** Context window floor (in tokens) below which a local model is classified
    as "small-local", triggering lightweight compaction strategies. *)
let small_local_ctx_floor = Env_config.ContextCompact.small_local_floor

let default_dynamic_selector (obs : observation_context) : strategy list =
  if obs.context_ratio >= dynamic_multi_agent_ctx && obs.active_agent_count > 1 then
    (* Dense coordination: preserve recent turns, aggressive pruning *)
    [PruneToolOutputs; DropLowImportance; MergeContiguous]
  else if obs.context_ratio >= dynamic_focused_ctx && obs.is_single_focused_task then
    (* Focused work near budget: summarize old context *)
    [PruneToolOutputs; SummarizeOld]
  else if obs.is_local_model && obs.context_window < small_local_ctx_floor then
    (* Small local models (< 64K): lightweight compaction only.
       Uses an approximate 64K floor here; llama-server default 8K is
       unsuitable for multi-turn keeper conversations. *)
    [PruneToolOutputs; MergeContiguous]
  else if obs.context_window >= Env_config.ContextCompact.large_cloud_floor then
    (* Large-context cloud: invest in quality-preserving strategies *)
    [DropLowImportance; SummarizeOld]
  else
    (* Default: importance-based *)
    [DropLowImportance]

(* ================================================================ *)
(* Public API                                                       *)
(* ================================================================ *)

(** Apply compaction via OAS Context_reducer.

    Messages are passed directly — no role conversion needed since
    MASC and OAS share the same [Agent_sdk.Types.message] type with
    the same 4 roles (System, User, Assistant, Tool).

    @param observation Optional observation context for Dynamic strategies.
      When a strategy list contains [Dynamic], this context determines
      which concrete strategies are applied. *)
(* Issue #8597 #1: dropped [~system_prompt]. The OAS Context_reducer
   pipeline operates on [messages] only — the system prompt is part of
   [messages] (role=System) when present. The labeled arg was passed by
   keeper_compact_policy but never read. *)
let compact
    ~(messages : Agent_sdk.Types.message list)
    ~(strategies : strategy list)
    ?(observation : observation_context option)
    ()
  : Agent_sdk.Types.message list =
  let resolved = resolve_strategies ~obs:observation strategies in
  let strategy_names = List.map strategy_name resolved in
  Log.Compact.info "[compact] strategies=[%s] %s"
    (String.concat "," strategy_names)
    (observation_summary observation);
  let oas_strategies = List.map oas_strategy_of resolved in
  let reducer = Agent_sdk.Context_reducer.compose
    (List.map (fun s -> { Agent_sdk.Context_reducer.strategy = s }) oas_strategies) in
  Agent_sdk.Context_reducer.reduce reducer messages
