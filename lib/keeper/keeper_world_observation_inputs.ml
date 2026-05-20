(** See [keeper_world_observation_inputs.mli] for the contract. *)

open Keeper_types
open Keeper_exec_context

let backlog_updated_since_last_scheduled_autonomous
      ~(meta : keeper_meta)
      ~(backlog : Masc_domain.backlog)
  : bool
  =
  let last_ts = meta.runtime.proactive_rt.last_ts in
  if last_ts <= 0.0
  then backlog.tasks <> []
  else (
    match Coord_resilience.Time.parse_iso8601_opt backlog.last_updated with
    | Some updated_at -> updated_at > last_ts
    | None -> false)
;;

let claim_goal_scope_filter ?agent_tool_names ~(config : Coord.config)
    ~(meta : keeper_meta) () =
  let scope =
    Keeper_runtime_contract.resolve_observation_claim_goal_scope
      ?agent_tool_names
      ~config
      ~meta
      ()
  in
  scope.task_filter
;;

let actionable_verification_request_ids ~(config : Coord.config) : string list =
  Verification.list_requests config.Coord.base_path
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

(** Read room backlog counts. *)
let read_backlog_counts ~allowed_tool_names ~(config : Coord.config) ~(meta : keeper_meta)
  : int * int * int * int * bool
  =
  try
    let backlog = Coord.read_backlog config in
    let unclaimed_tasks =
      List.filter
        (fun (t : Masc_domain.task) -> t.task_status = Masc_domain.Todo)
        backlog.tasks
    in
    let unclaimed = List.length unclaimed_tasks in
    let claim_scope_filter =
      claim_goal_scope_filter ?agent_tool_names:allowed_tool_names ~config ~meta ()
    in
    (* Build the allowed-set once and reuse across all candidates in
       the [unclaimed_tasks] filter below -- see PR #14826 for the
       O(R+A) rationale. *)
    let required_tools_allowed =
      Coord_task_schedule.make_required_tools_predicate
        ?agent_tool_names:allowed_tool_names
        ()
    in
    let claimable =
      List.length
        (List.filter
           (fun task ->
              Coord_task_schedule.task_is_claim_pool_candidate task
              && claim_scope_filter task
              && required_tools_allowed (Coord_task_schedule.task_required_tools task))
           unclaimed_tasks)
    in
    let failed =
      (* "Failed" here means still-auditable active work. Terminal Cancelled
         tasks are historical evidence, not a reason to wake every keeper. *)
      Coord.audit_orphan_tasks config
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
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_observation_query_failures
      ~labels:
        [ ("operation", Keeper_observation_query_operation.(to_label Read_backlog_counts)) ]
      ();
    Log.Keeper.warn "read_backlog_counts failed: %s" (Printexc.to_string ex);
    0, 0, 0, 0, false
;;

(** Count active agents in room. *)
let count_active_agents ~(config : Coord.config) : int =
  try List.length (Coord.get_agents_raw config) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | ex ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_observation_query_failures
      ~labels:
        [ ("operation", Keeper_observation_query_operation.(to_label Count_active_agents)) ]
      ();
    Log.Keeper.warn "count_active_agents failed: %s" (Printexc.to_string ex);
    0
;;

(** Compute idle seconds from keeper timestamps. *)
let compute_idle_seconds ~(meta : keeper_meta) : int =
  let now_ts = Time_compat.now () in
  let created_ts =
    Coord_resilience.Time.parse_iso8601_opt meta.created_at |> Option.value ~default:0.0
  in
  let activity_ts = List.fold_left max created_ts [ meta.runtime.proactive_rt.last_ts ] in
  if activity_ts <= 0.0 then 0 else int_of_float (max 0.0 (now_ts -. activity_ts))
;;

(** Read context ratio from checkpoint if available. *)
let read_context_ratio ~(config : Coord.config) ~(meta : keeper_meta) : float =
  try
    let cascade_models = Keeper_model_labels.configured_model_labels_of_meta meta in
    let primary_max_context =
      let resolution =
        Keeper_exec_context.resolve_max_context_resolution
          ~requested_override:meta.max_context_override
          cascade_models
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
    | Some c -> Keeper_exec_context.context_ratio c
    | None -> 0.0
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> 0.0
;;
