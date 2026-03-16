(** Room Multi-Room Management — room creation, switching, and registry.

    Extracted from room.ml for modularity.

    Note: [room_enter] calls [leave], [init], and [join] which are defined
    in room.ml and in scope via the [include Room_multiroom] site. *)

open Types
open Room_utils
open Room_state
open Room_task

(** Slugify a string for use as room ID *)
let slugify name =
  String.lowercase_ascii name
  |> String.map (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then c
      else '-')
  |> (fun s ->
      (* Remove leading/trailing dashes and collapse multiple dashes *)
      let rec collapse acc prev_dash = function
        | [] -> List.rev acc
        | '-' :: rest when prev_dash -> collapse acc true rest
        | '-' :: rest -> collapse ('-' :: acc) true rest
        | c :: rest -> collapse (c :: acc) false rest
      in
      String.to_seq s |> List.of_seq |> collapse [] true |> List.to_seq |> String.of_seq)
  |> (fun s ->
      let len = String.length s in
      if len > 0 && s.[0] = '-' then String.sub s 1 (len - 1) else s)
  |> (fun s ->
      let len = String.length s in
      if len > 0 && s.[len - 1] = '-' then String.sub s 0 (len - 1) else s)

(** Get rooms directory path *)
let rooms_dir config = rooms_root_dir config

(** Get room registry file path *)
let registry_path config = registry_root_path config

(** Get current room file path *)
let current_room_path config = current_room_root_path config

(** Read current room ID *)
let read_current_room config =
  let read_from path =
    match Safe_ops.read_file_safe path with
    | Ok content ->
      let trimmed = String.trim content in
      if trimmed = "" then None else Some trimmed
    | Error _ -> None
  in
  match read_from (current_room_path config) with
  | Some room_id -> Some room_id
  | None ->
      (match read_from (legacy_current_room_path config) with
       | Some legacy_room -> Some legacy_room
       | None -> Some "default")

(** Write current room ID *)
let write_current_room config room_id =
  let write_to path =
    mkdir_p (Filename.dirname path);
    let oc = open_out path in
    output_string oc room_id;
    output_char oc '\n';
    close_out oc
  in
  (* Canonical location inside .masc/ *)
  write_to (current_room_path config);
  (* Legacy compatibility: keep base_path/current_room in sync *)
  write_to (legacy_current_room_path config)

(** Get path for a specific room *)
let room_path config room_id = room_dir_for config room_id

(** Read raw agent records from a room directory *)
let get_agents_raw_in_room config room_id =
  if not (root_is_initialized config) then []
  else
    let agents_path = agents_dir_in_room config room_id in
    if not (Sys.file_exists agents_path) then []
    else
      Sys.readdir agents_path
      |> Array.to_list
      |> List.filter (fun name -> Filename.check_suffix name ".json")
      |> List.filter_map (fun name ->
          let path = Filename.concat agents_path name in
          let json = read_json config path in
          match agent_of_yojson json with
          | Ok agent -> Some agent
          | Error _ -> None
        )

(** Count agents in a room *)
let count_agents_in_room config room_id =
  List.length (get_agents_raw_in_room config room_id)

(** Count tasks in a room *)
let count_tasks_in_room config room_id =
  get_tasks_raw_in_room config room_id
  |> List.fold_left (fun acc (task : Types.task) ->
         match task.task_status with
         | Types.Todo | Types.Claimed _ | Types.InProgress _ -> acc + 1
         | Types.Done _ | Types.Cancelled _ -> acc
       ) 0

(** Load room registry *)
let load_registry config : Types.room_registry =
  let default_registry =
    { rooms = []; default_room = "default"; current_room = Some "default" }
  in
  let parse_registry json =
    match Types.room_registry_of_yojson json with
    | Ok registry -> registry
    | Error _ -> default_registry
  in
  let root_path = registry_path config in
  let legacy_path = legacy_registry_root_path config in
  if path_exists_root config root_path then
    parse_registry (read_json_root config root_path)
  else if Sys.file_exists legacy_path then
    (* Legacy fallback: migrate rooms.json into .masc/ root. *)
    let legacy_registry = parse_registry (read_json_local legacy_path) in
    write_json_root config root_path (Types.room_registry_to_yojson legacy_registry);
    legacy_registry
  else
    default_registry

