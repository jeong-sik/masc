(** Tool_room - Room management operations

    Handles: status, reset, init, rooms_list, room_create, room_enter

    Note: join, leave, set_room, who require state/registry and remain in mcp_server_eio.ml
*)

open Yojson.Safe.Util

type result = bool * string

type context = {
  config: Room.config;
  agent_name: string;
}

open Tool_args

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

let handle_status ctx _args =
  (true, Room.status ctx.config)

let handle_init ctx args =
  let agent = match get_string args "agent_name" "" with
    | "" -> None
    | s -> Some s
  in
  (true, Room.init ctx.config ~agent_name:agent)

let handle_reset ctx args =
  let confirm = get_bool args "confirm" false in
  if not confirm then
    (false, "⚠️ This will DELETE the entire .masc/ folder!\nCall with confirm=true to proceed.")
  else
    (true, Room.reset ctx.config)

let handle_rooms_list ctx _args =
  let result = Room.rooms_list ctx.config in
  let open Yojson.Safe.Util in
  let rooms = result |> member "rooms" |> to_list in
  let current = result |> member "current_room" |> to_string_option in
  let count = List.length rooms in
  let buf = Buffer.create 256 in
  Buffer.add_string buf (Printf.sprintf "Rooms: %d found" count);
  (match current with
   | Some r -> Buffer.add_string buf (Printf.sprintf " (current: %s)" r)
   | None -> ());
  Buffer.add_char buf '\n';
  List.iter (fun room ->
    let name = room |> member "name" |> to_string_option |> Option.value ~default:"?" in
    let id = room |> member "id" |> to_string_option |> Option.value ~default:"?" in
    Buffer.add_string buf (Printf.sprintf "  - %s (id: %s)\n" name id)
  ) rooms;
  Buffer.add_string buf "\n---\n";
  Buffer.add_string buf (Yojson.Safe.pretty_to_string result);
  (true, Buffer.contents buf)

let handle_room_create ctx args =
  let name = get_string args "name" "" in
  if name = "" then
    (false, "❌ Room name is required")
  else
    let description = match args |> member "description" with
      | `String d -> Some d
      | _ -> None
    in
    let result = Room.room_create ctx.config ~name ~description in
    let success = match result with
      | `Assoc fields -> not (List.mem_assoc "error" fields)
      | _ -> false
    in
    (success, Yojson.Safe.pretty_to_string result)

let handle_room_enter ctx args =
  let room_id = get_string args "room_id" "" in
  if room_id = "" then
    (false, "❌ Room ID is required")
  else
    let agent_type = get_string args "agent_type" "claude" in
    let result = Room.room_enter ctx.config ~room_id ~agent_type ~agent_name:ctx.agent_name () in
    let success = match result with
      | `Assoc fields -> not (List.mem_assoc "error" fields)
      | _ -> false
    in
    (success, Yojson.Safe.pretty_to_string result)

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
      ( true,
        Yojson.Safe.pretty_to_string
          (`Assoc
            [
              ("status", `String "ok");
              ("room_strategy", room_strategy_json ctx.config);
              ("updated_at", `String (Types.now_iso ()));
              ("project", `String updated.project);
            ]) )

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
  | "masc_rooms_list" -> Some (handle_rooms_list ctx args)
  | "masc_room_create" -> Some (handle_room_create ctx args)
  | "masc_room_enter" -> Some (handle_room_enter ctx args)
  | "masc_room_strategy_get" -> Some (handle_room_strategy_get ctx args)
  | "masc_room_strategy_set" -> Some (handle_room_strategy_set ctx args)
  | "masc_workflow_guide" -> Some (handle_workflow_guide ctx args)
  | "masc_check" -> Some (handle_check ctx args)
  | _ -> None

let schemas = Tool_schemas_room.schemas
