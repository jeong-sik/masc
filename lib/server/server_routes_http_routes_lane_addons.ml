open Server_auth
module Http = Http_server_eio
module Runtime = Lane_addon_runtime

open Result.Syntax
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

(* Route errors share [Server_auth.request_error] with the schedule routes.
   Access resolution only ever fails one way, so it carries its own
   single-constructor error and the call sites map it. *)
type source_access_error = Source_credential_unreadable

let respond_unavailable request reqd =
  respond_json_value_with_cors ~status:`Service_unavailable request reqd
    (error_json "credential store is unavailable; retry")

let source_access state request caller =
  let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
  match request_credential_standing ~base_path request with
  | Operator_credential -> Ok Lane_addon_sources.Operator_configuration
  | Agent_credential -> Ok (Lane_addon_sources.Keeper caller)
  | Player_credential | No_credential -> Ok Lane_addon_sources.Unauthenticated
  (* The route admitted the request on an earlier read; narrowing an
     operator to Unauthenticated on a later read failure would silently
     shrink what they may see or change. Callers answer 503. *)
  | Unreadable_credential -> Error Source_credential_unreadable

let broadcast_principal_for_standing standing caller =
  match standing with
  | Operator_credential when String.trim caller <> "" ->
      Ok ("principal:operator:" ^ caller)
  | Agent_credential when String.trim caller <> "" ->
      Ok ("principal:keeper:" ^ caller)
  | Operator_credential | Agent_credential
  | Player_credential | No_credential ->
      Error "Broadcast recovery requires an authenticated operator or Keeper principal"
  (* Fail closed for direct callers. The route screens this standing first
     and answers 503 (see [broadcast_principal]), so this arm never sets
     the route's status. *)
  | Unreadable_credential -> Error "credential store is unavailable; retry"

let broadcast_principal ~base_path request caller =
  match request_credential_standing ~base_path request with
  | Unreadable_credential -> Error Credential_store_unreadable
  | Operator_credential | Agent_credential | Player_credential | No_credential as standing ->
    broadcast_principal_for_standing standing caller
    |> Result.map_error (fun detail -> Bad_request_detail detail)

let read_context state request =
  let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
  match dashboard_actor_resolution_for_request ~base_path request with
  | Authenticated_actor caller ->
    let* access =
      source_access state request caller
      |> Result.map_error (fun Source_credential_unreadable -> Credential_store_unreadable)
    in
    Ok (Some caller, access)
  | Anonymous_actor_hint _ -> Ok (None, Lane_addon_sources.Unauthenticated)
  (* A credential the store could not read is the server's failure, not a
     bad request: answer 503 so the client retries. Only a store that
     failed to answer qualifies; a refused or absent credential stays a
     400. Every outcome is named: no catch-all may silently adopt a future
     rejection. *)
  | Rejected_credential
      (Auth_error_kind.Outcome_error
         { err =
             Masc_domain.System
               (Masc_domain.System_error.IoError _
               | Masc_domain.System_error.LockContention _)
         ; _
         }) ->
      Error Credential_store_unreadable
  (* The complement names every remaining error constructor, mirroring
     [Server_auth.request_credential_standing]: a wildcard over [err]
     here would silently adopt future errors (warning 4). *)
  | Rejected_credential
      (Auth_error_kind.Outcome_none
      | Auth_error_kind.Outcome_error
          { err =
              Masc_domain.System
                (Masc_domain.System_error.NotInitialized
                | Masc_domain.System_error.ValidationError _)
              | Masc_domain.Task _
              | Masc_domain.Agent _
              | Masc_domain.Auth _
          ; _
          }) ->
      Error (Bad_request_detail "Lane read credential is unavailable")

let query_fields request =
  Uri.query (Uri.of_string request.Httpun.Request.target)
  |> List.concat_map (fun (name, values) ->
       match values with [] -> [name, ""] | values -> List.map (fun value -> name, value) values)

let decode_inspect_query = function
  | [] -> Ok (`Assoc [])
  | ["instance_id", id] when String.trim id <> "" -> Ok (`Assoc ["instance_id", `String id])
  | _ -> Error "inspect accepts one non-blank instance_id or no parameters"

