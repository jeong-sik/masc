open Server_auth
module Http = Http_server_eio
module Runtime = Lane_addon_runtime

let ( let* ) = Result.bind
let error_json message = `Assoc ["error", `String message]
let decode_body body =
  try match Yojson.Safe.from_string body with
    | `Assoc fields as json ->
        let names = List.map fst fields in
        if List.length names = List.length (List.sort_uniq String.compare names)
        then Ok json else Error "duplicate request field"
    | _ -> Error "request body must be a JSON object"
  with Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)

let decode_slice_query fields =
  let names = List.map fst fields in
  if List.length names <> List.length (List.sort_uniq String.compare names)
  then Error "duplicate query field"
  else
    let rec parse acc = function
      | [] -> Ok (`Assoc (List.rev acc))
      | (name, value) :: rest ->
          let* parsed = match name with
            | "run_id" | "lane_id" ->
                if String.trim value = "" then Error (name ^ " must not be blank")
                else Ok (`String value)
            | "since" | "until" ->
                (match float_of_string_opt value with
                 | Some value when Float.is_finite value -> Ok (`Float value)
                 | Some _ | None -> Error (name ^ " must be finite Unix seconds"))
            | _ -> Error ("unknown slice parameter: " ^ name) in
          parse ((name, parsed) :: acc) rest
    in
    let* json = parse [] fields in
    match json with
    | `Assoc fields ->
        (match List.assoc_opt "since" fields, List.assoc_opt "until" fields with
         | Some (`Float since), Some (`Float until) when since > until -> Error "since must be <= until"
         | _ -> Ok json)
    | _ -> Error "slice query must be an object"

let respond request reqd = function
  | Ok json -> respond_json_value_with_cors request reqd json
  | Error detail -> respond_json_value_with_cors ~status:`Bad_request request reqd (error_json detail)

let dispatch ?caller ?access state operation args =
  Runtime.dispatch ?caller ?access ~config:(Mcp_server.workspace_config state) ~operation args
  |> Result.map_error Runtime.error_to_string

let source_access state request caller =
  let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
  match request_credential_standing ~base_path request with
  | Operator_credential -> Lane_addon_sources.Operator_configuration
  | Agent_credential -> Lane_addon_sources.Keeper caller
  | Player_credential | No_credential -> Lane_addon_sources.Unauthenticated

let broadcast_principal_for_standing standing caller =
  match standing with
  | Operator_credential when String.trim caller <> "" ->
      Ok ("principal:operator:" ^ caller)
  | Agent_credential when String.trim caller <> "" ->
      Ok ("principal:keeper:" ^ caller)
  | Operator_credential | Agent_credential
  | Player_credential | No_credential ->
      Error "Broadcast recovery requires an authenticated operator or Keeper principal"

let broadcast_principal ~base_path request caller =
  broadcast_principal_for_standing
    (request_credential_standing ~base_path request) caller

let read_context state request =
  let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
  match dashboard_actor_resolution_for_request ~base_path request with
  | Authenticated_actor caller -> Ok (Some caller, source_access state request caller)
  | Anonymous_actor_hint _ -> Ok (None, Lane_addon_sources.Unauthenticated)
  | Rejected_credential _ -> Error "Lane read credential is unavailable"

let query_fields request =
  Uri.query (Uri.of_string request.Httpun.Request.target)
  |> List.concat_map (fun (name, values) ->
       match values with [] -> [name, ""] | values -> List.map (fun value -> name, value) values)

let decode_inspect_query = function
  | [] -> Ok (`Assoc [])
  | ["instance_id", id] when String.trim id <> "" -> Ok (`Assoc ["instance_id", `String id])
  | _ -> Error "inspect accepts one non-blank instance_id or no parameters"

let get_inspect request reqd =
  with_read_auth (fun state _request reqd ->
    let result = let* caller, access = read_context state request in
      let* args = decode_inspect_query (query_fields request) in
      dispatch ?caller ~access state Runtime.Inspect args in
    respond request reqd result) request reqd

let package_catalog_payload state fields =
  let* directory = match fields with
    | [] -> Ok None
    | ["directory",path] when String.trim path <> "" -> Ok (Some path)
    | _ -> Error "package catalog accepts one nonblank directory or no parameters" in
  let config = Mcp_server.workspace_config state in
  Eio_unix.run_in_systhread (fun () ->
    Lane_addon_catalog.discover ~base_path:config.Workspace.workspace_path ~directory
      ~load_package:(fun ~path ->
        Lane_addon_manifest.load ~path
        |> Result.map_error Lane_addon_manifest.error_to_string
        |> Result.map (fun (package : Lane_addon_types.package) -> Lane_addon_catalog.{title=package.title;
          revision=package.revision; description=package.presentation.description})))
  |> Result.map Lane_addon_catalog.to_json

let package_preview_payload state fields =
  let* path = match fields with
    | ["manifest_path",path] when String.trim path<>"" -> Ok path
    | _ -> Error "package preview requires one manifest_path" in
  let config = Mcp_server.workspace_config state in
  (* The only filesystem path this API takes from a request. Relative
     names are read against the workspace, and the result has to stay
     there: without this an absolute name was opened as given, and a
     relative one kept its [..], so a read token reached any manifest on
     the host and the parse error told the caller what sat at a path it
     could not otherwise see. Symlinks resolve first, so a link inside
     the workspace cannot point out of it either.

     The refusal names no path and does not say whether one exists,
     which is why a missing file outside the workspace and a real one
     read alike. *)
  let base = Exec_policy_paths.resolve_path config.Workspace.workspace_path in
  let resolved =
    Exec_policy_paths.resolve_path ~base_dir:config.Workspace.workspace_path path
  in
  let* path =
    if Exec_policy_paths.is_within_dir ~dir:base resolved then Ok resolved
    else Error "manifest_path must name a file inside the workspace" in
  let* package = Eio_unix.run_in_systhread (fun () -> Lane_addon_manifest.load ~path)
      |> Result.map_error Lane_addon_manifest.error_to_string in
  let inspection = match state.Mcp_server.proc_mgr, Eio_context.get_clock () with
    | None, _ -> Error "Server process manager unavailable; image inspection was not performed"
    | Some _, Error message -> Error message
    | Some mgr, Ok clock -> Lane_addon_worker.inspect_image
        ~clock ~control_timeout_sec:Env_config_runtime.Sidecar.control_command_timeout_sec
        ~mgr ~package () |> Result.map_error Lane_addon_worker.error_to_string in
  let image = match inspection with
    | Ok digest -> `Assoc ["state",`String "available";"digest",`String digest]
    | Error detail -> `Assoc ["state",`String "unverified";"detail",`String detail] in
  Ok (`Assoc ["manifest_path",`String path;"package",Lane_addon_types.package_to_json package;
              "image",image])


let get_package_catalog request reqd =
  with_read_auth (fun state _request reqd ->
    respond request reqd (package_catalog_payload state (query_fields request))) request reqd

let get_package_preview request reqd =
  with_read_auth (fun state _request reqd ->
    respond request reqd (package_preview_payload state (query_fields request))) request reqd

let get_slice request reqd =
  with_read_auth (fun state _request reqd ->
    let result = let* caller, access = read_context state request in
      let* args = decode_slice_query (query_fields request) in dispatch ?caller ~access state Runtime.Slice args in
    respond request reqd result) request reqd

let get_action request reqd =
  with_read_auth (fun state _request reqd ->
    let result =
      let* caller, access = read_context state request in
      let fields = query_fields request |> List.sort (fun (a, _) (b, _) -> String.compare a b) in
      let* args = match fields with
        | ["instance_id", instance_id; "request_id", request_id]
            when String.trim instance_id <> "" && String.trim request_id <> "" ->
            Ok (`Assoc ["instance_id", `String instance_id; "request_id", `String request_id])
        | _ -> Error "action status requires exactly instance_id and request_id" in
      dispatch ?caller ~access state Runtime.Action_status args in
    respond request reqd result) request reqd

(* Use the source binding's kind table so a new kind must say whether it has a
   current screen before the live route can decode it. *)
let screen_source_kind machine =
  Lane_addon_sources.(kind_to_string (kind_of_machine machine))

type since = { count : int; incarnation : string }

let decode_live_query fields =
  let names = List.map fst fields in
  if List.length names <> List.length (List.sort_uniq String.compare names)
  then Error "duplicate query field"
  else
    match List.find_opt (fun name -> not (List.mem name ["source_kind"; "since"; "incarnation"])) names with
    | Some name -> Error ("unknown live parameter: " ^ name)
    | None ->
        let* source = match List.assoc_opt "source_kind" fields with
          | None -> Error "live requires source_kind"
          | Some raw ->
              (match Lane_addon_sources.kind_of_string raw with
               | None -> Error ("unknown source_kind: " ^ raw)
               | Some kind ->
                   (match Lane_addon_sources.machine_of_kind kind with
                    | Some machine -> Ok machine
                    | None ->
                        Error
                          (raw ^ " has no screen to watch; live accepts "
                           ^ String.concat " and " (List.map screen_source_kind Machine_lane.all)))) in
        (* Decimal digits only: int_of_string_opt also reads 0x10 and 1_000.
           Digits it still cannot read overflow an int. *)
        let count_of value =
          if value = "" || not (String.for_all (function '0' .. '9' -> true | _ -> false) value)
          then Error "since must be a nonnegative decimal integer"
          else match int_of_string_opt value with
            | Some count -> Ok count
            | None -> Error "since is too large to be a change count" in
        let* since = match List.assoc_opt "since" fields, List.assoc_opt "incarnation" fields with
          | None, None -> Ok None
          | Some _, Some "" -> Error "incarnation must be non-empty"
          | Some value, Some incarnation ->
              let* count = count_of value in
              Ok (Some { count; incarnation })
          | Some _, None | None, Some _ ->
              Error "since and incarnation come together: a count alone can repeat after a server restart" in
        Ok (source, since)

let marked_json source state ~count ~incarnation =
  [ "source_kind", `String (screen_source_kind source); "state", `String state
  ; "change_count", `Int count; "incarnation", `String incarnation ]

let no_machine_json source =
  `Assoc [ "source_kind", `String (screen_source_kind source); "state", `String "no_machine" ]

type live_answer = Answered of Yojson.Safe.t | Needs_locked_read

(* Both lanes publish the same three states. A running machine cannot answer
   unchanged from a mark it published before finishing the current run. *)
type screen_publication = since Machine_live_publication.t

let answer_from_publication source ~since = function
  | Machine_live_publication.No_screen -> Answered (no_machine_json source)
  | Machine_live_publication.Stable { count; incarnation } ->
      (match since with
       | Some seen when seen.count = count && String.equal seen.incarnation incarnation ->
           Answered (`Assoc (marked_json source "unchanged" ~count ~incarnation))
       | Some _ | None -> Needs_locked_read)
  | Machine_live_publication.Running _ -> Needs_locked_read

