(** Tool_coord - Coord management operations

    Handles: status, reset, init, workflow_guide, check

    Note: join, leave, set_room, who require state/registry and remain in mcp_server_eio.ml
*)

type tool_result = bool * string

type context = {
  config: Coord.config;
  agent_name: string;
}

open Tool_args

let take_items limit items =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: xs -> loop (remaining - 1) (x :: acc) xs
  in
  loop limit [] items

type text_cache = {
  mutable key : string option;
  mutable value : string option;
  mutable expires_at : float;
}

let make_text_cache () = { key = None; value = None; expires_at = 0.0 }

let _status_cache = make_text_cache ()

let cache_ttl_seconds env_var ~default =
  match Sys.getenv_opt env_var with
  | Some raw -> (
      match Float.of_string_opt (String.trim raw) with
      | Some value when value >= 0.0 -> value
      | _ -> default)
  | None -> default

let status_cache_ttl_s () = 2.0

let invalidate_status_cache () =
  _status_cache.key <- None;
  _status_cache.value <- None;
  _status_cache.expires_at <- 0.0

let cached_text_by_key cache ~key ~ttl_s compute =
  let now = Time_compat.now () in
  match cache.key, cache.value with
  | Some cached_key, Some value
    when String.equal cached_key key && now < cache.expires_at ->
      value
  | _ ->
      let value = compute () in
      cache.key <- Some key;
      cache.value <- Some value;
      cache.expires_at <- now +. ttl_s;
      value

let effective_cluster_name (config : Coord.config) =
  match String.trim config.backend_config.Backend_types.cluster_name with
  | "" -> Env_config_core.cluster_name ()
  | name -> name

(* Handlers *)

let bool_flag value = if value then "yes" else "no"

let option_or_dash = function
  | Some value when String.trim value <> "" -> value
  | _ -> "-"

let status_worktree_active (ctx : context) =
  let wt_dir = Filename.concat ctx.config.base_path ".worktrees" in
  try
    Sys.file_exists wt_dir && Sys.is_directory wt_dir
    && Array.length (Sys.readdir wt_dir) > 0
  with
  | Sys_error _ -> false
  | exn ->
      Log.Coord.warn "worktree_active check failed: %s" (Printexc.to_string exn);
      false

let safe_resolve_agent_name (ctx : context) ~joined =
  if not joined then
    ctx.agent_name
  else
    try Coord.resolve_agent_name ctx.config ctx.agent_name
    with
    | Sys_error _ | Yojson.Json_error _ -> ctx.agent_name
    | exn ->
        Log.Coord.warn "resolve_agent_name failed for %s: %s" ctx.agent_name
          (Printexc.to_string exn);
        ctx.agent_name

let safe_current_task (ctx : context) ~joined =
  if not joined then
    None
  else
    try Planning_eio.get_current_task ctx.config
    with
    | Sys_error _ | Yojson.Json_error _ -> None
    | exn ->
        Log.Coord.warn "get_current_task failed for %s: %s" ctx.agent_name
          (Printexc.to_string exn);
        None

let safe_get_agents (ctx : context) =
  try Coord.get_agents_raw ctx.config
  with
  | Sys_error _ | Yojson.Json_error _ -> []
  | exn ->
      Log.Coord.warn "get_agents_raw failed: %s" (Printexc.to_string exn);
      []

let safe_is_zombie_agent ~agent_name last_seen =
  try Coord.is_zombie_agent ~agent_name last_seen
  with
  | Sys_error _ | Yojson.Json_error _ -> false
  | exn ->
      Log.Coord.warn "is_zombie_agent failed for %s: %s" agent_name
        (Printexc.to_string exn);
      false

let task_status_badge = function
  | Types.Todo -> ("📋", "todo")
  | Types.Claimed _ -> ("🟡", "claimed")
  | Types.InProgress _ -> ("🟢", "in_progress")
  | Types.AwaitingVerification _ -> ("🔍", "awaiting_verification")
  | Types.Done _ -> ("✅", "done")
  | Types.Cancelled _ -> ("🚫", "cancelled")

