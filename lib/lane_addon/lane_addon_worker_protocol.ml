open Lane_addon_types

type contract = {
  action_tool : string option;
  tool_invocation : tool_invocation;
  exported_tools : string list;
  tool_hooks : tool_hook list;
  max_reply_bytes : int;
  host_requests : bool;
}
type error = Invalid_contract of string | Protocol_failed of string
  | Host_refusal of Lane_addon_call_context.host_refusal
  | Invalid_observation of string | Stopped
type operator_error = Operator_unavailable | Operator_rejected | Operator_outcome_unknown
type ready = {
  client : Agent_core.Mcp.t;
  exported_tools : Mcp_protocol.Mcp_types.tool list;
  tool_hooks : (string * Lane_addon_tool_hooks.t) list;
  action_schema : Yojson.Safe.t option;
  operator_schema : Yojson.Safe.t option;
  companion_tools : string list;
  observation_effects : (string * Lane_addon_call_context.observation_effect) list;
}
type attachment = Awaiting | Initializing of Agent_core.Mcp.t
  | Ready of ready | Retired of Agent_core.Mcp.t option

type t = {
  instance_id : string;
  contract : contract;
  artifact_store : Lane_addon_store.t option;
  input_history : Lane_addon_machine_history.t;
  sampling_broker : Lane_addon_sampling.t option;
  mutable attachment : attachment;
  mutex : Eio.Mutex.t;
}
open Result.Syntax

let companion_public_result (result : Mcp_protocol.Mcp_types.tool_result) =
  let module S = Mcp_protocol.Mcp_types in
  let is_error = result.is_error = Some true in
  let value = if is_error then None else result.structured_content in
  let text = match value with
    | Some value -> Yojson.Safe.to_string value
    | None -> "private companion operation failed" in
  {S.content=[S.TextContent {type_="text"; text; annotations=None}];
   structured_content=value; is_error=Some is_error; _meta=None}

let contract ~action_tool ~tool_invocation ~exported_tools ~tool_hooks ~max_reply_bytes ~host_requests =
  let invalid detail = Error (Invalid_contract detail) in
  let* exported_tools = validate_exported_tools ~action_tool exported_tools
    |> Result.map_error (fun detail -> Invalid_contract detail) in
  let* () = if max_reply_bytes > 0 then Ok () else invalid "max_reply_bytes must be positive" in
  let* () = if List.length tool_hooks = List.length (List.sort_uniq compare tool_hooks)
    then Ok () else invalid "duplicate tool hook" in
  let* () = match tool_invocation, action_tool with
    | Host_context, Some tool when String.equal tool Lane_addon_call_context.tool_name ->
        invalid "caller-context control port cannot also be the action port"
    | (Direct | Host_context), (None | Some _) -> Ok () in
  Ok {action_tool;tool_invocation;exported_tools;tool_hooks;max_reply_bytes;host_requests}
let contract_of_package (package : package) =
  contract ~action_tool:package.action_tool ~tool_invocation:package.tool_invocation
    ~exported_tools:package.exported_tools ~tool_hooks:package.tool_hooks
    ~max_reply_bytes:(Lane_addon_types.max_reply_bytes package) ~host_requests:(uses_host_requests package)
let create ~instance_id ~contract ?artifact_store ?sampling_broker () = {
  instance_id;contract;artifact_store;sampling_broker;
  input_history=Lane_addon_machine_history.create ();
  attachment=Awaiting;
  mutex=Eio.Mutex.create ();
}
let revoked t = match t.attachment with
  | Retired _ -> true | Awaiting | Initializing _ | Ready _ -> false
let revoke t = t.attachment <- (match t.attachment with
  | Awaiting -> Retired None
  | Initializing client -> Retired (Some client)
  | Ready ready -> Retired (Some ready.client)
  | Retired client -> Retired client)
let close t =
  revoke t;
  match t.attachment with
  | Retired client ->
      (try Option.iter Agent_core.Mcp.close client with
       | Eio.Io _ | Unix.Unix_error _ | Sys_error _ -> ())
  | Awaiting | Initializing _ | Ready _ -> ()
let exported_tools t = match t.attachment with
  | Ready ready -> ready.exported_tools | Awaiting | Initializing _ | Retired _ -> []
