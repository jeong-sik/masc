open Server_auth

let path = "/api/v1/play/events"
type change = Snapshot | Machine | Seats | Room | Keeper of string

let change_of_payload ~machine = function
  | `Assoc fields ->
    let string key = match List.assoc_opt key fields with Some (`String value) -> Some value | _ -> None in
    let named = Option.exists (fun name -> not (String.equal name "")) (string "name") in
    let timestamp = match List.assoc_opt "ts_unix" fields with
      | Some (`Float value) -> Float.is_finite value
      | Some (`Int _) -> true
      | _ -> false in
    (match string "type" with
     | Some kind when String.equal kind Workspace_dataset_event.event_type ->
       (match Workspace_dataset_event.of_fields fields with
        | Error _ -> None
        | Ok dataset ->
          let kind = Workspace_dataset_event.kind dataset in
          if kind = Workspace_dataset_event.Kind.Machine_live
             && Option.bind (string "machine") Machine_lane.of_wire <> Some machine then None
          else List.assoc_opt kind Workspace_dataset_event.Kind.
            [ Machine_live, Machine; Play_room, Room; Play_seats, Seats
            ; Lanes, Snapshot; Clients, Seats ])
     | Some "keeper_composite_changed" when named && timestamp -> Option.map (fun name -> Keeper name) (string "name")
     | Some "keeper_phase_changed" when named && timestamp ->
       (match Option.bind (string "prev_phase") Keeper_state_machine.phase_of_string,
              Option.bind (string "new_phase") Keeper_state_machine.phase_of_string with
        | Some _, Some _ -> Option.map (fun name -> Keeper name) (string "name") | _ -> None)
     | Some _ | None -> None)
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None

let credential_expiry (credential : Masc_domain.agent_credential) =
  Masc_domain.Credential_expiry.parse credential.expires_at
  |> Result.map (function
    | Masc_domain.Credential_expiry.No_expiry -> None
    | At second -> Some (second +. 1.0))

let next_seat_expiry ~now credentials =
  List.fold_left (fun next (credential : Masc_domain.agent_credential) ->
    match credential.role with
      | Masc_domain.Worker -> next
      | Admin | Player ->
        match credential_expiry credential with
        | Error (Masc_domain.Credential_expiry.Invalid_timestamp stamp) ->
          Log.Auth.warn "Play seat cannot read credential expiry for %s: %S"
            credential.agent_name stamp;
          next
        | Ok expiry -> match expiry with
          | Some at when Float.compare at now > 0 -> Some (Option.fold ~none:at ~some:(Float.min at) next)
          | Some _ | None -> next) None credentials

let observe_seat_expiry ~base_path =
  Auth.with_credential_transaction base_path
    Auth.list_current_credentials_in_transaction
  |> Result.join
  |> Result.map_error (fun _ -> ())
  |> Result.map (fun credentials ->
       next_seat_expiry ~now:(Time_compat.now ()) credentials)