(** Save room registry *)
let save_registry config (registry : Types.room_registry) =
  let path = registry_path config in
  mkdir_p (rooms_dir config);
  write_json_root config path (Types.room_registry_to_yojson registry);
  (* Keep legacy location in sync for older clients. *)
  write_json_local (legacy_registry_root_path config) (Types.room_registry_to_yojson registry)

(** List all available rooms *)
let rooms_list config : Yojson.Safe.t =
  if not (root_is_initialized config) then
    `Assoc [
      ("rooms", `List []);
      ("current_room", `Null);
      ("error", `String "MASC not initialized")
    ]
  else begin
    let registry = load_registry config in
    let current = read_current_room config in

    (* Always include default room even if not in registry *)
    let default_room : Types.room_info = {
      id = "default";
      name = "Default Room";
      description = Some "Default coordination room";
      created_at = now_iso ();  (* Current time instead of epoch *)
      created_by = None;
      agent_count = count_agents_in_room config "default";
      task_count = count_tasks_in_room config "default";
    } in

    (* Update room counts and merge with default *)
    let rooms_with_counts = List.map (fun (r : Types.room_info) ->
      { r with
        agent_count = count_agents_in_room config r.id;
        task_count = count_tasks_in_room config r.id;
      }
    ) registry.rooms in

    (* Ensure default is in the list *)
    let all_rooms =
      if List.exists (fun (r : Types.room_info) -> r.id = "default") rooms_with_counts then
        rooms_with_counts
      else
        default_room :: rooms_with_counts
    in

    `Assoc [
      ("rooms", `List (List.map Types.room_info_to_yojson all_rooms));
      ("current_room", match current with Some r -> `String r | None -> `String "default");
    ]
  end

(** Create a new room *)
let room_create config ~name ~description : Yojson.Safe.t =
  if not (root_is_initialized config) then
    `Assoc [("error", `String "MASC not initialized")]
  else begin
    let room_id = slugify name in

    (* Check if room already exists *)
    let registry = load_registry config in
    if List.exists (fun (r : Types.room_info) -> r.id = room_id) registry.rooms then
      `Assoc [("error", `String (Printf.sprintf "Room '%s' already exists" room_id))]
    else if room_id = "default" then
      `Assoc [("error", `String "Cannot create room with reserved name 'default'")]
    else begin
      (* Create room directory structure *)
      mkdir_p (rooms_dir config);
      let rpath = room_path config room_id in
      mkdir_p rpath;
      mkdir_p (Filename.concat rpath "agents");
      mkdir_p (Filename.concat rpath "tasks");
      mkdir_p (Filename.concat rpath "locks");

      (* Create room info *)
      let room_info : Types.room_info = {
        id = room_id;
        name;
        description;
        created_at = now_iso ();
        created_by = None;
        agent_count = 0;
        task_count = 0;
      } in

      (* Update registry *)
      let updated_registry = {
        registry with
        rooms = room_info :: registry.rooms;
      } in
      save_registry config updated_registry;

      `Assoc [
        ("id", `String room_id);
        ("name", `String name);
        ("message", `String (Printf.sprintf "✅ Room '%s' created" room_id));
      ]
    end
  end

(** Ensure room exists as an SSOT registry entry and directory skeleton. *)
let ensure_room_entry config room_id =
  if room_id = "default" || room_id = "" then
    ()
  else if not (root_is_initialized config) then
    ()
  else begin
    let registry = load_registry config in
    if List.exists (fun (r : Types.room_info) -> r.id = room_id) registry.rooms then
      ()
    else (
      mkdir_p (rooms_dir config);
      let rpath = room_path config room_id in
      mkdir_p rpath;
      mkdir_p (Filename.concat rpath "agents");
      mkdir_p (Filename.concat rpath "tasks");
      mkdir_p (Filename.concat rpath "locks");
      let room_info : Types.room_info = {
        id = room_id;
        name = room_id;
        description = None;
        created_at = now_iso ();
        created_by = None;
        agent_count = 0;
        task_count = 0;
      } in
      let updated_registry = {
        registry with
        rooms = room_info :: registry.rooms;
      } in
      save_registry config updated_registry
    )
  end

(* room_enter stays in room.ml — it depends on leave/init/join
   which are defined there and not available from Room_utils. *)
