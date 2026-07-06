(** Workspace_query -- Task/agent/message query and listing functions.

    Read-only operations on workspace state: raw list retrieval, orphan auditing,
    message collection, agent-session-bound checks, and formatted listing. *)

open Masc_domain
include Workspace_utils
include Workspace_state
open Workspace_backlog
open Workspace_identity

let update_priority config ~task_id ~priority =
  ensure_initialized config;

  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    match read_backlog_r config with
    | Error msg -> Printf.sprintf "Error: workspace backlog read failed: %s" msg
    | Ok backlog ->
      (try
      let task_opt = List.find_opt (fun (t : task) -> t.id = task_id) backlog.tasks in

      match task_opt with
      | None ->
          Printf.sprintf "Task %s not found" task_id
      | Some task ->
          let old_priority = task.priority in
          let new_tasks = List.map (fun (t : task) ->
            if t.id = task_id then { t with priority }
            else t
          ) backlog.tasks in

          let new_backlog = {
            tasks = new_tasks;
            last_updated = now_iso ();
            version = backlog.version + 1;
          } in
          write_backlog config new_backlog;

          log_event config (`Assoc [
            ("type", `String "priority_change");
            ("task", `String task_id);
            ("old", `Int old_priority);
            ("new", `Int priority);
            ("ts", `String (now_iso ()));
          ]);
          (Atomic.get Workspace_hooks.on_task_mutation_fn) ();

          Printf.sprintf "Task %s priority: P%d → P%d" task_id old_priority priority
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | e ->
         Printf.sprintf "Error: %s" (Printexc.to_string e))
  )

(** Get raw task list (for orchestrator).
    Requires initialization. *)
let get_tasks_raw_result config =
  ensure_initialized config;
  read_backlog_r config |> Result.map (fun backlog -> backlog.tasks)

let get_tasks_raw config =
  match get_tasks_raw_result config with
  | Ok tasks -> tasks
  | Error msg ->
    Log.Workspace.warn "get_tasks_raw: backlog read failed: %s" msg;
    []

(** Like [get_tasks_raw] but returns [[]] when MASC is not
    initialized — safe for dashboard and display contexts.
    Replaces the former [get_tasks_raw_in_workspace]. *)
let get_tasks_safe_result config =
  if not (root_is_initialized config) then Ok []
  else read_backlog_r config |> Result.map (fun backlog -> backlog.tasks)

let get_tasks_safe config =
  match get_tasks_safe_result config with
  | Ok tasks -> tasks
  | Error msg ->
    Log.Workspace.warn "get_tasks_safe: backlog read failed: %s" msg;
    []

let safe_yield () =
  Safe_ops.protect ~default:() (fun () -> Eio.Fiber.yield ())

let take_first = List.take

type 'a read_report =
  { values : 'a list
  ; read_errors : string list
  }

let read_report_to_result ~context report =
  match report.read_errors with
  | [] -> Ok report.values
  | errors -> Error (Printf.sprintf "%s: %s" context (String.concat "; " errors))

let list_leaf_json_names_result config dir =
  match list_dir_result config dir with
  | Error err -> Error err
  | Ok names ->
    Ok
      (names
       |> List.filter (fun name ->
              name <> ""
              && not (String.contains name '/')
              && Filename.check_suffix name ".json")
       |> List.sort String.compare)

let load_agents_from_dir_report config dir ~include_inactive =
  match list_leaf_json_names_result config dir with
  | Error err -> { values = []; read_errors = [ err ] }
  | Ok names ->
    let values, read_errors =
      List.fold_left
        (fun (agents, errors) name ->
           safe_yield ();
           let path = Filename.concat dir name in
           match read_agent_with_repair config path with
           | Ok agent when include_inactive || agent.status <> Masc_domain.Inactive ->
             (agent :: agents, errors)
           | Ok _ -> (agents, errors)
           | Error err ->
             ( agents
             , Printf.sprintf "failed to read agent file %s: %s" path err
               :: errors ))
        ([], [])
        names
    in
    { values = List.rev values; read_errors = List.rev read_errors }

let load_agents_from_dir_result config dir ~include_inactive =
  load_agents_from_dir_report config dir ~include_inactive
  |> read_report_to_result ~context:"load_agents_from_dir"