let get_inspect = (fun state request reqd ->
    match read_context state request with
    | Error Credential_store_unreadable -> respond_unavailable request reqd
    | Error (Bad_request_detail detail) -> respond request reqd (Error detail)
    | Ok (caller, access) ->
      let result = let* args = decode_inspect_query (query_fields request) in
        dispatch ?caller ~access state Runtime.Inspect args in
      respond request reqd result)

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
          revision=package.revision; description=package.presentation.description; ui_category=package.ui_category})))
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
  let execution = match package.execution with
    | Lane_addon_types.Host_process _ -> `Assoc ["kind",`String "host_process"]
    | Container container ->
        let inspection = match state.Mcp_server.proc_mgr, Eio_context.get_clock () with
          | None, _ -> Error "Server process manager unavailable; image inspection was not performed"
          | Some _, Error message -> Error message
          | Some mgr, Ok clock -> Lane_addon_worker.inspect_image
              ~clock ~control_timeout_sec:Env_config_runtime.Sidecar.control_command_timeout_sec
              ~mgr ~package () |> Result.map_error Lane_addon_worker.error_to_string in
        let image = match inspection with
          | Ok image -> `Assoc ["state",`String "available";
               "digest",`String (Lane_addon_engine.image_digest image)]
          | Error detail -> `Assoc ["state",`String "unverified";"detail",`String detail] in
        `Assoc ["kind",`String "container";"image_name",`String container.image;"image",image] in
  Ok (`Assoc ["manifest_path",`String path;"package",Lane_addon_types.package_to_json package;
              "execution",execution])


let get_package_catalog = (fun state request reqd ->
    respond request reqd (package_catalog_payload state (query_fields request)))

let get_package_preview = (fun state request reqd ->
    respond request reqd (package_preview_payload state (query_fields request)))

let get_slice = (fun state request reqd ->
    match read_context state request with
    | Error Credential_store_unreadable -> respond_unavailable request reqd
    | Error (Bad_request_detail detail) -> respond request reqd (Error detail)
    | Ok (caller, access) ->
      let result = let* args = decode_slice_query (query_fields request) in dispatch ?caller ~access state Runtime.Slice args in
      respond request reqd result)

let get_action = (fun state request reqd ->
    match read_context state request with
    | Error Credential_store_unreadable -> respond_unavailable request reqd
    | Error (Bad_request_detail detail) -> respond request reqd (Error detail)
    | Ok (caller, access) ->
      let result =
        let fields = query_fields request |> List.sort (fun (a, _) (b, _) -> String.compare a b) in
        let* args = match fields with
          | ["instance_id", instance_id; "request_id", request_id]
              when String.trim instance_id <> "" && String.trim request_id <> "" ->
              Ok (`Assoc ["instance_id", `String instance_id; "request_id", `String request_id])
          | _ -> Error "action status requires exactly instance_id and request_id" in
        dispatch ?caller ~access state Runtime.Action_status args in
      respond request reqd result)

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

(* One machine frame is the same bytes for every watcher until the worker
   publishes the next observation. Building and compressing those bytes per
   request made each guest's 300 ms poll re-read, re-serialize and gzip the
   whole 1.2 MB frame JSON. A frame is now parsed once per published blob,
   built once per observation by whichever request comes first (the others
   wait for the same result), and each encoding is made only when a client
   first asks for it. *)
type encoded = string * (string * string) list

type live_frame = {
  etag : string;
  identity : string;
  zstd : encoded Eio.Lazy.t;
  gzip : encoded Eio.Lazy.t;
}

(* What a live read found, before any HTTP encoding: a small answer, or the
   complete frame of the current observation. *)
type live_read =
  | Live_answer of Yojson.Safe.t
  | Live_full of { blob : Lane_addon_types.evidence; blob_bytes : int; screen : Yojson.Safe.t;
                   fields : (string * Yojson.Safe.t) list; observation_seq : int; refreshing : bool }

let observed_fields fields ~observation_seq ~refreshing =
  fields @ [ "observation_seq", `Int observation_seq; "refreshing", `Bool refreshing ]

type frame_cache = {
  blob : Lane_addon_types.evidence;
  blob_bytes : int;
  screen : Yojson.Safe.t;
  frame : ((int * bool) * live_frame Eio.Lazy.t) option;
}

(* One entry per workspace and machine: only the frame its worker publishes
   now is worth keeping. Blobs are content-addressed, so a hit is exactly
   what a fresh read would give. *)
let frame_caches : ((string * Machine_lane.t) * frame_cache) list Atomic.t = Atomic.make []

