(** Tool_control - Flow control operations

    Handles: pause, pause_status, resume, switch_mode, get_config
*)

open Yojson.Safe.Util

type result = bool * string

type context = {
  config: Room.config;
  agent_name: string;
}

(* JSON helpers *)
let get_string args key default =
  match args |> member key with
  | `String s -> s
  | _ -> default

(* Handlers *)

let handle_pause ctx args =
  let reason = get_string args "reason" "Manual pause" in
  Room.pause ctx.config ~by:ctx.agent_name ~reason;
  (true, Printf.sprintf "⏸️ Room paused by %s: %s" ctx.agent_name reason)

let handle_resume ctx _args =
  match Room.resume ctx.config ~by:ctx.agent_name with
  | `Resumed -> (true, Printf.sprintf "▶️ Room resumed by %s" ctx.agent_name)
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
            ("paused_by", (match by with Some s -> `String s | None -> `Null));
            ( "pause_reason",
              match reason with Some s -> `String s | None -> `Null );
            ("paused_at", (match at with Some s -> `String s | None -> `Null));
            ("message", `String "⏸️ Room is paused");
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
            ("message", `String "▶️ Room is running (not paused)");
          ]
  in
  (true, Yojson.Safe.to_string payload)

let handle_switch_mode ctx args =
  let mode = get_string args "mode" "autonomous" in
  (* Mode.switch may not exist, but we mirror the original behavior *)
  (true, Printf.sprintf "🔄 Mode switched to: %s by %s" mode ctx.agent_name)

let handle_get_config ctx _args =
  let room_path = Room.masc_dir ctx.config in
  let summary = Config.get_config_summary room_path in
  (true, Yojson.Safe.pretty_to_string summary)

(* Dispatch function *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_pause" -> Some (handle_pause ctx args)
  | "masc_resume" -> Some (handle_resume ctx args)
  | "masc_pause_status" -> Some (handle_pause_status ctx args)
  | "masc_switch_mode" -> Some (handle_switch_mode ctx args)
  | "masc_get_config" -> Some (handle_get_config ctx args)
  | _ -> None
