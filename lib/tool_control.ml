(** Tool_control - Flow control operations

    Handles: pause, pause_status, resume
*)

open Tool_args

type result = bool * string

type context = {
  config: Room.config;
  agent_name: string;
}

(* Handlers *)

let handle_pause ctx args =
  let reason = get_string args "reason" "Manual pause" in
  Room.pause ctx.config ~by:ctx.agent_name ~reason;
  (true, Printf.sprintf "Paused by %s: %s" ctx.agent_name reason)

let handle_resume ctx _args =
  match Room.resume ctx.config ~by:ctx.agent_name with
  | `Resumed -> (true, Printf.sprintf "Resumed by %s" ctx.agent_name)
  | `Already_running -> (true, "Room is not paused")

let handle_pause_status ctx args =
  let requested_room = get_string args "room_id" "" |> String.trim in
  let current_room =
    Room.read_current_room ctx.config |> Option.value ~default:"default"
  in
  let room_id = if requested_room = "" then current_room else requested_room in
  let payload =
    match Room.pause_info ctx.config with
    | Some (by, reason, at) ->
        `Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("status", `String "paused");
            ("paused", `Bool true);
            ("paused_by", Json_util.string_opt_to_json by);
            ( "pause_reason",
              Json_util.string_opt_to_json reason );
            ("paused_at", Json_util.string_opt_to_json at);
            ("message", `String "Room is paused");
          ]
    | None ->
        `Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("status", `String "running");
            ("paused", `Bool false);
            ("paused_by", `Null);
            ("pause_reason", `Null);
            ("paused_at", `Null);
            ("message", `String "Room is running (not paused)");
          ]
  in
  (true, Yojson.Safe.to_string payload)

let schemas = Tool_schemas_control.schemas

(* Dispatch function *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_pause" -> Some (handle_pause ctx args)
  | "masc_resume" -> Some (handle_resume ctx args)
  | "masc_pause_status" -> Some (handle_pause_status ctx args)
  | _ -> None
