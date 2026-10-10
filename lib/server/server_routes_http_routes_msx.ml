(** HTTP routes for the workspace MSX machine (RFC-0439 §3.7, RFC #38695).

    Spectating the machine goes through
    [GET /api/v1/lane-addons/live?source_kind=msx_capture] (RFC #38695);
    the legacy per-machine frame route has been removed.

    [POST /api/v1/msx/press] lets the human at the TUI press keys on the same
    machine a keeper is playing (RFC-0439 §3.3): [{keys:[..], hold_frames?,
    frames?, sequence?}] goes to the attached worker under the identity
    [with_tool_actor_auth] resolved for the request, so its edges land in the
    shared ledger next to the keeper's under the name the credential carries.
    It is a write, gated like the mutating MSX tools. A field of the wrong
    type is a 400 naming the field, never a silent default. *)

open Server_auth
module Http = Http_server_eio

(* Frames a press holds its keys down, and the frames the call advances in
   all, when the body names neither (RFC-0439 §3.3): a tap. *)
let press_default_hold_frames = 5
let press_default_step_frames = 15

let press_result_json ~ok ?message (obs : Yojson.Safe.t option) =
  let fields = ["ok", `Bool ok] @ (match message with None -> [] | Some message -> ["message", `String message]) in
  let observation = match obs with
    | Some (`Assoc fields) -> List.filter (fun (name, _) -> List.mem name ["frame";"mode";"cartridge";"disk"]) fields
    | None | Some _ -> [] in
  `Assoc (fields @ observation)
;;

type worker_response = {
  status : [ `OK | `Conflict | `Bad_request | `Service_unavailable | `Internal_server_error ];
  ok : bool;
  message : string;
  data : Yojson.Safe.t;
  code : string option;
}

let worker_response ~config ~principal ~(schema : Masc_domain.tool_schema) ~arguments =
  let failed status message = {status;ok=false;message;data=`Null;code=None} in
  match Tool_input_validation.validate_args ~schema:schema.input_schema ~name:schema.name ~args:arguments () with
  | Error refusal -> failed `Bad_request (Tool_result.message refusal)
  | Ok arguments ->
      match Machine_addon_host.call_shared ~config ~principal ~name:schema.name ~arguments with
      | Error (Lane_addon_runtime.Unavailable message
          | Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Unavailable message)) ->
          failed `Service_unavailable message
      | Error (Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Rejected message)) ->
          failed `Bad_request message
      | Error (Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Activity_disabled message)) ->
          {(failed `Conflict message) with code=Some "activity_disabled"}
      | Error (Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Activity_unobserved message)) ->
          {(failed `Conflict message) with code=Some "activity_unobserved"}
      | Error (Lane_addon_runtime.Outcome_unknown message) ->
          failed `Service_unavailable (message ^ "; inspect the current machine before retrying")
      | Ok result ->
          let field name = match result.Mcp_protocol.Mcp_types._meta with
            | Some (`Assoc fields) -> List.assoc_opt name fields | _ -> None in
          let ok = result.is_error <> Some true in
          let code = match field "io.github.jeong-sik/masc.machine.errorCode" with
            | Some (`String ("activity_disabled" | "activity_unobserved" as code)) -> Some code
            | _ -> None in
          let status = if ok then `OK else match code with
            | Some _ -> `Conflict
            | None -> match field "io.github.jeong-sik/masc.machine.failure" with
              | Some (`String "rejected") -> `Bad_request
              | _ -> `Internal_server_error in
          {status;ok;code;message=Agent_core.Mcp.text_of_tool_result result;
           data=Option.value ~default:`Null result.structured_content}

let press_response ~config ~who ~body =
  let error message = `Bad_request, press_result_json ~ok:false ~message None in
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error message -> error ("invalid JSON: " ^ message)
  | `Assoc fields ->
      (* HTTP taps retain their shorter default; the model-facing tool uses 30. *)
      let fields = if List.mem_assoc "frames" fields then fields
        else ("frames", `Int press_default_step_frames) :: fields in
      let fields = if List.mem_assoc "hold_frames" fields then fields
        else ("hold_frames", `Int press_default_hold_frames) :: fields in
      let result = worker_response ~config ~principal:(Lane_addon_call_context.Host_actor who)
        ~schema:Tool_schemas_misc_toml.msx_press ~arguments:(`Assoc fields) in
      let fields = ["ok", `Bool result.ok; "message", `String result.message] in
      let fields = match result.code with None -> fields | Some code -> ("code", `String code)::fields in
      let observation = if result.ok then match result.data with
        | `Assoc data -> List.filter (fun (name,_) -> List.mem name ["frame";"mode";"cartridge";"disk"]) data
        | _ -> [] else [] in
      result.status, `Assoc (fields @ observation)
  | _ -> error "body must be a JSON object"
;;

let handle_press ~config ~who request reqd =
  Http.Request.read_body_async reqd (fun body ->
      let status, json = press_response ~config ~who ~body in
      respond_json_value_with_cors ~status:(status :> Httpun.Status.t) request reqd json)
;;

let carts_response ~config =
  let result = worker_response ~config ~principal:Lane_addon_call_context.Anonymous
    ~schema:Tool_schemas_misc_toml.msx_meta ~arguments:(`Assoc ["include_inventory", `Bool true]) in
  if not result.ok then result.status, `Assoc ["ok", `Bool false; "message", `String result.message]
  else match result.data with
    | `Assoc fields -> (match List.assoc_opt "inventory" fields with
        | Some (`Assoc _ as inventory) -> `OK, inventory
        | _ -> `Internal_server_error, `Assoc ["ok", `Bool false;
            "message", `String "MSX worker omitted its cartridge inventory"])
    | _ -> `Internal_server_error, `Assoc ["ok", `Bool false;
        "message", `String "invalid MSX worker inventory response"]
;;

let load_result_json ~ok ~message : Yojson.Safe.t =
  `Assoc [ ("ok", `Bool ok); ("message", `String message) ]
;;

(* The worker resolves inventory names against its persistent storage. *)
let load_response ~(config : Workspace.config) ~agent_name ~body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error message ->
      `Bad_request, load_result_json ~ok:false ~message:("invalid JSON: " ^ message)
  | arguments ->
      let result = worker_response ~config ~principal:(Lane_addon_call_context.Host_actor agent_name)
        ~schema:Tool_schemas_misc_toml.msx_load ~arguments in
      result.status, load_result_json ~ok:result.ok ~message:result.message
;;

let handle_load ~(config : Workspace.config) ~agent_name request reqd =
  Http.Request.read_body_async reqd (fun body ->
      let status, json = load_response ~config ~agent_name ~body in
      respond_json_value_with_cors ~status:(status :> Httpun.Status.t) request reqd json)
;;

(* Frames per poll-cadence tick (RFC-0439 §3.2). At the TUI's ~3 Hz spectator
   poll this advances ~54 frames a second, close enough to the machine's 60 Hz
   that a game reads as live without a server-side ticker. *)
let msx_tick_default_frames = 18

let clamp_tick_frames requested =
  let schema = Tool_schemas_misc_toml.msx_step.Masc_domain.input_schema in
  let maximum = Yojson.Safe.Util.(schema |> member "properties" |> member "frames" |> member "maximum" |> to_int) in
  max 1 (min maximum requested)

type pixel_reference = { revision : string; width : int; height : int }
type pixel_response = Full_frame | Retained_pixels of pixel_reference option

let decode_pixel_reference = function
  | `Assoc fields when List.length fields = 3 ->
      (match List.assoc_opt "revision" fields, List.assoc_opt "width" fields,
             List.assoc_opt "height" fields with
       | Some (`String revision), Some (`Int width), Some (`Int height)
         when String.length revision = 64 && width > 0 && height > 0
              && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) revision ->
           Ok { revision; width; height }
       | _ -> Error "known_pixels requires a SHA256 revision and positive width/height")
  | _ -> Error "known_pixels requires exactly revision, width and height"

