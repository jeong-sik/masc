(** Room multi-room management helpers — slugify, registry, room paths.

    Extracted from Room module. Depends on Room_utils and Room_state. *)

open Types
open Room_utils [@@warning "-33"]
open Room_state [@@warning "-33"]
open Room_query

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
    Fs_compat.mkdir_p (Filename.dirname path);
    Fs_compat.save_file path (room_id ^ "\n")
  in
  (* Canonical location inside .masc/ *)
  write_to (current_room_path config);
  (* Legacy compatibility: keep base_path/current_room in sync *)
  write_to (legacy_current_room_path config)

(** Get path for a specific room *)
let room_path config room_id = room_dir_for config room_id

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
