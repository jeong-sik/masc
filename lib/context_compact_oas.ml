(** Context_compact_oas — direct delegation to OAS Context_reducer.

    MASC messages are [Agent_sdk.Types.message] — the same type OAS uses.
    No role conversion or extra tagging is needed; OAS Context_reducer
    natively supports all 4 roles (System, User, Assistant, Tool) and
    preserves ToolUse/ToolResult pairing.

    MASC-specific strategies (DropLowImportance, SummarizeOld) map to OAS
    built-in reducers ({!Agent_sdk.Context_reducer.importance_scored} and
    {!Agent_sdk.Context_reducer.summarize_old}) so that improvements in OAS
    automatically flow to MASC.

    @since Phase 1 — OAS Context_reducer integration
    @since Phase B — legacy tag removal (roles are natively compatible)
    @since Phase C — DropLowImportance/SummarizeOld → OAS built-ins *)

(* ================================================================ *)
(* Strategy Type                                                     *)
(* ================================================================ *)

(** Observation context for dynamic strategy selection (#3070).
    Mirrors key fields from [Keeper_world_observation.world_observation]
    but without the module dependency — callers map their observation
    into this lightweight record. *)
type observation_context = {
  context_ratio : float;          (** [0.0, 1.0] — current context window utilization *)
  active_agent_count : int;       (** Agents currently active in the workspace *)
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

let goal_prefix = "[GOAL]"

(** Identity anchor tag injected by [Keeper_prompt.build_keeper_system_prompt].
    Messages containing this tag are never dropped or summarized — they anchor
    the keeper's self-identity and survive compaction intact. *)
let identity_anchor_tag = "<identity_anchor>"

let first_sentence (s : string) =
  let s = String.trim s in
  let max_len = 120 in
  let cut_at =
    let period = String.index_opt s '.' in
    let newline = String.index_opt s '\n' in
    match period, newline with
    | Some p, Some n -> Some (min p n + 1)
    | Some p, None -> Some (p + 1)
    | None, Some n -> Some n
    | None, None -> None
  in
  match cut_at with
  | Some pos when pos <= max_len -> String.sub s 0 pos
  | _ -> String_util.utf8_safe ~max_bytes:(max_len + 3) ~suffix:"..." s |> String_util.to_string

let summarize_chunk (msgs : Agent_sdk.Types.message list) : Agent_sdk.Types.message option =
  if List.length msgs < 2 then
    None
  else
  let lines =
    msgs
    |> List.mapi (fun i (m : Agent_sdk.Types.message) ->
      let role_str = Agent_sdk.Types.role_to_string m.role in
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
          (Printf.sprintf "[MEMORY_SUMMARY] Compacted %d older messages\n%s"
             (List.length msgs) (String.concat "\n" lines))
      ];
      name = None;
      tool_call_id = None;
      metadata = [];
    }

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
let w_recency = Env_config.ContextCompact.w_recency
let w_role = Env_config.ContextCompact.w_role
let w_tool = Env_config.ContextCompact.w_tool

(** Role importance values. *)
let role_system = Env_config.ContextCompact.role_system
let role_tool = Env_config.ContextCompact.role_tool
let role_user = Env_config.ContextCompact.role_user
let role_assistant = Env_config.ContextCompact.role_assistant

(** Tool content presence weight. *)
let tool_present = Env_config.ContextCompact.tool_present
let tool_absent = Env_config.ContextCompact.tool_absent

(** Minimum score for memory/goal anchor messages. *)
let anchor_boost = Env_config.ContextCompact.anchor_boost

(** Score threshold below which messages are dropped by [DropLowImportance]. *)
let drop_importance_threshold = Env_config.ContextCompact.drop_importance_threshold

(** Number of recent messages to keep in [SummarizeOld] strategy. *)
let summarize_keep_recent = Env_config.ContextCompact.summarize_keep_recent

let score_message ~index ~total (m : Agent_sdk.Types.message) : float =
  let recency = if total <= 1 then 1.0
    else let t = float_of_int index /. float_of_int (total - 1) in
         t *. t
  in
  let role_w = match m.role with
    | Agent_sdk.Types.System -> role_system
    | Agent_sdk.Types.Tool -> role_tool
    | Agent_sdk.Types.User -> role_user
    | Agent_sdk.Types.Assistant -> role_assistant
  in
  let msg_text = Agent_sdk.Types.text_of_message m in
  let has_tool_content =
    List.exists
      (fun block ->
        Option.is_some (Agent_sdk.Canonical_tool.tool_call_of_block block)
        || Option.is_some (Agent_sdk.Canonical_tool.tool_result_of_block block))
      m.content
  in
  let tool_w = if has_tool_content then tool_present else tool_absent in
  let score = w_recency *. recency +. w_role *. role_w +. w_tool *. tool_w in
  let score =
    if String.starts_with ~prefix:memory_summary_prefix msg_text
       || String.starts_with ~prefix:goal_prefix msg_text then
      Float.max score anchor_boost
    else score
  in
  (* Identity anchor and System messages are never dropped.
     - Identity anchor: explicit <identity_anchor> tag in system prompt.
     - System role: the system prompt carries identity, goals, and policy
       that cannot be reconstructed from conversation context.
     Without this floor, System messages at index 0 score ~0.425 due to
     zero recency, which can fall below the drop threshold. *)
  let score =
    if String.contains msg_text '<'
       && String_util.contains_substring msg_text identity_anchor_tag then
      Float.max score anchor_boost
    else if match m.role with Agent_sdk.Types.System -> true | _ -> false then
      Float.max score anchor_boost
    else score
  in
  Float.min 1.0 (Float.max 0.0 score)

let score_messages (msgs : Agent_sdk.Types.message list) : (int * float) list =
  let n = List.length msgs in
  List.mapi (fun i m -> (i, score_message ~index:i ~total:n m)) msgs

(* ================================================================ *)
(* Strategy Mapping: Local -> OAS                                   *)
(* ================================================================ *)

(** Map a local strategy to an OAS Context_reducer [t].

    - [PruneToolOutputs] and [MergeContiguous] use OAS built-in constructors.
    - [DropLowImportance] uses OAS {!importance_scored} with the MASC
      composite scorer ({!score_message}).
    - [SummarizeOld] uses OAS {!summarize_old} with an extractive
      summarizer ({!extractive_summarizer}).
    - [Dynamic] is resolved before reaching this function; if it leaks
      through, it falls back to {!importance_scored}. *)
let extractive_summarizer (msgs : Agent_sdk.Types.message list) : string =
  match summarize_chunk msgs with
  | None -> ""
  | Some msg -> Agent_sdk.Types.text_of_message msg

(** Max length for tool output before pruning. Shared with keeper_agent_run. *)
let tool_output_prune_limit = Env_config.ContextCompact.tool_output_prune_limit

let oas_strategy_of (s : strategy) : Agent_sdk.Context_reducer.t =
  match s with
  | PruneToolOutputs ->
    Agent_sdk.Context_reducer.prune_tool_outputs ~max_output_len:tool_output_prune_limit
  | MergeContiguous ->
    Agent_sdk.Context_reducer.merge_contiguous
  | DropLowImportance ->
    Agent_sdk.Context_reducer.importance_scored
      ~threshold:drop_importance_threshold
      ~scorer:score_message
      ()
  | Dynamic _ ->
    (* Dynamic is resolved before reaching oas_strategy_of.
       If it leaks here, fall back to importance scoring. *)
    Agent_sdk.Context_reducer.importance_scored
      ~threshold:drop_importance_threshold
      ~scorer:score_message
      ()
  | SummarizeOld ->
    Agent_sdk.Context_reducer.summarize_old
      ~keep_recent:summarize_keep_recent
      ~summarizer:extractive_summarizer

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
    to an OAS built-in reducer and applied in sequence.

    {2 Why both exist}

    OAS Dynamic is turn-scoped and message-scoped — it answers
    "given this conversation state, which single reduction to apply?".
    MASC Dynamic is world-scoped — it answers "given the multi-agent
    workspace state, which {i combination} of reductions is appropriate?".

    They operate at different abstraction levels:
    - OAS Dynamic:  per-conversation, single strategy, inside [reduce]
    - MASC Dynamic: per-keeper-turn, strategy list, before [compact]

    MASC Dynamic resolves to concrete MASC strategies, which are then
    mapped to OAS built-in reducers.  OAS Dynamic is not called.
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
            context_window = Runtime_constants.fallback_context_window;
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
        "obs=ratio=%.2f keepers=%d unclaimed=%d single_task=%b ctx=%dk local=%b"
        obs.context_ratio obs.active_agent_count obs.unclaimed_task_count
        obs.is_single_focused_task (obs.context_window / 1000) obs.is_local_model

(** Default dynamic strategy selector.
    Chooses strategies based on observation context:
    - High context + multi-agent: aggressive compaction (preserve workspace)
    - High context + single task: summarize old + drop low importance
    - Small local model: prefer pruning (cheaper, faster)
    - Large-context cloud (>= 500K): quality-preserving with summarization
    - Normal: standard DropLowImportance *)

(** {1 Dynamic Strategy Selection}

    @boundary-contract
    - MASC owns: world-aware strategy resolution (which strategies to apply
      based on agent count, task focus, model class, context ratio).
      Algorithm thresholds are code-reviewed constants exposed through
      [Env_config.ContextCompact], not runtime env knobs.
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
    (* Dense workspace: preserve recent turns, aggressive pruning *)
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
  (* Deterministic guard: separate System messages from the compaction
     pipeline. System messages carry identity anchors, goals, and policy
     that must never be dropped or lossily summarized. This is a hard
     mechanical guarantee — not a score-based heuristic. The OAS reducer
     operates only on non-System messages; System messages are prepended
     back verbatim after reduction. *)
  let system_msgs, other_msgs = List.partition
      (fun (m : Agent_sdk.Types.message) ->
         match m.role with Agent_sdk.Types.System -> true | _ -> false)
      messages
  in
  let oas_strategies = List.map oas_strategy_of resolved in
  let reducer = Agent_sdk.Context_reducer.compose oas_strategies in
  let reduced = Agent_sdk.Context_reducer.reduce reducer other_msgs in
  system_msgs @ reduced
