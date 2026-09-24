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

let dispatch ?caller state operation args =
  Runtime.dispatch ?caller ~config:(Mcp_server.workspace_config state) ~operation args
  |> Result.map_error Runtime.error_to_string

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
    let result = let* args = decode_inspect_query (query_fields request) in
      dispatch state Runtime.Inspect args in
    respond request reqd result) request reqd

let get_package_preview request reqd =
  with_read_auth (fun state _request reqd ->
    let result =
      let* path = match query_fields request with
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
      let base = Exec_policy_paths.resolve_path config.Workspace.base_path in
      let resolved =
        Exec_policy_paths.resolve_path ~base_dir:config.Workspace.base_path path
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
                  "image",image]) in
    respond request reqd result) request reqd

let get_slice request reqd =
  with_read_auth (fun state _request reqd ->
    let result = let* args = decode_slice_query (query_fields request) in dispatch state Runtime.Slice args in
    respond request reqd result) request reqd

let get_action request reqd =
  with_read_auth (fun state _request reqd ->
    let result =
      let fields = query_fields request |> List.sort (fun (a, _) (b, _) -> String.compare a b) in
      let* args = match fields with
        | ["instance_id", instance_id; "request_id", request_id]
            when String.trim instance_id <> "" && String.trim request_id <> "" ->
            Ok (`Assoc ["instance_id", `String instance_id; "request_id", `String request_id])
        | _ -> Error "action status requires exactly instance_id and request_id" in
      dispatch state Runtime.Action_status args in
    respond request reqd result) request reqd

(* Use the source binding's kind table so a new kind must say whether it has a
   current screen before the live route can decode it. *)
type screen_source = Lane_addon_sources.live_reader = Msx_screen | Dos_screen

let screen_source_kind = function
  | Msx_screen -> "msx_capture"
  | Dos_screen -> "dos_capture"

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
                   (match Lane_addon_sources.live_screen_of_kind kind with
                    | Some screen -> Ok screen
                    | None ->
                        Error (raw ^ " has no screen to watch; live accepts msx_capture and dos_capture"))) in
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

let screen_json ~width ~height ~rgb =
  "screen", `Assoc [ "format", `String "rgb8"; "width", `Int width; "height", `Int height
                   ; "rgb_base64", `String (Base64.encode_string rgb) ]

type live_answer = Answered of Yojson.Safe.t | Needs_locked_read

(* The lock-free half of a live read. [current] is the machine's published
   mark, read without its lock. No machine and a [since] that still names it
   are answered here, on the request fiber, with no systhread; only a mark
   that moved needs the locked read, which runs in a systhread. *)
let answer_from_mark source ~since ~current =
  match current, since with
  | None, (Some _ | None) -> Answered (no_machine_json source)
  | Some (count, incarnation), Some seen
    when seen.count = count && String.equal seen.incarnation incarnation ->
      Answered (`Assoc (marked_json source "unchanged" ~count ~incarnation))
  | Some _, (Some _ | None) -> Needs_locked_read

let live_from_published_mark source ~since =
  let current =
    match source with
    | Msx_screen ->
        Option.map (fun { Msx_lane.count; incarnation } -> (count, incarnation))
          (Msx_lane.current_mark ())
    | Dos_screen ->
        Option.map (fun { Dos_lane.count; incarnation } -> (count, incarnation))
          (Dos_lane.current_mark ()) in
  answer_from_mark source ~since ~current

(* The locked half: the lane compares again and copies under one hold, so a
   Changed mark always names its pixels. It writes nothing. *)
let msx_live source ~since () : Yojson.Safe.t =
  let since = Option.map (fun { count; incarnation } -> { Msx_lane.count; incarnation }) since in
  match Msx_lane.live ~since with
  | Msx_lane.Nothing_loaded -> no_machine_json source
  | Msx_lane.Unchanged { count; incarnation } ->
      `Assoc (marked_json source "unchanged" ~count ~incarnation)
  | Msx_lane.Changed ({ count; incarnation }, frame) ->
      `Assoc (marked_json source "changed" ~count ~incarnation @
        [ "frame_number", `Int frame.Msx_lane.number
        ; screen_json ~width:frame.Msx_lane.width ~height:frame.Msx_lane.height
            ~rgb:frame.Msx_lane.rgb ])

let dos_live source ~since () : Yojson.Safe.t =
  let since = Option.map (fun { count; incarnation } -> { Dos_lane.count; incarnation }) since in
  match Dos_lane.live ~since with
  | Dos_lane.Nothing_loaded -> no_machine_json source
  | Dos_lane.Unchanged { count; incarnation } ->
      `Assoc (marked_json source "unchanged" ~count ~incarnation)
  | Dos_lane.Changed ({ count; incarnation }, frame) ->
      `Assoc (marked_json source "changed" ~count ~incarnation @
        [ screen_json ~width:frame.Dos_lane.width ~height:frame.Dos_lane.height
            ~rgb:frame.Dos_lane.rgb ])

let live_json source ~since : Yojson.Safe.t =
  match live_from_published_mark source ~since with
  | Answered json -> json
  | Needs_locked_read ->
      (match source with
       | Msx_screen -> Eio_unix.run_in_systhread (msx_live source ~since)
       | Dos_screen -> Eio_unix.run_in_systhread (dos_live source ~since))

let get_live request reqd =
  with_read_auth (fun _state _request reqd ->
    match decode_live_query (query_fields request) with
    | Error detail -> respond request reqd (Error detail)
    | Ok (source, since) ->
        Http.Response.json_value_on_cpu ~compress:true ~request
          ~extra_headers:(cors_headers (get_origin request)) (live_json source ~since) reqd)
    request reqd

let post ~operation ~tool_name request reqd =
  with_tool_actor_auth ~tool_name (fun state caller _request reqd ->
    Http.Request.read_body_async reqd (fun body ->
      let result = let* args = decode_body body in dispatch ~caller state operation args in
      respond request reqd result)) request reqd

let respond_declaration request reqd = function
  | Ok json -> respond_json_value_with_cors request reqd json
  | Error (error : Lane_addon_declaration.error) ->
      let status = match error.code with
        | Invalid_request | Invalid_declaration -> `Bad_request
        | Not_found -> `Not_found | Revision_conflict -> `Conflict | Io_error -> `Internal_server_error in
      respond_json_value_with_cors ~status request reqd (Lane_addon_declaration.error_to_json error)

let read_declaration request reqd =
  with_tool_actor_auth ~tool_name:"masc_lane_declaration_read" (fun state _caller _request reqd ->
    let args = `Assoc (List.map (fun (key,value) -> key,`String value) (query_fields request)) in
    respond_declaration request reqd (Runtime.read_declaration ~config:(Mcp_server.workspace_config state) args)) request reqd

let save_declaration request reqd =
  with_tool_actor_auth ~tool_name:"masc_lane_declaration_save" (fun state _caller _request reqd ->
    Http.Request.read_body_async reqd (fun body ->
      let result = match decode_body body with
        | Error message -> Error {Lane_addon_declaration.code=Invalid_request;message;current=None}
        | Ok args -> Runtime.save_declaration ~config:(Mcp_server.workspace_config state) args in
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
  |> Http.Router.get "/api/v1/lane-addons/package-preview" get_package_preview
  |> Http.Router.post "/api/v1/lane-addons/subscriptions"
       (with_tool_actor_auth ~tool_name:"masc_lane_updates" (fun state caller request reqd ->
         Http.Request.read_body_async reqd (fun body ->
           let result = let* args=decode_body body in
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Lane_addon_subscription.handle ~config:(Mcp_server.workspace_config state) ~caller args) in
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