let decode_tick body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error _ -> Error "tick body must be valid JSON"
  | `Assoc fields ->
      let ( let* ) = Result.bind in
      let names = List.map fst fields in
      let* () =
        if List.length names <> List.length (List.sort_uniq String.compare names)
           || List.exists (fun name -> not (List.mem name ["frames"; "pixel_response"; "known_pixels"])) names
        then Error "tick has duplicate or unknown fields" else Ok () in
      let* frames = match List.assoc_opt "frames" fields with
        | None -> Ok msx_tick_default_frames
        | Some (`Int n) -> Ok (clamp_tick_frames n)
        | Some _ -> Error "frames must be an integer" in
      let* pixels = match List.assoc_opt "pixel_response" fields, List.assoc_opt "known_pixels" fields with
        | None, None -> Ok Full_frame
        | Some (`String "retained"), None -> Ok (Retained_pixels None)
        | Some (`String "retained"), Some value ->
            Result.map (fun reference -> Retained_pixels (Some reference)) (decode_pixel_reference value)
        | _ -> Error "known_pixels requires pixel_response=retained" in
      Ok (frames, pixels)
  | _ -> Error "tick body must be an object"
;;

let tick_response ~config ~body =
  match decode_tick body with
  | Error message -> `Bad_request, `Assoc ["ok", `Bool false; "message", `String message]
  | Ok (frames, pixel_response) ->
      let pixels = match pixel_response with
        | Full_frame -> []
        | Retained_pixels known -> ["pixel_response", `String "retained"] @
            (match known with None -> [] | Some p -> ["known_pixels", `Assoc [
              "revision", `String p.revision; "width", `Int p.width; "height", `Int p.height]]) in
      let result = worker_response ~config ~principal:Lane_addon_call_context.Operator
        ~schema:Tool_schemas_misc_toml.msx_step
        ~arguments:(`Assoc (["frames", `Int frames; "include_frame", `Bool true] @ pixels)) in
      if result.ok then result.status, result.data
      else result.status, `Assoc (["ok", `Bool false; "message", `String result.message]
        @ match result.code with None -> [] | Some code -> ["code", `String code])
