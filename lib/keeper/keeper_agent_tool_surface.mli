(** Tool selection constants and backlog task reconciliation. *)

(** Per-turn lane classification.  Closed sum type; the OCaml side
    pins the alphabet emitted by keeper_run_tools
    ({"text_only", "tool_optional", "tool_disabled", "retry"}).
    Plain to_string/of_string keeps this module from exposing
    additional spec catalog bindings. *)
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

(** Diagnostic surface metrics emitted into trajectory entries. *)
type tool_surface_metrics =
  { turn_lane : turn_lane
  ; config_root : string
  ; runtime_config_path : string option
  }

(** Affordances that influence per-turn tool gating. *)
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

(** [affordance_can_mutate aff] is [true] iff [aff] grants a tool that can
    change task/world state (and thus clear the signal that surfaced it).
    [Task_audit] is the sole advisory-only ([false]) affordance: a signal whose
    only affordance is [Task_audit] must never drive a proactive wake, or the
    keeper livelocks on a signal it cannot clear (RFC-keeper-proactive-wake-actionability-invariant). Exhaustive over the
    closed [turn_affordance] sum. *)
val affordance_can_mutate : turn_affordance -> bool

(** Compute the satisfying tools for a set of turn affordances,
    intersected with [allowed_tool_names] and deduplicated.
    Used to provide actionable alternatives in retry messages. *)
val satisfying_tools_for_turn :
  turn_affordances:string list -> allowed_tool_names:string list -> string list

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

val owned_active_task_id_result_for_meta :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  (Keeper_id.Task_id.t option, string) result
(** Result-returning variant for callers where an unreadable backlog must not
    be interpreted as "no active task". *)

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