let task_assignee = function
  | Types.Claimed { assignee; _ }
  | Types.InProgress { assignee; _ }
  | Types.AwaitingVerification { assignee; _ }
  | Types.Done { assignee; _ } -> assignee
  | Types.Cancelled { cancelled_by; _ } -> cancelled_by
  | Types.Todo -> "unclaimed"

let agent_status_icon ~is_zombie = function
  | _ when is_zombie -> "💀"
  | Types.Busy -> "🔴"
  | Types.Active -> "🟢"
  | Types.Listening -> "🎧"
  | Types.Inactive -> "⚫"

let agent_focus_label ~is_zombie (agent : Types.agent) =
  if is_zombie then "stale"
  else option_or_dash agent.current_task |> function
    | "-" -> Types.agent_status_to_string agent.status
    | task -> task

let status_summary_string (ctx : context) =
  Coord.ensure_initialized ctx.config;
  let state = Coord.read_state ctx.config in
  let current_room = "default" in
  let backlog = Coord.read_backlog ctx.config in
  let max_agents_display = 40 in
  let max_active_tasks_display = 30 in
  let joined =
    try Coord.is_agent_joined ctx.config ~agent_name:ctx.agent_name
    with Sys_error _ | Yojson.Json_error _ -> false
  in
  let actual_name = safe_resolve_agent_name ctx ~joined in
  let matches_you assignee =
    String.equal assignee ctx.agent_name || String.equal assignee actual_name
  in
  let current_task = safe_current_task ctx ~joined in
  let worktree_active = status_worktree_active ctx in
  let cluster_name = effective_cluster_name ctx.config in
  let agents =
    safe_get_agents ctx
    |> List.sort (fun (a : Types.agent) (b : Types.agent) ->
           String.compare a.name b.name)
  in
  let agents_with_state =
    List.map
      (fun (agent : Types.agent) ->
        Coord_query.safe_yield ();
        let is_zombie =
          safe_is_zombie_agent ~agent_name:agent.name agent.last_seen
        in
        (agent, is_zombie))
      agents
  in
  let shown_agents = take_items max_agents_display agents_with_state in
  let agent_count = List.length agents_with_state in
  let zombie_count =
    List.fold_left
      (fun acc (_, is_zombie) -> if is_zombie then acc + 1 else acc)
      0 agents_with_state
  in
  let active_tasks, todo_count, claimed_count, in_progress_count, done_count,
      cancelled_count =
    List.fold_left
      (fun
         (active, todo_cnt, claimed_cnt, in_progress_cnt, done_cnt, cancelled_cnt)
         (task : Types.task) ->
        Coord_query.safe_yield ();
        match task.task_status with
        | Types.Todo ->
            (task :: active, todo_cnt + 1, claimed_cnt, in_progress_cnt,
             done_cnt, cancelled_cnt)
        | Types.Claimed _ ->
            (task :: active, todo_cnt, claimed_cnt + 1, in_progress_cnt,
             done_cnt, cancelled_cnt)
        | Types.InProgress _ ->
            (task :: active, todo_cnt, claimed_cnt, in_progress_cnt + 1,
             done_cnt, cancelled_cnt)
        | Types.Done _ ->
            (active, todo_cnt, claimed_cnt, in_progress_cnt, done_cnt + 1,
             cancelled_cnt)
        | Types.AwaitingVerification _ ->
            (task :: active, todo_cnt, claimed_cnt, in_progress_cnt + 1,
             done_cnt, cancelled_cnt)
        | Types.Cancelled _ ->
            (active, todo_cnt, claimed_cnt, in_progress_cnt, done_cnt,
             cancelled_cnt + 1))
      ([], 0, 0, 0, 0, 0)
      backlog.tasks
  in
  let active_tasks = List.rev active_tasks in
  let shown_active_tasks = take_items max_active_tasks_display active_tasks in
  let your_task =
    active_tasks
    |> List.find_map (fun (task : Types.task) ->
           let assignee = task_assignee task.task_status in
           if matches_you assignee then Some task.id else None)
  in
  let guidance =
    Workflow_guide.current_state_guidance
      ~room_set:true
      ~joined
      ~task_claimed:(Option.is_some your_task)
      ~current_task_set:(Option.is_some current_task)
      ~worktree_active ~session_active:false
  in
  let suggested_next =
    guidance.next_steps
    |> take_items 2
    |> List.map (fun (step : Workflow_guide.step) -> step.tool)
  in
  let attention_items =
    []
    |> fun items ->
    if not joined then
      items @ [ "You are not joined in the project namespace. Call masc_join." ]
    else
      items
    |> fun items ->
    if Option.is_some your_task && Option.is_none current_task then
      items
      @ [ "You own a task but planning current_task is unset. Call masc_plan_set_task." ]
    else
      items
    |> fun items ->
    if zombie_count > 0 then
      items
      @ [ Printf.sprintf "%d stale agent(s) are still visible in the namespace."
            zombie_count ]
    else
      items
    |> fun items ->
    if todo_count > 0 && Option.is_none your_task then
      items
      @ [ Printf.sprintf "%d unclaimed task(s) are available right now."
            todo_count ]
    else
      items
  in
  let buf = Buffer.create 256 in
  Buffer.add_string buf (Printf.sprintf "🏢 Cluster: %s\n" cluster_name);
  if cluster_name <> state.project then
    Buffer.add_string buf (Printf.sprintf "📦 Project: %s\n" state.project);
  Buffer.add_string buf
    (Printf.sprintf "📍 Scope: %s (flattened)\n" current_room);
  Buffer.add_string buf (Printf.sprintf "📁 Path: %s\n" ctx.config.base_path);
  Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";
  Buffer.add_string buf
    (Printf.sprintf
       "⚡ Snapshot: agents=%d zombies=%d | tasks active=%d todo=%d claimed=%d in_progress=%d | messages=%d\n"
       agent_count zombie_count (List.length active_tasks) todo_count claimed_count
       in_progress_count (max 0 state.message_seq));
  Buffer.add_string buf
    (Printf.sprintf
       "🧭 You: agent=%s | joined=%s | owned=%s | current=%s | worktree=%s\n"
       actual_name (bool_flag joined) (option_or_dash your_task)
       (option_or_dash current_task) (bool_flag worktree_active));
  if suggested_next <> [] then
    Buffer.add_string buf
      (Printf.sprintf "💡 Suggested next: %s\n"
         (String.concat " -> " suggested_next));
  if attention_items <> [] then begin
    Buffer.add_string buf "\n⚠️ Attention:\n";
    List.iter
      (fun item ->
        Buffer.add_string buf (Printf.sprintf "  - %s\n" item))
      attention_items
  end;
  Buffer.add_string buf "📌 Players:\n";
  (match shown_agents with
  | [] ->
      Buffer.add_string buf "  (no agents)\n"
  | _ ->
      List.iter
        (fun ((agent : Types.agent), is_zombie) ->
          Coord_query.safe_yield ();
          let icon = agent_status_icon ~is_zombie agent.status in
          let you_marker =
            if String.equal agent.name actual_name then " (you)" else ""
          in
          Buffer.add_string buf
            (Printf.sprintf "  %s %s%s -> %s\n" icon agent.name you_marker
               (agent_focus_label ~is_zombie agent)))
        shown_agents;
      if agent_count > max_agents_display then
        Buffer.add_string buf
          (Printf.sprintf
             "  … and %d more agents (use masc_who for full list)\n"
             (agent_count - max_agents_display)));
  Buffer.add_string buf "\n📋 Quest Board:\n";
  List.iter
    (fun (task : Types.task) ->
      Coord_query.safe_yield ();
      let (status_icon, status_label) = task_status_badge task.task_status in
      let assignee = task_assignee task.task_status in
      Buffer.add_string buf
        (Printf.sprintf "  %s %s P%d [%s] %s (%s)\n" status_icon task.id
           task.priority status_label task.title assignee))
    shown_active_tasks;
  if active_tasks = [] then
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
      (Printf.sprintf "\n💬 Messages: %d (cumulative)\n" total_messages);
    Buffer.add_string buf "   Use masc_messages for recent details\n"
  end else
    Buffer.add_string buf "\n💬 Messages: 0\n";
  Buffer.contents buf