let load_agents_from_dir config dir ~include_inactive =
  let report = load_agents_from_dir_report config dir ~include_inactive in
  (match report.read_errors with
   | [] -> ()
   | errors ->
     Log.Workspace.warn
       "load_agents_from_dir: partial read failure for %s: %s"
       dir
       (String.concat "; " errors));
  report.values

let agent_type_of_state_agent_name name =
  if Workspace_resilience.Zombie.is_keeper_name name
  then "keeper"
  else (
    match Nickname.extract_agent_type name with
    | Some agent_type -> agent_type
    | None -> name)

let state_backed_agent state (name : string) : Masc_domain.agent =
  let agent_type = agent_type_of_state_agent_name name in
  let timestamp = state.started_at in
  let meta : Masc_domain.agent_meta =
    { session_id = "workspace-state:" ^ name
    ; agent_type
    ; pid = None
    ; hostname = None
    ; tty = None
    ; parent_task = None
    ; keeper_name = None
    ; keeper_id = None
    }
  in
  { id = None
  ; name
  ; agent_type
  ; status = Masc_domain.Active
  ; capabilities = []
  ; current_task = None
  ; session_bound_at = timestamp
  ; last_seen = timestamp
  ; meta = Some meta
  }

let state_backed_active_agents_result config =
  let snapshot = read_state_snapshot config in
  match snapshot.status with
  | State_default_from_read_error ->
    Error (String.concat "; " snapshot.read_errors)
  | State_authoritative | State_recovered_unpersisted ->
    Ok
      (snapshot.state.active_agents
       |> normalized_string_list
       |> List.map (state_backed_agent snapshot.state))

let state_backed_active_agents config =
  match state_backed_active_agents_result config with
  | Ok agents -> agents
  | Error msg ->
    Log.Workspace.warn "state_backed_active_agents: state read failed: %s" msg;
    []

let runtime_agents config =
  try (Atomic.get Workspace_hooks.runtime_agents_fn) config with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Workspace.warn
      "runtime_agents_fn failed while reading active agents: %s"
      (Printexc.to_string exn);
    []

let agent_status_is_active = function
  | Masc_domain.Active | Busy | Listening -> true
  | Inactive -> false

let active_runtime_agents config =
  runtime_agents config
  |> List.filter (fun (agent : Masc_domain.agent) ->
         agent_status_is_active agent.status)

let merge_agents primary secondary =
  let seen = Hashtbl.create (List.length primary + List.length secondary) in
  let add_if_new acc (agent : Masc_domain.agent) =
    if Hashtbl.mem seen agent.name then acc
    else (
      Hashtbl.add seen agent.name ();
      agent :: acc)
  in
  List.rev (List.fold_left add_if_new (List.fold_left add_if_new [] primary) secondary)

(** Get raw agent list (for orchestrator).
    Includes inactive agents. Requires initialization. *)
let get_agents_raw config =
  ensure_initialized config;
  let agents_path = agents_dir config in
  load_agents_from_dir config agents_path ~include_inactive:true

(** Return active agents only.  Returns [[]] when MASC is not
    initialized — safe for dashboard and display contexts.
    Replaces the former [get_agents_raw_in_workspace]. *)
let get_active_agents config =
  if not (root_is_initialized config) then []
  else
    let agents_path = agents_dir config in
    let workspace_agents = load_agents_from_dir config agents_path ~include_inactive:false in
    let state_agents = state_backed_active_agents config in
    merge_agents (merge_agents workspace_agents state_agents) (active_runtime_agents config)

(** Like [get_agents_raw] but returns [[]] when not initialized
    instead of raising.  Includes inactive agents.
    Useful for keeper backlog-triage enrollment. *)
let get_all_agents config =
  if not (root_is_initialized config) then []
  else
    let agents_path = agents_dir config in
    load_agents_from_dir config agents_path ~include_inactive:true

