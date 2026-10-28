open Server_utils
open Server_auth
module Http = Http_server_eio
module Draft = Artifact_draft
module Store = Artifact_draft_store
module Live = Artifact_draft_live
open Result.Syntax
let respond ?cors ?(status = `OK) request reqd json =
  let cors = match cors with Some headers -> headers | None -> public_read_cors_headers request in
  Http.Response.json_value ~status
    ~extra_headers:(["cache-control", "private, no-store"] @ cors) json reqd
let refuse request reqd error =
  let json, status = Server_routes_http_routes_artifact_drafts.error_response error in
  respond ~status request reqd json
(* Each connection receives only its authenticated document room, never the
   global agent event stream. The promise is replaced under the room mutex, so
   a commit between observe and await cannot be lost. *)
let stream ~sw ~clock ~session request reqd =
  let headers = Httpun.Headers.of_list
    (["content-type", "text/event-stream"; "cache-control", "private, no-store";
      "x-accel-buffering", "no"] @ public_read_cors_headers request) in
  let writer = Httpun.Reqd.respond_with_streaming reqd (Httpun.Response.create ~headers `OK) in
  let mutex = Eio.Mutex.create () in
  let closed = Atomic.make false in
  let stopped, stop = Eio.Promise.create () in
  let request_close () =
    if Atomic.compare_and_set closed false true then (
      Live.leave session; Eio.Promise.resolve stop ()) in
  let send frame = Eio.Mutex.use_rw ~protect:true mutex (fun () ->
    if Atomic.get closed || Httpun.Body.Writer.is_closed writer then request_close ()
    else (
      Httpun.Body.Writer.write_string writer frame;
      let flushed, resolve = Eio.Promise.create () in
      Httpun.Body.Writer.flush writer (fun outcome -> Eio.Promise.resolve resolve outcome);
      match Eio.Promise.await flushed with `Written -> () | `Closed -> request_close ())) in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run (fun connection ->
      Eio.Switch.on_release connection (fun () ->
        request_close ();
        Eio.Mutex.use_rw ~protect:true mutex (fun () -> Httpun.Body.Writer.close writer));
      let guarded f () =
        (try f () with Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Log.Server.debug "Artifact draft stream closed: %s" (Printexc.to_string exn));
        request_close (); `Stop_daemon in
      Eio.Fiber.fork_daemon ~sw:connection (guarded (fun () ->
        let rec loop () = match Live.observe session with
          | None -> ()
          | Some (frame, pulse) ->
            send ("event: draft\ndata: " ^ Yojson.Safe.to_string frame ^ "\n\n");
            if not (Atomic.get closed) then (Eio.Promise.await pulse; loop ()) in loop ()));
      Eio.Fiber.fork_daemon ~sw:connection (guarded (fun () ->
        let rec loop () =
          Eio.Time.sleep clock Server_mcp_transport_http_headers.sse_ping_interval_s;
          if not (Atomic.get closed) then (send ": ping\n\n"; loop ()) in loop ()));
      Eio.Promise.await stopped))

type presence = Position of Artifact_document_engine.selection option | Leave
let parse_presence json =
  let field name fields = Option.value ~default:`Null (List.assoc_opt name fields) in
  let* fields = match json with
    | `Assoc fields when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
    | _ -> Error "expected presence object with unique fields" in
  let* action, allowed = match field "action" fields with
    | `String "leave" -> Ok ("leave", ["action"; "target"; "session_id"])
    | `String "position" -> Ok ("position", ["action"; "target"; "session_id"; "position"])
    | _ -> Error "invalid presence action" in
  let* () = if List.length fields = List.length allowed && List.for_all (fun (key, _) -> List.mem key allowed) fields
    then Ok () else Error "unknown or missing presence field" in
  let* target = Draft.target_of_json (field "target" fields) in
  let* session_id = match field "session_id" fields with `String value when value <> "" -> Ok value | _ -> Error "invalid session id" in
  let* command = if action = "leave" then Ok Leave else match field "position" fields with
    | `Null -> Ok (Position None)
    | json -> Artifact_document_engine.selection_of_json json |> Result.map (fun position -> Position (Some position)) in
  Ok (target, session_id, command)

let target_of_request request =
  let* artifact_id = match extract_path_param ~prefix:"/api/v1/artifact-draft-events/" (Http.Request.path request) with
    | Some id -> Ok id | None -> Error "artifact id required" in
  let* generation = match query_param request "generation" with Some value -> Ok value | None -> Error "draft generation required" in
  Draft.target_of_json (`Assoc ["artifact_id", `String artifact_id; "generation", `String generation])

let join ~base_path ~actor ~target =
  let session = Live.join ~base_path ~actor ~source:Live.Dashboard_connection ~target in
  (* Register before reading so a newer broadcast cannot be replaced by an
     older initial read. The successful transport owns [session]. *)
  try match Store.read ~base_path ~artifact_id:target.Draft.artifact_id () with
  | Error error -> Live.leave session; Error error
  | Ok view when view.draft.target <> target ->
    Live.leave session; Error (Store.Generation_conflict view.draft.target)
  | Ok view ->
    Live.publish ~base_path ~draft:view.draft ~content:view.content;
    Ok session
  with exn -> Live.leave session; raise exn

let presence ~base_path ~actor ~body =
  let parsed = match Yojson.Safe.from_string body with
    | json -> parse_presence json | exception Yojson.Json_error _ -> Error "invalid presence JSON" in
  let closed () =
    `Assoc ["code", `String "artifact_draft_session_closed";
      "error", `String "The editing session is closed or belongs to another actor."], `Conflict in
  match parsed with
  | Error message -> Server_routes_http_routes_artifact_drafts.error_response (Store.Invalid message)
  | Ok (target, session_id, command) ->
    match Live.find ~base_path ~actor ~target ~session_id with
    | Error _ -> closed ()
    | Ok session ->
      let validated = match command with
        | Leave | Position None -> Ok ()
        | Position (Some position) ->
          Store.execute ~base_path ~actor (Draft.Resolve { target; position }) |> Result.map (fun _ -> ()) in
      match validated with
      | Error error -> Server_routes_http_routes_artifact_drafts.error_response error
      | Ok () ->
        let result = match command with Leave -> Live.leave session; Ok () | Position position -> Live.position session position in
        match result with Error _ -> closed () | Ok () -> `Assoc ["ok", `Bool true], `OK

let add_routes router = router
  |> Server_route.prefix_get (Server_route.Token_permission Masc_domain.CanReadState) "/api/v1/artifact-draft-events/" (fun state actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    match target_of_request request, state.Mcp_server.sw, state.Mcp_server.clock with
    | Error message, _, _ -> refuse request reqd (Store.Invalid message)
    | Ok _, None, _ | Ok _, _, None -> refuse request reqd (Store.Unavailable "server runtime not initialized")
    | Ok target, Some sw, Some clock ->
      (match join ~base_path ~actor ~target with
       | Error error -> refuse request reqd error
       | Ok session ->
         (try stream ~sw ~clock ~session request reqd with exn -> Live.leave session; raise exn)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanBroadcast) "/api/v1/artifact-draft-presence" (fun state actor request reqd ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let cors = public_read_cors_headers request in
    Http.Request.read_body_async reqd (fun body ->
      let json, status = presence ~base_path ~actor ~body in
      respond ~cors ~status request reqd json))