let frame change =
  let fields = match change with
    | Snapshot -> ["change", `String "snapshot"]
    | Machine -> ["change", `String "machine"]
    | Seats -> ["change", `String "seats"]
    | Room -> ["change", `String "room"]
    | Keeper name -> ["change", `String "keeper"; "keeper", `String name] in
  "event: play\ndata: " ^ Yojson.Safe.to_string (`Assoc fields) ^ "\n\n"

let unavailable = "event: unavailable\ndata: {}\n\n"

let query request =
  let fields = Uri.query (Uri.of_string request.Httpun.Request.target) in
  let value key = match List.filter (fun (name, _) -> String.equal name key) fields with
    | [] -> Ok None
    | [_, [value]] -> Ok (Some value)
    | _ -> Error "ambiguous Play observation scope" in
  let open Result.Syntax in
  let* machine = value "machine" in
  let* machine = match Option.bind machine Machine_lane.of_wire with
    | Some machine -> Ok machine | None -> Error "machine must be msx or dos" in
  let* client = value "client_id" in
  let* () = if List.for_all (fun (key, _) -> List.mem key ["machine"; "client_id"]) fields
    then Ok () else Error "unknown Play observation scope" in
  let* presence = match client with
    | None -> Ok None
    | Some play_client ->
      let scope : Play_room_presence.scope = { play_client; machine } in
      Play_room_presence.presence_action Play_room.Join scope
      |> Result.map (fun _ -> Some scope)
      |> Result.map_error Play_room.error_message in
  Ok (machine, presence)

let serve ~state ~name ~request ~reqd ~sw ~clock ~machine ~presence (credential : Masc_domain.agent_credential) =
  let scope = Mcp_server.workspace_scope state in
  let config = scope.config in
  let current () =
    Option.exists (fun active -> active == state) (current_server_state ())
    && Mcp_server.Workspace_scope_epoch.equal scope.epoch (Mcp_server.workspace_scope state).epoch
    && match authorize_token_bound_permission_request ~base_path:config.base_path
         ~permission:Masc_domain.CanPlayMachine request with
       | Ok actor -> String.equal actor name | Error _ -> false in
  let client_id = Sse.fresh_client_id () in
  let id = "play-observation-" ^ string_of_int client_id in
  let response = Server_sse_response.respond ~clock
      ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
      ~flush_headers_immediately:true reqd
      (Httpun.Response.create ~headers:(Httpun.Headers.of_list
        (Http_server_eio.Response.scoped_headers () @
         ["content-type", "text/event-stream"; "cache-control", "private, no-store";
          "connection", "close"; "x-accel-buffering", "no"])) `OK) in
  Eio.Fiber.fork ~sw (fun () ->
    match Eio.Switch.run (fun connection ->
      let stopped, stop = Eio.Promise.create () in
      let joined = ref false in
      let role = credential.Masc_domain.role in
      let presence_call f presence = f ~base_path:config.base_path ~agent_name:name ~role
          ~scope:presence ~sse_client_id:client_id in
      let disconnect () = Option.iter (fun presence ->
        match presence_call Play_room_presence.disconnect presence with
        | Ok () -> ()
        | Error _ -> Log.Server.warn "Play observation presence cleanup failed") presence in
      Eio.Switch.on_release connection (fun () ->
        Sse.unsubscribe_external id;
        ignore (Eio.Promise.try_resolve stop ());
        Server_sse_response.close response;
        disconnect ());
      let sync_presence () = match presence with
        | None -> true
        | Some presence ->
          (* Keep exact credential admission through the presence effect. A
             revoke/role replacement cannot slip between the read and Join. *)
          (match Auth.with_credential_transaction config.base_path (fun transaction ->
             match Auth.current_credential_in_transaction transaction name with
             | Error _ | Ok None -> false
             | Ok (Some actual) ->
               String.equal actual.token credential.token && actual.role = role
               && Masc_domain.has_permission actual.role Masc_domain.CanPlayMachine
               && Play_invite.expired ~now:(Time_compat.now ()) actual = Ok false
               && match Play_participation.current ~transaction ~base_path:config.base_path ~name with
                  | Error _ -> false
                  | Ok Play_participation.Departed -> disconnect (); joined := false; true
                  | Ok Play_participation.Connected ->
                    if !joined then Result.is_ok (presence_call Play_room_presence.renew presence)
                    else match presence_call Play_room_presence.connect presence with
                      | Ok Play_room_presence.Connected -> joined := true; true
                      | Ok Play_room_presence.Stale | Error _ -> false) with
           | Ok admitted -> admitted | Error _ -> false) in
      let queue = Server_sse_pump.Queue.create ~max_queued_events:Sse.stream_capacity in
      let expiry_wake = Eio.Stream.create 1 in
      let expiry_mu = Stdlib.Mutex.create () in
      let wake_expiry () = Stdlib.Mutex.protect expiry_mu (fun () ->
        if Eio.Stream.is_empty expiry_wake then Eio.Stream.add expiry_wake ()) in
      let authority = Sse.runtime_authority_exn ~base_path:config.base_path in
      Sse.subscribe_external ~runtime_authority:authority
        ~observer_instance_id:(Server_observer_scope.instance_id scope) ~id
        ~is_alive:(fun () -> not (Server_sse_response.is_closed response))
        ~callback:(fun event -> Option.iter (fun change ->
          Server_sse_pump.Queue.push queue change;
          match change with Seats | Snapshot -> wake_expiry () | Machine | Room | Keeper _ -> ())
          (change_of_payload ~machine event.Sse.ext_payload)) ();
      (* The subscription exists before the client is told to read. A commit
         during its initial GET queues another invalidation. *)
      Server_sse_pump.Queue.push queue Snapshot;
      let guard () = current () && sync_presence () in
      let pump () = Server_sse_pump.run ~source:(Server_sse_pump.Queue.source queue)
          ~step:(fun change -> if guard () then Server_sse_pump.Send (frame change) else Send_last unavailable)
          ~idle:(fun () -> Server_sse_pump.Quiet)
          ~clock ~ping_interval_s:Server_mcp_transport_http_headers.sse_ping_interval_s
          ~closed:(fun () -> Server_sse_response.await_closed response)
          ~send:(Server_sse_response.send response) |> ignore in
      let transport () =
        if guard () then (
        Server_machine_spectator.start ~sw:connection ~clock ~stop_promise:stopped ~machine ~config;
        Eio.Fiber.fork_daemon ~sw:connection (fun () ->
          let rec keepalive () =
            Eio.Time.sleep clock Server_mcp_transport_http_headers.sse_ping_interval_s;
            if guard () then
              (match Server_sse_response.send response ": keepalive\n\n" with
               | Written -> keepalive ()
               | Closed | Stalled -> Server_sse_response.close response)
            else (
              ignore (Server_sse_response.send response unavailable);
              Server_sse_response.close response) in
          keepalive (); `Stop_daemon);
        Eio.Fiber.fork_daemon ~sw:connection (fun () ->
          let rec deadlines () =
            match observe_seat_expiry ~base_path:config.base_path with
            | Error () ->
              ignore (Server_sse_response.send response unavailable);
              Server_sse_response.close response
            | Ok next ->
              (* A boundary may pass between the initial invalidation and
                 this scan. Resync after the scan as well as at its deadline. *)
              Server_sse_pump.Queue.push queue Seats;
              let changed () = Eio.Stream.take expiry_wake in
              (match next with
               | None -> changed ()
               | Some at -> ignore (Eio.Fiber.first changed (fun () -> Wall_deadline.sleep_until at)));
              deadlines () in
          deadlines (); `Stop_daemon);
        pump ())
        else ignore (Server_sse_response.send response unavailable) in
      let expiry () = match credential_expiry credential with
        | Error _ -> ()
        | Ok None -> Eio.Promise.await (Mcp_server.workspace_scope_replaced scope)
        | Ok (Some at) -> Wall_deadline.sleep_until at in
      ignore (Eio.Fiber.first
        (fun () -> transport ())
        (fun () -> Eio.Fiber.first expiry
          (fun () -> Eio.Promise.await (Mcp_server.workspace_scope_replaced scope))));
      (* The spectator is a child of this switch. Stop it before waiting for
         children; on_release alone runs too late on an ordinary disconnect. *)
      ignore (Eio.Promise.try_resolve stop ())) with
    | () -> ()
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> Log.Server.warn "Play observation ended: %s" (Printexc.exn_slot_name exn))

