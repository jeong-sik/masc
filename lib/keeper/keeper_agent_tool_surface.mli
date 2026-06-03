(** Tool-surface visibility, selection constants, and backlog task
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

(** Per-turn lane classification.  Closed sum type; the OCaml side
    pins the alphabet emitted by keeper_run_tools
    ({"text_only", "tool_optional", "tool_disabled", "retry"}).
    Plain to_string/of_string (no [@@deriving tla] — that
    derives module-level all_symbols which is already bound to
    [tool_surface_class] below).  A future RFC-0065 spec extension
    can add a TurnLaneSet catalog and lift this to deriving. *)
type turn_lane =
  | Lane_pre_dispatch
      (** Pre-turn placeholder before [compute_tool_surface] runs.
          Emitted only by [keeper_turn_helpers.pre_dispatch_tool_surface];
          never produced by the per-turn lane logic at
          keeper_run_tools.ml:963-973. *)
  | Lane_text_only
  | Lane_tool_optional
  | Lane_tool_disabled
  | Lane_retry

val turn_lane_to_string : turn_lane -> string
val turn_lane_of_string : string -> turn_lane option
val turn_lane_to_yojson : turn_lane -> Yojson.Safe.t

(** Tool-surface selection mode.  Closed sum type pinning the two
    possible outputs of [keeper_run_tools.ml::compute_tool_surface]'s
    [selection_mode] field:

    - [Selection_deterministic_plus_llm_hint] when the keeper has
      [llm_rerank_enabled = true] and the per-turn TopK_llm path
      decorated the deterministic selection with an LLM-reranked hint.
    - [Selection_core_plus_prefilter_plus_discovered] when the keeper
      relies on the deterministic prefilter + discovered-tool union
      only (no LLM rerank for this turn).

    Disambiguated as [tool_selection_mode] (the [Keeper_skill_routing]
    and [Keeper_alerting] modules each own their own [selection_mode]
    sum type unrelated to tool-surface composition). *)
type tool_selection_mode =
  | Selection_deterministic_plus_llm_hint
  | Selection_core_plus_prefilter_plus_discovered

val tool_selection_mode_to_string : tool_selection_mode -> string
val tool_selection_mode_of_string : string -> tool_selection_mode option
val tool_selection_mode_to_yojson : tool_selection_mode -> Yojson.Safe.t


(** Classification of the per-turn tool surface.  Closed sum type; the wire
    labels are fixed by [@@deriving tla] symbols so JSON, Prometheus labels,
    and dashboard surfaces stay aligned. *)
type tool_surface_class =
  | Surface_none [@tla.symbol "none"]
  | Surface_public_only [@tla.symbol "public_only"]
  | Surface_mixed [@tla.symbol "mixed"]
[@@deriving tla]

val tool_surface_class_to_string : tool_surface_class -> string
val tool_surface_class_of_string : string -> tool_surface_class option
val tool_surface_class_to_yojson : tool_surface_class -> Yojson.Safe.t

(** Diagnostic surface metrics emitted into trajectory entries. *)
type tool_surface_metrics =
  { turn_lane : turn_lane
  ; tool_surface_class : tool_surface_class
  ; visible_tool_count : int
  ; tool_surface_fallback_used : bool
  ; config_root : string
  ; runtime_config_path : string option
  ; gemini_mcp_disabled : bool
  ; approval_mode_effective : string option
  ; approval_mode_derived : bool
  }

(** Result of computing the per-turn tool surface (selection +
    classification + lane). *)
type computed_tool_surface =
  { turn_visible_tool_names : string list
  ; absolute_turn : int
  ; checkpoint_start_turn : int
  ; per_call_turn : int
  ; per_call_max_turns : int
  ; core_count : int
  ; deterministic_prefilter : string list
  ; deterministic_prefilter_count : int
  ; discovered_count : int
  ; llm_selected_count : int
  ; selection_mode : tool_selection_mode
  ; is_last_turn : bool
  ; is_warning_zone : bool
  ; tool_surface_class : tool_surface_class
  ; claim_context_allowed : bool
  ; tool_surface_fallback_used : bool
  ; lane : turn_lane
  ; query_text : string
  }

(** Affordances that influence per-turn tool visibility. *)
type turn_affordance =
  | Board_curation
  | Board_post_or_comment
  | Message_sweep
  | Task_claim
  | Task_audit
  | Task_verify

val turn_affordance_of_string : string -> turn_affordance option

(** Tools worth keeping visible for an affordance. This is advisory surface
    shaping only; it must not force a tool call or reject text. *)
val tools_for_affordance : turn_affordance -> string list

(** Specific tools that should be force-included/preferred for an
    affordance, when the active runtime schema exposes them. *)
val preferred_tool_names_for_turn_affordances : string list -> string list

val has_turn_affordance : turn_affordance -> string list -> bool

val has_task_claim_affordance : string list -> bool

(** Find the active task ID a keeper currently owns. *)
val owned_active_task_id_for_meta :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_id.Task_id.t option

(** Field-level merge for [write_meta_with_merge]. *)
val merge_current_task_id :
  latest:Keeper_meta_contract.keeper_meta ->
  caller:Keeper_meta_contract.keeper_meta ->
  Keeper_meta_contract.keeper_meta

(** Reconcile [meta.current_task_id] with the backlog. *)
val sync_current_task_id_from_backlog :
  config:Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  Keeper_meta_contract.keeper_meta

(** Best-effort reconciliation for callers that only know an agent name.
    No-ops for non-keeper agents. *)
val sync_current_task_id_for_agent_name :
  config:Workspace.config ->
  agent_name:string ->
  unit

(** Convenience [List.map Keeper_tool_name.to_string]. *)
val tool_names : Keeper_tool_name.t list -> string list

val fallback_floor_tool_names : string list

(** Re-export of [Keeper_tool_progress.is_claim_tool_name]. *)
val is_claim_tool_name : string -> bool

(** Re-export of [Keeper_tool_progress.is_claim_context_tool_name]. *)
val is_claim_context_tool_name : string -> bool

val keeper_selection_top_k : int

val keeper_selection_bm25_prefilter_n : int

val tool_search_alias_entries : (string * string) list

val tool_search_aliases : string -> string list

val tool_index_entry :
  name:string -> description:string -> Agent_sdk.Tool_index.entry

val tool_index_entry_of_tool : Agent_sdk.Tool.t -> Agent_sdk.Tool_index.entry