let action_schema t = match t.attachment with
  | Ready ready -> ready.action_schema | Awaiting | Initializing _ | Retired _ -> None
let operator_schema t = match t.attachment with
  | Ready ready -> ready.operator_schema | Awaiting | Initializing _ | Retired _ -> None
let companion_tools t = match t.attachment with
  | Ready ready -> ready.companion_tools | Awaiting | Initializing _ | Retired _ -> []
let observation_effect t name = match t.attachment with
  | Ready ready ->
      (match List.assoc_opt name ready.observation_effects with
       | Some declared -> declared
       | None -> Lane_addon_call_context.May_change)
  | Awaiting | Initializing _ | Retired _ -> Lane_addon_call_context.May_change
let ready_for_call t = match t.attachment with
  | Ready ready -> Ok ready
  | Awaiting | Initializing _ -> Error (Host_refusal (Lane_addon_call_context.Unavailable "worker protocol is not ready"))
  | Retired _ -> Error Stopped
let client_for_call t = ready_for_call t |> Result.map (fun ready -> ready.client)
let initialize t client =
  match t.attachment with
  | Initializing _ | Ready _ | Retired (Some _) -> Error (Invalid_contract "worker protocol already has its connection")
  | Retired None -> t.attachment <- Retired (Some client); close t; Error Stopped
  | Awaiting ->
  t.attachment <- Initializing client;
  let result = try
    let protocol_error error = Protocol_failed (Agent_core.Error.to_string error) in
        let* () = Agent_core.Mcp.initialize client |> Result.map_error protocol_error in
        let* tools = Agent_core.Mcp.list_tools_full client |> Result.map_error protocol_error in
        if not (List.exists (fun (tool : Mcp_protocol.Mcp_types.tool) ->
            String.equal tool.name "lane_observe") tools) then
          Error (Protocol_failed "package must advertise lane_observe in its initial tools/list page")
        else if revoked t then Error Stopped
        else
          let* action_schema = match t.contract.action_tool with
            | None -> Ok None
            | Some name ->
                (match List.filter (fun (tool : Mcp_protocol.Mcp_types.tool) -> tool.name = name) tools with
                 | [tool] ->
                     let* () = Lane_addon_action.validate_schema tool.input_schema
                       |> Result.map_error (fun detail -> Protocol_failed detail) in
                     Ok (Some tool.input_schema)
                 | _ -> Error (Protocol_failed "package must advertise exactly one configured action tool")) in
          let* () = match t.contract.tool_invocation with
            | Direct -> Ok ()
            | Host_context ->
                if t.contract.action_tool = Some Lane_addon_call_context.tool_name then
                  Error (Invalid_contract "caller-context control port cannot also be the action port")
                else match List.filter (fun (tool : Mcp_protocol.Mcp_types.tool) ->
                    String.equal tool.name Lane_addon_call_context.tool_name) tools with
                  | [_] -> Ok ()
                  | _ -> Error (Protocol_failed "package must advertise exactly one lane_call control tool") in
          let* () = if not t.contract.host_requests then Ok () else
            let advertised_once name=List.length (List.filter (fun (tool:Mcp_protocol.Mcp_types.tool) -> tool.name=name) tools)=1 in
            if advertised_once host_requests_tool && advertised_once host_result_tool then Ok ()
            else Error (Protocol_failed "a package that declares exact outputs must advertise lane_host_requests and lane_host_result once each") in
          let* operator_schema = match List.filter (fun (tool : Mcp_protocol.Mcp_types.tool) ->
              tool.name = operator_tool) tools with
            | [] -> Ok None
            | [tool] ->
                let* () = Lane_addon_action.validate_value_schema tool.input_schema
                  |> Result.map_error (fun _ -> Protocol_failed "invalid private operator schema") in
                Ok (Some tool.input_schema)
            | _ -> Error (Protocol_failed "duplicate private operator port") in
          let* companion_tools = match List.filter (fun (tool:Mcp_protocol.Mcp_types.tool) ->
              tool.name=companion_tool) tools with
            | [] -> Ok []
            | [_] when t.contract.tool_invocation=Host_context ->
                let* reply=Agent_core.Mcp.call_tool_full client ~name:companion_tool ~arguments:(`Assoc ["version",`Int 3])
                  |> Result.map_error (fun _ -> Protocol_failed "private companion handshake failed") in
                let* value=match reply.is_error,reply.structured_content with
                  | (None|Some false),Some value -> Lane_addon_action.canonical value
                    |> Result.map_error (fun _ -> Protocol_failed "invalid private companion handshake")
                  | Some true,_ | (None|Some false),None -> Error (Protocol_failed "private companion handshake refused") in
                (match value with
                 | `Assoc fields when List.sort String.compare (List.map fst fields)=["tools";"version"] ->
                   (match List.assoc "version" fields,List.assoc "tools" fields with
                    | `Int 3,`List names ->
                      let* names=List.fold_left (fun result -> function
                        | `String name when List.mem name t.contract.exported_tools -> Result.map (fun names -> name::names) result
                        | _ -> Error (Protocol_failed "invalid companion export name")) (Ok []) names in
                      if List.length names=List.length (List.sort_uniq String.compare names) then Ok (List.rev names)
                      else Error (Protocol_failed "duplicate companion export")
                    | _ -> Error (Protocol_failed "unsupported private companion handshake"))
                 | _ -> Error (Protocol_failed "invalid private companion handshake"))
            | [_] -> Error (Invalid_contract "private companion requires host-context invocation")
            | _ -> Error (Protocol_failed "duplicate private companion handshake") in
          (* Only an explicit schema marker opts into the worker's word on
             which exports leave its observation as it was. Absent or ambiguous
             opt-in declares nothing; a malformed reply refuses Ready. *)
          (* An existing package can already use this name as its action or an
             export. Its declared role wins over the new private handshake. *)
          let effect_name = Lane_addon_call_context.effects_tool in
          let module Export_names = Set.Make (String) in
          let export_names = List.fold_left (fun names name -> Export_names.add name names)
            Export_names.empty t.contract.exported_tools in
          let* observation_effects = if t.contract.action_tool = Some effect_name
              || Export_names.mem effect_name export_names then Ok [] else
            match List.filter (fun (tool:Mcp_protocol.Mcp_types.tool) ->
              tool.name=effect_name) tools with
            | [tool] when Lane_addon_call_context.supports_effects_tool tool.input_schema ->
                let* reply=Agent_core.Mcp.call_tool_full client ~name:Lane_addon_call_context.effects_tool
                    ~arguments:(`Assoc [])
                  |> Result.map_error (fun _ -> Protocol_failed "observation effect handshake failed") in
                (match reply.is_error,reply.structured_content with
                 | (None|Some false),Some value ->
                     Lane_addon_call_context.effects_of_json
                       ~listed:(List.map (fun (tool:Mcp_protocol.Mcp_types.tool) -> tool.name) tools) value
                     |> Result.map (List.filter (fun (name,_) -> Export_names.mem name export_names))
                     |> Result.map_error (fun detail -> Protocol_failed detail)
                 | Some true,_ | (None|Some false),None ->
                     Error (Protocol_failed "observation effect handshake refused"))
            | _ -> Ok [] in
          let* exported = List.fold_left (fun result name ->
            let* selected = result in
            match List.filter (fun (tool : Mcp_protocol.Mcp_types.tool) -> String.equal tool.name name) tools with
            | [tool] -> Ok (tool :: selected)
            | _ -> Error (Protocol_failed ("package must advertise exactly one exported tool: " ^ name)))
            (Ok []) t.contract.exported_tools in
          let* tool_hooks = List.fold_left (fun result (tool : Mcp_protocol.Mcp_types.tool) ->
            let* checks = result in
            let* () = if List.mem tool.name companion_tools then
                (match tool.output_schema with
                 | Some schema -> Lane_addon_companion_publication.validate_output_schema schema
                   |> Result.map_error (fun _ -> Protocol_failed "private companion output schema must be recursively closed")
                 | None -> Error (Protocol_failed "private companion output schema is required"))
              else Ok () in
            let selected_hooks=if List.mem tool.name companion_tools then
                List.sort_uniq compare (Validate_input::Validate_output::t.contract.tool_hooks) else t.contract.tool_hooks in
            let* hooks = Lane_addon_tool_hooks.prepare ~hooks:selected_hooks tool
              |> Result.map_error (fun detail -> Protocol_failed detail) in
            Ok ((tool.name, hooks) :: checks)) (Ok []) exported in
          Ok {client;tool_hooks;action_schema;operator_schema;companion_tools;observation_effects;
            exported_tools=List.rev exported}
    with
    | Eio.Cancel.Cancelled _ as exn -> revoke t; raise exn
    | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _
      | Invalid_argument _) as exn -> Error (Protocol_failed (Printexc.to_string exn)) in
  match result with
  | Error error -> revoke t; Error error
  | Ok ready -> (match t.attachment with
      | Initializing _ -> t.attachment <- Ready ready; Ok ()
      | Retired _ -> Error Stopped
      | Awaiting | Ready _ -> Error (Invalid_contract "worker initialization state changed"))

(* A call cancelled after it wrote to the worker has an effect nobody will
   learn, so the connection is retired. [reached] says whether it wrote. *)
let protect_call ?(reached = fun () -> true) t work =
  try work () with Eio.Cancel.Cancelled _ as exn -> if reached () then revoke t; raise exn

let call_operator t ~admit ~arguments =
  protect_call t (fun () ->
    Eio.Mutex.use_ro t.mutex (fun () ->
      let* ready = ready_for_call t |> Result.map_error (fun _ -> Operator_unavailable) in
      let* schema = Option.to_result ~none:Operator_unavailable ready.operator_schema in
      let* arguments = Lane_addon_action.validate_input ~schema ~name:operator_tool arguments
        |> Result.map_error (fun _ -> Operator_rejected) in
      let* () = admit () in
      let* () = if revoked t then Error Operator_unavailable else Ok () in
      (* Raw replies and failures stay on this private path. In particular, do
         not use exported-tool finalizers, on_result or action receipts here. *)
      let unknown () = revoke t; Error Operator_outcome_unknown in
      try
        let* result = Agent_core.Mcp.call_tool_full ready.client ~name:operator_tool ~arguments
          |> Result.map_error (fun _ -> revoke t; Operator_outcome_unknown) in
        let* () = match t.attachment with
          | Ready current when current == ready -> Ok ()
          | Awaiting | Initializing _ | Ready _ | Retired _ -> Error Operator_outcome_unknown in
        match result.Mcp_protocol.Mcp_types.is_error, result.structured_content with
        | Some true, _ -> unknown ()
        | (Some false | None), Some (`Assoc _ as value) -> Ok value
        | (Some false | None), (Some _ | None) -> unknown ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      (* This privacy boundary deliberately erases even unexpected SDK failure
         text: parser exceptions can embed a worker response containing secrets. *)
      | _ -> unknown ()))

