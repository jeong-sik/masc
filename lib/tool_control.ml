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
  | `Already_running -> (true, "Default project scope is not paused")

let handle_pause_status ctx args =
  let requested_namespace = get_string args "namespace_id" "" |> String.trim in
  let namespace_id = "default" in
  let payload =
    match Room.pause_info ctx.config with
    | Some (by, reason, at) ->
        `Assoc
          [
            ("ok", `Bool true);
            ("namespace_id", `String namespace_id);
            ("namespace", `String namespace_id);
            ("namespace_mode", `String "flattened");
            ("status", `String "paused");
            ("paused", `Bool true);
            ("paused_by", Json_util.string_opt_to_json by);
            ( "pause_reason",
              Json_util.string_opt_to_json reason );
            ("paused_at", Json_util.string_opt_to_json at);
            ("message", `String "Default project scope is paused");
            ( "requested_namespace_id",
              if requested_namespace = "" then `Null
              else `String requested_namespace );
          ]
    | None ->
        `Assoc
          [
            ("ok", `Bool true);
            ("namespace_id", `String namespace_id);
            ("namespace", `String namespace_id);
            ("namespace_mode", `String "flattened");
            ("status", `String "running");
            ("paused", `Bool false);
            ("paused_by", `Null);
            ("pause_reason", `Null);
            ("paused_at", `Null);
            ("message", `String "Default project scope is running (not paused)");
            ( "requested_namespace_id",
              if requested_namespace = "" then `Null
              else `String requested_namespace );
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

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_control
           ~input_schema:s.input_schema
           ()))
    schemas