let handle_status ctx _args =
  let cache_key = Printf.sprintf "%s::%s" ctx.config.base_path ctx.agent_name in
  (true, cached_text_by_key _status_cache ~key:cache_key
       ~ttl_s:(status_cache_ttl_s ()) (fun () ->
       status_summary_string ctx))

let handle_reset ctx args =
  let confirm = get_bool args "confirm" false in
  if not confirm then
    (false, "⚠️ This will DELETE the entire .masc/ folder!\nCall with confirm=true to proceed.")
  else begin
    invalidate_status_cache ();
    (true, Coord.reset ctx.config)
  end

(* ── State inspection (shared by workflow_guide and check) ──────── *)

type agent_state = {
  room_set : bool;
  joined : bool;
  task_claimed : bool;
  current_task_set : bool;
  worktree_active : bool;
}

let inspect_state ctx =
  let room_set = Coord.is_initialized ctx.config in
  let joined =
    if room_set then
      (try Coord.is_agent_joined ctx.config ~agent_name:ctx.agent_name
       with Sys_error _ | Yojson.Json_error _ -> false)
    else false
  in
  let task_claimed =
    if joined then
      let actual_name = Coord.resolve_agent_name ctx.config ctx.agent_name in
      Coord.get_tasks_raw ctx.config
      |> List.exists (fun (task : Types.task) ->
             match task.task_status with
             | Types.Claimed { assignee; _ } | Types.InProgress { assignee; _ }
             | Types.AwaitingVerification { assignee; _ } ->
                 assignee = ctx.agent_name || assignee = actual_name
             | Types.Todo | Types.Done _ | Types.Cancelled _ -> false)
    else false
  in
  let current_task_set =
    if joined then Option.is_some (Planning_eio.get_current_task ctx.config)
    else false
  in
  let worktree_active =
    if room_set then
      status_worktree_active ctx
    else false
  in
  { room_set; joined; task_claimed; current_task_set; worktree_active }

