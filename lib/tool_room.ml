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
  (true, Yojson.Safe.pretty_to_string result)

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
  | _ -> None
