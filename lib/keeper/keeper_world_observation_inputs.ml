(** See [keeper_world_observation_inputs.mli] for the contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

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

type task_age =
  | Age_days of int
  | Created_at_unreadable

type task_goal_links =
  | Active_goals of string list
  | Goal_links_unread

type claimable_task_identity =
  { task_id : Keeper_id.Task_id.t
  ; priority : int
  ; age : task_age
  ; returns : int
  ; goal_links : task_goal_links
  }

type held_task_skills =
  { held_task_id : string
  ; held_skills : Skill_reference.t list
  }

type backlog_snapshot =
  { unclaimed_count : int
  ; claimable_tasks : claimable_task_identity list
  ; failed_count : int
  ; revision : int option
  ; held_task_skills : held_task_skills list
  }

let empty_backlog_snapshot =
  { unclaimed_count = 0
  ; claimable_tasks = []
  ; failed_count = 0
  ; revision = None
  ; held_task_skills = []
  }
;;

(* Every task this keeper holds (Claimed or InProgress, same actor identity as
   a transition would use) that names at least one skill, in backlog order.
   The current task is left out: its own block already carries its skills.

   This is why the projection exists at all. A keeper's current_task_id is
   reconciled from ownership and, once bound, stays on the task it already
   names — so a keeper holding task A that claims task B keeps A current, and
   B's skills never reached the prompt through the current-task block
   (task-364). Reading the skills off every held task makes the line
   independent of which task the reconciler picked. *)
let held_task_skills_of_tasks
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      (tasks : Masc_domain.task list)
  : held_task_skills list
  =
  let current_task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id in
  List.filter_map
    (fun (task : Masc_domain.task) ->
       let held =
         match task.task_status with
         | Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ } ->
           Workspace_task_classify.same_task_actor config assignee meta.name
         | Masc_domain.Todo
         | Masc_domain.AwaitingVerification _
         | Masc_domain.Done _
         | Masc_domain.Cancelled _ -> false
       in
       let is_current =
         match current_task_id with
         | Some id -> String.equal id task.id
         | None -> false
       in
       if held && (not is_current) && task.skills <> []
       then Some { held_task_id = task.id; held_skills = task.skills }
       else None)
    tasks
;;

let rec tasks_with_identities = function
  | [] -> Ok []
  | (task : Masc_domain.task) :: rest ->
    (match Keeper_id.Task_id.of_string task.id with
     | Error reason -> Error reason
     | Ok task_id ->
       Result.map
         (fun tasks -> (task, task_id) :: tasks)
         (tasks_with_identities rest))
;;

(* The backlog store hands back the same decoded record while the file is
   unchanged ([Workspace_backlog] caches by mtime and size), so the task list
   is physically shared across observations. Validating every task id again
   on each of them, a regex per task, was 2-3% of the main thread on a live
   keeper (RFC main-domain-scheduler-latency section 8.8). One entry: the
   last list seen and what it parsed to. A different list, which is what a
   changed backlog produces, is parsed afresh. *)
let identities_memo
  : (Masc_domain.task list
     * ((Masc_domain.task * Keeper_id.Task_id.t) list, string) result)
      option
      Atomic.t
  =
  Atomic.make None
;;

let tasks_with_identities_memoized tasks =
  match Atomic.get identities_memo with
  | Some (seen, result) when seen == tasks -> result
  | Some _ | None ->
    (* A changed backlog: parse every task id again, on the domain pool when
       one is installed, so the regex per task does not run on the fiber. *)
    let result = Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () -> tasks_with_identities tasks) in
    Atomic.set identities_memo (Some (tasks, result));
    result
;;

(* The in-progress Goals each Task is linked to, from the Goal store and the
   primary link registry: the readers the turn's task context uses. [Error]
   when either cannot be read, so the caller marks every row unread instead
   of unlinked. The registry is read only when a Goal is in progress. *)
