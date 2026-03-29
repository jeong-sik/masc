(** Tool_room - Room management operations

    Handles: status, reset, init, room_strategy, workflow_guide, check

    Note: join, leave, set_room, who require state/registry and remain in mcp_server_eio.ml
*)

open Yojson.Safe.Util

type result = bool * string

type context = {
  config: Room.config;
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

let status_cache_ttl_s () =
  cache_ttl_seconds "MASC_STATUS_CACHE_TTL_S" ~default:2.0

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

let normalize_search_strategy value =
  match String.trim value with
  | "" -> Ok None
  | "legacy" | "best_first_v1" as strategy -> Ok (Some strategy)
  | other -> Error ("❌ search_strategy_default must be legacy or best_first_v1, got: " ^ other)

let normalize_speculation_budget value =
  match value with
  | None -> Ok None
  | Some v when v <= 0 -> Error "❌ speculation_budget must be > 0"
  | Some v -> Ok (Some v)

let room_strategy_json config =
  let state = Room.read_state config in
  `Assoc
    [
      ("room_id", `String (Room.current_room_id config));
      ("search_strategy_default",
       match state.search_strategy_default with Some v -> `String v | None -> `Null);
      ("speculation_enabled", `Bool state.speculation_enabled);
      ("speculation_budget",
       match state.speculation_budget with Some v -> `Int v | None -> `Null);
    ]

(* Handlers *)

let status_summary_string (ctx : context) =
  Room.ensure_initialized ctx.config;
  let state = Room.read_state ctx.config in
  let current_room =
    Room.read_current_room ctx.config |> Option.value ~default:"default"
  in
  let backlog = Room.read_backlog_in_room ctx.config current_room in
  let max_agents_display = 40 in
  let max_active_tasks_display = 30 in
  let cluster_name =
    match ctx.config.backend_config.Backend_types.cluster_name with
    | "" -> state.project
    | name -> name
  in
  let active_agents =
    state.active_agents |> List.sort String.compare
  in
  let active_tasks, done_count, cancelled_count =
    List.fold_left
      (fun (active, done_cnt, cancelled_cnt) (task : Types.task) ->
        match task.task_status with
        | Types.Done _ -> (active, done_cnt + 1, cancelled_cnt)
        | Types.Cancelled _ -> (active, done_cnt, cancelled_cnt + 1)
        | _ -> (task :: active, done_cnt, cancelled_cnt))
      ([], 0, 0)
      backlog.tasks
  in
  let active_tasks = List.rev active_tasks in
  let shown_agents = take_items max_agents_display active_agents in
  let shown_active_tasks = take_items max_active_tasks_display active_tasks in
  let buf = Buffer.create 256 in
  Buffer.add_string buf (Printf.sprintf "🏢 Cluster: %s\n" cluster_name);
  if cluster_name <> state.project then
    Buffer.add_string buf (Printf.sprintf "📦 Project: %s\n" state.project);
  Buffer.add_string buf (Printf.sprintf "📍 Room: %s\n" current_room);
  Buffer.add_string buf (Printf.sprintf "📁 Path: %s\n" ctx.config.base_path);
  Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";
  Buffer.add_string buf "📌 Players:\n";
  (match shown_agents with
  | [] ->
      Buffer.add_string buf "  (no active agents)\n"
  | _ ->
      List.iter
        (fun agent_name ->
          Buffer.add_string buf (Printf.sprintf "  🟢 %s\n" agent_name))
        shown_agents;
      if List.length active_agents > max_agents_display then
        Buffer.add_string buf
          (Printf.sprintf
             "  … and %d more agents (use masc_who for full list)\n"
             (List.length active_agents - max_agents_display)));
  Buffer.add_string buf "\n📋 Quest Board:\n";
  List.iter
    (fun (task : Types.task) ->
      let status_icon =
        match task.task_status with
        | Types.Done _ -> "✅"
        | Types.Claimed _ | Types.InProgress _ -> "🔄"
        | Types.Todo -> "📋"
        | Types.Cancelled _ -> "🚫"
      in
      let assignee =
        match task.task_status with
        | Types.Claimed { assignee; _ }
        | Types.InProgress { assignee; _ }
        | Types.Done { assignee; _ } -> assignee
        | Types.Cancelled { cancelled_by; _ } -> cancelled_by
        | Types.Todo -> "unclaimed"
      in
      Buffer.add_string buf
        (Printf.sprintf "  %s %s: %s (%s)\n" status_icon task.id task.title
           assignee))
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
  (true, cached_text_by_key _status_cache ~key:ctx.config.base_path
       ~ttl_s:(status_cache_ttl_s ()) (fun () ->
       status_summary_string ctx))

let handle_init ctx args =
  let agent = match get_string args "agent_name" "" with
    | "" -> None
    | s -> Some s
  in
  invalidate_status_cache ();
  (true, Room.init ctx.config ~agent_name:agent)

let handle_reset ctx args =
  let confirm = get_bool args "confirm" false in
  if not confirm then
    (false, "⚠️ This will DELETE the entire .masc/ folder!\nCall with confirm=true to proceed.")
  else begin
    invalidate_status_cache ();
    (true, Room.reset ctx.config)
  end

let handle_room_strategy_get ctx _args =
  (true, Yojson.Safe.pretty_to_string (room_strategy_json ctx.config))

let handle_room_strategy_set ctx args =
  let search_strategy_raw = get_string_opt args "search_strategy_default" in
  let search_strategy_default =
    match search_strategy_raw with
    | Some value -> normalize_search_strategy value
    | None -> Ok None
  in
  let speculation_enabled = get_bool_opt args "speculation_enabled" in
  let speculation_budget =
    match args |> member "speculation_budget" with
    | `Int value -> normalize_speculation_budget (Some value)
    | `Null -> Ok None
    | _ -> Ok None
  in
  match search_strategy_default, speculation_budget with
  | Error e, _ -> (false, e)
  | _, Error e -> (false, e)
  | Ok search_strategy_default, Ok speculation_budget ->
      let updated =
        Room.update_state ctx.config (fun state ->
            {
              state with
              search_strategy_default =
                (match search_strategy_raw with Some _ -> search_strategy_default | None -> state.search_strategy_default);
              speculation_enabled =
                Option.value ~default:state.speculation_enabled speculation_enabled;
              speculation_budget =
                (match args |> member "speculation_budget" with
                | `Null -> None
                | `Int _ -> speculation_budget
                | _ -> state.speculation_budget);
            })
      in
      invalidate_status_cache ();
      ( true,
        Yojson.Safe.pretty_to_string
          (`Assoc
            [
              ("status", `String "ok");
              ("room_strategy", room_strategy_json ctx.config);
              ("updated_at", `String (Types.now_iso ()));
              ("project", `String updated.project);
            ]) )

let handle_vote_create ctx args =
  let topic = get_string args "topic" "" in
  let options = get_string_list args "options" in
  let required_votes = get_int args "required_votes" 1 in
  if String.trim topic = "" then
    (false, "❌ topic is required")
  else
    (true,
     Room.vote_create ctx.config ~proposer:ctx.agent_name ~topic ~options
       ~required_votes)

let handle_vote_cast ctx args =
  let vote_id = get_string args "vote_id" "" in
  let choice = get_string args "choice" "" in
  if String.trim vote_id = "" then
    (false, "❌ vote_id is required")
  else if String.trim choice = "" then
    (false, "❌ choice is required")
  else
    (true, Room.vote_cast ctx.config ~agent_name:ctx.agent_name ~vote_id ~choice)

let handle_vote_status ctx args =
  let vote_id = get_string args "vote_id" "" in
  if String.trim vote_id = "" then
    (false, "❌ vote_id is required")
  else
    (true, Yojson.Safe.pretty_to_string (Room.vote_status ctx.config ~vote_id))

let handle_votes ctx _args =
  (true, Yojson.Safe.pretty_to_string (Room.list_votes ctx.config))

(* ── State inspection (shared by workflow_guide and check) ──────── *)

type agent_state = {
  room_set : bool;
  joined : bool;
  task_claimed : bool;
  current_task_set : bool;
  worktree_active : bool;
}

let inspect_state ctx =
  let room_set = Room.is_initialized ctx.config in
  let joined =
    if room_set then
      (try Room.is_agent_joined ctx.config ~agent_name:ctx.agent_name
       with Sys_error _ | Yojson.Json_error _ -> false)
    else false
  in
  let task_claimed =
    if joined then
      let actual_name = Room.resolve_agent_name ctx.config ctx.agent_name in
      Room.get_tasks_raw ctx.config
      |> List.exists (fun (task : Types.task) ->
             match task.task_status with
             | Types.Claimed { assignee; _ } | Types.InProgress { assignee; _ } ->
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
      let wt_dir = Filename.concat ctx.config.base_path ".worktrees" in
      (try Sys.file_exists wt_dir && Sys.is_directory wt_dir &&
           Array.length (Sys.readdir wt_dir) > 0
       with
       | Sys_error _ -> false
       | exn ->
           Log.Room.warn "worktree_active check failed: %s" (Printexc.to_string exn);
           false)
    else false
  in
  { room_set; joined; task_claimed; current_task_set; worktree_active }

let state_to_json st =
  `Assoc [
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
  (true, Yojson.Safe.pretty_to_string result)

(* ── State check (assertion-based verification) ────────────────── *)

let check_assertion st assertion =
  let (passed, fix_hint) = match assertion with
    | "room_set" ->
        (st.room_set,
         "Call masc_set_room with your project root path")
    | "joined" ->
        (st.joined,
         "Call masc_join to register your agent in the room")
    | "task_claimed" ->
        (st.task_claimed,
         "Call masc_claim to get a task")
    | "current_task_set" ->
        (st.current_task_set,
         "Call masc_plan_set_task after claim paths that did not auto-bind current_task (for example masc_transition(action=claim))")
    | "worktree_active" ->
        (st.worktree_active,
         "Call masc_worktree_create to work in an isolated branch")
    | other ->
        (false, Printf.sprintf "Unknown assertion: %s" other)
  in
  `Assoc [
    ("assertion", `String assertion);
    ("passed", `Bool passed);
    ("fix_hint", if passed then `Null else `String fix_hint);
  ]

let handle_check ctx args =
  let st = inspect_state ctx in
  let default_assertions = [ "room_set"; "joined"; "task_claimed"; "current_task_set" ] in
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
  (true, Yojson.Safe.pretty_to_string result)

(* Dispatch function *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_status" -> Some (handle_status ctx args)
  | "masc_init" -> Some (handle_init ctx args)
  | "masc_reset" -> Some (handle_reset ctx args)
  | "masc_vote_create" -> Some (handle_vote_create ctx args)
  | "masc_vote_cast" -> Some (handle_vote_cast ctx args)
  | "masc_vote_status" -> Some (handle_vote_status ctx args)
  | "masc_votes" -> Some (handle_votes ctx args)
  | "masc_room_strategy_get" -> Some (handle_room_strategy_get ctx args)
  | "masc_room_strategy_set" -> Some (handle_room_strategy_set ctx args)
  | "masc_workflow_guide" -> Some (handle_workflow_guide ctx args)
  | "masc_check" -> Some (handle_check ctx args)
  | _ -> None

let schemas = Tool_schemas_room.schemas
