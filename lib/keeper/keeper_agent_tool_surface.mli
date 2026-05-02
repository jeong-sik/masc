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
val tool_requirement_of_string : string -> tool_requirement
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

(** Like [turn_affordances_require_tool_gate] but only fires when at
    least one of the gating affordance's tools is in
    [allowed_tool_names]. *)
val turn_affordances_require_tool_gate_with_allowed :
  allowed_tool_names:string list -> string list -> bool

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
