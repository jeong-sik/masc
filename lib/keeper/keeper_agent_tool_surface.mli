(** Tool-surface gating, selection constants, and backlog task
    reconciliation. *)

(** Per-keeper dedupe set used by [should_log_unexpected_tool_partial_once]
    so a partial-match warning fires once per (keeper, tool list) tuple. *)
val unexpected_tool_partial_warned : (string, unit) Hashtbl.t

(** Mutex guarding [unexpected_tool_partial_warned] mutation. *)
val unexpected_tool_partial_warn_mu : Eio.Mutex.t

(** [true] iff this is the first time the (keeper_name,
    sorted unexpected_tool_names) tuple has been seen. *)
val should_log_unexpected_tool_partial_once :
  keeper_name:string -> unexpected_tool_names:string list -> bool

(** Whether tools are required, optional, or absent for this turn. *)
type tool_requirement =
  | Required
  | Optional
  | No_tools

val tool_requirement_to_string : tool_requirement -> string
val tool_requirement_of_string : string -> tool_requirement option
val tool_requirement_to_yojson : tool_requirement -> Yojson.Safe.t

(** Diagnostic surface metrics emitted into trajectory entries. *)
type tool_surface_metrics =
  { turn_lane : string
  ; tool_surface_class : string
  ; tool_requirement : tool_requirement
  ; visible_tool_count : int
  ; tool_gate_enabled : bool
  ; tool_surface_fallback_used : bool
  ; required_tool_names : string list
  ; missing_required_tool_names : string list
  ; config_root : string
  ; cascade_config_path : string option
  ; gemini_mcp_disabled : bool
  ; approval_mode_effective : string option
  ; approval_mode_derived : bool
  }

(** Result of computing the per-turn tool surface (selection +
    classification + lane). *)
type computed_tool_surface =
  { all_allowed : string list
  ; absolute_turn : int
  ; checkpoint_start_turn : int
  ; per_call_turn : int
  ; per_call_max_turns : int
  ; core_count : int
  ; deterministic_prefilter_count : int
  ; discovered_count : int
  ; llm_selected_count : int
  ; selection_mode : string
  ; is_last_turn : bool
  ; is_warning_zone : bool
  ; tool_surface_class : string
  ; tool_requirement : tool_requirement
  ; tool_gate_requested : bool
  ; tool_surface_fallback_used : bool
  ; required_tool_names : string list
  ; missing_required_tool_names : string list
  ; lane : string
  ; query_text : string
  }

(** Affordances that influence per-turn tool gating. *)
type turn_affordance =
  | Board_curation
  | Board_post_or_comment
  | Message_sweep
  | Reply_in_room
  | Task_claim
  | Task_audit
  | Task_verify
  | Work_discovery
  | Inspect_worktree_delta

val turn_affordance_of_string : string -> turn_affordance option

(** [true] for affordances that should require a tool call (not text). *)
val should_tool_gate_affordance : turn_affordance -> bool

(** [true] iff at least one of [turn_affordances] is gating-eligible. *)
val turn_affordances_require_tool_gate : string list -> bool

(** Tools that satisfy a gated affordance (used by
    [turn_affordances_require_tool_gate_with_allowed]). *)
val tools_for_gated_affordance : turn_affordance -> string list

(** Specific tools that should be force-included/preferred for an
    affordance, when the keeper policy exposes them. *)
val preferred_tool_names_for_turn_affordances : string list -> string list

(** Like [turn_affordances_require_tool_gate] but only fires when at
    least one of the gating affordance's tools is in
    [allowed_tool_names] and can satisfy the required-tool contract.
    Passive read/status tools may still be visible, but they cannot be
    the sole reason to force [Require_tool_use]. *)
val turn_affordances_require_tool_gate_with_allowed :
     ?record_suppression_metric:bool
  -> allowed_tool_names:string list
  -> string list
  -> bool

