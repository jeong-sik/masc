(** HTTP routes that let a person play the shared DOS machine (RFC
    play-link-for-the-shared-machine §2.5).

    [POST /api/v1/dos/press], [/type], [/step] and [/pass] take the body of
    the tool of the same name, check it against that tool's schema, and run
    the tool under the identity [with_tool_actor_auth] resolved for the
    request. The ledger, the controller and the board therefore see the same
    call a Keeper's tool makes, under the name the credential carries. A field
    of the wrong type is a 400 naming the field and nothing runs. The answer is
    [{ok, message, data}]: 200 when the tool succeeded, 400 when it refused
    (another player holds the controller, no machine is loaded, an unknown
    key), as [POST /api/v1/msx/load] answers.

    Each call resolves an attached shared DOS worker. Host credential policy
    and worker serialization cover controller admission and execution. A missing
    worker is unavailable; no process-local emulator is used as a fallback. *)

open Server_auth
module Http = Http_server_eio

type route =
  | Press
  | Type
  | Step
  | Pass

let all_routes = [ Press; Type; Step; Pass ]

let path = function
  | Press -> "/api/v1/dos/press"
  | Type -> "/api/v1/dos/type"
  | Step -> "/api/v1/dos/step"
  | Pass -> "/api/v1/dos/pass"

let tool_name = function
  | Press -> "masc_dos_press"
  | Type -> "masc_dos_type"
  | Step -> "masc_dos_step"
  | Pass -> "masc_dos_pass"

let schema = function
  | Press -> Tool_schemas_misc_toml.dos_press
  | Type -> Tool_schemas_misc_toml.dos_type
  | Step -> Tool_schemas_misc_toml.dos_step
  | Pass -> Tool_schemas_misc_toml.dos_pass

let moves = List.map (fun route -> path route, schema route) all_routes

let result_json ~ok ~message data =
  `Assoc [ ("ok", `Bool ok); ("message", `String message); ("data", data) ]

let invoke_response ~config ~who ~name ~args =
  match Machine_addon_host.call_shared ~config
    ~principal:(Lane_addon_call_context.Host_actor who) ~name ~arguments:args with
  | Error (Lane_addon_runtime.Unavailable message
          | Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Unavailable message)) ->
      `Service_unavailable, result_json ~ok:false ~message `Null
  | Error (Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Rejected message | Activity_disabled message | Activity_unobserved message)) ->
      `Bad_request, result_json ~ok:false ~message `Null
  | Error (Lane_addon_runtime.Outcome_unknown message) ->
      `Service_unavailable, result_json ~ok:false
        ~message:(message ^ "; inspect the current machine before retrying") `Null
  | Ok result ->
      let ok = result.Mcp_protocol.Mcp_types.is_error <> Some true in
      (if ok then `OK else `Bad_request),
      result_json ~ok ~message:(Agent_core.Mcp.text_of_tool_result result)
        (Option.value ~default:`Null result.structured_content)

(* Every one of these moves what a watcher shows: press, type and step run the
   machine, and pass changes the holder the capture carries
   ([Lane_addon_sources.activity_of_misc_operation]). A refusal from the tool
   wakes watchers too: [Guest_fault] comes back after the machine ran up to the
   fault. A wake with nothing new costs a watcher one "unchanged" read; a
   missed one leaves it showing an old frame. A body the schema refused never
   reached the machine and wakes nothing. *)
let machine_changed ~config =
  Eio.Cancel.protect (fun () ->
    Lane_addon_runtime.notify_activity ~config
      ~activity:(Lane_addon_sources.Machine_changed Machine_lane.Dos))

let run_response ~config ~who ~route ~body =
  let name = tool_name route in
  let rejected message = `Bad_request, result_json ~ok:false ~message `Null in
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error message -> rejected ("body is not JSON: " ^ message)
  | args ->
    (match Tool_input_validation.validate_args ~schema:(schema route).Masc_domain.input_schema ~name ~args () with
     | Error refusal -> rejected (Tool_result.message refusal)
     | Ok args ->
       let status, json = invoke_response ~config ~who ~name ~args in
       machine_changed ~config;
       status, json)

(* The worker checks the expected program while holding its machine lock. *)
let press_into ~config ~who ~saves_name ~keys =
  let status, json = invoke_response ~config ~who ~name:(tool_name Press)
    ~args:(`Assoc ["keys", `List (List.map (fun key -> `String key) keys);
      "expected_program", `String saves_name]) in
  machine_changed ~config;
  status, json

let add_route router route =
  Http.Router.post (path route)
    (fun request reqd ->
      with_tool_actor_auth ~tool_name:(tool_name route)
        (fun state who request reqd ->
          let config = Mcp_server.workspace_config state in
          Http.Request.read_body_async reqd (fun body ->
            let status, json = run_response ~config ~who ~route ~body in
            respond_json_value_with_cors ~status request reqd json))
        request reqd)
    router

let add_routes router = List.fold_left add_route router all_routes