let add_routes router =
  router |> Server_route.get (Server_route.Token_permission Masc_domain.CanPlayMachine) path
    (fun state name request reqd ->
      let config = Mcp_server.workspace_config state in
      match query request, auth_token_from_request request, state.Mcp_server.sw, state.clock with
      | Error detail, _, _, _ -> respond_json_value_with_cors ~status:`Bad_request request reqd
          (Server_refusal.json ~code:"invalid_play_observation" detail)
      | Ok _, None, _, _ -> respond_json_value_with_cors ~status:`Unauthorized request reqd
          (Server_refusal.json ~code:"play_bearer_required" "Play observation requires a bearer header")
      | Ok _, Some _, None, _ | Ok _, Some _, _, None -> respond_json_value_with_cors
          ~status:`Service_unavailable request reqd (Server_refusal.json ~code:"not_ready" "Play observation is not ready")
      | Ok (machine, presence), Some token, Some sw, Some clock ->
        (match Auth.verify_token config.base_path ~agent_name:name ~token with
         | Error _ -> respond_json_value_with_cors ~status:`Unauthorized request reqd
             (Server_refusal.json ~code:"invalid_play_credential" "Play credential is unavailable")
         | Ok credential -> serve ~state ~name ~request ~reqd ~sw ~clock ~machine ~presence credential))

module For_testing = struct
  let next_seat_expiry = next_seat_expiry
  let observe_seat_expiry = observe_seat_expiry
end