(** On a required-action turn, trim the visible surface to tools that can make
    progress when such tools exist. Passive status/read tools remain visible on
    optional turns and on surfaces that have no actionable alternative.

    Explicit [required_tool_names] are preserved even when they are read-only:
    operator/harness calls such as [masc_keeper_msg.required_tools =
    ["masc_web_search"]] are a direct evidence contract, not a generic
    actionable-world-signal gate. *)
val tool_names_for_required_gate_surface :
  tool_gate_requested:bool ->
  required_tool_names:string list ->
  string list ->
  string list

(** Whether the very first turn of a multi-turn slot should require
    a tool call. *)
val should_require_tools_for_initial_turn :
  max_turns:int -> turn_affordances:string list -> bool

val has_turn_affordance : turn_affordance -> string list -> bool

val has_task_claim_affordance : string list -> bool

(** Pick the model-facing [tool_choice] when the gate fires. *)
val preferred_tool_choice_for_required_turn :
  has_current_task:bool ->
  turn_affordances:string list ->
  allowed_tool_names:string list ->
  Agent_sdk.Types.tool_choice

(** Per-call [masc_keeper_msg.required_tools] is an explicit operator/harness
    contract for this turn. When present, it takes precedence over the keeper's
    active task contract so stale task-specific required tools cannot hijack the
    message. *)
val required_tool_names_for_turn :
  current_task_required_tool_names:string list ->
  per_call_required_tool_names:string list ->
  string list

(** Remove required tools that have already been satisfied in the current
    Agent.run. This keeps a multi-turn keeper message from forcing the same
    specific tool again after the successful tool call has already happened. *)
val outstanding_required_tool_names :
  required_tool_names:string list -> satisfied_tool_names:string list -> string list

(** Extract successfully satisfied required-contract tools from observed
    [(tool_name, outcome)] pairs. Failed or passive calls stay outstanding. *)
val satisfied_required_tool_names_of_outcomes :
  (string * string) list -> string list

(** Pick the model-facing [tool_choice] for an explicit required-tool list.
    Visible required tools use [Any] so OAS enforces tool use without
    exact-name matching before MASC canonicalizes MCP-prefixed tool names. The
    specific required names are checked after execution. *)
val preferred_tool_choice_for_required_tool_names :
  required_tool_names:string list ->
  allowed_tool_names:string list ->
  Agent_sdk.Types.tool_choice

(** Find the active task ID a keeper currently owns. *)
val owned_active_task_id_for_meta :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  Keeper_id.Task_id.t option

(** Field-level merge for [write_meta_with_merge]. *)
val merge_current_task_id :
  latest:Keeper_types.keeper_meta ->
  caller:Keeper_types.keeper_meta ->
  Keeper_types.keeper_meta

(** Reconcile [meta.current_task_id] with the backlog. *)
val sync_current_task_id_from_backlog :
  config:Coord.config ->
  Keeper_types.keeper_meta ->
  Keeper_types.keeper_meta

(** Best-effort reconciliation for callers that only know an agent name.
    No-ops for non-keeper agents. *)
val sync_current_task_id_for_agent_name :
  config:Coord.config ->
  agent_name:string ->
  unit

(** Convenience [List.map Tool_name.to_string]. *)
val tool_names : Tool_name.t list -> string list

val fallback_floor_tool_names : string list

val fallback_repo_probe_tool_names : string list

(** Re-export of [Keeper_tool_disclosure.is_claim_tool_name]. *)
val is_claim_tool_name : string -> bool

(** Re-export of [Keeper_tool_disclosure.is_claim_context_tool_name]. *)
val is_claim_context_tool_name : string -> bool

val keeper_selection_top_k : int

val keeper_selection_bm25_prefilter_n : int

val tool_search_alias_entries : (string * string) list

val tool_search_aliases : string -> string list

val tool_index_entry :
  name:string -> description:string -> Agent_sdk.Tool_index.entry

val tool_index_entry_of_tool : Agent_sdk.Tool.t -> Agent_sdk.Tool_index.entry