let state_to_json st =
  `Assoc [
    ("project_ready", `Bool st.room_set);
    ("namespace_ready", `Bool st.room_set);
    ("room_set", `Bool st.room_set);
    ("joined", `Bool st.joined);
    ("task_claimed", `Bool st.task_claimed);
    ("current_task_set", `Bool st.current_task_set);
    ("worktree_active", `Bool st.worktree_active);
    ("session_active", `Bool false);
  ]

(* ── Workflow guide ─────────────────────────────────────────────── *)

let handle_workflow_guide ctx _args =
  let st = inspect_state ctx in
  let guidance =
    Workflow_guide.current_state_guidance
      ~room_set:st.room_set ~joined:st.joined
      ~task_claimed:st.task_claimed ~current_task_set:st.current_task_set
      ~worktree_active:st.worktree_active ~session_active:false
  in
  let result =
    `Assoc [
      ("current_state", state_to_json st);
      ("guidance", Workflow_guide.guidance_to_json guidance);
    ]
  in
  (true, Yojson.Safe.to_string result)

(* ── State check (assertion-based verification) ────────────────── *)

(** Issue #8636: SSOT for [masc_check] assertion vocabulary. Schema
    enum, handler match, and default fallback used to disagree on
    which strings were valid. The Variant + helpers below give a
    single witness that compile-fails when a constructor is added but
    [assertion_kind_to_string] / [assertion_kind_of_string_lenient]
    aren't updated. Same shape as #8546 / #8601 / #8592. *)
type assertion_kind =
  | Room_set        (* legacy alias: namespace_ready *)
  | Joined
  | Task_claimed
  | Current_task_set
  | Worktree_active

let assertion_kind_to_string = function
  | Room_set -> "room_set"
  | Joined -> "joined"
  | Task_claimed -> "task_claimed"
  | Current_task_set -> "current_task_set"
  | Worktree_active -> "worktree_active"

let all_assertion_kinds =
  [ Room_set; Joined; Task_claimed; Current_task_set; Worktree_active ]

let valid_assertion_strings =
  List.map assertion_kind_to_string all_assertion_kinds

let assertion_kind_of_string_lenient = function
  | "room_set" | "namespace_ready" | "project_ready" -> Some Room_set
  | "joined" -> Some Joined
  | "task_claimed" -> Some Task_claimed
  | "current_task_set" -> Some Current_task_set
  | "worktree_active" -> Some Worktree_active
  | _ -> None

let assertion_fix_hint = function
  | Room_set ->
      "Call masc_start with your project root path."
  | Joined ->
      "Call masc_join to register your agent in the project namespace"
  | Task_claimed ->
      "Claim a task with masc_transition(action=claim) or masc_claim_next"
  | Current_task_set ->
      "Call masc_plan_set_task after claim paths that did not auto-bind \
       current_task (for example masc_transition(action=claim))"
  | Worktree_active ->
      "Call masc_worktree_create to work in an isolated branch"

let assertion_passes st = function
  | Room_set -> st.room_set
  | Joined -> st.joined
  | Task_claimed -> st.task_claimed
  | Current_task_set -> st.current_task_set
  | Worktree_active -> st.worktree_active

let check_assertion st assertion =
  match assertion_kind_of_string_lenient assertion with
  | Some kind ->
      let passed = assertion_passes st kind in
      let fix_hint = assertion_fix_hint kind in
      `Assoc [
        ("assertion", `String assertion);
        ("passed", `Bool passed);
        ("fix_hint", if passed then `Null else `String fix_hint);
      ]
  | None ->
      `Assoc [
        ("assertion", `String assertion);
        ("passed", `Bool false);
        ("fix_hint",
         `String
           (Printf.sprintf "Unknown assertion: %s (expected one of: %s)"
              assertion (String.concat ", " valid_assertion_strings)));
      ]

let handle_check ctx args =
  let st = inspect_state ctx in
  let default_assertions = [ "project_ready"; "joined"; "task_claimed"; "current_task_set" ] in
  let assertions =
    match Yojson.Safe.Util.member "assertions" args with
    | `List items ->
        let parsed = List.filter_map (function `String s -> Some s | _ -> None) items in
        if parsed = [] then default_assertions else parsed
    | _ -> default_assertions
  in
  let results = List.map (check_assertion st) assertions in
  let all_passed = List.for_all (fun r ->
    match Yojson.Safe.Util.member "passed" r with
    | `Bool b -> b | _ -> false) results
  in
  let fix_hint =
    if all_passed then `Null
    else
      let first_fail = List.find_opt (fun r ->
        match Yojson.Safe.Util.member "passed" r with
        | `Bool false -> true | _ -> false) results
      in
      match first_fail with
      | Some r -> Yojson.Safe.Util.member "fix_hint" r
      | None -> `Null
  in
  let result =
    `Assoc [
      ("assertions", `List results);
      ("all_passed", `Bool all_passed);
      ("fix_hint", fix_hint);
    ]
  in
  (true, Yojson.Safe.to_string result)

(* Dispatch function *)
let handle_heartbeat ctx _args =
  let result = Coord.heartbeat ctx.config ~agent_name:ctx.agent_name in
  (* Coord.heartbeat returns "⚠ ..." on failure (agent not found, invalid file) *)
  let success = not (String.length result >= 3
    && Char.code result.[0] = 0xe2
    && Char.code result.[1] = 0x9a
    && Char.code result.[2] = 0xa0) in
  (success, result)

let dispatch ctx ~name ~args : tool_result option =
  match name with
  | "masc_status" -> Some (handle_status ctx args)
  | "masc_heartbeat" -> Some (handle_heartbeat ctx args)
  | "masc_reset" -> Some (handle_reset ctx args)
  | "masc_workflow_guide" -> Some (handle_workflow_guide ctx args)
  | "masc_check" -> Some (handle_check ctx args)
  | _ -> None

let schemas = Tool_schemas_coord.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only = [ "masc_status" ]
let _tool_spec_system_internal = [ "masc_reset" ]

let _tool_spec_requires_join = [ "masc_heartbeat" ]

let tool_required_permission = function
  | "masc_status" | "masc_workflow_guide" | "masc_check" ->
      Some Types.CanReadState
  | "masc_heartbeat" ->
      Some Types.CanBroadcast
  | "masc_reset" ->
      Some Types.CanReset
  | _ -> None

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      let is_system = List.mem s.name _tool_spec_system_internal in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_room
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~requires_join:(List.mem s.name _tool_spec_requires_join)
           ~is_read_only:(List.mem s.name _tool_spec_read_only)
           ~is_idempotent:(List.mem s.name _tool_spec_read_only)
           ~visibility:(if is_system then Tool_catalog.Hidden else Tool_catalog.Default)
           ~allow_direct_call_when_hidden:is_system
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