let observe t ~binding ~sources =
  protect_call t (fun () ->
  if revoked t then Error Stopped
  (* Cancellation must remain possible during an unresponsive request. After
     cancellation this client is retired, so no future request can consume a
     response belonging to the cancelled call. *)
  else Eio.Mutex.use_ro t.mutex (fun () ->
    if revoked t then Error Stopped
    else
      let read () =
      try
        let* client = client_for_call t in
        let* result = Agent_core.Mcp.call_tool_full client ~name:"lane_observe"
            ~arguments:(`Assoc ([ "binding", binding; "sources", sources ] @
              match t.contract.action_tool with None -> []
              | Some _ -> ["context", Lane_addon_action.context t.instance_id]))
          |> Result.map_error (fun error -> Protocol_failed (Agent_core.Error.to_string error)) in
        if revoked t then Error Stopped
        else match result.Mcp_protocol.Mcp_types.is_error with
          | Some true -> Error (Protocol_failed (Agent_core.Mcp.text_of_tool_result result))
          (* MCP permits omission of isError; only an explicit true reports
             tool failure. Structured observation validation remains required. *)
          | Some false | None ->
              match result.structured_content with
              | None -> Error (Invalid_observation "lane_observe must return structuredContent")
              | Some json ->
                  let* output = Eio_unix.run_in_systhread (fun () ->
                    Lane_addon_packet.decode ?store:t.artifact_store json)
                    |> Result.map_error (fun detail -> Invalid_observation detail) in
                  let has_history = List.exists (fun (row : row) -> List.mem_assoc "input_history" row.fields) output.rows in
                  if not has_history then Ok output else
                  let* store = match t.artifact_store with Some store -> Ok store
                    | None -> Error (Invalid_observation "machine history requires an owned artifact store") in
                  let* output = Lane_addon_machine_history.retain t.input_history ~store ~instance_id:t.instance_id
                    ~max_response_bytes:t.contract.max_reply_bytes
                    ~call:(fun ~name ~arguments ->
                      if revoked t then Error "worker stopped during input history transfer"
                      else Agent_core.Mcp.call_tool_full client ~name ~arguments
                        |> Result.map_error Agent_core.Error.to_string) output
                    |> Result.map_error (fun detail -> Invalid_observation detail) in
                  if revoked t then Error Stopped else Ok output
      with
      | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _
        | Invalid_argument _) as exn ->
          if revoked t then Error Stopped
          else Error (Protocol_failed (Printexc.to_string exn)) in
      match t.sampling_broker with
      | None -> read ()
      | Some broker -> Lane_addon_sampling.with_observation broker ~binding ~sources
          ~on_error:(fun detail -> Invalid_observation detail) read)
)

(* This call only reports transport success or the package's explicit outcome.
   Once dispatched, errors never establish that the environment was unchanged. *)
let act t ~arguments =
  protect_call t (fun () ->
  if revoked t then Error Stopped
  else Eio.Mutex.use_ro t.mutex (fun () ->
    if revoked t then Error Stopped
    else try
      let* client = client_for_call t in
      let* name, schema, store = match t.contract.action_tool, action_schema t, t.artifact_store with
        | Some name, Some schema, Some store -> Ok (name, schema, store)
        | _ -> Error (Protocol_failed "worker does not advertise an available action port") in
      let* arguments = Lane_addon_action.validate ~schema ~name arguments
        |> Result.map_error (fun detail -> Protocol_failed detail) in
      let* result = Agent_core.Mcp.call_tool_full client ~name ~arguments
        |> Result.map_error (fun error -> Protocol_failed (Agent_core.Error.to_string error)) in
      match result.Mcp_protocol.Mcp_types.is_error with
      | Some true -> Error (Protocol_failed (Agent_core.Mcp.text_of_tool_result result))
      | None | Some false ->
          (match result.structured_content with
           | None -> Error (Protocol_failed "action tool must return structuredContent")
           | Some json -> Eio_unix.run_in_systhread (fun () ->
               Lane_addon_action.decode_result ~store json)
               |> Result.map_error (fun detail -> Protocol_failed detail))
    with
    | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _ | Invalid_argument _) as exn ->
        Error (Protocol_failed (Printexc.to_string exn)))
)

type result_finalizer = name:string -> arguments:Yojson.Safe.t ->
  principal:Lane_addon_call_context.principal -> result:Mcp_protocol.Mcp_types.tool_result ->
  (Mcp_protocol.Mcp_types.tool_result, string) result
type companion_admission = {context:Lane_addon_call_context.companion;admit:unit -> bool}
let call_exported_tool ?(on_result = fun _ -> ()) ?(on_dispatch = fun () -> ()) ?companion
    ?(finalize_result = fun ~name:_ ~arguments:_ ~principal:_ ~result -> Ok result)
    ?authorize ?(principal = Lane_addon_call_context.Anonymous) t ~name ~arguments =
  (* A call cancelled while it waits for the RPC mutex, or in its mediation
     before its first RPC, wrote nothing, and the session stays as it was. *)
  let dispatched = ref false in
  let on_dispatch () = dispatched := true; on_dispatch () in
  protect_call ~reached:(fun () -> !dispatched) t (fun () ->
  if revoked t then Error Stopped
  else
      let* ready = ready_for_call t in
      let* ()=match companion with
        | None when List.mem name ready.companion_tools ->
            Error (Host_refusal (Lane_addon_call_context.Unavailable "private companion grant is required"))
        | None -> Ok ()
        | Some _ when List.mem name ready.companion_tools -> Ok ()
        | Some _ -> Error (Host_refusal (Lane_addon_call_context.Rejected "tool has no private companion grant")) in
      let* () = if List.exists (fun (tool : Mcp_protocol.Mcp_types.tool) ->
          String.equal tool.name name) ready.exported_tools then Ok ()
        else Error (Protocol_failed "tool is not exported by this worker") in
      let client = ready.client in
      let* hooks = match List.assoc_opt name ready.tool_hooks with
        | Some hooks -> Ok hooks
        | None -> Error (Protocol_failed "exported tool middleware is unavailable") in
      let* () = Lane_addon_tool_hooks.before_call hooks arguments
        |> Result.map_error (fun detail -> Host_refusal (Lane_addon_call_context.Rejected detail)) in
      let call ~name ~arguments =
        Eio.Mutex.use_ro t.mutex (fun () ->
          let admitted=not (revoked t) && (match companion with None -> true | Some admission -> admission.admit ()) in
          if not admitted || revoked t
          then Error "Add-on worker is unavailable"
          else (on_dispatch ();
            Agent_core.Mcp.call_tool_full client ~name ~arguments)
            |> Result.map (fun result -> (match companion with None -> on_result result | Some _ -> ()); result)
            |> Result.map_error (fun error -> match companion with
              | None -> Agent_core.Error.to_string error | Some _ -> "private invocation outcome unknown")) in
      try
        let* result = Lane_addon_worker_invocation.run ~invocation:t.contract.tool_invocation
          ~companion:(Option.map (fun admission -> admission.context) companion)
          ~authorize ~principal ~name ~arguments ~call
        |> Result.map_error (function
          | Lane_addon_call_context.Host_refusal refusal -> Host_refusal refusal
          | Transport_error detail -> Protocol_failed (match companion with
              | None -> detail | Some _ -> "private invocation outcome unknown")) in
        let validate_result result = Lane_addon_tool_hooks.after_call hooks result
          |> Result.map_error (fun detail -> Protocol_failed (match companion with
            | None -> "tool result rejected after dispatch: " ^ detail
            | Some _ -> "private invocation public result rejected")) in
        let* result = match companion with
          | None -> Ok result
          | Some _ ->
            let* () = validate_result result in
            Ok (companion_public_result result) in
        let* result = (try finalize_result ~name ~arguments ~principal ~result with
          | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
          | exn -> Error (match companion with None -> Printexc.to_string exn | Some _ -> "private invocation finalization failed"))
          |> Result.map_error (fun detail -> Protocol_failed (match companion with
            | None -> "tool result finalization failed after dispatch: " ^ detail
            | Some _ -> "private invocation finalization failed")) in
        let* () = validate_result result in
        let result=match companion with
          | None -> result
          | Some _ -> companion_public_result result in
        (match companion with Some _ -> on_result result | None -> ());
        Ok result
      with
      | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _ | Invalid_argument _) as exn ->
          Error (Protocol_failed (match companion with None -> Printexc.to_string exn | Some _ -> "private invocation outcome unknown")))

let call_host_tool t ~name ~arguments = protect_call t (fun () ->
  if not t.contract.host_requests then Error (Protocol_failed "worker contract has no host request ports")
  else Eio.Mutex.use_ro t.mutex (fun () ->
    let* ready=ready_for_call t in
    try
      let* result=Agent_core.Mcp.call_tool_full ready.client ~name ~arguments
        |> Result.map_error (fun error -> Protocol_failed (Agent_core.Error.to_string error)) in
      match result.Mcp_protocol.Mcp_types.is_error with
      | Some true -> Error (Protocol_failed (Agent_core.Mcp.text_of_tool_result result))
      | None|Some false -> Option.to_result ~none:(Protocol_failed (name ^ " must return structuredContent")) result.structured_content
    with
    | (Eio.Io _|Unix.Unix_error _|Sys_error _|End_of_file|Failure _|Invalid_argument _) as exn ->
        Error (Protocol_failed (Printexc.to_string exn))))
let host_requests t = call_host_tool t ~name:host_requests_tool ~arguments:(`Assoc [])
let host_result t ~arguments = call_host_tool t ~name:host_result_tool ~arguments
