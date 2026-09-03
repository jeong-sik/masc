val dashboard_json : Workspace.config -> Yojson.Safe.t
(** Cross-subsystem keeper waiting/deferred read model for dashboard tools.
    This parent-library module is shared by server and tool entrypoints; it may
    join MASC stores, but it does not add a dashboard dependency to lower
    keeper/runtime libraries. *)

val dashboard_json_for_keeper :
  Workspace.config -> keeper_name:string -> Yojson.Safe.t
(** The same typed projection narrowed to one keeper for latency-sensitive
    detail surfaces. It does not overwrite fleet-wide waiting metrics. *)

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
  val dashboard_json_with_pending_reader :
    read_pending:
      (base_path:string ->
      ( Keeper_approval_queue_rules_types.pending_approval list
      , Keeper_approval_queue.storage_error )
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
