let ( let* ) = Result.bind

type lane_addons_slice_source = Cached_snapshot | Fresh_inventory

let catch_non_cancel ~on_error f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> on_error (Printexc.to_string exn)

let map_lane_addons (state : Masc_tui_types.state) f =
  match state.lane_addons with
  | Some view -> state.lane_addons <- Some (f view)
  | None -> state.lane_addons_cached <- f state.lane_addons_cached

let lane_addons_input_failure detail =
  Some (Masc_tui_lane_addons.Input_failure detail)

let lane_addons_detail_failure detail =
  Some (Masc_tui_lane_addons.Detail_read_failure detail)

(* A lane add-on request the workspace guard stopped, said as kept back and
   never as a failed read or request (RFC §2). *)
let lane_addons_kept_back (state : Masc_tui_types.state) ~request refusal =
  Some
    (Masc_tui_lane_addons.Kept_back
       (Masc_tui_types.workspace_refusal_text
          ~ko:(state.ui_language = Masc_tui_types.Lang_ko)
          ~request refusal))

(* An installer read the guard stopped: like a failed read, the installer
   goes back to what it showed before the read, but only when that read is
   the one pending. *)
let lane_installer_kept_back state (view : Masc_tui_lane_addons.t) read refusal =
  match view.installer with
  | Some installer
    when Masc_tui_lane_installer.pending_read installer = Some read ->
      let installer = Masc_tui_lane_installer.suspend_read installer in
      let package_directory =
        match read with
        | Masc_tui_lane_installer.Read_catalog _ ->
            Masc_tui_lane_installer.directory installer
        | Masc_tui_lane_installer.Read_preview _ -> view.package_directory
      in
      { view with
        loading = false
      ; installer = Some installer
      ; package_directory
      ; error =
          lane_addons_kept_back state
            ~request:Masc_tui_words.Kept_request.Addon_read refusal
      ; scroll = 0
      }
  | Some _ | None -> view

let launch_lane_application (state : Masc_tui_types.state) ~mailbox =
  if Masc_tui_types.server_authority_ready state then begin
    let module Addons = Masc_tui_lane_addons in
    match state.lane_addons with
    | None -> ()
    | Some view -> (
        match Addons.begin_application_read view with
        | None -> ()
        | Some (view, ticket) ->
            state.lane_addons <- Some view;
            let host = Masc_tui_transport.Workspace_admission.server_peer_host
            and port = state.port in
            Masc_tui_transport.Workspace_admission.launch_guarded_request state
              ~mailbox
              ~boundary_error:(fun detail ->
                Masc_tui_types.Request_failed detail)
              ~withdrawn:(fun refusal ->
                Masc_tui_types.Request_withdrawn refusal)
              ~deliver:(fun result ->
                Masc_tui_async_protocol.Lane_msg
                  (Masc_tui_async_protocol.Lane_application_loaded
                     (ticket, result)))
              (fun () ->
                Result.bind
                  (Masc_tui_http.get_json ~host ~port ~path:"/api/v1/lane-addons")
                  Addons.decode_configuration
                |> Result.map_error (fun detail ->
                       Masc_tui_types.Request_failed detail)))
  end

let lane_addons_request_failure detail =
  Some (Masc_tui_lane_addons.Request_failure detail)

