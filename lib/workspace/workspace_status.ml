(** Workspace Status - Workspace status display.

    Extracted from Workspace module. Renders the full project status view
    including agents, tasks, and message summary. *)

open Masc_domain
open Workspace_utils
open Workspace_state
open Workspace_backlog

(** Get project status *)
let status config =
  ensure_initialized config;

  let state = read_state config in
  let backlog = read_backlog config in
  let active_task_assignees =
    Workspace_task_schedule.active_task_assignees_by_task_id backlog
  in
  let max_agents_display = 40 in
  let max_active_tasks_display = 30 in

  let buf = Buffer.create 256 in
  let cluster_name =
    match config.backend_config.Backend_types.cluster_name with
    | "" -> state.project
    | name -> name
  in
  Printf.bprintf buf "🏢 Cluster: %s\n" cluster_name;
  if cluster_name <> state.project then
    Printf.bprintf buf "Project: %s\n" state.project;
  Buffer.add_string buf "📍 Workspace: root\n";
  Printf.bprintf buf "📁 Path: %s\n" config.base_path;
  Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";
  Buffer.add_string buf "Players:\n";

  let agents =
    Workspace_query.get_active_agents config
    |> List.filter_map (fun (agent : Masc_domain.agent) ->
           let stale_current_task =
             match agent.current_task with
             | Some task_id ->
                 not
                   (Workspace_task_schedule.agent_current_task_matches_assignments
                      active_task_assignees ~agent_name:agent.name task_id)
             | None -> false
           in
           let display_status =
             if stale_current_task then
               match agent.status with
               | Inactive -> Inactive
               | Active | Busy | Listening -> Active
             else
               agent.status
           in
           let icon =
             match display_status with
             | Busy -> "🔴"
             | Active -> "🟢"
             | Listening -> "🎧"
             | Inactive -> "⚫"
           in
           let task =
             if stale_current_task then "idle"
             else
               match agent.current_task with
               | Some task_id -> task_id
               | None -> "idle"
           in
           Some (agent.name, icon, task))
    |> List.sort (fun (a, _, _) (b, _, _) -> String.compare a b)
  in
  let total_agents = List.length agents in
  let shown_agents = take max_agents_display agents in
  List.iter (fun (name, icon, task) ->
    Printf.bprintf buf "  %s %s → %s\n" icon name task
  ) shown_agents;
  if total_agents > max_agents_display then
    Buffer.add_string buf
      (Printf.sprintf
         "  … and %d more agents\n"
         (total_agents - max_agents_display));

  Buffer.add_string buf "\nQuest Board:\n";

  let sorted_tasks = List.sort (fun a b -> compare a.priority b.priority) backlog.tasks in
  let active_tasks, done_count, cancelled_count =
    List.fold_left
      (fun (active, done_cnt, cancelled_cnt) task ->
        let s = task.task_status in
        if Masc_domain.task_status_is_done s then (active, done_cnt + 1, cancelled_cnt)
        else if Masc_domain.task_status_is_terminal s then (active, done_cnt, cancelled_cnt + 1)
        else (task :: active, done_cnt, cancelled_cnt))
      ([], 0, 0) sorted_tasks
  in
  let active_tasks = List.rev active_tasks in
  let shown_active_tasks = take max_active_tasks_display active_tasks in
  List.iter (fun task ->
    let status_icon = Masc_domain.task_status_icon task.task_status in
    let assignee = Masc_domain.task_display_assignee task.task_status in
    Printf.bprintf buf "  %s %s: %s (%s)\n" status_icon task.id task.title assignee
  ) shown_active_tasks;

  if active_tasks = [] then
    Buffer.add_string buf "  (no active tasks)\n";
  if List.length active_tasks > max_active_tasks_display then
    Buffer.add_string buf
      (Printf.sprintf
         "  … and %d more active tasks (use masc_tasks for full list)\n"
         (List.length active_tasks - max_active_tasks_display));
  Buffer.add_string buf
    (Printf.sprintf
       "  Summary: active=%d, done=%d, cancelled=%d, total=%d\n"
       (List.length active_tasks) done_count cancelled_count (List.length backlog.tasks));

  (* Message summary: use cumulative sequence to avoid heavy directory scans *)
  let total_messages = max 0 state.message_seq in
  if total_messages > 0 then begin
    Printf.bprintf buf "\nMessages: %d (cumulative)\n" total_messages;
    Buffer.add_string buf "   Use masc_messages for recent details\n"
  end else
    Buffer.add_string buf "\nMessages: 0\n";

  Buffer.contents buf