let live_json ~config source ~since =
  let name = match source with Machine_lane.Msx -> "masc_msx_screen" | Dos -> "masc_dos_screen" in
  let* snapshot = Lane_addon_runtime.observation_for_export ~config
    ~access:Lane_addon_sources.Unauthenticated ~name in
  match snapshot with
  | None -> Error "No attached shared machine worker is available"
  | Some snapshot ->
      let references = List.filter_map (fun (row : Lane_addon_types.row) ->
        Option.map (fun value -> row.evidence,value) (List.assoc_opt "machine_live" row.fields)) snapshot.output.rows in
      let* matches = match references with
        | [evidence,value] ->
            let* reference = Lane_addon_types.evidence_of_json value in
            let* () = if List.mem reference evidence then Ok () else Error "machine screen is not declared as row evidence" in
            let store = Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
            let* bytes = Eio_unix.run_in_systhread (fun () -> Lane_addon_store.read_blob ~max_bytes:snapshot.max_bytes store reference) in
            (try Ok [Yojson.Safe.from_string bytes] with Yojson.Json_error detail -> Error detail)
        | _ -> Error "worker observation does not provide one machine screen reference" in
      (* Blob I/O yields: an installation can detach or publish a newer frame
         before these bytes return. Only publish the still-current observation. *)
      let* current = Lane_addon_runtime.observation_for_export ~config
        ~access:Lane_addon_sources.Unauthenticated ~name in
      let* refreshing = match current with
        | Some current when current.instance_id = snapshot.instance_id
            && current.observation_seq = snapshot.observation_seq ->
            Ok (snapshot.refreshing || current.refreshing)
        | _ -> Error "machine observation changed while reading its screen" in
      (match matches with
       | [`Assoc fields] when List.assoc_opt "source_kind" fields = Some (`String (screen_source_kind source)) ->
           let status = List.assoc_opt "state" fields in
           let* result = match status with
             | Some (`String "no_machine") -> Ok (`Assoc fields)
             | Some (`String "changed") ->
                 (match List.assoc_opt "change_count" fields, List.assoc_opt "incarnation" fields,
                        List.assoc_opt "screen" fields with
                  | Some (`Int count), Some (`String incarnation), Some (`Assoc _)
                    when count >= 0 && incarnation <> "" ->
                      let publication = if refreshing then
                        Machine_live_publication.Running {count;incarnation}
                        else Machine_live_publication.Stable {count;incarnation} in
                      (match answer_from_publication source ~since publication with
                       | Needs_locked_read -> Ok (`Assoc fields)
                       | Answered (`Assoc unchanged) ->
                           Ok (`Assoc (unchanged @ (match List.assoc_opt "activity" fields with
                             | None -> [] | Some activity -> ["activity",activity])))
                       | Answered json -> Ok json)
                  | _ -> Error "invalid worker machine screen snapshot")
             | _ -> Error "worker observation must contain a complete machine screen" in
           (match result with `Assoc fields -> Ok (`Assoc (fields @ [
             "observation_seq", `Int snapshot.observation_seq; "refreshing", `Bool refreshing]))
            | _ -> Ok result)
       | _ -> Error "worker observation does not provide one matching machine screen")

(* An invited Player holds CanPlayMachine and no CanReadState: it watches
   the machine here and reads nothing else. Workers and Admins hold both. *)
(* A terminal that just changed the machine names the workspace it read, so a
   server swapped onto the same port between the change and this read answers
   409 instead of handing its picture to the wrong view. Both fields or neither;
   the live query decoder never sees them. *)
let live_workspace_precondition ~config fields =
  let names = ["expected_base_path"; "expected_masc_root"] in
  let expected, rest = List.partition (fun (name, _) -> List.mem name names) fields in
  match expected with
  | [] -> Ok rest
  | _ ->
    (match List.assoc_opt "expected_base_path" expected, List.assoc_opt "expected_masc_root" expected with
     | Some base, Some root when List.length expected = 2 ->
       let precondition =
         `Assoc [ "expected_workspace", `Assoc [ "base_path", `String base; "masc_root", `String root ] ] in
       (match Workspace.validate_expected_workspace ~config precondition with
        | Ok _ -> Ok rest
        | Error Workspace.Invalid_workspace_precondition ->
          Error (`Bad_request, "invalid expected_workspace precondition")
        | Error Workspace.Workspace_precondition_failed ->
          Error (`Conflict, "workspace precondition failed"))
     | _ -> Error (`Bad_request, "live takes expected_base_path and expected_masc_root together"))

let get_live request reqd =
  with_permission_auth ~permission:Masc_domain.CanPlayMachine (fun state _request reqd ->
    match live_workspace_precondition ~config:(Mcp_server.workspace_config state) (query_fields request) with
    | Error (status, detail) ->
        respond_json_value_with_cors ~status request reqd (error_json detail)
    | Ok fields ->
    match decode_live_query fields with
    | Error detail -> respond request reqd (Error detail)
    | Ok (source, since) ->
        (match live_json ~config:(Mcp_server.workspace_config state) source ~since with
         | Ok json -> Http.Response.json_value_on_cpu ~compress:true ~request
             ~extra_headers:(cors_headers (get_origin request)) json reqd
         | Error detail -> respond_json_value_with_cors ~status:`Service_unavailable request reqd
             (Server_refusal.json ~code:"machine_observation_unavailable" detail)))
    request reqd

let post ~operation ~tool_name request reqd =
  with_tool_actor_auth ~tool_name (fun state caller _request reqd ->
    Http.Request.read_body_async reqd (fun body ->
      let result = let* args = decode_body body in dispatch ~caller ~access:(source_access state request caller) state operation args in
      respond request reqd result)) request reqd

let respond_declaration request reqd = function
  | Ok json -> respond_json_value_with_cors request reqd json
  | Error (error : Lane_addon_declaration.error) ->
      let status = match error.code with
        | Invalid_request | Invalid_declaration -> `Bad_request
        | Not_found -> `Not_found | Revision_conflict -> `Conflict | Io_error -> `Internal_server_error in
      respond_json_value_with_cors ~status request reqd (Lane_addon_declaration.error_to_json error)

let read_declaration request reqd =
  with_tool_actor_auth ~tool_name:"masc_lane_declaration_read" (fun state caller _request reqd ->
    let args = `Assoc (List.map (fun (key,value) -> key,`String value) (query_fields request)) in
    respond_declaration request reqd (Runtime.read_declaration ~access:(source_access state request caller) ~config:(Mcp_server.workspace_config state) args)) request reqd

let save_declaration request reqd =
  with_tool_actor_auth ~tool_name:"masc_lane_declaration_save" (fun state caller _request reqd ->
    Http.Request.read_body_async reqd (fun body ->
      let result = match decode_body body with
        | Error message -> Error {Lane_addon_declaration.code=Invalid_request;message;current=None}
        | Ok args -> Runtime.save_declaration ~access:(source_access state request caller) ~config:(Mcp_server.workspace_config state) args in
      respond_declaration request reqd result)) request reqd

let register_delivery ~sw ~clock =
  Runtime.register_delivery_handler (fun ~config ~caller ~keeper_name ~prompt ->
    match current_server_state () with
    | None -> Error "server state is unavailable for Keeper evidence delivery"
    | Some state ->
        let current_config = Mcp_server.workspace_config state in
        if not (String.equal config.Workspace.base_path current_config.Workspace.base_path)
        then Error "evidence belongs to a different workspace"
        else
          let context : _ Keeper_tool_surface.context = {
            config; agent_name = caller; sw; clock;
            proc_mgr = state.Mcp_server.proc_mgr; net = state.Mcp_server.net;
            publication_recovery_provider = Mcp_server.publication_recovery_availability_provider state;
          } in
          let* message = Keeper_invocation_contract.direct_message
            ~keeper_name ~prompt ~direct_reply:true
            ~surface_context:(`Assoc ["kind", `String "lane_addon_evidence"; "optional", `Bool true])
            ~channel:"" ~user_blocks:[] ~attachments:[] ()
            |> Result.map_error Keeper_invocation_contract.request_error_to_string in
          let result = Keeper_tool_surface.dispatch_keeper_msg ~submitted_by:caller context ~message in
          match result with
          | Tool_result.Completed _ | Tool_result.Deferred _ -> Ok (Tool_result.to_json result)
          | Tool_result.Failed failure -> Error failure.message)

let add_routes ~sw ~clock router =
  register_delivery ~sw ~clock;
  router
  |> Http.Router.get "/api/v1/lane-addons/broadcast-principal"
       (with_tool_actor_auth ~tool_name:"masc_lane_evidence" (fun state caller request reqd ->
         let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
         let result = broadcast_principal ~base_path request caller
           |> Result.map (fun principal -> `Assoc ["principal",`String principal]) in
         respond request reqd result))
  |> Http.Router.get "/api/v1/lane-addons/package-catalog" get_package_catalog
  |> Http.Router.get "/api/v1/lane-addons/package-preview" get_package_preview
  |> Http.Router.post "/api/v1/lane-addons/subscriptions"
       (with_tool_actor_auth ~tool_name:"masc_lane_updates" (fun state caller request reqd ->
         Http.Request.read_body_async reqd (fun body ->
           let result = let* args=decode_body body in
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Lane_addon_subscription.handle ~access:(source_access state request caller) ~config:(Mcp_server.workspace_config state) ~caller args) in
           respond request reqd result)))
  |> Http.Router.get "/api/v1/lane-addons/declaration" read_declaration
  |> Http.Router.post "/api/v1/lane-addons/declaration" save_declaration
  |> Http.Router.get "/api/v1/lane-addons" get_inspect
  |> Http.Router.get "/api/v1/lane-addons/slice" get_slice
  |> Http.Router.get "/api/v1/lane-addons/actions" get_action
  |> Http.Router.get "/api/v1/lane-addons/live" get_live
  |> Http.Router.post "/api/v1/lane-addons/actions" (post ~operation:Runtime.Act ~tool_name:"masc_lane_act")
  |> Http.Router.post "/api/v1/lane-addons/attach" (post ~operation:Runtime.Attach ~tool_name:"masc_lane_attach")
  |> Http.Router.post "/api/v1/lane-addons/observe" (post ~operation:Runtime.Observe ~tool_name:"masc_lane_observe")
  |> Http.Router.post "/api/v1/lane-addons/detach" (post ~operation:Runtime.Detach ~tool_name:"masc_lane_detach")
  |> Http.Router.post "/api/v1/lane-addons/evidence" (post ~operation:Runtime.Evidence ~tool_name:"masc_lane_evidence")
