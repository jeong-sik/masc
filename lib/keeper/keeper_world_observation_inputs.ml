(** See [keeper_world_observation_inputs.mli] for the contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

type backlog_edge_observation =
  | Backlog_read_unavailable of string
  | Recovery_backlog of
      { revision : int
      ; projection_sha256 : string
      ; recovery : Workspace.backlog_recovery
      }
  | Observed_backlog of
      { revision : int
      ; projection_sha256 : string
      ; updated_since_last_scheduled_autonomous : bool
      }

let backlog_edge_observation_to_string = function
  | Backlog_read_unavailable _ -> "unavailable"
  | Recovery_backlog { revision; projection_sha256; recovery = _ } ->
    Printf.sprintf
      "recovery(revision=%d; projection=%s)"
      revision
      projection_sha256
  | Observed_backlog { revision; projection_sha256; _ } ->
    Printf.sprintf "primary(revision=%d; projection=%s)" revision projection_sha256
(* RFC-0357 §3.2: the backlog edge compares monotonic commit revisions, not
   wall clocks. The previous ISO8601 comparison against [proactive_rt.last_ts]
   had four defects this replacement dissolves by construction: same-second
   ties under a strict [>], NTP rewinds, a [last_ts <= 0.0] arm that degraded
   to the level check [backlog.tasks <> []], and a parse-failure arm that
   silently returned [false] forever. [last_consumed_backlog_revision] starts
   at 0 (never consumed), so a live backlog (version >= 1) admits exactly one
   turn before the first consumption is recorded — the zero-point arm is not
   needed. *)
type current_task_observation =
  | No_current_task
  | Current_task of Masc_domain.task
  | Recovered_current_task of
      { task : Masc_domain.task
      ; recovery : Workspace.backlog_recovery
      }
  | Current_task_missing of
      { task_id : Keeper_id.Task_id.t
      ; recovery : Workspace.backlog_recovery option
      }
  | Current_task_unavailable of
      { task_id : Keeper_id.Task_id.t
      ; error : string
      }

type backlog_edge_observation =
  | Backlog_read_unavailable
  | Observed_backlog of
      { revision : int
      ; projection_sha256 : string
       ; updated_since_last_scheduled_autonomous : bool
       }

(* RFC-0357 §3.2: the backlog edge compares monotonic commit revisions, not
   wall clocks. The previous ISO8601 comparison against [proactive_rt.last_ts]
   had four defects this replacement dissolves by construction: same-second
   ties under a strict [>], NTP rewinds, a [last_ts <= 0.0] arm that degraded
   to the level check [backlog.tasks <> []], and a parse-failure arm that
   silently returned [false] forever. [last_consumed_backlog_revision] starts
   at 0 (never consumed), so a live backlog (version >= 1) admits exactly one
    turn before the first consumption is recorded — the zero-point arm is not
    needed. *)
let backlog_updated_since_last_scheduled_autonomous
      ~(meta : keeper_meta)
      ~(backlog : Masc_domain.backlog)
      ~(projection_sha256 : string)
  : bool
  =
  let proactive_rt = meta.runtime.proactive_rt in
  backlog.version > proactive_rt.last_consumed_backlog_revision
  && not
       (String.equal
          projection_sha256
          proactive_rt.last_consumed_backlog_projection_sha256)
;;

(* A keeper must not treat a task it authored itself as work waiting for it.
   Without this, a persona whose response to "an unclaimed task exists" is to
   create a routing/report task produces a closed positive feedback loop: the
   new task is itself an unclaimed Todo authored by the same keeper, so it
   re-satisfies the trigger on the next observation. Live evidence: taskmaster
   authored 367 of the active tasks, 272 of them the same four "Route g0700 #N"
   templates re-emitted once per iteration (#28..#90), none ever claimed.

   Only unclaimed [Todo] work is excluded. [AwaitingVerification] is not
   claimable or actionable by any Keeper, regardless of who authored it. *)
let task_is_self_authored_todo ~(meta : keeper_meta) (task : Masc_domain.task) =
  match task.task_status, task.created_by with
  | Masc_domain.Todo, Some author -> String.equal author meta.name
  | Masc_domain.Todo, None -> false
  | ( Masc_domain.AwaitingVerification _
    | Masc_domain.Claimed _
    | Masc_domain.InProgress _
    | Masc_domain.Done _
    | Masc_domain.Cancelled _ )
    , (None | Some _) ->
    false
;;

let relevant_backlog_projection_sha256
      ~(meta : keeper_meta)
      (tasks : Masc_domain.task list)
  =
  tasks
  |> List.filter (fun task -> not (task_is_self_authored_todo ~meta task))
  |> List.map Masc_domain.task_to_yojson
  |> List.map (fun json -> Yojson.Safe.to_string json, json)
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  |> List.map snd
  |> fun sorted -> Yojson.Safe.to_string (`List sorted)
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let claim_goal_scope_filter ~(config : Workspace.config) ~(meta : keeper_meta)
    ~(tasks : Masc_domain.task list) () =
  (* [read_backlog_counts] already loaded [tasks]. Reuse them to get the same
     empty-scope fallback as the claim path without a second backlog read.
     Self-authored Todo work is a hard exclusion, so it cannot keep the scope
     artificially nonempty and hide eligible peer work. *)
  let task_eligible task = not (task_is_self_authored_todo ~meta task) in
  let scope =
    Keeper_runtime_contract.resolve_claim_goal_scope_for_tasks
      ~config
      ~meta
      ~tasks
      ~task_eligible
      ()
  in
  scope.task_filter
;;

(** Read workspace backlog counts. *)
let read_backlog_counts ~(config : Workspace.config) ~(meta : keeper_meta)
  : int * int * int * backlog_edge_observation
  =
  try
    match Workspace.read_backlog_observation_r config with
    | Error message ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ObservationQueryFailures)
        ~labels:
          [ ( "operation"
            , Runtime_observation_query_operation.(to_label Read_backlog_counts) )
          ]
        ();
      Log.Keeper.warn "read_backlog_counts: backlog read failed: %s" message;
      (* Primary and recovery are both invalid. Preserve the typed unavailable
         state so admission can report [Backlog_unreadable] without silencing
         independent message, board, or schedule stimuli. *)
      0, 0, 0, Backlog_read_unavailable
    | Ok backlog ->
    let unclaimed_tasks =
      List.filter
        (fun (t : Masc_domain.task) -> t.task_status = Masc_domain.Todo)
        backlog.tasks
    in
    let unclaimed = List.length unclaimed_tasks in
    let claim_scope_filter =
      claim_goal_scope_filter ~config ~meta ~tasks:backlog.tasks ()
    in
    let claimable =
      List.length
        (List.filter
           (fun task ->
              Workspace_task_schedule.task_is_claim_pool_candidate task
              && claim_scope_filter task
              (* Self-authored tasks stay in [unclaimed] (the count stays an
                 honest view of the backlog) but are not offered back to their
                 author as claimable work — that edge is the feedback loop. *)
              && not (task_is_self_authored_todo ~meta task))
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
    let projection_sha256 =
      relevant_backlog_projection_sha256 ~meta backlog.tasks
    in
    let backlog_edge =
      match recovered_from with
      | None ->
        Observed_backlog
          { revision = backlog.version
          ; projection_sha256
          ; updated_since_last_scheduled_autonomous =
              backlog_updated_since_last_scheduled_autonomous
                ~meta
                ~backlog
                ~projection_sha256
          }
      | Some recovery ->
        Log.Keeper.warn
          "read_backlog_counts: using non-authoritative recovery for observation only path=%s primary_error=%s"
          recovery.recovery_path
          recovery.primary_error;
        Recovery_backlog { revision = backlog.version; projection_sha256; recovery }
    in
    unclaimed, claimable, failed, backlog_edge
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | ex ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ObservationQueryFailures)
      ~labels:
        [ ("operation", Runtime_observation_query_operation.(to_label Read_backlog_counts)) ]
      ();
    Log.Keeper.warn "read_backlog_counts failed: %s" (Printexc.to_string ex);
    raise ex
;;

(** Resolve the keeper's claimed task to a source-preserving observation. *)
let read_current_task ~(config : Workspace.config) ~(meta : keeper_meta)
  : current_task_observation
  =
  match meta.current_task_id with
  | None -> No_current_task
  | Some task_id ->
    let record_unavailable error =
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ObservationQueryFailures)
        ~labels:
          [ ( "operation"
            , Runtime_observation_query_operation.(to_label Read_current_task) )
          ]
        ();
      Log.Keeper.warn
        "read_current_task unavailable task_id=%s: %s"
        (Keeper_id.Task_id.to_string task_id)
        error
    in
    try
      match Workspace.read_backlog_observation_with_source_r config with
      | Error message ->
        record_unavailable message;
        Current_task_unavailable { task_id; error = message }
      | Ok { Workspace.observed_backlog = backlog; recovered_from = None } ->
        let task_id_string = Keeper_id.Task_id.to_string task_id in
        (match
           List.find_opt
             (fun (t : Masc_domain.task) -> String.equal t.id task_id_string)
             backlog.tasks
         with
         | Some task -> Current_task task
         | None -> Current_task_missing { task_id; recovery = None })
      | Ok
          { Workspace.observed_backlog = backlog
          ; recovered_from = Some recovery
          } ->
        let task_id_string = Keeper_id.Task_id.to_string task_id in
        (match
           List.find_opt
             (fun (t : Masc_domain.task) -> String.equal t.id task_id_string)
             backlog.tasks
         with
         | Some task -> Recovered_current_task { task; recovery }
         | None -> Current_task_missing { task_id; recovery = Some recovery })
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | ex ->
      let rendered = Printexc.to_string ex in
      record_unavailable rendered;
      raise ex
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
