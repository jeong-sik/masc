module Published = Server_routes_http_routes_published_artifacts
module Draft = Server_routes_http_routes_artifact_drafts
module Draft_live = Server_routes_http_routes_artifact_draft_live
module App_data = Server_routes_http_routes_artifact_app_data
module Store = Artifact_draft_store
module Live = Artifact_draft_live
module Resources = Server_h2_response_resources
open Server_h2_gateway_helpers

type admission =
  { with_token : permission:Masc_domain.permission ->
      (Mcp_server.server_state -> string -> (string * string) list -> unit) -> unit
  ; with_public :
      (Mcp_server.server_state -> string option -> (string * string) list -> unit) -> unit
  ; read_body : (string -> unit) -> unit
  ; refuse_auth : Masc_domain.masc_error -> unit
  }

let reserve_output bytes =
  (* The complete encoded string stays reachable while a slow peer drains it.
     Reserve that string and one scheduled H2 chunk for the entire write. *)
  let length = String.length bytes in
  let chunk_size = min H2.Settings.default.max_frame_size
    (max 1 (H2_response_limits.max_pending_bytes () / 2)) in
  let chunk_bytes = min length chunk_size in
  if length > max_int - chunk_bytes then Error Resources.Capacity_exhausted
  else match Resources.reserve (Resources.current_exn ()) ~bytes:(length + chunk_bytes) with
    | Error error -> Error error
    | Ok lease -> Ok (lease, chunk_size)

let send_chunks ~chunk_size writer bytes =
  let rec loop offset =
    if offset < String.length bytes then (
      let length = min chunk_size (String.length bytes - offset) in
      let flushed, resolve = Eio.Promise.create () in
      let chunk = Bigstringaf.of_string bytes ~off:offset ~len:length in
      H2.Body.Writer.schedule_bigstring writer chunk;
      H2.Body.Writer.flush writer (fun result -> Eio.Promise.resolve resolve result);
      (match Eio.Promise.await flushed with
       | `Written -> ()
       | `Closed -> raise Resources.Response_writer_closed);
      loop (offset + length)) in
  loop 0

let write_stream_frame writer frame =
  match reserve_output frame with
  | Error Capacity_exhausted -> raise Resources.Response_capacity_exhausted
  | Error Request_closed -> raise Resources.Response_writer_closed
  | Ok (lease, chunk_size) ->
    Fun.protect ~finally:(fun () -> Resources.release lease)
      (fun () -> send_chunks ~chunk_size writer frame)