(** Audit tasks: find claimed/in_progress tasks whose assignees are not active agents.
    Matches assignees by exact name or agent-type prefix (e.g. "<prefix>" matches "<prefix>-xxx").
    Agents with Inactive status are excluded from the active set.

    Staleness uses a keeper-aware threshold: actual keeper agents get the
    longer keeper grace ([MASC_KEEPER_ZOMBIE_THRESHOLD_SEC], default 3600s) and
    ordinary agents the default ([MASC_ZOMBIE_THRESHOLD_SEC], default 300s).
    Keeper status is decided by the shared {!Workspace_resilience.Zombie}
    file-backed predicate ([agent_type = "keeper"] or keeper-owned [meta])
    rather than by the keeper-shaped name pattern, so a keeper-shaped
    non-keeper worker does not inherit the longer grace. A live keeper that has
    gone quiet between heartbeats (but within its grace) is therefore not
   classified as inactive, so its own claimed/in-progress task is not
   mis-reported as an orphan at the source. *)
let audit_orphan_tasks_result config : ((Masc_domain.task * string) list, string) result =
  if not (is_initialized config) then Ok []
  else
    (* Read agent files from the same path that cleanup_zombies and session binding use *)
    let agents_path = agents_dir config in
    match load_agents_from_dir_result config agents_path ~include_inactive:false with
    | Error err -> Error (Printf.sprintf "active agent read failed: %s" err)
    | Ok agents ->
      let active_names =
        agents
        |> List.filter (fun (agent : Masc_domain.agent) ->
               not
                 (Workspace_resilience.Zombie.is_zombie_for_agent
                    ~agent_type:agent.agent_type
                    ?agent_meta:agent.meta
                    ~agent_name:agent.name
                    agent.last_seen))
        |> List.map (fun (agent : Masc_domain.agent) -> agent.name)
      in
      let is_active_agent assignee =
        List.mem assignee active_names
        ||
        let prefix = assignee ^ "-" in
        List.exists
          (fun name ->
             String.length name > String.length prefix
             && String.starts_with name ~prefix)
          active_names
      in
      (match read_backlog_r config with
       | Error err -> Error (Printf.sprintf "backlog read failed: %s" err)
       | Ok backlog ->
         Ok
           (List.filter_map
              (fun (task : Masc_domain.task) ->
                 match task.task_status with
                 | Masc_domain.Claimed { assignee; _ }
                 | Masc_domain.InProgress { assignee; _ }
                 | Masc_domain.AwaitingVerification { assignee; _ } ->
                   if is_active_agent assignee then None else Some (task, assignee)
                 | Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _ ->
                   None)
              backlog.tasks))

let audit_orphan_tasks config : (Masc_domain.task * string) list =
  match audit_orphan_tasks_result config with
  | Ok tasks -> tasks
  | Error msg ->
    Log.TaskState.warn "audit_orphan_tasks: %s" msg;
    []

(* RFC-0294 PR-4: the single typed source of truth for "is this status
   orphan-eligible, and under which gauge class". EXHAUSTIVE over [task_status]
   ([@warning "-4"] absent on purpose): adding a new constructor forces a
   classification decision here at compile time, so a future orphan-eligible
   status can never be silently dropped from the gauge — the exact failure the
   old [String.equal (task_status_to_string …)] round-trip allowed. The label
   strings are the [Masc_domain.task_status_to_string] values for the active
   statuses, kept here so the metric vocabulary has one owner. Must stay aligned
   with the orphan-eligibility match in [audit_orphan_tasks] above (both select
   Claimed / InProgress / AwaitingVerification); the surfacer test pins both the
   Some-labels and the None-set so a divergence fails the test. *)
let orphan_status_class_of_status : Masc_domain.task_status -> string option = function
  | Masc_domain.Claimed _ -> Some "claimed"
  | Masc_domain.InProgress _ -> Some "in_progress"
  | Masc_domain.AwaitingVerification _ -> Some "awaiting_verification"
  | Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _ -> None

(* The fixed class set the gauge reports (0 when a class is empty, so a cleared
   class resets rather than going stale). Exactly the Some-range of
   [orphan_status_class_of_status]; the drift-guard test pins that equality. *)
let orphan_status_classes = [ "claimed"; "in_progress"; "awaiting_verification" ]

(* Pure: count orphan-audit results per status class over the fixed class set.
   Membership is decided by the typed [orphan_status_class_of_status], not a
   string round-trip, so the grouping shares one exhaustive classifier with the
   gauge vocabulary. Separated from the metric I/O (the gauge emitter lives in
   the orchestrator pulse, which owns the Otel dependency) so the grouping is
   unit-testable without workspace or metric-store side effects. *)