;;

let handle_tick ~config request reqd =
  Http.Request.read_body_async reqd (fun body ->
      let status, json = tick_response ~config ~body in
      Http.Response.json_value_on_cpu ~status:(status :> Httpun.Status.t) ~request
        ~extra_headers:(Server_auth.cors_headers (Server_auth.get_origin request)) json reqd)
;;

let activity_json ~config:_ =
  let activity, message = match Runtime.machine_configuration () with
    | None -> Machine_configuration.Unobserved, Some "Machine activity configuration is unavailable"
    | Some configuration ->
        (if configuration.Machine_configuration.msx_enabled then Machine_configuration.Enabled else Disabled), None in
  `Assoc (["schema", `String "masc.msx-activity/v1";
    "activity", `String (Machine_configuration.activity_to_wire activity)]
    @ match message with None -> [] | Some message -> ["message", `String message])

let checkpoint_response ~(config : Workspace.config) ~restore ~body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error message ->
      `Bad_request, load_result_json ~ok:false ~message
  | `Assoc fields when
      List.length fields <> List.length (List.sort_uniq String.compare (List.map fst fields)) ->
      `Bad_request, load_result_json ~ok:false ~message:"checkpoint has duplicate fields"
  | arguments ->
      let schema = if restore then Tool_schemas_misc_toml.msx_restore else Tool_schemas_misc_toml.msx_save in
      let result = worker_response ~config ~principal:Lane_addon_call_context.Operator ~schema ~arguments in
      result.status, load_result_json ~ok:result.ok ~message:result.message
;;

let handle_change_disk ~(config : Workspace.config) request reqd =
  Http.Request.read_body_async reqd (fun body ->
    let status, json = match Yojson.Safe.from_string body with
      | exception Yojson.Json_error message -> `Bad_request, load_result_json ~ok:false ~message
      | arguments ->
          let result = worker_response ~config ~principal:Lane_addon_call_context.Operator
            ~schema:Tool_schemas_misc_toml.msx_change_disk ~arguments in
          result.status, load_result_json ~ok:result.ok ~message:result.message in
    respond_json_value_with_cors ~status:(status :> Httpun.Status.t) request reqd json)
;;

let handle_checkpoint ~config ~restore request reqd =
  Http.Request.read_body_async reqd (fun body ->
    let status, json = checkpoint_response ~config ~restore ~body in
    respond_json_value_with_cors ~status:(status :> Httpun.Status.t) request reqd json)
;;

let add_routes router =
  router
  |> Http.Router.get "/api/v1/msx/activity" (fun request reqd ->
       with_public_read
         (fun state req reqd -> Http.Response.json_value ~compress:true ~request:req
           (activity_json ~config:(Mcp_server.workspace_config state)) reqd)
         request reqd)
  |> Http.Router.get "/api/v1/msx/carts" (fun request reqd ->
       with_public_read
         (fun state req reqd ->
           let status, json = carts_response ~config:(Mcp_server.workspace_config state) in
           respond_json_value_with_cors ~status:(status :> Httpun.Status.t) req reqd json)
         request reqd)
  |> Http.Router.post "/api/v1/msx/press" (fun request reqd ->
       with_tool_actor_auth ~tool_name:"masc_msx_press"
         (fun state who _req reqd ->
           handle_press ~config:(Mcp_server.workspace_config state) ~who request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/load" (fun request reqd ->
       with_tool_actor_auth ~tool_name:"masc_msx_load"
         (fun state agent_name _req reqd ->
           handle_load ~config:(Mcp_server.workspace_config state) ~agent_name request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/save" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_save"
         (fun state _req reqd ->
           handle_checkpoint ~config:(Mcp_server.workspace_config state) ~restore:false
             request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/restore" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_restore"
         (fun state _req reqd ->
           handle_checkpoint ~config:(Mcp_server.workspace_config state) ~restore:true
             request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/disk" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_change_disk"
         (fun state _req reqd ->
           handle_change_disk ~config:(Mcp_server.workspace_config state) request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/tick" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_step"
         (fun state _req reqd -> handle_tick ~config:(Mcp_server.workspace_config state) request reqd)
         request reqd)
;;
