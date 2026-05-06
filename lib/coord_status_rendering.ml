module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Coord_status_rendering - Logic for masc_status rendering *)

open Masc_domain
open Coord_types

let bool_flag value = if value then "yes" else "no"

let option_or_dash = function
  | Some value when not (String.equal (String.trim value) "") -> value
  | _ -> "-"

let take_items limit items =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: xs -> loop (remaining - 1) (x :: acc) xs
  in
  loop limit [] items

let task_status_badge = function
  | Masc_domain.Todo -> ("📋", "todo")
  | Masc_domain.Claimed _ -> ("🟡", "claimed")
  | Masc_domain.InProgress _ -> ("🟢", "in_progress")
  | Masc_domain.AwaitingVerification _ -> ("🔍", "awaiting_verification")
  | Masc_domain.Done _ -> ("✅", "done")
  | Masc_domain.Cancelled _ -> ("🚫", "cancelled")

let task_assignee = function
  | Masc_domain.Claimed { assignee; _ }
  | Masc_domain.InProgress { assignee; _ }
  | Masc_domain.AwaitingVerification { assignee; _ }
  | Masc_domain.Done { assignee; _ } -> assignee
  | Masc_domain.Cancelled { cancelled_by; _ } -> cancelled_by
  | Masc_domain.Todo -> "unclaimed"

let active_task_assignee = function
  | Masc_domain.Claimed { assignee; _ }
  | Masc_domain.InProgress { assignee; _ }
  | Masc_domain.AwaitingVerification { assignee; _ } ->
      Some assignee
  | Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _ -> None

let assigned_task_ids ~matches_you tasks =
  List.filter_map
    (fun (task : Masc_domain.task) ->
      match active_task_assignee task.task_status with
      | Some assignee when matches_you assignee -> Some task.id
      | Some _ | None -> None)
    tasks

let agent_status_icon ~is_zombie = function
  | _ when is_zombie -> "💀"
  | Masc_domain.Busy -> "🔴"
  | Masc_domain.Active -> "🟢"
  | Masc_domain.Listening -> "🎧"
  | Masc_domain.Inactive -> "⚫"

let agent_focus_label ~is_zombie ~active_assigned_task_ids
    (agent : Masc_domain.agent) =
  if is_zombie then "stale"
  else
    match active_assigned_task_ids with
    | task :: [] -> task
    | task :: rest -> Printf.sprintf "%s (+%d)" task (List.length rest)
    | [] -> (
        match agent.current_task with
        | Some task when not (String.equal (String.trim task) "") ->
            Printf.sprintf "%s (stale:%s)"
              (Masc_domain.agent_status_to_string agent.status)
              task
        | _ -> Masc_domain.agent_status_to_string agent.status)

let task_id_list_label = function
  | [] -> "[]"
  | ids -> "[" ^ String.concat "," ids ^ "]"

let first_line text =
  match String.index_opt text '\n' with
  | Some i -> String.sub text 0 i
  | None -> text

let deliverable_claims_completion ~task_id deliverable =
  let normalized =
    deliverable
    |> String.trim
    |> String.lowercase_ascii
    |> first_line
  in
  not (String.equal normalized "")
  && (String.starts_with ~prefix:(String.lowercase_ascii task_id ^ " completed")
        normalized
      || String.starts_with ~prefix:"completed" normalized)