let orphan_counts_by_status_class (orphans : (Masc_domain.task * string) list)
  : (string * int) list =
  List.map
    (fun status_class ->
       let count =
         List.length
           (List.filter
              (fun ((task : Masc_domain.task), _assignee) ->
                 match orphan_status_class_of_status task.task_status with
                 | Some c -> String.equal c status_class
                 | None -> false)
              orphans)
       in
       status_class, count)
    orphan_status_classes

let is_agent_active_at_path config path =
  match read_json_opt config path with
  | None -> false
  | Some json ->
      (match agent_of_yojson json with
       | Ok agent -> agent.status <> Inactive
       | Error _ -> false)

(** Check if an agent has session-bound *)
let is_agent_session_bound config ~agent_name =
  if not (root_is_initialized config) then false
  else
    let actual_name = resolve_agent_name config agent_name in
    let filename = safe_filename actual_name ^ ".json" in
    let agents_path = agents_dir config in
    let agent_path = Filename.concat agents_path filename in
    is_agent_active_at_path config agent_path

(** Check if filename is valid (no special characters) *)
let is_valid_filename name =
  String.for_all (fun c ->
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c = '_' || c = '-' || c = '.'
  ) name

(** Extract seq number from filename like "000001885_unknown_broadcast.json" or "1664_<agent>_broadcast.json" *)
let extract_seq_from_filename name =
  match String.index_opt name '_' with
  | None -> 0
  | Some idx -> Safe_ops.int_of_string_with_default ~default:0 (String.sub name 0 idx)

let select_recent_message_names ~since_seq ~limit names =
  let insert_candidate acc name =
    let seq = extract_seq_from_filename name in
    if limit <= 0 || seq <= since_seq then
      acc
    else
      let rec insert prefix = function
        | [] -> List.rev_append prefix [ (seq, name) ]
        | ((existing_seq, _) as existing) :: rest ->
            if seq >= existing_seq then
              List.rev_append prefix ((seq, name) :: existing :: rest)
            else
              insert (existing :: prefix) rest
      in
      insert [] acc |> take_first limit
  in
  names
  |> List.fold_left
       (fun acc name ->
         safe_yield ();
         insert_candidate acc name)
       []
  |> List.map snd

let select_all_message_names ~since_seq names =
  names
  |> List.filter_map (fun name ->
       let seq = extract_seq_from_filename name in
       if seq <= since_seq then None else Some (seq, name))
  |> List.sort (fun (seq_a, name_a) (seq_b, name_b) ->
       let cmp = compare seq_a seq_b in
       if cmp <> 0 then cmp else String.compare name_a name_b)
  |> List.map snd

(** Read most-recent messages without parsing the entire history directory. *)
let collect_recent_messages config ~msgs_path ~since_seq ~limit ~warn_label =
  if not (Sys.file_exists msgs_path) then []
  else
    let names =
      Sys.readdir msgs_path
      |> Array.to_list
      |> List.filter is_valid_filename
      |> select_recent_message_names ~since_seq ~limit
    in
    let rec loop remaining acc = function
      | _ when remaining <= 0 -> List.rev acc
      | [] -> List.rev acc
      | name :: rest ->
          safe_yield ();
          if extract_seq_from_filename name <= since_seq then List.rev acc
          else
            let path = Filename.concat msgs_path name in
            match read_json config path with
            | json ->
                (match message_of_yojson json with
                 | Ok msg when msg.seq > since_seq -> loop (remaining - 1) (msg :: acc) rest
                 | Ok _ | Error _ -> loop remaining acc rest)
            | exception (Eio.Cancel.Cancelled _ as e) -> raise e
            | exception e ->
                Log.legacy_traceln ~level:Log.Warn ~module_name:"Workspace"
                  (Printf.sprintf "[WARN] Failed to read %s %s: %s" warn_label
                     name (Printexc.to_string e));
                loop remaining acc rest
    in
    loop limit [] names

(** Get raw message list (for dashboard).
    Returns [[]] when MASC is not initialized. *)
