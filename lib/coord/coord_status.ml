(** Coord Status - Coord status display.

    Extracted from Coord module. Renders the full room status view
    including agents, tasks, and message summary. *)

open Types
open Coord_utils
open Coord_state

(** Get room status *)
let status config =
  ensure_initialized config;

  let state = read_state config in
  let backlog = read_backlog config in
  let current_room = "default" in
  let max_agents_display = 40 in
  let max_active_tasks_display = 30 in

  let buf = Buffer.create 256 in
  let cluster_name =
    match config.backend_config.Backend_types.cluster_name with
    | "" -> state.project
    | name -> name
  in
  Buffer.add_string buf (Printf.sprintf "🏢 Cluster: %s\n" cluster_name);
  if cluster_name <> state.project then
    Buffer.add_string buf (Printf.sprintf "📦 Project: %s\n" state.project);
  Buffer.add_string buf (Printf.sprintf "📍 Namespace: %s (flattened)\n" current_room);
  Buffer.add_string buf (Printf.sprintf "📁 Path: %s\n" config.base_path);
  Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";
  Buffer.add_string buf "📌 Players:\n";

  (* List agents (bounded for responsiveness) *)
  let agents_path = agents_dir config in
  if Sys.file_exists agents_path then begin
    let agents =
      Sys.readdir agents_path
      |> Array.to_list
      |> List.filter (fun name -> Filename.check_suffix name ".json")
      |> List.filter_map (fun name ->
          let path = Filename.concat agents_path name in
          let json = read_json config path in
          match agent_of_yojson json with
          | Ok agent ->
              let is_zombie = is_zombie_agent ~agent_name:agent.name agent.last_seen in
              let icon =
                if is_zombie then "💀"
                else
                  match agent.status with
                  | Busy -> "🔴"
                  | Active -> "🟢"
                  | Listening -> "🎧"
                  | Inactive -> "⚫"
              in
              let task =
                if is_zombie then "zombie"
                else Option.value agent.current_task ~default:"idle"
              in
              Some (agent.name, icon, task)
          | Error _ -> None)
      |> List.sort (fun (a, _, _) (b, _, _) -> String.compare a b)
    in
    let total_agents = List.length agents in
    let shown_agents = take max_agents_display agents in
    List.iter (fun (name, icon, task) ->
      Buffer.add_string buf (Printf.sprintf "  %s %s → %s\n" icon name task)
    ) shown_agents;
    if total_agents > max_agents_display then
      Buffer.add_string buf
        (Printf.sprintf
           "  … and %d more agents (use masc_who for full list)\n"
           (total_agents - max_agents_display))
  end;

  Buffer.add_string buf "\n📋 Quest Board:\n";

  let sorted_tasks = List.sort (fun a b -> compare a.priority b.priority) backlog.tasks in
  let active_tasks, done_count, cancelled_count =
    List.fold_left
      (fun (active, done_cnt, cancelled_cnt) task ->
        match task.task_status with
        | Done _ -> (active, done_cnt + 1, cancelled_cnt)
        | Cancelled _ -> (active, done_cnt, cancelled_cnt + 1)
        | _ -> (task :: active, done_cnt, cancelled_cnt))
      ([], 0, 0) sorted_tasks
  in
  let active_tasks = List.rev active_tasks in
  let shown_active_tasks = take max_active_tasks_display active_tasks in
  List.iter (fun task ->
    let status_icon = match task.task_status with
      | Done _ -> "✅"
      | Claimed _ | InProgress _ -> "🔄"
      | Todo -> "📋"
      | Cancelled _ -> "🚫"
    in
    let assignee = match task.task_status with
      | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } -> assignee
      | Cancelled { cancelled_by; _ } -> cancelled_by
      | Todo -> "unclaimed"
    in
    Buffer.add_string buf (Printf.sprintf "  %s %s: %s (%s)\n" status_icon task.id task.title assignee)
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
    Buffer.add_string buf (Printf.sprintf "\n💬 Messages: %d (cumulative)\n" total_messages);
    Buffer.add_string buf "   Use masc_messages for recent details\n"
  end else
    Buffer.add_string buf "\n💬 Messages: 0\n";

  Buffer.contents buf