let lane_addons_request_failure_kind request =
  let module Addons = Masc_tui_lane_addons in
  match request with
  | Addons.Inspect -> `Inventory
  | Addons.Slice _ | Addons.Action_status _ -> `Detail
  | Addons.Attach _ | Addons.Observe _ | Addons.Detach _ | Addons.Evidence _
  | Addons.Act _ | Addons.Subscriptions _ -> `Request

let lane_addons_failure_for_request request detail :
    Masc_tui_async_protocol.lane_addons_failure =
  match lane_addons_request_failure_kind request with
  | `Inventory -> `Inventory detail
  | `Detail -> `Detail detail
  | `Request -> `Request detail

let launch_lane_package_catalog (state : Masc_tui_types.state) ~mailbox
    directory =
  if Masc_tui_types.server_authority_ready state then begin
    let view =
      Option.value ~default:state.lane_addons_cached state.lane_addons
    in
    if view.loading then ()
    else (
      state.lane_addons_generation <- state.lane_addons_generation + 1;
      let generation = state.lane_addons_generation in
      state.lane_addons_reading <- Some generation;
      let pending =
        Result.bind
          (Option.to_result ~none:"No installation wizard" view.installer)
          (Masc_tui_lane_installer.begin_catalog ~request_id:generation
             ~directory)
      in
      match pending with
      | Error detail ->
          state.lane_addons <-
            Some { view with error = lane_addons_input_failure detail }
      | Ok installer ->
          state.lane_addons <-
            Some
              { view with
                generation
              ; installer = Some installer
              ; loading = true
              ; error = None
              ; scroll = 0
              };
          let host = Masc_tui_transport.Workspace_admission.server_peer_host
          and port = state.port in
          let query =
            match directory with
            | None -> ""
            | Some path ->
                "?directory=" ^ Masc_tui_http.percent_encode_query_value path
          in
          Masc_tui_transport.Workspace_admission.launch_guarded_request state
            ~mailbox
            ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
            ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
            ~deliver:(fun result ->
              Masc_tui_async_protocol.Lane_msg
                (Masc_tui_async_protocol.Lane_package_catalog_loaded
                   (generation, directory, result)))
            (fun () ->
              Masc_tui_http.get_json ~host ~port
                ~path:("/api/v1/lane-addons/package-catalog" ^ query)
              |> Result.map_error (fun detail ->
                     Masc_tui_types.Request_failed detail)))
  end

let launch_lane_package_preview (state : Masc_tui_types.state) ~mailbox path =
  if Masc_tui_types.server_authority_ready state then begin
    let view =
      Option.value ~default:state.lane_addons_cached state.lane_addons
    in
    if view.loading then ()
    else (
      state.lane_addons_generation <- state.lane_addons_generation + 1;
      let generation = state.lane_addons_generation in
      state.lane_addons_reading <- Some generation;
      let pending =
        Result.bind
          (Option.to_result ~none:"No installation wizard" view.installer)
          (Masc_tui_lane_installer.begin_preview ~request_id:generation ~path)
      in
      match pending with
      | Error detail ->
          state.lane_addons <-
            Some { view with error = lane_addons_input_failure detail }
      | Ok installer ->
          state.lane_addons <-
            Some
              { view with
                generation
              ; installer = Some installer
              ; loading = true
              ; error = None
              };
          let host = Masc_tui_transport.Workspace_admission.server_peer_host
          and port = state.port in
          Masc_tui_transport.Workspace_admission.launch_guarded_request state
            ~mailbox
            ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
            ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
            ~deliver:(fun result ->
              Masc_tui_async_protocol.Lane_msg
                (Masc_tui_async_protocol.Lane_package_preview_loaded
                   (generation, path, result)))
            (fun () ->
              Masc_tui_http.get_json ~host ~port
                ~path:
                  ("/api/v1/lane-addons/package-preview?manifest_path="
                  ^ Masc_tui_http.percent_encode_query_value path)
              |> Result.map_error (fun detail ->
                     Masc_tui_types.Request_failed detail)))
  end

let lane_draft_directory (view : Masc_tui_lane_addons.t) =
  Option.bind view.snapshot (fun (snapshot : Masc_tui_lane_addons.snapshot) ->
      Option.map
        (fun (config : Masc_tui_lane_addons.configuration) -> config.directory)
        snapshot.configuration)

let launch_lane_declaration (state : Masc_tui_types.state) ~mailbox ~edit
    request =
  if Masc_tui_types.server_authority_ready state then begin
    let module Document = Masc_tui_lane_declaration in
    let view =
      Option.value ~default:state.lane_addons_cached state.lane_addons
    in
    let create_directory = lane_draft_directory view in
    if view.loading then
      map_lane_addons state (fun view ->
          { view with
            error =
              lane_addons_input_failure
                "A request is pending; drafts remain editable"
          })
    else
      match
        match request with
        | Document.Read path ->
            Result.map (fun _ -> ())
              (Document.find_for_path ?create_directory ~path view.documents)
        | Document.Save _ -> Ok ()
      with
      | Error detail ->
          state.lane_addons <-
            Some
              { view with
                document_key = None
              ; editor_ready = false
              ; scroll = 0
              ; error = lane_addons_input_failure detail
              }
      | Ok () ->
          state.lane_addons_generation <- state.lane_addons_generation + 1;
          let generation = state.lane_addons_generation in
          state.lane_addons_reading <-
            (match request with
             | Document.Read _ -> Some generation
             | Document.Save _ -> None);
          state.lane_nested_read_resume <-
            (match request with
             | Document.Read path ->
                 Some
                   ( generation
                   , Masc_tui_types.Lane_declaration_read { path; edit } )
             | Document.Save _ -> None);
          let document_key =
            Some
              (match request with
               | Document.Read path -> Filename.basename path
               | Document.Save session -> session.Document.file_name)
          in
          state.lane_addons <-
            Some
              { view with
                generation
              ; loading = true
              ; error = None
              ; editor_ready = false
              ; document_key
              ; application_reading = Masc_tui_lane_application.empty
              };
          let host = Masc_tui_transport.Workspace_admission.server_peer_host
          and port = state.port in
          let perform () =
            let* status, body =
              match request with
              | Document.Read source_path ->
                  Masc_tui_http.http_get ~host ~port
                    ~path:
                      ("/api/v1/lane-addons/declaration?source_path="
                      ^ Masc_tui_http.percent_encode_query_value source_path)
              | Document.Save session ->
                  Masc_tui_http.http_post ~host ~port
                    ~headers:(Masc_tui_http.auth_headers ())
                    ~path:"/api/v1/lane-addons/declaration"
                    ~body:(Yojson.Safe.to_string (Document.write_json session))
            in
            Document.decode_response request ~status ~body
          in
          Masc_tui_transport.Workspace_admission.launch_guarded_request state
            ~mailbox
            ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
            ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
            ~deliver:(fun result ->
              Masc_tui_async_protocol.Lane_msg
                (Masc_tui_async_protocol.Lane_declaration_loaded
                   (generation, request, edit, create_directory, result)))
            (fun () ->
              Result.map_error
                (fun detail -> Masc_tui_types.Request_failed detail)
                (perform ()))
  end

let launch_lane_subscriptions (state : Masc_tui_types.state) ~mailbox request =
  if Masc_tui_types.server_authority_ready state then begin
    let module Subs = Masc_tui_lane_subscriptions in
    match state.lane_addons with
    | None -> ()
    | Some view when view.loading -> ()
    | Some view ->
        state.lane_addons_generation <- state.lane_addons_generation + 1;
        let generation = state.lane_addons_generation in
        state.lane_addons_reading <-
          (match request with
           | Subs.Inspect -> Some generation
           | Subs.Save _ -> None);
        state.lane_nested_read_resume <-
          (match request with
           | Subs.Inspect -> Some (generation, Masc_tui_types.Lane_subscriptions_read)
           | Subs.Save _ -> None);
        state.lane_addons <-
          Some { view with generation; loading = true; error = None };
        let host = Masc_tui_transport.Workspace_admission.server_peer_host
        and port = state.port in
        Masc_tui_transport.Workspace_admission.launch_guarded_request
          ~operation:
            (match request with Subs.Inspect -> false | Subs.Save _ -> true)
          state ~mailbox
          ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
          ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
          ~deliver:(fun result ->
            Masc_tui_async_protocol.Lane_msg
              (Masc_tui_async_protocol.Lane_subscriptions_loaded
                 (generation, result)))
          (fun () ->
            Result.bind
              (Masc_tui_http.post_json ~host ~port
                 ~path:"/api/v1/lane-addons/subscriptions"
                 ~body:(Yojson.Safe.to_string (Subs.request_json request)))
              Subs.decode
            |> Result.map_error (fun detail ->
                   Masc_tui_types.Request_failed detail))
  end

let launch_lane_addons ?target (state : Masc_tui_types.state) ~mailbox request =
  if not (Masc_tui_types.server_authority_ready state) then
    Masc_tui_loader.report_action state "error"
      (Masc_tui_transport.Request_notice.kept_back_until_reconnect
         ~ko:(state.ui_language = Masc_tui_types.Lang_ko)
         ~request:Masc_tui_words.Kept_request.Addon_request)
  else begin
    let module Addons = Masc_tui_lane_addons in
    let view =
      Option.value ~default:state.lane_addons_cached state.lane_addons
    in
    match Addons.request_read_target ?target view request with
    | Error refusal ->
        state.lane_addons <- Some (Addons.refuse_read_scope view refusal)
    | Ok target ->
        if view.loading then
          (* The answer to the key just pressed goes at the top of the pane, so a
             reader scrolled into a draft would not see it. *)
          state.lane_addons <-
            Some
              { view with
                scroll = 0
              ; error =
                  lane_addons_input_failure
                    "A Lane request is pending; Esc returns to existing activity"
              }
        else (
          state.lane_addons_generation <- state.lane_addons_generation + 1;
          let generation = state.lane_addons_generation in
          (match request, target with
           | Addons.Inspect, Addons.Read_detail (instance_id, incarnation) ->
               state.lane_addons_owed <-
                 Option.map
                   (fun ((owner, epoch), owed) ->
                     if String.equal owner instance_id && String.equal epoch incarnation
                     then (owner, epoch), Masc_tui_owed_read.started owed
                     else (owner, epoch), owed)
                   state.lane_addons_owed
           | ( Addons.Inspect
             , (Addons.Read_screen | Addons.Read_installation_results _) )
           | ( ( Addons.Attach _ | Addons.Observe _ | Addons.Detach _
               | Addons.Slice _ | Addons.Evidence _ | Addons.Act _
               | Addons.Action_status _ | Addons.Subscriptions _ )
             , _ ) -> ());
          state.lane_addons_reading <-
            (match request with
             | Addons.Inspect | Addons.Slice _ | Addons.Action_status _ ->
                 Some generation
             | Addons.Attach _ | Addons.Observe _ | Addons.Detach _
             | Addons.Evidence _ | Addons.Act _ | Addons.Subscriptions _ -> None);
          let last_action, action_receipt =
            match request with
            | Addons.Act action -> Some action, None
            | Addons.Action_status action -> Some action, view.action_receipt
            | Addons.Inspect | Addons.Attach _ | Addons.Observe _
            | Addons.Detach _ | Addons.Slice _ | Addons.Evidence _
            | Addons.Subscriptions _ -> view.last_action, view.action_receipt
          in
          let presentation =
            match request with
            | Addons.Subscriptions _ -> Addons.Technical
            | Addons.Inspect | Addons.Attach _ | Addons.Observe _
            | Addons.Detach _ | Addons.Slice _ | Addons.Evidence _
            | Addons.Act _ | Addons.Action_status _ -> view.presentation
          in
          let application_reading =
            match lane_addons_request_failure_kind request with
            | `Request ->
                Masc_tui_lane_application.suspend view.application_reading
            | `Inventory | `Detail -> view.application_reading
          in
          let initial_detail =
            match target with
            | Addons.Read_detail (id, incarnation) -> Some (id, incarnation)
            | Addons.Read_screen | Addons.Read_installation_results _ -> None
          in
          let pending_view =
            { (Addons.set_presentation view presentation) with
              generation
            ; loading = true
            ; error = None
            ; application_reading
            ; draft = None
            ; action_menu = None
            ; last_action
            ; action_receipt
            }
          in
          state.lane_addons <- Some pending_view;
          let host = Masc_tui_transport.Workspace_admission.server_peer_host
          and port = state.port in
          let broadcast_path =
            Filename.concat
              (Common.masc_dir_from_base_path ~base_path:state.local_base_path)
              "tui-lane-broadcast.jsonl"
          in
          let broadcast_scope =
            Masc_tui_types.broadcast_workspace_scope
              ~local_paths:state.local_workspace_paths state.server_identity
          in
          let broadcast_workspace_verified =
            state.workspace_identity = Masc_tui_types.Workspace_identity_match
          in
          let authority = state.workspace_authority in
          let identity = state.server_identity in
          let check_request =
            Masc_tui_transport.Workspace_admission.admission_sequence state
              ~mailbox ~authority ~identity ~host ~port
          in
          (* Each request in the chain is admitted again. The guard's refusal stays
             apart from the request's own failure, which [kind] names. *)
          let guarded kind send =
            match check_request () with
            | Error refusal -> Error (`Kept_back refusal)
            | Ok () -> Result.map_error kind (send ())
          in
          let get_json kind ~path =
            guarded kind (fun () -> Masc_tui_http.get_json ~host ~port ~path)
          in
          let post_json kind ~path ~body =
            guarded kind (fun () ->
                Masc_tui_http.post_json ~host ~port ~path ~body)
          in
          let perform () =
            let inventory_failure detail = `Inventory detail in
            let detail_failure detail = `Detail detail in
            let request_failure detail = `Request detail in
            let detail_result result = Result.map_error detail_failure result in
            let request_result result =
              Result.map_error request_failure result
            in
            let reply ?snapshot ?receipt ?action ?diagnostic
                ?(inventory_read = `Unchanged) ?kept_back () =
              { Masc_tui_async_protocol.lar_snapshot = snapshot
              ; lar_receipt = receipt
              ; lar_action = action
              ; lar_diagnostic = diagnostic
              ; lar_inventory_read = inventory_read
              ; lar_kept_back = kept_back
              }
            in
            let inspect () =
              catch_non_cancel
                ~on_error:(fun detail -> Error (inventory_failure detail))
                (fun () ->
                  let* json =
                    get_json inventory_failure ~path:"/api/v1/lane-addons"
                  in
                  Result.map_error inventory_failure (Addons.decode json))
            in
            match request with
            | Addons.Inspect -> (
                let* snapshot = inspect () in
                let retained =
                  Option.bind initial_detail (fun (id, incarnation) ->
                      List.find_opt
                        (fun (item : Addons.instance) ->
                          item.id = id && item.incarnation = incarnation
                          && item.runtime_presence = Addons.Retained_binding)
                        snapshot.Addons.instances)
                in
                match retained with
                | None -> Ok (reply ~snapshot ~inventory_read:`Read ())
                | Some item -> (
                    let history =
                      Result.bind
                        (get_json detail_failure
                           ~path:
                             ("/api/v1/lane-addons/slice?run_id="
                             ^ Masc_tui_http.percent_encode_query_value
                                 item.run_id))
                        (fun json ->
                          detail_result (Addons.decode_slice ~snapshot json))
                    in
                    match history with
                    | Ok snapshot -> Ok (reply ~snapshot ~inventory_read:`Read ())
                    | Error (`Detail detail) ->
                        Ok
                          (reply ~snapshot ~inventory_read:`Read
                             ~diagnostic:(Addons.Detail_read_failure detail) ())
                    | Error (`Kept_back refusal) ->
                        Ok
                          (reply ~snapshot ~inventory_read:`Read
                             ~kept_back:refusal ())))
            | Addons.Subscriptions args ->
                let* json =
                  post_json request_failure
                    ~path:"/api/v1/lane-addons/subscriptions"
                    ~body:(Yojson.Safe.to_string args)
                in
                Ok (reply ~receipt:json ())
            | Addons.Slice query -> (
                let path =
                  match query with
                  | [] -> "/api/v1/lane-addons/slice"
                  | _ :: _ ->
                      let query =
                        List.map
                          (fun (key, value) ->
                            key ^ "="
                            ^ Masc_tui_http.percent_encode_query_value value)
                          query
                        |> String.concat "&"
                      in
                      "/api/v1/lane-addons/slice?" ^ query
                in
                let* json = get_json detail_failure ~path in
                let* previous, source =
                  match view.snapshot with
                  | Some snapshot -> Ok (snapshot, Cached_snapshot)
                  | None ->
                      let* snapshot = inspect () in
                      Ok (snapshot, Fresh_inventory)
                in
                let inventory_read =
                  match source with
                  | Cached_snapshot -> `Unchanged
                  | Fresh_inventory -> `Read
                in
                match Addons.decode_slice ~snapshot:previous json with
                | Ok snapshot -> Ok (reply ~snapshot ~inventory_read ())
                | Error detail -> (
                    match source with
                    | Fresh_inventory ->
                        Ok
                          (reply ~snapshot:previous ~inventory_read
                             ~diagnostic:(Addons.Detail_read_failure detail) ())
                    | Cached_snapshot -> Error (`Detail detail)))
            | Addons.Act action | Addons.Action_status action ->
                let* json =
                  match request with
                  | Addons.Act _ ->
                      post_json request_failure
                        ~path:"/api/v1/lane-addons/actions"
                        ~body:(Yojson.Safe.to_string (Addons.action_json action))
                  | Addons.Inspect | Addons.Attach _ | Addons.Observe _
                  | Addons.Detach _ | Addons.Slice _ | Addons.Evidence _
                  | Addons.Action_status _ | Addons.Subscriptions _ ->
                      get_json detail_failure
                        ~path:
                          ("/api/v1/lane-addons/actions?instance_id="
                          ^ Masc_tui_http.percent_encode_query_value
                              action.Addons.instance_id
                          ^ "&request_id="
                          ^ Masc_tui_http.percent_encode_query_value
                              action.Addons.request_id)
                in
                let* receipt =
                  match request with
                  | Addons.Act _ ->
                      request_result (Addons.action_receipt action json)
                  | Addons.Inspect | Addons.Attach _ | Addons.Observe _
                  | Addons.Detach _ | Addons.Slice _ | Addons.Evidence _
                  | Addons.Action_status _ | Addons.Subscriptions _ ->
                      detail_result (Addons.action_receipt action json)
                in
                Ok (reply ~receipt:json ~action:receipt ())
            | Addons.Attach _ | Addons.Observe _ | Addons.Detach _
            | Addons.Evidence _ -> (
                let suffix, body =
                  match request with
                  | Addons.Attach json -> "attach", json
                  | Addons.Observe id ->
                      "observe", `Assoc [ "instance_id", `String id ]
                  | Addons.Detach id ->
                      "detach", `Assoc [ "instance_id", `String id ]
                  | Addons.Evidence json -> "evidence", json
                  | Addons.Inspect | Addons.Slice _ | Addons.Act _
                  | Addons.Action_status _ | Addons.Subscriptions _ ->
                      assert false
                in
                let broadcast =
                  match request, body with
                  | Addons.Evidence _, `Assoc fields ->
                      List.assoc_opt "broadcast" fields = Some (`Bool true)
                  | ( Addons.Evidence _
                    , ( `Null | `List _ | `Bool _ | `Float _ | `Int _
                      | `Intlit _ | `String _ ) )
                  | ( ( Addons.Inspect | Addons.Attach _ | Addons.Observe _
                      | Addons.Detach _ | Addons.Slice _ | Addons.Act _
                      | Addons.Action_status _ | Addons.Subscriptions _ )
                    , _ ) -> false
                in
                let credential = Masc_tui_http.bind_credential () in
                let* scope =
                  if not broadcast then Ok None
                  else if not broadcast_workspace_verified then
                    Error
                      (`Request
                         "Verify the server workspace before sharing evidence via Broadcast")
                  else
                    match broadcast_scope with
                    | Some scope -> Ok (Some scope)
                    | None ->
                        Error
                          (`Request
                             "Verify the server workspace before sharing evidence via Broadcast")
                in
                let* principal =
                  match scope with
                  | None -> Ok None
                  | Some _ ->
                      guarded request_failure (fun () ->
                          Masc_tui_http.lane_broadcast_principal_bound
                            ~credential ~host ~port)
                      |> Result.map Option.some
                in
                let* body =
                  match principal, scope with
                  | None, _ -> Ok body
                  | Some principal, Some scope ->
                      request_result
                        (Masc_tui_lane_broadcast_pending.prepare
                           ~path:broadcast_path ~scope ~credential:principal body)
                  | Some _, None ->
                      Error
                        (`Request "Broadcast workspace scope is unavailable")
                in
                let post ~path ~body =
                  if broadcast then
                    guarded request_failure (fun () ->
                        Masc_tui_http.post_json_bound ~credential ~host ~port
                          ~path ~body)
                  else post_json request_failure ~path ~body
                in
                let* receipt =
                  post
                    ~path:("/api/v1/lane-addons/" ^ suffix)
                    ~body:(Yojson.Safe.to_string body)
                in
                let diagnostic =
                  match principal, scope with
                  | None, _ -> None
                  | Some principal, Some scope -> (
                      match
                        Masc_tui_lane_broadcast_pending.acknowledge
                          ~path:broadcast_path ~scope ~credential:principal
                          ~request:body receipt
                      with
                      | Ok () -> None
                      | Error detail ->
                          Some
                            (Addons.Request_failure
                               ("Broadcast receipt received; retry tracking could not be confirmed: "
                               ^ detail)))
                  | Some _, None ->
                      Some
                        (Addons.Request_failure
                           "Broadcast workspace scope is unavailable")
                in
                match request with
                | Addons.Evidence _ ->
                    (* Preserving evidence does not change worker inventory. That
                       inventory omits retained rows, so applying it here would erase
                       the original result view after its receipt was saved. *)
                    Ok (reply ~receipt ?diagnostic ())
                | Addons.Attach _ | Addons.Observe _ | Addons.Detach _ -> (
                    match inspect () with
                    | Ok snapshot ->
                        Ok
                          (reply ~snapshot ~receipt ?diagnostic
                             ~inventory_read:`Read ())
                    | Error (`Inventory detail) ->
                        Ok
                          (reply ~receipt ?diagnostic
                             ~inventory_read:(`Failed detail) ())
                    (* The change was applied; only the read after it was kept back. *)
                    | Error (`Kept_back refusal) ->
                        Ok
                          (reply ~receipt ?diagnostic ~kept_back:refusal ()))
                | Addons.Inspect | Addons.Slice _ | Addons.Act _
                | Addons.Action_status _ | Addons.Subscriptions _ ->
                    assert false)
          in
          Masc_tui_transport.Workspace_admission.launch_guarded_request
            ~operation:
              (match request with
               | Addons.Inspect | Addons.Slice _ | Addons.Action_status _ ->
                   false
               | Addons.Attach _ | Addons.Observe _ | Addons.Detach _
               | Addons.Evidence _ | Addons.Act _ | Addons.Subscriptions _ ->
                   true)
            state ~mailbox
            ~boundary_error:(lane_addons_failure_for_request request)
            ~withdrawn:(fun refusal -> `Kept_back refusal)
            ~deliver:(fun result ->
              Masc_tui_async_protocol.Lane_msg
                (Masc_tui_async_protocol.Lane_addons_loaded
                   (generation, target, result)))
            perform)
  end

let launch_browser_history (state : Masc_tui_types.state) ~mailbox ~reload =
  let module Browser_history = Masc_tui_types.Browser_history in
  if Masc_tui_types.server_authority_ready state then begin
    match state.browser_history with
    | None -> ()
    | Some history ->
        state.browser_history_generation <- state.browser_history_generation + 1;
        let generation = state.browser_history_generation in
        (* A recovered read owns Loading again. A second identity outage must
           retire and resume this request just like the first one. *)
        let history = Browser_history.start_read ~reload history in
        state.browser_history <- Some history;
        let host = Masc_tui_transport.Workspace_admission.server_peer_host
        and port = state.port in
        if reload then
          Masc_tui_transport.Workspace_admission.launch_json_read state ~mailbox
            ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
            ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
            ~deliver:(fun result ->
              Masc_tui_async_protocol.Browser_msg
                (Masc_tui_async_protocol.Browser_history_list_loaded
                   (generation, result)))
            (fun () ->
              Masc_tui_http.fetch_keeper_calls ~host ~port
                ~keeper_name:history.Browser_history.keeper_name ~limit:100
              |> Result.map_error (fun detail ->
                     Masc_tui_types.Request_failed detail))
        else begin
          let enqueue_async =
            Masc_tui_transport.Workspace_admission.workspace_enqueue state
          in
          let fetch () =
            Masc_tui_async_protocol.Browser_msg
              (Masc_tui_async_protocol.Browser_history_page_loaded
                 ( generation
                 , match Browser_history.selected history with
                   | None ->
                       Error
                         "No retained observations in these 100 recent tool calls"
                   | Some entry ->
                       Masc_tui_http.fetch_browser_observation ~host ~port
                         entry.Browser_history.artifact ))
          in
          let perform () =
            catch_non_cancel
              ~on_error:(fun detail ->
                Masc_tui_async_protocol.Browser_msg
                  (Masc_tui_async_protocol.Browser_history_page_loaded
                     (generation, Error detail)))
              fetch
          in
          match Eio_context.get_switch_opt () with
          | None ->
              state.browser_history <-
                Some
                  { history with
                    Browser_history.content =
                      Browser_history.List_failed "Eio switch is unavailable"
                  }
          | Some sw ->
              Eio.Fiber.fork_daemon ~sw (fun () ->
                  enqueue_async mailbox (perform ());
                  `Stop_daemon)
        end
  end
  else begin
    (* Opening or changing history can own a loading state after the last
       identity failure already retired reads. Keep this unsent selection
       eligible for recovery too. *)
    state.browser_history_generation <- state.browser_history_generation + 1;
    state.browser_history <-
      Option.map Browser_history.suspend state.browser_history
  end

let launch_browser_lane (state : Masc_tui_types.state) ~mailbox operation =
  let module View = Masc_tui_types.Browser_lane_view in
  let enqueue_async =
    Masc_tui_transport.Workspace_admission.workspace_enqueue state
  in
  if Masc_tui_types.server_authority_ready state then begin
    match state.browser_lane with
    | Some view when Option.is_some state.browser_history -> (
        match operation with
        | View.Read -> state.browser_lane <- Some (View.defer_read view)
        | View.Read_refresh | View.Discover _ | View.Screenshot _
        | View.Scene_read _ | View.Scene_regions _ | View.Scene_refresh _
        | View.Scene_scroll _ | View.Scene_focus _ | View.Scene_click _
        | View.Scene_follow _ | View.Scene_follow_refresh _
        | View.Viewport_refresh _ | View.Viewport_observed _
        | View.Viewport_pointer _ -> ())
    | None -> ()
    | Some view when View.busy view -> ()
    | Some view
      when (match operation with
            | View.Read | View.Read_refresh | View.Screenshot _
            | View.Scene_read _ | View.Scene_regions _ | View.Scene_scroll _
            | View.Scene_refresh _ | View.Scene_focus _ | View.Scene_click _
            | View.Scene_follow _ | View.Scene_follow_refresh _
            | View.Viewport_refresh _ | View.Viewport_observed _
            | View.Viewport_pointer _ -> true
            | View.Discover _ -> false)
           && not (View.selected_client_available view) ->
        state.browser_lane <-
          Some
            { view with
              View.client_picker = Some 0
            ; scene = None
            ; scene_cursor = 0
            ; scene_scope = None
            ; scene_delta = None
            ; load =
                View.Failed "Choose a connected browser before reading its tabs"
            }
    | Some view -> (
        (* Scene geometry belongs to its observation. Browser effects and explicit
           reads and effectful gestures withdraw it before dispatch; a scroll
           keeps the prior observation visible while its replacement is checked;
           a screenshot may itself observe a
           navigation, so dismissing its overlay must not resurrect old nodes.
           Scene_click and Scene_follow retain their exact reference in
           [operation], and the matching completion can install the newly
           observed scene. A follow additionally pins the navigation receipt so
           a same-URL reload cannot be mistaken for a completed transition; a
           failed destination read keeps that guard for [Scene_follow_refresh]
           and never carries the old region scope into the destination. A cadence
           refresh keeps its frame visible so periodic observations do not erase
           the operator's reading position. Operator input supersedes a cadence
           result; effects still use the observed document/URL checks. Failed
           refreshes withdraw that scene. *)
        let view =
          match operation with
          | View.Discover _ | View.Read_refresh | View.Scene_refresh _
          | View.Viewport_observed _ -> view
          | View.Read | View.Screenshot _ | View.Scene_read _
          | View.Scene_regions _ | View.Scene_follow _
          | View.Scene_follow_refresh _ | View.Viewport_refresh _
          | View.Viewport_pointer _ ->
              { view with
                View.scene = None
              ; scene_cursor = 0
              ; scene_scope = None
              ; scene_delta = None
              }
          | View.Scene_scroll _ -> view
          | View.Scene_click _ | View.Scene_focus _ ->
              { view with
                View.scene = None
              ; scene_cursor = 0
              ; scene_delta = None
              }
        in
        state.browser_lane_generation <- state.browser_lane_generation + 1;
        let generation = state.browser_lane_generation in
        let image_generation = state.image_request_generation in
        let launched =
          { view with
            View.load = View.Loading (generation, operation)
          ; read_continuation =
              (match operation with
               | View.Read -> View.No_read_continuation
               | View.Discover _ | View.Screenshot _ | View.Read_refresh
               | View.Scene_read _ | View.Scene_regions _ | View.Scene_refresh _
               | View.Scene_scroll _ | View.Scene_focus _ | View.Scene_click _
               | View.Scene_follow _ | View.Scene_follow_refresh _
               | View.Viewport_refresh _ | View.Viewport_observed _
               | View.Viewport_pointer _ -> view.View.read_continuation)
          ; read_view = View.read_view_for_operation operation view.View.read_view
          ; refresh_pending =
              (if View.operation_is_refresh operation then Some generation
               else view.View.refresh_pending)
          }
        in
        (* The picker withholds the previous list and host while asking again.
           Its dated startup recovery evidence remains until a successful list answers.
           Every other request leaves what the last discovery said. *)
        state.browser_lane <-
          Some
            (match operation with
             | View.Discover View.Choose_client ->
                 View.withdraw_discovery launched
             | View.Discover View.Read_after_discovery | View.Read
             | View.Read_refresh | View.Screenshot _ | View.Scene_read _
             | View.Scene_regions _ | View.Scene_scroll _
             | View.Scene_refresh _ | View.Scene_focus _ | View.Scene_click _
             | View.Scene_follow _ | View.Scene_follow_refresh _
             | View.Viewport_refresh _ | View.Viewport_observed _
             | View.Viewport_pointer _ -> launched);
        let host = Masc_tui_transport.Workspace_admission.server_peer_host
        and port = state.port in
        (* The mailbox is the effect boundary. Cancellation still belongs to
           the switch; unexpected transport failures become visible errors. *)
        let call f = catch_non_cancel ~on_error:Result.error f in
        let perform () =
          match operation with
          | View.Discover _ ->
              Masc_tui_async_protocol.Browser_msg
                (Masc_tui_async_protocol.Browser_lane_clients_loaded
                   ( generation
                   , call (fun () ->
                         Masc_tui_http.fetch_browser_lane_clients ~host ~port)
                   ))
          | View.Read | View.Read_refresh ->
              Masc_tui_async_protocol.Browser_msg
                (Masc_tui_async_protocol.Browser_lane_loaded
                   ( generation
                   , call (fun () ->
                         Masc_tui_http.fetch_browser_lane ~host ~port view) ))
          | View.Scene_read tab_id ->
              Masc_tui_async_protocol.Browser_msg
                (Masc_tui_async_protocol.Browser_lane_scene_loaded
                   ( generation
                   , call (fun () ->
                         Masc_tui_http.fetch_browser_scene ~host ~port ~view
                           ~tab_id ()) ))
          | View.Scene_regions tab_id ->
              Masc_tui_async_protocol.Browser_msg
                (Masc_tui_async_protocol.Browser_lane_scene_loaded
                   ( generation
                   , call (fun () ->
                         Masc_tui_http.fetch_browser_scene
                           ~scene_view:Browser_lane.Regions ~host ~port ~view
                           ~tab_id ()) ))
          | View.Scene_scroll
              { tab_id; expected_url; scene_view; scope; delta_y; _ } ->
              Masc_tui_async_protocol.Browser_msg
                (Masc_tui_async_protocol.Browser_lane_scene_loaded
                   ( generation
                   , call (fun () ->
                         Result.bind
                           (Masc_tui_http.scroll_browser_scene ~host ~port ~view
                              ~tab_id ~expected_url ~delta_y)
                           (fun () ->
                             Masc_tui_http.fetch_browser_scene ?scope
                               ~expected_url ~scene_view ~host ~port ~view ~tab_id
                               ())) ))
          | View.Scene_refresh { tab_id; scene_view; scope } ->
              Masc_tui_async_protocol.Browser_msg
                (Masc_tui_async_protocol.Browser_lane_scene_loaded
                   ( generation
                   , call (fun () ->
                         Masc_tui_http.refresh_browser_scene ~host ~port ~view
                           ~tab_id ~scene_view ~scope) ))
          | View.Scene_focus { tab_id; target } ->
              Masc_tui_async_protocol.Browser_msg
                (Masc_tui_async_protocol.Browser_lane_scene_loaded
                   ( generation
                   , call (fun () ->
                         Masc_tui_http.fetch_browser_scene ~scope:target ~host
                           ~port ~view ~tab_id ()) ))
          | View.Scene_click
              { tab_id; document_id; node_id; expected_url; scope } ->
              Masc_tui_async_protocol.Browser_msg
                (Masc_tui_async_protocol.Browser_lane_scene_loaded
                   ( generation
                   , call (fun () ->
                         Result.bind
                           (Masc_tui_http.click_browser_scene ~host ~port ~view
                              ~tab_id ~document_id ~node_id ~expected_url)
                           (fun () ->
                             Masc_tui_http.fetch_browser_scene ?scope ~host ~port
                               ~view ~tab_id ())) ))
          | View.Scene_follow { tab_id; document_id; node_id; expected_url } ->
              Masc_tui_async_protocol.Browser_msg
                (Masc_tui_async_protocol.Browser_lane_follow_loaded
                   ( generation
                   , call (fun () ->
                         match
                           Masc_tui_http.follow_browser_scene ~host ~port ~view
                             ~tab_id ~document_id ~node_id ~expected_url
                         with
                         | Error detail -> Error detail
                         | Ok receipt ->
                             let expected_source : Masc.Browser_scene.navigation_source =
                               { url = expected_url; document_id }
                             in
                             if
                               receipt.Masc_tui_http.navigation_source
                               <> expected_source
                             then Error "follow receipt navigation source mismatch"
                             else
                               Ok
                                 ( receipt
                                 , Masc_tui_http.fetch_browser_scene
                                     ?expected_url:
                                       (Some
                                          receipt.Masc_tui_http.destination_url)
                                     ?navigation_source:
                                       (Some
                                          receipt
                                            .Masc_tui_http.navigation_source)
                                     ~host ~port ~view ~tab_id () )) ))
          | View.Scene_follow_refresh { tab_id; guard; scene_view } ->
              Masc_tui_async_protocol.Browser_msg
                (Masc_tui_async_protocol.Browser_lane_scene_loaded
                   ( generation
                   , call (fun () ->
                         Masc_tui_http.fetch_browser_scene ~scene_view
                           ~expected_url:guard.View.expected_url
                           ~navigation_source:guard.View.navigation_source
                           ~host ~port ~view ~tab_id ()) ))
          | View.Screenshot tab_id
          | View.Viewport_refresh { tab_id; _ }
          | View.Viewport_observed tab_id ->
              Masc_tui_async_protocol.Browser_msg
                (Masc_tui_async_protocol.Browser_lane_screenshot_ready
                   { generation
                   ; image_generation
                   ; result =
                       call (fun () ->
                           Masc_tui_http.fetch_browser_lane_screenshot ~host
                             ~port ~view ~tab_id)
                   })
          | View.Viewport_pointer { tab_id; expected_url; action } ->
              Masc_tui_async_protocol.Browser_msg
                (Masc_tui_async_protocol.Browser_lane_screenshot_ready
                   { generation
                   ; image_generation
                   ; result =
                       call (fun () ->
                           Result.bind
                             (Masc_tui_http.act_browser_viewport ~host ~port
                                ~view ~tab_id ~expected_url ~action)
                             (fun () ->
                               Masc_tui_http.fetch_browser_lane_screenshot ~host
                                 ~port ~view ~tab_id))
                   })
        in
        match Eio_context.get_switch_opt () with
        | Some sw ->
            (* Inventory and page content settle independently. A slow activity
               read must not delay the page result or change its owner. *)
            if
              View.operation_is_refresh operation && view.View.source = View.Live
            then
              Eio.Fiber.fork_daemon ~sw (fun () ->
                  Eio.Fiber.yield ();
                  enqueue_async mailbox
                    (Masc_tui_async_protocol.Browser_msg
                       (Masc_tui_async_protocol.Browser_lane_clients_loaded
                          ( generation
                          , call (fun () ->
                                Masc_tui_http.fetch_browser_lane_clients ~host
                                  ~port) )));
                  `Stop_daemon);
            Eio.Fiber.fork_daemon ~sw (fun () ->
                let message = perform () in
                enqueue_async mailbox
                  (if View.operation_is_read operation then message
                   else Masc_tui_async_protocol.Workspace_operation message);
                `Stop_daemon)
        | None ->
            state.browser_lane <-
              Some
                { view with
                  View.load = View.Failed "Eio switch is unavailable"
                })
  end

let refresh_browser_lane (state : Masc_tui_types.state) ~mailbox =
  let module View = Masc_tui_types.Browser_lane_view in
  match state.browser_lane with
  | Some view when not (View.busy view) ->
      state.browser_lane <- Some (View.refresh view);
      launch_browser_lane state ~mailbox
        (match view.View.selection, view.View.source with
         | View.Live_unbound, _ -> View.Discover View.Choose_client
         | View.Unbound, _ | (View.Bound_automatic | View.Bound_explicit), View.Live ->
             View.Discover View.Read_after_discovery)
  | Some _ | None -> ()

let open_browser_lane state ~mailbox =
  Masc_tui_types.show_browser_lane state;
  Masc_tui_types.release_composer_for_browser_reader state;
  refresh_browser_lane state ~mailbox