let get_messages_raw config ~since_seq ~limit =
  if not (root_is_initialized config) then []
  else
    let msgs_path = messages_dir config in
    collect_recent_messages config ~msgs_path ~since_seq ~limit ~warn_label:"message"

let get_all_messages_raw config ~since_seq =
  if not (root_is_initialized config) then []
  else
    let msgs_path = messages_dir config in
    if not (Sys.file_exists msgs_path) then []
    else
      let names =
        Sys.readdir msgs_path
        |> Array.to_list
        |> List.filter is_valid_filename
        |> select_all_message_names ~since_seq
      in
      let rec loop acc = function
        | [] -> List.rev acc
        | name :: rest ->
            safe_yield ();
            let path = Filename.concat msgs_path name in
            match read_json config path with
            | json ->
                (match message_of_yojson json with
                 | Ok msg when msg.seq > since_seq -> loop (msg :: acc) rest
                 | Ok _ | Error _ -> loop acc rest)
            | exception (Eio.Cancel.Cancelled _ as e) -> raise e
            | exception e ->
                Log.legacy_traceln ~level:Log.Warn ~module_name:"Workspace"
                  (Printf.sprintf
                     "[WARN] Failed to read workspace message %s: %s"
                     name (Printexc.to_string e));
                loop acc rest
      in
      loop [] names

(** List tasks *)
let list_tasks_result
      ?(include_done = false)
      ?(include_cancelled = false)
      ?status
      config
  =
  ensure_initialized config;

  match read_backlog_r config with
  | Error msg -> Error msg
  | Ok backlog ->
  let tasks =
    match status with
    | Some status_filter ->
        List.filter (fun (task : task) ->
          String.equal status_filter (string_of_task_status task.task_status)
        ) backlog.tasks
    | None ->
        List.filter (fun (task : task) ->
          let status = task.task_status in
          let is_done = Masc_domain.task_status_is_done status in
          let is_cancelled = match status with
            | Masc_domain.Cancelled _ -> true
            | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
            | Masc_domain.AwaitingVerification _ | Masc_domain.Done _ -> false
          in
          (include_done || not is_done) &&
          (include_cancelled || not is_cancelled)
        ) backlog.tasks
  in
  if tasks = [] then
    if backlog.tasks = [] then
      "No tasks. ACTION: STOP calling keeper_tasks_list — the backlog is empty. Move on to other work or end your turn."
    else
      "No active tasks (all done/cancelled). ACTION: STOP calling keeper_tasks_list — do not re-check. Move on to other work or end your turn."
  else begin
    let buf = Buffer.create 256 in
    Buffer.add_string buf "Quest Board\n";
    Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";

    let sorted = List.sort (fun a b -> compare a.priority b.priority) tasks in
    List.iter (fun task ->
      let status_icon = Masc_domain.task_status_icon task.task_status in
      let assignee = Masc_domain.task_display_assignee task.task_status in
      let status_str = Masc_domain.string_of_task_status task.task_status in
      Printf.bprintf buf "%s [%d] %s: %s\n" status_icon task.priority task.id task.title;
      Printf.bprintf buf "   └─ %s | %s\n" status_str assignee
    ) sorted;

    Buffer.contents buf
  end

let list_tasks ?include_done ?include_cancelled ?status config =
  match list_tasks_result ?include_done ?include_cancelled ?status config with
  | Ok result -> result
  | Error msg ->
    Log.Workspace.warn "list_tasks: backlog read failed: %s" msg;
    Printf.sprintf "Error: workspace backlog read failed: %s" msg

(** Get recent messages *)
let get_messages config ~since_seq ~limit =
  ensure_initialized config;

  let buf = Buffer.create 256 in
  Buffer.add_string buf "Recent Messages\n";
  Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
  let messages = get_messages_raw config ~since_seq ~limit in
  List.iter
    (fun msg ->
      let time_part =
        String.sub msg.timestamp 0 (min 16 (String.length msg.timestamp))
      in
      let time_str = String.map (function 'T' -> ' ' | c -> c) time_part in
      Buffer.add_string buf
        (Printf.sprintf "[%s] %s: %s\n" time_str msg.from_agent msg.content))
    messages;

  if Buffer.length buf = 73 then (* Only header *)
    Buffer.add_string buf "(no new messages)\n";

  Buffer.contents buf
