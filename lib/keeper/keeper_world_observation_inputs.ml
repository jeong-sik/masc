(** See [keeper_world_observation_inputs.mli] for the contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

let backlog_updated_since_last_scheduled_autonomous
      ~(meta : keeper_meta)
      ~(backlog : Masc_domain.backlog)
  : bool
  =
  let last_ts = meta.runtime.proactive_rt.last_ts in
  if last_ts <= 0.0
  then backlog.tasks <> []
  else (
    match Workspace_resilience.Time.parse_iso8601_opt backlog.last_updated with
    | Some updated_at -> updated_at > last_ts
    | None -> false)
;;

let claim_goal_scope_filter ~(config : Workspace.config) ~(meta : keeper_meta) () =
  (* Use [resolve_claim_goal_scope] (backlog-aware, widens filter when no
     scoped claimable tasks exist) rather than the pure-meta observation
     variant.  [read_backlog_counts] already reads the backlog, so this
     does not add a disk read.  Without the widening, a keeper whose active
     goals carry no live claimable task sees [claimable_task_count = 0]
     and never wakes for backlog work — the "coordination-role tasks are
     blocked from re-claim by completion" staleness (task-1869). *)
  let scope =
    Keeper_runtime_contract.resolve_claim_goal_scope ~config ~meta ()
  in
  scope.task_filter
;;

let actionable_verification_request_ids ~(config : Workspace.config) : string list =
  Verification.list_requests config.Workspace.base_path
  |> List.filter Verification.request_is_actionable
  |> List.map (fun (req : Verification.verification_request) -> req.id)
;;

let task_has_actionable_verification actionable_request_ids
    (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.AwaitingVerification { verification_id; _ } ->
    List.exists (String.equal verification_id) actionable_request_ids
  | Masc_domain.Todo
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.Done _
  | Masc_domain.Cancelled _ -> false
;;

(** Read workspace backlog counts. *)
let read_backlog_counts ~(config : Workspace.config) ~(meta : keeper_meta)
  : int * int * int * int * bool
  =
  try
    let backlog = Workspace.read_backlog config in
    let unclaimed_tasks =
      List.filter
        (fun (t : Masc_domain.task) -> t.task_status = Masc_domain.Todo)
        backlog.tasks
    in
    let unclaimed = List.length unclaimed_tasks in
    let claim_scope_filter = claim_goal_scope_filter ~config ~meta () in
    let claimable =
      List.length
        (List.filter
           (fun task ->
              Workspace_task_schedule.task_is_claim_pool_candidate task
              && claim_scope_filter task)
           unclaimed_tasks)
    in
    let failed =
      (* "Failed" here means still-auditable active work. Terminal Cancelled
         tasks are historical evidence, not a reason to wake every keeper.
         Keep the current keeper's own task out of the count: keepers may
         claim without a materialized [.masc/agents/] record, so the audit can
         still see the self-assigned task as an orphan. *)
      Workspace.audit_orphan_tasks config
      |> List.filter (fun (_, assignee) -> assignee <> meta.agent_name)
      |> List.map fst
      |> List.filter claim_scope_filter
      |> List.length
    in
    let pending_verification =
      let actionable_request_ids = actionable_verification_request_ids ~config in
      List.length
        (List.filter
           (task_has_actionable_verification actionable_request_ids)
           backlog.tasks)
    in
    let backlog_updated_since_last_scheduled_autonomous =
      backlog_updated_since_last_scheduled_autonomous ~meta ~backlog
    in
    ( unclaimed
    , claimable
    , failed
    , pending_verification
    , backlog_updated_since_last_scheduled_autonomous )
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | ex ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ObservationQueryFailures)
      ~labels:
        [ ("operation", Runtime_observation_query_operation.(to_label Read_backlog_counts)) ]
      ();
    Log.Keeper.warn "read_backlog_counts failed: %s" (Printexc.to_string ex);
    0, 0, 0, 0, false
;;

(** Resolve the keeper's claimed task to its backlog record (RFC-0315). *)
let read_current_task ~(config : Workspace.config) ~(meta : keeper_meta)
  : Masc_domain.task option
  =
  match meta.current_task_id with
  | None -> None
  | Some task_id ->
    let task_id = Keeper_id.Task_id.to_string task_id in
    (try
       let backlog = Workspace.read_backlog config in
       List.find_opt
         (fun (t : Masc_domain.task) -> String.equal t.id task_id)
         backlog.tasks
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | ex ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string ObservationQueryFailures)
         ~labels:
           [ ( "operation"
             , Runtime_observation_query_operation.(to_label Read_current_task)
             )
           ]
         ();
       Log.Keeper.warn "read_current_task failed: %s" (Printexc.to_string ex);
       None)
;;

(** Count live keeper fibers for keeper world state.

    Keepers do not write the legacy [.masc/agents/] registry.  That registry may
    be empty while keepers are running normally, so keeper observations must use
    the live keeper registry instead. *)
let count_running_keeper_fibers ~(config : Workspace.config) : int =
  try Keeper_registry.count_running ~base_path:config.base_path () with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | ex ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ObservationQueryFailures)
      ~labels:
        [
          ( "operation",
            Runtime_observation_query_operation.(
              to_label Count_running_keeper_fibers) );
        ]
      ();
    Log.Keeper.warn "count_running_keeper_fibers failed: %s" (Printexc.to_string ex);
    0
;;

(** Compute idle seconds from keeper timestamps. *)
let compute_idle_seconds ~(meta : keeper_meta) : int =
  let now_ts = Time_compat.now () in
  let created_ts =
    Workspace_resilience.Time.parse_iso8601_opt meta.created_at |> Option.value ~default:0.0
  in
  let activity_ts = List.fold_left max created_ts [ meta.runtime.proactive_rt.last_ts ] in
  if activity_ts <= 0.0 then 0 else int_of_float (max 0.0 (now_ts -. activity_ts))
;;

(** Read context ratio from checkpoint if available. *)
let read_context_ratio ~(config : Workspace.config) ~(meta : keeper_meta) : float =
  try
    let primary_max_context =
      let resolution =
        Keeper_context_runtime.resolve_max_context_resolution_of_meta meta
      in
      resolution.effective_budget
    in
    let base_dir = session_base_dir config in
    let _session, ctx_opt =
      load_context_from_checkpoint
        ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
        ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
        ~primary_model_max_tokens:primary_max_context
        ~base_dir
    in
    match ctx_opt with
    | Some c -> Keeper_context_runtime.context_ratio c
    | None -> 0.0
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> 0.0
;;