let active_goals_by_task ~(config : Workspace.config) =
  match Goal_store.list_goals_result config () with
  | Error unavailable -> Error (Goal_store.unavailable_to_string unavailable)
  | Ok goals ->
    (match
       List.filter_map
         (fun (goal : Goal_store.goal) ->
            if Goal_phase.admits_self_directed_progress goal.phase
            then Some goal.id
            else None)
         goals
     with
     | [] -> Ok (fun ~task_id:(_ : string) -> [])
     | active_goal_ids ->
       Result.map
         (fun links ->
            let by_task =
              Workspace_goal_index.build_task_goal_map
                ~goal_task_links:
                  (List.filter
                     (fun (goal_id, (_ : string list)) ->
                        List.exists (String.equal goal_id) active_goal_ids)
                     links)
                ()
            in
            fun ~task_id ->
              Workspace_goal_index.goals_for_task_in_map by_task ~task_id
              |> List.sort_uniq String.compare)
         (Workspace_goal_index.read_goal_task_links_authoritative_r config))
;;

let seconds_per_day = 86_400.0

(* The order the rows are shown in, which is not the order a claim without a
   task id picks in ([Workspace.claim_next_r]: priority, then oldest):

   1. Tasks linked to an in-progress Goal. A Goal is what the operator and
      the Keepers declared they are advancing now.
   2. The author's priority.
   3. Newest first, so a Task a turn just added is not behind every older
      sibling of its priority (#29101).
   4. Task id.

   Measured on one fleet backlog on 2026-11-12, 465 claimable Tasks of which
   84 were linked to an in-progress Goal: the first ten rows of the claim
   order were 28 to 66 days old and one of them was Goal-linked; the first
   ten rows of this order were 6 to 14 days old and all ten were Goal-linked.

   A Task whose [created_at] does not parse sorts after the ones that do
   within its priority. Its age is [Created_at_unreadable], not zero. When the
   Goal links cannot be read every row is [Goal_links_unread] and step 1 does
   not apply. *)
let claimable_rows ~(config : Workspace.config) ~keeper_name ~now = function
  | [] -> []
  | claimable ->
    let goal_links_of =
      match active_goals_by_task ~config with
      | Ok active_goals -> fun ~task_id -> Active_goals (active_goals ~task_id)
      | Error detail ->
        Log.Keeper.warn ~keeper_name "claimable tasks: Goal links unreadable: %s" detail;
        fun ~task_id:(_ : string) -> Goal_links_unread
    in
    let goal_rank (row : claimable_task_identity) =
      match row.goal_links with
      | Active_goals (_ :: _) -> 0
      | Active_goals [] | Goal_links_unread -> 1
    in
    let newest_first left right =
      match left, right with
      | Some left, Some right -> Float.compare right left
      | Some _, None -> -1
      | None, Some _ -> 1
      | None, None -> 0
    in
    claimable
    |> List.map (fun ((task : Masc_domain.task), task_id) ->
      let created = Masc_domain.parse_iso8601_opt task.created_at in
      ( created
      , { task_id
        ; priority = task.priority
        ; age =
            (match created with
             | Some created ->
               Age_days (int_of_float (Float.floor ((now -. created) /. seconds_per_day)))
             | None -> Created_at_unreadable)
        ; returns = task.cycle_count
        ; goal_links = goal_links_of ~task_id:task.id
        } ))
    |> List.sort (fun (left_created, left) (right_created, right) ->
      match Int.compare (goal_rank left) (goal_rank right) with
      | 0 ->
        (match Int.compare left.priority right.priority with
         | 0 ->
           (match newest_first left_created right_created with
            | 0 ->
              String.compare
                (Keeper_id.Task_id.to_string left.task_id)
                (Keeper_id.Task_id.to_string right.task_id)
            | order -> order)
         | order -> order)
      | order -> order)
    |> List.map snd
;;

(** Read one authoritative backlog snapshot. Counts, claimable rows, and
    revision are projected from the same primary read. *)
let read_backlog_snapshot ~(config : Workspace.config) ~(meta : keeper_meta)
  : backlog_snapshot
  =
  try
    match Workspace.read_backlog_observation_with_source_r config with
    | Error message ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ObservationQueryFailures)
        ~labels:
          [ ( "operation"
            , Runtime_observation_query_operation.(to_label Read_backlog_snapshot) )
          ]
        ();
      Log.Keeper.warn "read_backlog_snapshot: backlog read failed: %s" message;
      empty_backlog_snapshot
    | Ok { Workspace.recovered_from = Some recovery; _ } ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ObservationQueryFailures)
        ~labels:
          [ ( "operation"
            , Runtime_observation_query_operation.(to_label Read_backlog_snapshot) )
          ]
        ();
      Log.Keeper.warn
        "read_backlog_snapshot: recovery snapshot is non-authoritative: %s"
        recovery.primary_error;
      empty_backlog_snapshot
    | Ok { Workspace.observed_backlog = backlog; recovered_from = None } ->
    (match tasks_with_identities_memoized backlog.tasks with
     | Error reason ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string ObservationQueryFailures)
         ~labels:
           [ ( "operation"
             , Runtime_observation_query_operation.(to_label Read_backlog_snapshot) )
           ]
         ();
       Log.Keeper.warn
         "read_backlog_snapshot: invalid task identity: %s"
         reason;
       empty_backlog_snapshot
     | Ok tasks_with_ids ->
       let unclaimed_tasks =
         List.filter
           (fun ((task : Masc_domain.task), _) ->
              task.task_status = Masc_domain.Todo)
           tasks_with_ids
       in
       let unclaimed = List.length unclaimed_tasks in
       let claimable_tasks =
         claimable_rows
           ~config
           ~keeper_name:meta.name
           ~now:(Time_compat.now ())
           (List.filter
              (fun ((task : Masc_domain.task), _) ->
                 Workspace_task_schedule.task_is_claim_pool_candidate task)
              unclaimed_tasks)
       in
       let failed =
         (* "Failed" here means still-auditable active work. Terminal Cancelled
            tasks are historical evidence, not a reason to wake every keeper.
            Keep the current keeper's own task out of the count: keepers may
            claim without a materialized [.masc/agents/] record, so the audit can
            still see the self-assigned task as an orphan. *)
         Workspace.audit_orphan_tasks_in_tasks config backlog.tasks
         |> List.filter (fun (_, assignee) -> assignee <> meta.name)
         |> List.map fst
         |> List.length
       in
       { unclaimed_count = unclaimed
       ; claimable_tasks
       ; failed_count = failed
       ; revision = Some backlog.version
       ; held_task_skills = held_task_skills_of_tasks ~config ~meta backlog.tasks
       })
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | ex ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ObservationQueryFailures)
      ~labels:
        [ ( "operation"
          , Runtime_observation_query_operation.(to_label Read_backlog_snapshot) )
        ]
      ();
    Log.Keeper.warn "read_backlog_snapshot failed: %s" (Printexc.to_string ex);
    raise ex