let cached_frame key = List.assoc_opt key (Atomic.get frame_caches)

(* Keep a newly read blob unless the same blob is already cached, so a racing
   first read does not drop a frame another request just started building. *)
let rec remember_screen key ~blob ~blob_bytes ~screen =
  let current = Atomic.get frame_caches in
  match List.assoc_opt key current with
  | Some cached when cached.blob = blob -> ()
  | Some _ | None ->
      let next = (key, { blob; blob_bytes; screen; frame = None }) :: List.remove_assoc key current in
      if not (Atomic.compare_and_set frame_caches current next) then
        remember_screen key ~blob ~blob_bytes ~screen

let encode_lazily identity encoding =
  Eio.Lazy.from_fun ~cancel:`Restart (fun () ->
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
      Http_response_payload.compress_encoded_body ~level:3 encoding identity))

let build_frame ~fields ~observation_seq ~refreshing =
  let identity, etag = Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
    let identity = Yojson.Safe.to_string (`Assoc (observed_fields fields ~observation_seq ~refreshing)) in
    identity, Http.Response.weak_etag_value identity) in
  { etag; identity
  ; zstd = encode_lazily identity Http_response_payload.Prefer_zstd
  ; gzip = encode_lazily identity Http_response_payload.Prefer_gzip }

let live_frame key ~blob ~blob_bytes ~screen ~fields ~observation_seq ~refreshing =
  let wanted = (observation_seq, refreshing) in
  let rec claim () =
    let current = Atomic.get frame_caches in
    match List.assoc_opt key current with
    | Some { blob = cached_blob; frame = Some (cached_key, frame); _ }
      when cached_blob = blob && cached_key = wanted -> frame
    | Some _ | None ->
        let frame = Eio.Lazy.from_fun ~cancel:`Restart (fun () ->
          build_frame ~fields ~observation_seq ~refreshing) in
        let entry = { blob; blob_bytes; screen; frame = Some (wanted, frame) } in
        let next = (key, entry) :: List.remove_assoc key current in
        if Atomic.compare_and_set frame_caches current next then frame else claim () in
  Eio.Lazy.force (claim ())

let select_live_frame ~accept_encoding frame =
  match Http_response_payload.negotiate_encoding accept_encoding with
  | Http_response_payload.Prefer_zstd -> Eio.Lazy.force frame.zstd
  | Http_response_payload.Prefer_gzip -> Eio.Lazy.force frame.gzip
  | Http_response_payload.Identity_only -> frame.identity, [ Http_response_payload.vary_accept_encoding ]

let live_read ~config source ~since =
  let name = match source with Machine_lane.Msx -> "masc_msx_screen" | Dos -> "masc_dos_screen" in
  let* snapshot = Lane_addon_runtime.observation_for_export ~config
    ~access:Lane_addon_sources.Unauthenticated ~name
    |> Result.map_error Lane_addon_runtime.export_refusal_message in
  match snapshot with
  | None -> Error "No attached shared machine worker is available"
  | Some snapshot ->
      let references = List.filter_map (fun (row : Lane_addon_types.row) ->
        Option.map (fun value -> row.evidence,value) (List.assoc_opt "machine_live" row.fields)) snapshot.output.rows in
      let cache_key = (Workspace.masc_dir config, source) in
      let* blob, blob_bytes, screen = match references with
        | [evidence,value] ->
            let* reference = Lane_addon_types.evidence_of_json value in
            let* () = if List.mem reference evidence then Ok () else Error "machine screen is not declared as row evidence" in
            (match cached_frame cache_key with
             | Some cached when cached.blob = reference && cached.blob_bytes <= snapshot.max_bytes ->
                 Ok (reference, cached.blob_bytes, cached.screen)
             | Some _ | None ->
                 let store = Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
                 (* A DOS screen blob is about 1.2 MB. Its digest check and
                    parse take about 10 ms on an idle machine, so both run on
                    the system-thread host rather than on the domain serving
                    HTTP, as [Systhread_host] intends (#46410). *)
                 let* blob_bytes, screen = Systhread_host.run ~label:"machine-live-screen" (fun () ->
                   let* bytes = Lane_addon_store.read_blob ~max_bytes:snapshot.max_bytes store reference in
                   match Yojson.Safe.from_string bytes with
                   | screen -> Ok (String.length bytes, screen)
                   | exception Yojson.Json_error detail -> Error detail) in
                 remember_screen cache_key ~blob:reference ~blob_bytes ~screen;
                 Ok (reference, blob_bytes, screen))
        | _ -> Error "worker observation does not provide one machine screen reference" in
      (* Blob I/O yields: an installation can detach or publish a newer frame
         before these bytes return. Only publish the still-current observation. *)
      let* current = Lane_addon_runtime.observation_for_export ~config
        ~access:Lane_addon_sources.Unauthenticated ~name
        |> Result.map_error Lane_addon_runtime.export_refusal_message in
      let* refreshing = match current with
        | Some current when current.instance_id = snapshot.instance_id
            && current.observation_seq = snapshot.observation_seq ->
            Ok (snapshot.refreshing || current.refreshing)
        | _ -> Error "machine observation changed while reading its screen" in
      let observed fields = Live_answer (`Assoc (observed_fields fields
        ~observation_seq:snapshot.observation_seq ~refreshing)) in
      (match screen with
       | `Assoc fields when List.assoc_opt "source_kind" fields = Some (`String (screen_source_kind source)) ->
           (match List.assoc_opt "state" fields with
            | Some (`String "no_machine") -> Ok (observed fields)
            | Some (`String "changed") ->
                (match List.assoc_opt "change_count" fields, List.assoc_opt "incarnation" fields,
                       List.assoc_opt "screen" fields with
                 | Some (`Int count), Some (`String incarnation), Some (`Assoc _)
                   when count >= 0 && incarnation <> "" ->
                     let publication = if refreshing then
                       Machine_live_publication.Running {count;incarnation}
                       else Machine_live_publication.Stable {count;incarnation} in
                     (match answer_from_publication source ~since publication with
                      | Needs_locked_read ->
                          Ok (Live_full { blob; blob_bytes; screen; fields;
                                          observation_seq = snapshot.observation_seq; refreshing })
                      | Answered (`Assoc unchanged) ->
                          Ok (observed (unchanged @ (match List.assoc_opt "activity" fields with
                            | None -> [] | Some activity -> ["activity",activity])))
                      | Answered json -> Ok (Live_answer json))
                 | _ -> Error "invalid worker machine screen snapshot")
            | _ -> Error "worker observation must contain a complete machine screen")
       | _ -> Error "worker observation does not provide one matching machine screen")