let stream ~request_sw ~clock ~session ~cors ~admission_headers h2_reqd =
  let headers = H2.Headers.of_list
    (admission_headers @
     ["content-type", "text/event-stream"; "cache-control", "private, no-store";
      "x-accel-buffering", "no"] @ cors) in
  let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd
    (H2.Response.create ~headers `OK) in
  (* Stream reset or connection loss cancels this exact request switch. *)
  Eio.Switch.on_release request_sw (fun () -> Live.leave session);
  (* No ping may be inserted within a frame. Capacity exhaustion resets the
     stream; reconnecting attempts a full snapshot under the same budget. *)
  Fun.protect
    ~finally:(fun () -> Live.leave session)
    (fun () ->
      let rec observe () = match Live.observe session with
        | None -> ()
        | Some (frame, pulse) ->
          let encoded = Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
            "event: draft\ndata: " ^ Yojson.Safe.to_string frame ^ "\n\n") in
          write_stream_frame writer encoded;
          wait_for_change pulse
      and wait_for_change pulse =
        match Eio.Fiber.first
          (fun () -> Eio.Promise.await pulse; `Changed)
          (fun () -> Eio.Time.sleep clock Server_mcp_transport_http_headers.sse_ping_interval_s; `Ping) with
        | `Changed -> observe ()
        | `Ping -> write_stream_frame writer ": ping\n\n"; wait_for_change pulse in
      observe ();
      if not (H2.Body.Writer.is_closed writer) then h2_close_after_flush writer)

let dispatch ~request_sw ~h2_reqd ~request ~path ~cors ~admission meth =
  let respond headers (json, status) =
    let response, body = Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
      let status = Http_server_eio.Response.timeout_envelope_status_override ~status json in
      Http_server_eio.Response.prepare_json ~status ~request
        ~extra_headers:(headers @ ["cache-control", "private, no-store"] @ cors)
        (Yojson.Safe.to_string json)) in
    match reserve_output body with
    | Error Request_closed -> raise Resources.Response_writer_closed
    | Error Capacity_exhausted ->
      h2_respond_json ~status:`Service_unavailable ~compress:false
        ~extra_headers:(headers @ cors @ ["cache-control", "no-store"])
        h2_reqd ""
    | Ok (lease, chunk_size) ->
      Fun.protect ~finally:(fun () -> Resources.release lease) (fun () ->
        H2.Body.Reader.discard (H2.Reqd.request_body h2_reqd);
        let headers = response.Httpun.Response.headers |> Httpun.Headers.to_list |> H2.Headers.of_list in
        let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd
          (H2.Response.create ~headers (response.status :> H2.Status.t)) in
        (* A failed or cancelled write is reset, never ended as a short 200. *)
        send_chunks ~chunk_size writer body;
        h2_close_after_flush writer) in
  let respond_published headers (response : Published.response) =
    respond headers (response.json, response.status) in
  let base state = (Mcp_server.workspace_config state).base_path in
  let private_error =
    Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized
      { reason = Missing_token;
        message = "Authentication required unless external sharing is enabled for this artifact." }) in
  match meth, path with
  | `GET, "/api/v1/published-artifacts" ->
    admission.with_token ~permission:Masc_domain.CanReadState (fun state _actor headers ->
      respond_published headers (Published.list ~base_path:(base state)));
    true
  | `GET, path when String.starts_with ~prefix:"/api/v1/published-artifacts/" path ->
    admission.with_public (fun state actor headers ->
      match Published.read ~base_path:(base state) ~actor ~request with
      | Private -> admission.refuse_auth private_error
      | Response result -> respond_published headers result);
    true
  | `POST, "/api/v1/published-artifacts" ->
    admission.with_token ~permission:Masc_domain.CanBroadcast (fun state actor headers ->
      admission.read_body (fun body ->
        respond_published headers (Published.publish ~base_path:(base state) ~actor ~body)));
    true
  | `GET, "/api/v1/published-artifact-checks" ->
    admission.with_token ~permission:Masc_domain.CanReadState (fun state _actor headers ->
      respond_published headers (Published.list_checks ~base_path:(base state)));
    true
  | `POST, "/api/v1/published-artifact-checks" ->
    admission.with_token ~permission:Masc_domain.CanAdmin (fun state actor headers ->
      let config = Mcp_server.workspace_config state in
      admission.read_body (fun body ->
        respond_published headers (Published.set_check ~config ~actor ~body)));
    true
  | `POST, "/api/v1/published-artifact-shares" ->
    admission.with_token ~permission:Masc_domain.CanAdmin (fun state _actor headers ->
      let config = Mcp_server.workspace_config state in
      admission.read_body (fun body ->
        respond_published headers (Published.set_share ~config ~body)));
    true
  | `GET, path when String.starts_with ~prefix:"/api/v1/artifact-app-data/" path ->
    admission.with_token ~permission:Masc_domain.CanAdmin (fun state actor headers ->
      respond headers (App_data.read ~base_path:(base state) ~actor ~request));
    true
  | `POST, "/api/v1/artifact-app-data" ->
    admission.with_token ~permission:Masc_domain.CanAdmin (fun state actor headers ->
      let config = Mcp_server.workspace_config state in
      admission.read_body (fun body -> respond headers (App_data.set ~config ~actor ~body)));
    true
  | `GET, path when String.starts_with ~prefix:"/api/v1/artifact-drafts/" path ->
    admission.with_token ~permission:Masc_domain.CanReadState (fun state _actor headers ->
      let response = match Server_utils.extract_path_param ~prefix:"/api/v1/artifact-drafts/" path with
        | None -> Draft.error_response (Store.Invalid "artifact id required")
        | Some artifact_id -> Draft.read ~base_path:(base state) ~artifact_id in
      respond headers response);
    true
  | `POST, "/api/v1/artifact-drafts" ->
    admission.with_token ~permission:Masc_domain.CanBroadcast (fun state actor headers ->
      admission.read_body (fun body -> respond headers (Draft.execute ~base_path:(base state) ~actor ~body)));
    true
  | `POST, "/api/v1/artifact-draft-checkpoints" ->
    admission.with_token ~permission:Masc_domain.CanBroadcast (fun state actor headers ->
      admission.read_body (fun body -> respond headers (Draft.checkpoint ~base_path:(base state) ~actor ~body)));
    true
  | `POST, "/api/v1/artifact-draft-presence" ->
    admission.with_token ~permission:Masc_domain.CanBroadcast (fun state actor headers ->
      admission.read_body (fun body -> respond headers (Draft_live.presence ~base_path:(base state) ~actor ~body)));
    true
  | `GET, path when String.starts_with ~prefix:"/api/v1/artifact-draft-events/" path ->
    admission.with_token ~permission:Masc_domain.CanReadState (fun state actor headers ->
      match Draft_live.target_of_request request, state.Mcp_server.sw, state.Mcp_server.clock with
      | Error message, _, _ -> respond headers (Draft.error_response (Store.Invalid message))
      | Ok _, None, _ | Ok _, _, None ->
        respond headers (Draft.error_response (Store.Unavailable "server runtime not initialized"))
      | Ok target, Some _, Some clock ->
        Eio.Switch.check request_sw;
        (match Draft_live.join ~base_path:(base state) ~actor ~target with
         | Error error -> respond headers (Draft.error_response error)
         | Ok session ->
           (try stream ~request_sw ~clock ~session ~cors ~admission_headers:headers h2_reqd
            with exn -> Live.leave session; raise exn)));
    true
  | (`GET | `POST | `DELETE | `OPTIONS | `PUT | `HEAD | `CONNECT | `TRACE | `Other _), _ -> false