let status_summary_string
    ~(ctx : context)
    ~(joined : bool)
    ~(actual_name : string)
    ~(credential_state : credential_state)
    ~credential_blocked:_
    ~(current_task : string option)
    ~(worktree_active : bool)
    ~(effective_cluster_name : string)
    ~(agents_with_state : (Masc_domain.agent * bool) list)
    ~(active_tasks : Masc_domain.task list)
    ~(todo_count : int)
    ~(claimed_count : int)
    ~(in_progress_count : int)
    ~(done_count : int)
    ~(cancelled_count : int)
    ~(todo_conflict_task_ids : string list)
    ~(binding : current_binding)
    ~(planning_state : planning_context_state)
    ~(suggested_next : string list)
    ~(attention_items : string list)
    ~(state : Masc_domain.room_state)
    ~(backlog : Masc_domain.backlog) =
  
  let max_agents_display = 40 in
  let max_active_tasks_display = 30 in
  let shown_agents = take_items max_agents_display agents_with_state in
  let agent_count = List.length agents_with_state in
  let zombie_count =
    List.fold_left
      (fun acc (_, is_zombie) -> if is_zombie then acc + 1 else acc)
      0 agents_with_state
  in
  let shown_active_tasks = take_items max_active_tasks_display active_tasks in
  let current_room = "default" in

  let buf = Buffer.create 256 in
  Printf.bprintf buf "🏢 Cluster: %s\n" effective_cluster_name;
  if not (String.equal effective_cluster_name state.project) then
    Printf.bprintf buf "Project: %s\n" state.project;
  Buffer.add_string buf
    (Printf.sprintf "📍 Scope: %s (flattened)\n" current_room);
  Printf.bprintf buf "📁 Path: %s\n" ctx.config.base_path;
  Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";
  Buffer.add_string buf
    (Printf.sprintf
       "Snapshot: agents=%d zombies=%d | tasks active=%d todo=%d claimed=%d in_progress=%d | messages=%d\n"
       agent_count zombie_count (List.length active_tasks) todo_count claimed_count
       in_progress_count (max 0 state.message_seq));
  Buffer.add_string buf
    (Printf.sprintf
       "🧭 You: agent=%s | joined=%s | owned=%s | current=%s | worktree=%s\n"
       actual_name (bool_flag joined) (option_or_dash binding.primary_owned)
       (option_or_dash current_task) (bool_flag worktree_active));
  Buffer.add_string buf
    (Printf.sprintf
       "🔎 Task binding: assigned_set=%s | primary_owned=%s | planning_current=%s | current_is_assigned=%s | effective_current=%s | drift_reason=%s | claim_first_suppressed=%s\n"
       (task_id_list_label binding.assigned_task_ids)
       (option_or_dash binding.primary_owned)
       (option_or_dash binding.planning_current)
       (bool_flag binding.current_is_assigned)
       (option_or_dash binding.effective_current)
       (option_or_dash binding.drift_reason)
       (bool_flag binding.claim_first_suppressed));
  (match planning_state.planning_missing_task with
  | Some task_id ->
      Buffer.add_string buf
        (Printf.sprintf "Planning: missing=yes | task=%s\n" task_id)
  | None -> ());
  (match planning_state.deliverable_conflict_task with
  | Some task_id ->
      Buffer.add_string buf
        (Printf.sprintf "Planning: deliverable_conflict=yes | task=%s\n"
           task_id)
  | None -> ());
  if credential_state.credential_required then
    Buffer.add_string buf
      (Printf.sprintf "Credential: required=yes | available=%s | candidates=%s\n"
         (bool_flag credential_state.credential_available)
         (String.concat "," credential_state.credential_candidates));
  (match suggested_next with [] -> () | _ ->
    Buffer.add_string buf
      (Printf.sprintf "Suggested next: %s\n"
         (String.concat " -> " suggested_next)));
  (match attention_items with
  | [] -> ()
  | _ ->
    Buffer.add_string buf "\nAttention:\n";
    List.iter
      (fun item ->
        Printf.bprintf buf "  - %s\n" item)
      attention_items);
  Buffer.add_string buf "Players:\n";
  (match shown_agents with
  | [] ->
      Buffer.add_string buf "  (no agents)\n"
  | _ ->
      List.iter
        (fun ((agent : Masc_domain.agent), is_zombie) ->
          Coord_query.safe_yield ();
          let icon = agent_status_icon ~is_zombie agent.status in
          let matches_agent assignee =
            String.equal assignee agent.name
            || (String.equal agent.name actual_name
               && String.equal assignee ctx.agent_name)
          in
          let active_assigned_task_ids =
            assigned_task_ids ~matches_you:matches_agent active_tasks
          in
          let you_marker =
            if String.equal agent.name actual_name then " (you)" else ""
          in
          Buffer.add_string buf
            (Printf.sprintf "  %s %s%s -> %s\n" icon agent.name you_marker
               (agent_focus_label ~is_zombie ~active_assigned_task_ids agent)))
        shown_agents;
      if agent_count > max_agents_display then
        Buffer.add_string buf
          (Printf.sprintf
             "  … and %d more agents (use masc_who for full list)\n"
             (agent_count - max_agents_display)));
  Buffer.add_string buf "\nQuest Board:\n";
  List.iter
    (fun (task : Masc_domain.task) ->
      Coord_query.safe_yield ();
      let (status_icon, status_label) =
        if List.exists (String.equal task.id) todo_conflict_task_ids then
          ("warning", "todo_conflict")
        else
          task_status_badge task.task_status
      in
      let assignee = task_assignee task.task_status in
      Buffer.add_string buf
        (Printf.sprintf "  %s %s P%d [%s] %s (%s)\n" status_icon task.id
           task.priority status_label task.title assignee))
    shown_active_tasks;
  if (match active_tasks with [] -> true | _ -> false) then
    Buffer.add_string buf "  (no active tasks)\n";
  if List.length active_tasks > max_active_tasks_display then
    Buffer.add_string buf
      (Printf.sprintf
         "  … and %d more active tasks (use masc_tasks for full list)\n"
         (List.length active_tasks - max_active_tasks_display));
  Buffer.add_string buf
    (Printf.sprintf "  Summary: active=%d, done=%d, cancelled=%d, total=%d\n"
       (List.length active_tasks) done_count cancelled_count
       (List.length backlog.tasks));
  let total_messages = max 0 state.message_seq in
  if total_messages > 0 then begin
    Buffer.add_string buf
      (Printf.sprintf "\nMessages: %d (cumulative)\n" total_messages);
    Buffer.add_string buf "   Use masc_messages for recent details\n"
  end else
    Buffer.add_string buf "\nMessages: 0\n";
  Buffer.contents buf