let live_json ~config source ~since =
  Result.map (function
    | Live_answer json -> json
    | Live_full { fields; observation_seq; refreshing; blob = _; blob_bytes = _; screen = _ } ->
        `Assoc (observed_fields fields ~observation_seq ~refreshing))
    (live_read ~config source ~since)

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
     | _ -> Error (`Bad_request, "expected_base_path and expected_masc_root go together"))

let respond_live_frame request reqd frame =
  let extra_headers = cors_headers (get_origin request) in
  let validator = [ "etag", frame.etag
                  ; "cache-control", Http.Response.json_revalidate_cache_control ] in
  match Httpun.Headers.get request.Httpun.Request.headers "if-none-match" with
  | Some client_tag when Http.Response.client_tag_matches ~etag:frame.etag ~client_tag ->
      Http.Response.not_modified
        ~headers:(extra_headers @ validator @ [ Http_response_payload.vary_accept_encoding ]) reqd
  | Some _ | None ->
      let body, encoding = select_live_frame
        ~accept_encoding:(Httpun.Headers.get request.Httpun.Request.headers "accept-encoding")
        frame in
      Http.Response.bytes ~headers:(extra_headers @ validator @ encoding)
        ~content_type:Http.Response.json_content_type body reqd

let get_live = (fun state request reqd ->
    match live_workspace_precondition ~config:(Mcp_server.workspace_config state) (query_fields request) with
    | Error (status, detail) ->
        respond_json_value_with_cors ~status request reqd (error_json detail)
    | Ok fields ->
    match decode_live_query fields with
    | Error detail -> respond request reqd (Error detail)
    | Ok (source, since) ->
        (match live_read ~config:(Mcp_server.workspace_config state) source ~since with
         | Ok (Live_answer json) -> Http.Response.json_value_on_cpu ~compress:true ~request
             ~extra_headers:(cors_headers (get_origin request)) json reqd
         | Ok (Live_full { blob; blob_bytes; screen; fields; observation_seq; refreshing }) ->
             let key = (Workspace.masc_dir (Mcp_server.workspace_config state), source) in
             respond_live_frame request reqd
               (live_frame key ~blob ~blob_bytes ~screen ~fields ~observation_seq ~refreshing)
         | Error detail -> respond_json_value_with_cors ~status:`Service_unavailable request reqd
             (Server_refusal.json ~code:"machine_observation_unavailable" detail)))

let post ~operation state caller request reqd =
    Http.Request.read_body_async reqd (fun body ->
      match source_access state request caller with
      | Error Source_credential_unreadable -> respond_unavailable request reqd
      | Ok access ->
        let result = let* args = decode_body body in dispatch ~caller ~access state operation args in
        respond request reqd result)

let respond_declaration request reqd = function
  | Ok json -> respond_json_value_with_cors request reqd json
  | Error (error : Lane_addon_declaration.error) ->
      let status = match error.code with
        | Invalid_request | Invalid_declaration -> `Bad_request
        | Not_found -> `Not_found | Revision_conflict -> `Conflict | Io_error -> `Internal_server_error in
      respond_json_value_with_cors ~status request reqd (Lane_addon_declaration.error_to_json error)

let read_declaration state caller request reqd =
    let args = `Assoc (List.map (fun (key,value) -> key,`String value) (query_fields request)) in
    match source_access state request caller with
    | Error Source_credential_unreadable -> respond_unavailable request reqd
    | Ok access -> respond_declaration request reqd (Runtime.read_declaration ~access ~config:(Mcp_server.workspace_config state) args)

let save_declaration state caller request reqd =
    Http.Request.read_body_async reqd (fun body ->
      match source_access state request caller with
      | Error Source_credential_unreadable -> respond_unavailable request reqd
      | Ok access ->
        let result = match decode_body body with
          | Error message -> Error {Lane_addon_declaration.code=Invalid_request;message;current=None}
          | Ok args -> Runtime.save_declaration ~access ~config:(Mcp_server.workspace_config state) args in
        respond_declaration request reqd result)

type operator_command = Describe_operator | Invoke_operator of Yojson.Safe.t
type operator_request = {
  instance_id : string; expected_incarnation : string; command : operator_command;
}
let decode_operator_request body =
  let* json = decode_body body |> Result.map_error (fun _ -> ()) in
  match json with
  | `Assoc fields ->
      let names = List.map fst fields |> List.sort String.compare in
      let identity name = match List.assoc_opt name fields with
        | Some (`String value) when value <> "" && String.trim value = value -> Ok value
        | Some _ | None -> Error () in
      let* instance_id = identity "instance_id" in
      let* expected_incarnation = identity "expected_incarnation" in
      let* command = match List.assoc_opt "mode" fields, List.assoc_opt "arguments" fields with
        | Some (`String "describe"), None
          when names = ["expected_incarnation";"instance_id";"mode"] -> Ok Describe_operator
        | Some (`String "invoke"), Some (`Assoc _ as arguments)
          when names = ["arguments";"expected_incarnation";"instance_id";"mode"] -> Ok (Invoke_operator arguments)
        | (Some _ | None), (Some _ | None) -> Error () in
      Ok {instance_id;expected_incarnation;command}
  | _ -> Error ()

let private_headers = ["cache-control","no-store";"referrer-policy","no-referrer";
  "x-content-type-options","nosniff"]
let operator_callback _request reqd =
  (* Static page: no query/fragment is interpolated into server HTML or logs.
     Only its original same-origin opener can receive the private return. *)
  let script = {|const returned=window.location.href;
const originalOpener=window.opener;
const query=new URL(returned).searchParams;
const state=query.getAll("state").length===1?query.get("state"):null;
const receiptKind=query.get("error")==="access_denied"?"declined":"captured";
let connectionId=null;
let cleared=false;
const status=document.getElementById("status");
function deliver(){
  if(cleared || !originalOpener || originalOpener===window || state===null){
    status.textContent="The original connection window is unavailable. Keep this return open; its capture has not been confirmed.";
    return;
  }
  originalOpener.postMessage({kind:"masc-addon-oauth-callback",url:returned},window.location.origin);
  status.textContent="Waiting for the original connection to confirm capture. Keep this window open.";
}
window.addEventListener("message",event=>{
  if(cleared || state===null || event.source!==originalOpener || event.origin!==window.location.origin)return;
  const data=event.data;
  if(typeof data!=="object" || data===null || data.state!==state
    || typeof data.connection_id!=="string" || data.connection_id==="")return;
  if(data.kind==="masc-addon-oauth-pending"){
    if(connectionId===null)connectionId=data.connection_id;
    return;
  }
  if(data.kind!=="masc-addon-oauth-captured" || connectionId===null
    || data.connection_id!==connectionId || data.receipt_kind!==receiptKind)return;
  window.history.replaceState(null,"",window.location.pathname);
  cleared=true;
  originalOpener.postMessage({kind:"masc-addon-oauth-cleared",url:returned,connection_id:connectionId},window.location.origin);
  status.textContent="Return captured by the original connection. You can close this window.";
  window.close();
});
document.getElementById("retry").addEventListener("click",deliver);
deliver();
|} in
  let hash = Agent_core_sha256.digest_string script |> Agent_core_sha256.to_raw_string |> Base64.encode_string in
  let policy = "default-src 'none'; script-src 'sha256-" ^ hash ^ "'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" in
  Http.Response.html ~headers:(private_headers @ ["content-security-policy",policy;
    "cross-origin-opener-policy","same-origin-allow-popups"])
    ("<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"referrer\" content=\"no-referrer\"><title>Connection return</title>"
     ^ "<p id=\"status\">Returning to connection settings…</p><button id=\"retry\" type=\"button\">Retry original return</button><script>" ^ script ^ "</script></html>") reqd
let operator_control state _actor request reqd =
    let reply ?(status=`OK) value =
      Http.Response.with_scoped_headers private_headers (fun () ->
        Http.Response.json_value ~status ~compress:false ~request value reqd) in
    (* No reflected CORS and no dev-origin widening for private OAuth material.
       Native operator clients can omit Origin; browser clients must match. *)
    let origin = classify_request_origin
      ~request_authority:(Server_request_authority.current_exn ()) request in
    let allowed = match origin with
      | Single_origin {admission=Same_origin;_} -> true
      | Missing_origin ->
          (match Httpun.Headers.get_multi request.Httpun.Request.headers "sec-fetch-site" with
           | [] -> true | [_] | _::_::_ -> false)
      | Single_origin {admission=(Allowed_dev_origin|Rejected);_}
      | Multiple_origins | Malformed_origin -> false in
    let config = Mcp_server.workspace_config state in
    match allowed, request_credential_standing ~base_path:config.Workspace.base_path request with
    | false, _ -> reply ~status:`Forbidden (error_json "private operator origin refused")
    | true, Unreadable_credential -> reply ~status:`Service_unavailable (error_json "operator credential unavailable")
    | true, (Agent_credential | Player_credential | No_credential) ->
        reply ~status:`Forbidden (error_json "operator credential required")
    | true, Operator_credential ->
        Http.Request.read_body_async_with_limit reqd ~max_bytes:Http.Request.max_body_bytes
          ~on_error:(function
            | `Too_large _ -> reply ~status:`Payload_too_large (error_json "private operator request too large")
            | `Internal _ -> reply ~status:`Internal_server_error (error_json "private operator operation unavailable"))
          ~on_body:(fun body ->
          match decode_operator_request body with
          | Error () -> reply ~status:`Bad_request (error_json "invalid private operator request")
          | Ok {instance_id;expected_incarnation;command} ->
              let access = Lane_addon_sources.Operator_configuration in
              let result = match command with
                | Describe_operator -> Runtime.operator_schema ~config ~access ~instance_id ~expected_incarnation
                    |> Result.map (fun schema -> `Assoc ["schema", match schema with Some value -> value | None -> `Null])
                | Invoke_operator arguments -> Runtime.call_operator ~config ~access ~instance_id ~expected_incarnation ~arguments in
              match result with
              | Ok value -> reply value
              | Error Runtime.Operator_unavailable -> reply ~status:`Conflict (error_json "original operator control unavailable")
              | Error Runtime.Operator_rejected -> reply ~status:`Bad_request (error_json "operator request refused")
              | Error Runtime.Operator_outcome_unknown -> reply ~status:`Conflict (error_json "operator outcome unknown; inspect before another attempt"))

(* RFC operator-quiz §4.6: an installation's questions, beside the Keeper
   questions in Approvals. Questions and resolutions use the Keeper wire form,
   so one editor answers both. *)
let decode_asks_query = function
  | [] | ["include_resolved", "false"] -> Ok false
  | ["include_resolved", "true"] -> Ok true
  | _ -> Error "asks accepts include_resolved=true|false once or no parameters"

let installation_ask_json ~declaration_id (ask_id, ((ask : Lane_addon_asks.ask), resolution)) =
  `Assoc
    [ "declaration_id", `String declaration_id
    ; "title", `String ask.title
    ; "ask_id", `String ask_id
    ; "asked_at", `Float ask.asked_at
    ; "context", (match ask.context with None -> `Null | Some text -> `String text)
    ; "questions", `List (List.map Keeper_ask_operator_projection.ask_question_json ask.questions)
    ; "resolution", Keeper_ask_operator_projection.ask_resolution_json resolution ]

let asks_payload ~config ~include_resolved =
  let* questions = Runtime.installation_questions ~config in
  Ok (`Assoc ["asks", `List (List.concat_map (fun (declaration_id, rows) ->
    rows
    |> List.filter (fun (_, (_, resolution)) ->
         include_resolved || Keeper_ask_operator_projection.ask_row_is_open resolution)
    |> List.map (installation_ask_json ~declaration_id)) questions)])

let handle_asks state request reqd =
  let config = Mcp_server.workspace_config state in
  match live_workspace_precondition ~config (query_fields request) with
  | Error (status, detail) -> respond_json_value_with_cors ~status request reqd (error_json detail)
  | Ok fields ->
    match decode_asks_query fields with
    | Error detail -> respond request reqd (Error detail)
    | Ok include_resolved ->
      match asks_payload ~config ~include_resolved with
      | Ok json -> respond_json_value_with_cors request reqd json
      | Error detail ->
        respond_json_value_with_cors ~status:`Internal_server_error request reqd (error_json detail)

let decode_ask_answer body =
  let* json = decode_body body in
  match json with
  | `Assoc fields ->
    let known = ["declaration_id"; "ask_id"; "answers"; "session_id"] in
    let* () = match List.find_opt (fun (name, _) -> not (List.mem name known)) fields with
      | None -> Ok ()
      | Some (name, _) -> Error ("unknown ask-answer field: " ^ name) in
    let nonblank name = match List.assoc_opt name fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | Some _ | None -> Error (name ^ " must be a non-blank string") in
    let* declaration_id = nonblank "declaration_id" in
    let* ask_id = nonblank "ask_id" in
    let* submissions = match List.assoc_opt "answers" fields with
      | Some answers -> Keeper_ask.submissions_of_json answers
      | None -> Error "answers is required" in
    let* session_id = match List.assoc_opt "session_id" fields with
      | None -> Ok None
      | Some (`String value) when String.trim value <> "" -> Ok (Some value)
      | Some _ -> Error "session_id must be a non-blank string" in
    Ok (declaration_id, ask_id, submissions, session_id)
  | _ -> Error "request body must be a JSON object"

let ask_answer_failure_response ~ask_id (failure : Lane_addon_asks.answer_failure) =
  let detail = Lane_addon_asks.answer_failure_to_string failure in
  match failure with
  | Ask_not_found -> `Not_found, error_json detail
  | Already_answered { answered_at } ->
    `Conflict, `Assoc [ "error", `String detail; "state", `String "answered"
                      ; "ask_id", `String ask_id; "answered_at", `Float answered_at ]
  | Already_withdrawn { withdrawn_at } ->
    `Conflict, `Assoc [ "error", `String detail; "state", `String "withdrawn"
                      ; "ask_id", `String ask_id; "withdrawn_at", `Float withdrawn_at ]
  | Rejected invalid ->
    `Bad_request, `Assoc [ "error", `String detail
                         ; "invalid_answers", `List (List.map (fun reason ->
                             `String (Keeper_ask.invalid_answer_to_string reason)) invalid) ]
  | Store_failed _ -> `Internal_server_error, error_json detail

let ask_answer_recorded_json ~declaration_id ~ask_id ~answer_count =
  `Assoc [ "recorded", `Bool true; "declaration_id", `String declaration_id
         ; "ask_id", `String ask_id; "answer_count", `Int answer_count ]

let handle_ask_answer ~actor state request reqd =
  Http.Request.read_body_async reqd (fun body ->
    match decode_ask_answer body with
    | Error detail -> respond request reqd (Error detail)
    | Ok (declaration_id, ask_id, submissions, session_id) ->
      let responder =
        { Keeper_ask.surface = Surface_ref.Dashboard { session_id }
        ; actor_id = Some actor; display_name = None } in
      match Runtime.answer_installation_question ~config:(Mcp_server.workspace_config state)
              ~declaration_id ~ask_id ~submissions ~responder with
      | Ok answers ->
        respond_json_value_with_cors request reqd
          (ask_answer_recorded_json ~declaration_id ~ask_id ~answer_count:(List.length answers))
      | Error failure ->
        let status, json = ask_answer_failure_response ~ask_id failure in
        respond_json_value_with_cors ~status request reqd json)

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
            ~media_store:(Tool_blob_media_store.of_base_path ~base_path:config.Workspace.base_path)
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
  |> Server_route.get (Server_route.Tool_actor { tool_name = "masc_lane_evidence" }) "/api/v1/lane-addons/broadcast-principal"
       (fun state caller request reqd ->
         let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
         match broadcast_principal ~base_path request caller with
         | Ok principal -> respond request reqd (Ok (`Assoc ["principal",`String principal]))
         | Error (Bad_request_detail detail) -> respond request reqd (Error detail)
         | Error Credential_store_unreadable -> respond_unavailable request reqd)
  |> Server_route.get Server_route.Read_auth "/api/v1/lane-addons/package-catalog" get_package_catalog
  |> Server_route.get Server_route.Read_auth "/api/v1/lane-addons/package-preview" get_package_preview
  |> Server_route.post (Server_route.Tool_actor { tool_name = "masc_lane_updates" }) "/api/v1/lane-addons/subscriptions"
       (fun state caller request reqd ->
         Http.Request.read_body_async reqd (fun body ->
           match source_access state request caller with
           | Error Source_credential_unreadable -> respond_unavailable request reqd
           | Ok access ->
             let result = let* args=decode_body body in
               Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                 Lane_addon_subscription.handle ~access ~config:(Mcp_server.workspace_config state) ~caller args) in
             respond request reqd result))
  |> Server_route.get (Server_route.Tool_actor { tool_name = "masc_lane_declaration_read" }) "/api/v1/lane-addons/declaration" read_declaration
  |> Server_route.post (Server_route.Tool_actor { tool_name = "masc_lane_declaration_save" }) "/api/v1/lane-addons/declaration" save_declaration
  |> Server_route.post (Server_route.Private_token_permission Masc_domain.CanAdmin) "/api/v1/lane-addons/operator" operator_control
  |> Server_route.get (Server_route.Self_authenticated Route_access.Oauth_protocol) "/addons/oauth/callback" operator_callback
  |> Server_route.get Server_route.Read_auth "/api/v1/lane-addons" get_inspect
  |> Server_route.get Server_route.Read_auth "/api/v1/lane-addons/slice" get_slice
  |> Server_route.get Server_route.Read_auth "/api/v1/lane-addons/actions" get_action
  |> Server_route.get (Server_route.Permission Masc_domain.CanPlayMachine) "/api/v1/lane-addons/live" get_live
  |> Server_route.get Server_route.Read_auth "/api/v1/lane-addons/asks" handle_asks
  |> Server_route.post (Server_route.Tool_actor { tool_name = "lane_addon_ask_answer_route" }) "/api/v1/lane-addons/ask-answer"
       (fun state actor request reqd ->
         handle_ask_answer ~actor state request reqd)
  |> Server_route.post (Server_route.Tool_actor { tool_name = "masc_lane_act" }) "/api/v1/lane-addons/actions" (post ~operation:Runtime.Act)
  |> Server_route.post (Server_route.Tool_actor { tool_name = "masc_lane_attach" }) "/api/v1/lane-addons/attach" (post ~operation:Runtime.Attach)
  |> Server_route.post (Server_route.Tool_actor { tool_name = "masc_lane_observe" }) "/api/v1/lane-addons/observe" (post ~operation:Runtime.Observe)
  |> Server_route.post (Server_route.Tool_actor { tool_name = "masc_lane_detach" }) "/api/v1/lane-addons/detach" (post ~operation:Runtime.Detach)
  |> Server_route.post (Server_route.Tool_actor { tool_name = "lane_addon_retain_route" }) "/api/v1/lane-addons/retain" (post ~operation:Runtime.Retain)
  |> Server_route.post (Server_route.Tool_actor { tool_name = "masc_lane_evidence" }) "/api/v1/lane-addons/evidence" (post ~operation:Runtime.Evidence)
