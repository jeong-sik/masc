val dashboard_json : Workspace.config -> Yojson.Safe.t
(** Cross-subsystem keeper waiting/deferred read model for dashboard tools.
    This parent-library module is shared by server and tool entrypoints; it may
    join MASC stores, but it does not add a dashboard dependency to lower
    keeper/runtime libraries. *)

val health_json : Workspace.config -> Yojson.Safe.t
(** Compact health projection from the same typed inventory snapshot. Normal
    waiting does not imply a fault. Unreadable sources and a schedule recovery
    mirror make completeness unknown, retain explicitly observed counts, and
    report a repair reason. No payloads or raw storage errors are exposed. *)

val health_placeholder : status:Health_status.t -> Yojson.Safe.t
(** No inventory has been observed: all counts remain unknown. The caller
    supplies the background snapshot's grade, including warming/error. *)

val dashboard_json_for_keeper :
  Workspace.config -> keeper_name:string -> Yojson.Safe.t
(** The same typed projection narrowed to one keeper for latency-sensitive
    detail surfaces. It does not overwrite fleet-wide waiting metrics. *)

val keeper_json_by_name :
  Workspace.config -> ((string * Yojson.Safe.t) list, Yojson.Safe.t list) result
(** One fleet snapshot's public per-Keeper projections, keyed by Keeper name.
    The rows have the same shape as [dashboard_json]'s [keepers] entries and
    the per-Keeper endpoint, so another public-read projection can join them
    without recomputing the inventory or inventing a second wire contract.
    If a fleet-scoped source is unreadable or the schedule ledger is observed
    only through its recovery mirror, return public error rows instead of
    attributing them to every Keeper or reporting an incomplete snapshot as
    healthy. Per-Keeper errors remain in the affected Keeper's projection. *)

type waiting_source =
  | Event_queue_pending
  | Chat_operation_queued
  | Chat_operation_running
  | Hitl_pending
  | Fusion_running
  | Schedule_waiting
  | Owner_shutdown
  | Operator_pending_confirm
  | Read_error

val source_of_string : string -> (waiting_source, string) result
(** Decode the source vocabulary emitted by this inventory. Unknown sources
    are errors, never ordinary queued work. *)

type wake_producer =
  | Board_dispatch
  | Board_attention_judge
  | Keeper_owner_actor
  | Keeper_supervisor
  | Fusion_sink
  | Connector_attention_hook
  | Hitl_resolution_hook
  | Keeper_ask_answer
  | Schedule_store
  | Schedule_runner
  | Operator_pending_confirm_store
  | Completion_authority
  | Keeper_task_cancellation
  | Keeper_workspace_message
  | Keeper_delegate
  | Keeper_composition
  | Keeper_job
  | Keeper_addon
  | Read_model_reader

type waiting_row =
  { keeper_name : string option
  ; source : waiting_source
  ; waiting_on : string
  ; what : string
  ; wake_producer : wake_producer
  ; since : float option
  ; due_at : float option
  ; next_action : string
  ; detail : Yojson.Safe.t
  }

module For_testing : sig
  val health_json_with_pending_reader :
    read_pending:
      (base_path:string ->
      ( Keeper_approval_queue_rules_types.pending_approval list
      , Keeper_approval_queue_result.storage_error )
      result) ->
    Workspace.config ->
    Yojson.Safe.t

  val dashboard_json_with_pending_reader :
    read_pending:
      (base_path:string ->
      ( Keeper_approval_queue_rules_types.pending_approval list
      , Keeper_approval_queue_result.storage_error )
      result) ->
    Workspace.config ->
    Yojson.Safe.t

  (** Pending external-attention items grouped for display: one row per
      (urgency, source, conversation), the oldest member anchoring the row.
      Exposed for the grouping tests; production reads go through
      [dashboard_json]. *)

  (** Pending queue selections with Connector_attention stimuli collapsed
      into one row per urgency. Exposed for the grouping tests; production
      reads go through [dashboard_json]. *)
  val rows_for_queue_snapshot :
    keeper_name:string ->
    source:waiting_source ->
    next_action:string ->
    Keeper_event_queue_state.pending_selection list ->
    waiting_row list
end