;;

(** The direct-message lane builds its prompt before it observes the world, so
    it reads the held-task skills on their own. A backlog that cannot be read
    or only recovers yields no lines: the skills line is context, and the fact
    that the backlog is degraded reaches the prompt through the current-task
    observation. *)
let read_held_task_skills ~(config : Workspace.config) ~(meta : keeper_meta)
  : held_task_skills list
  =
  try
    match Workspace.read_backlog_observation_with_source_r config with
    | Error message ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ObservationQueryFailures)
        ~labels:
          [ ( "operation"
            , Runtime_observation_query_operation.(to_label Read_held_task_skills) )
          ]
        ();
      Log.Keeper.warn "read_held_task_skills: backlog read failed: %s" message;
      []
    | Ok { Workspace.recovered_from = Some _; _ } -> []
    | Ok { Workspace.observed_backlog = backlog; recovered_from = None } ->
      held_task_skills_of_tasks ~config ~meta backlog.tasks
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | ex ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ObservationQueryFailures)
      ~labels:
        [ ( "operation"
          , Runtime_observation_query_operation.(to_label Read_held_task_skills) )
        ]
      ();
    Log.Keeper.warn "read_held_task_skills failed: %s" (Printexc.to_string ex);
    []
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

(** Seconds since the keeper's last turn of any channel, or since it was
    created when it has not run one. *)
let compute_idle_seconds ~(meta : keeper_meta) : int =
  let now_ts = Time_compat.now () in
  let created_ts =
    Workspace_resilience.Time.parse_iso8601_opt meta.created_at |> Option.value ~default:0.0
  in
  let activity_ts = max created_ts meta.runtime.usage.last_turn_ts in
  if activity_ts <= 0.0 then 0 else int_of_float (max 0.0 (now_ts -. activity_ts))
;;
