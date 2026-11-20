let ( let* ) = Result.bind

let launch_runtime_config_load ?(force = false) (state : Masc_tui_types.state)
    ~mailbox =
  if Masc_tui_types.server_authority_ready state then begin
    match state.runtime_config_read with
    | `Loading pending -> state.runtime_config_read <- `Loading (pending || force)
    | `Idle ->
        (* Cadence ticks share a single read. Only an explicit new intent or a
           write queues another read, whose source must be newer than this one. *)
        state.runtime_config_read <- `Loading false;
        state.runtime_config_owed <-
          Masc_tui_owed_read.started state.runtime_config_owed;
        state.runtime_config_generation <- state.runtime_config_generation + 1;
        let generation = state.runtime_config_generation in
        let requested_model = state.runtime_model_jump in
        let host = Masc_tui_transport.Workspace_admission.server_peer_host in
        let port = state.port in
        let started_ns = Mtime_clock.elapsed_ns () in
        Log.Transport.info
          "tui_runtime_config_read generation=%d started_ns=%Ld phase=started"
          generation started_ns;
        Masc_tui_transport.Workspace_admission.launch_guarded_request state ~mailbox
          ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
          ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
          ~deliver:(fun result ->
            let ready_ns = Mtime_clock.elapsed_ns () in
            Log.Transport.info
              "tui_runtime_config_read generation=%d started_ns=%Ld ready_ns=%Ld phase=prepared outcome=%s"
              generation started_ns ready_ns
              (match result with Ok _ -> "source_loaded" | Error _ -> "read_failed");
            Masc_tui_async_protocol.Runtime_msg
              (Masc_tui_async_protocol.Runtime_config_view_loaded
                 (generation, requested_model, started_ns, ready_ns, result)))
          (fun () ->
            Masc_tui_loader.load_runtime_config_snapshot ~host ~port
            |> Result.map_error (fun detail -> Masc_tui_types.Request_failed detail))
  end

let commit_runtime_config_text ?prior_contact (state : Masc_tui_types.state)
    ~mailbox ~authority ~identity ~before_commit ~expected_source_path
    ~expected_source_revision edited =
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.port in
  (* The guard's refusal is [`Kept_back]: the save was not sent, so it is
     never the server's refusal (RFC §2). *)
  let admit ?prior_contact () =
    Masc_tui_transport.Workspace_admission.admit_request ?prior_contact state
      ~mailbox ~authority ~identity ~host ~port ()
    |> Result.map_error (fun refusal -> `Kept_back refusal)
  in
  let refused result =
    Result.map_error
      (fun detail -> `Save (Masc_tui_http.Runtime_config_save_refused detail))
      result
  in
  let* () = admit ?prior_contact () in
  let* preview =
    refused
      (Masc_tui_http.post_runtime_config_preview ~host ~port ~source_text:edited)
  in
  let* preview =
    refused (Masc_tui_runtime_config_receipt.decode_preview preview)
  in
  match preview with
  | Masc_tui_runtime_config_receipt.Cannot_save reason ->
      Error
        (`Save
           (Masc_tui_http.Runtime_config_save_refused
              ("Preview rejected the edit: " ^ reason)))
  | Masc_tui_runtime_config_receipt.Can_save ->
      let* () =
        admit ~prior_contact:Masc_tui_server_lifecycle.Server_reached ()
      in
      before_commit ();
      Masc_tui_http.post_runtime_config_raw ~host ~port ~source_text:edited
        ~expected_source_path ~expected_source_revision
      |> Result.map_error (fun error -> `Save error)

let save_runtime_config_text ?prior_contact state ~mailbox ~authority ~identity
    ~expected_source_path ~expected_source_revision edited =
  match
    commit_runtime_config_text ?prior_contact state ~mailbox ~authority ~identity
      ~before_commit:(fun () -> ())
      ~expected_source_path ~expected_source_revision edited
  with
  | Error _ as error -> error
  | Ok receipt ->
      launch_runtime_config_load ~force:true state ~mailbox;
      Ok receipt

let launch_keeper_settings_save (state : Masc_tui_types.state) ~mailbox
    (request : Masc_tui_types.keeper_settings_save_request) =
  let host = Masc_tui_transport.Workspace_admission.server_peer_host
  and port = state.port in
  let key = request.ksv_key in
  let sent = ref false
  and prepared = ref None in
  let publish status =
    let observed_ns = Mtime_clock.elapsed_ns () in
    if Masc_tui_types.publish_keeper_settings_save request ~observed_ns status then
      Log.Transport.info
        "tui_keeper_settings_save keeper=%s intent=%s started_ns=%Ld observed_ns=%Ld worker_phase=%s"
        key.ksk_keeper
        (Masc_tui_types.keeper_settings_save_intent_name request)
        request.ksv_started_ns observed_ns
        (Masc_tui_types.keeper_settings_save_phase status)
  in
  let finish outcome =
    publish (Masc_tui_types.Settings_finished (!prepared, outcome))
  in
  let interrupted detail =
    if !sent then Masc_tui_types.Settings_unconfirmed detail
    else Masc_tui_types.Settings_not_sent detail
  in
  let check_workspace =
    Masc_tui_transport.Workspace_admission.admission_sequence state ~mailbox
      ~authority:key.ksk_authority ~identity:(Some request.ksv_expected) ~host
      ~port
  in
  (* The guard's refusal is [Settings_kept_back]: the save was not sent, and
     it is never said as the read's or the server's failure (RFC §2). *)
  let check () =
    if request.ksv_reading != state.workspace_read_authority then
      Error
        (Masc_tui_types.Settings_not_sent
           "Settings read authority withdrew before dispatch")
    else
      Result.map_error
        (fun refusal -> Masc_tui_types.Settings_kept_back refusal)
        (check_workspace ())
  in
  let run () =
    let outcome =
      try
        let not_sent result =
          Result.map_error
            (fun detail -> Masc_tui_types.Settings_not_sent detail)
            result
        in
        let prepare () =
          let* () = check () in
          let* snapshot =
            match request.ksv_input with
            | Masc_tui_types.Settings_editor_input draft ->
                Ok
                  { Masc_tui_types.ksp_snapshot =
                      draft.Masc_tui_types.ksd_snapshot
                        .Masc_tui_types.kss_observed
                  ; ksp_patch = Some draft.Masc_tui_types.ksd_patch
                  }
            | Masc_tui_types.Sandbox_shortcut_input profile ->
                publish Masc_tui_types.Settings_reading;
                let* json =
                  not_sent
                    (Masc_tui_http.fetch_keeper_config_snapshot ~host ~port
                       ~keeper_name:key.ksk_keeper)
                in
                let* patch =
                  not_sent
                    (Masc_tui_response_decode.run
                       ~name:"keeper.sandbox_save.decode_wait" (fun () ->
                         Masc_tui_keeper_config.sandbox_patch ~profile json))
                in
                Ok
                  { Masc_tui_types.ksp_snapshot = json; ksp_patch = patch }
          in
          prepared := Some snapshot;
          let* () =
            match request.ksv_input with
            | Masc_tui_types.Settings_editor_input _ -> Ok ()
            | Masc_tui_types.Sandbox_shortcut_input _ -> check ()
          in
          if request.ksv_reading != state.workspace_read_authority then
            Error
              (Masc_tui_types.Settings_not_sent
                 "Settings read authority withdrew before dispatch")
          else Ok snapshot
        in
        match prepare () with
        | Error outcome -> outcome
        | Ok snapshot -> (
            match snapshot.Masc_tui_types.ksp_patch with
            | None -> Masc_tui_types.Settings_unchanged
            | Some patch -> (
                sent := true;
                publish (Masc_tui_types.Settings_posting snapshot);
                match
                  Masc_tui_http.post_keeper_config ~host ~port
                    ~keeper_name:key.ksk_keeper
                    ~patch_json:(Yojson.Safe.to_string patch)
                with
                | Ok response -> (
                    match
                      Masc_tui_keeper_config.config_write_status_message
                        ~keeper_name:key.ksk_keeper response
                    with
                    | Ok (severity, message) ->
                        Masc_tui_types.Settings_applied
                          { response; severity; message }
                    | Error detail ->
                        Masc_tui_types.Settings_unconfirmed
                          ("Invalid settings write receipt: " ^ detail))
                | Error (Masc_tui_http.Keeper_config_revision_conflict response) ->
                    Masc_tui_types.Settings_observation_required
                      (Masc_tui_types.Settings_revision_conflict, response)
                | Error
                    (Masc_tui_http.Keeper_config_reconciliation_required response) ->
                    Masc_tui_types.Settings_observation_required
                      (Masc_tui_types.Settings_reconciliation_required, response)
                | Error
                    (Masc_tui_http.Keeper_config_runtime_sync_failed response) ->
                    Masc_tui_types.Settings_observation_required
                      (Masc_tui_types.Settings_runtime_sync_failed, response)
                | Error
                    (Masc_tui_http.Keeper_config_refused_before_write
                       { response; detail }) ->
                    Masc_tui_types.Settings_refused (response, detail)
                | Error
                    (( Masc_tui_http.Keeper_config_transport_error _
                     | Masc_tui_http.Keeper_config_http_error _ ) as error) ->
                    Masc_tui_types.Settings_unconfirmed
                      (Masc_tui_http.keeper_config_post_error_to_string error)))
      with
      | Eio.Cancel.Cancelled _ as exn ->
          finish (interrupted "Settings save worker interrupted");
          raise exn
      | exn -> interrupted (Printexc.to_string exn)
    in
    finish outcome
  in
  Log.Transport.info
    "tui_keeper_settings_save keeper=%s intent=%s started_ns=%Ld phase=checking"
    key.ksk_keeper
    (Masc_tui_types.keeper_settings_save_intent_name request)
    request.ksv_started_ns;
  match Eio_context.get_switch_opt () with
  | None -> finish (Masc_tui_types.Settings_not_sent "Eio switch is unavailable")
  | Some sw -> (
      try
        Masc_tui_transport.Workspace_admission.fork_job state ~mailbox ~sw
          ~on_withdrawn:(fun () ->
            finish (interrupted "Workspace withdrew before worker entry"))
          run
      with
      | Eio.Cancel.Cancelled _ as exn ->
          finish (interrupted "Settings save worker interrupted");
          raise exn
      | exn -> finish (interrupted (Printexc.to_string exn)))

let launch_runtime_form_save (state : Masc_tui_types.state) ~mailbox
    (request : Masc_tui_types.runtime_form_save_request) =
  let host = Masc_tui_transport.Workspace_admission.server_peer_host
  and port = state.port in
  let prepared = ref None
  and sent = ref false in
  let publish status =
    (* The input loop recovers each advancing observation. Publishing cannot
       wait for a bounded mailbox before dispatch or during cancellation. *)
    ignore
      (Masc_tui_types.publish_runtime_form_save request
         ~observed_ns:(Mtime_clock.elapsed_ns ()) status)
  in
  let finish outcome =
    publish (Masc_tui_types.Form_finished (!prepared, outcome))
  in
  let interrupted detail =
    if !sent then Masc_tui_types.Form_unconfirmed detail
    else Masc_tui_types.Form_not_sent detail
  in
  let run () =
    let result =
      try
        let not_sent result =
          Result.map_error
            (fun detail -> Masc_tui_types.Form_not_sent detail)
            result
        in
        let* draft =
          match request.rfs_draft with
          | Masc_tui_types.Config_document_draft session ->
              Ok (Masc_tui_types.prepare_runtime_document session)
          | Masc_tui_types.Model_form_draft _
          | Masc_tui_types.Account_form_draft _ ->
              let* () =
                Masc_tui_transport.Workspace_admission.admit_request state ~mailbox
                  ~authority:request.rfs_authority
                  ~identity:(Some request.rfs_workspace) ~host ~port ()
                |> Result.map_error (fun refusal ->
                       Masc_tui_types.Form_kept_back refusal)
              in
              let* json =
                not_sent (Masc_tui_http.fetch_runtime_config_raw ~host ~port)
              in
              let* reading =
                not_sent
                  (Masc_tui_response_decode.run ~name:"runtime-form-source"
                     (fun () -> Masc_tui_runtime_config_view.decode json))
              in
              (* Account declaration may resolve a client path/environment. Keep
                 that boundary out of the UI domain and pure response decoder. *)
              Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                  Masc_tui_types.prepare_runtime_form_save request.rfs_draft reading)
        in
        prepared := Some draft;
        publish (Masc_tui_types.Form_previewing draft);
        let prior_contact =
          match request.rfs_draft with
          | Masc_tui_types.Config_document_draft _ -> None
          | Masc_tui_types.Model_form_draft _
          | Masc_tui_types.Account_form_draft _ ->
              Some Masc_tui_server_lifecycle.Server_reached
        in
        commit_runtime_config_text ?prior_contact state ~mailbox
          ~authority:request.rfs_authority ~identity:(Some request.rfs_workspace)
          ~before_commit:(fun () ->
            sent := true;
            publish (Masc_tui_types.Form_posting draft))
          ~expected_source_path:
            draft.Masc_tui_types.rfp_base.Masc_tui_runtime_config_edit.path
          ~expected_source_revision:
            draft.Masc_tui_types.rfp_base
              .Masc_tui_runtime_config_edit.source_revision
          draft.Masc_tui_types.rfp_text
        |> Result.map_error (function
             | `Save (Masc_tui_http.Runtime_config_conflict current) ->
                 Masc_tui_types.Form_conflict current
             | `Save (Masc_tui_http.Runtime_config_save_refused detail) ->
                 Masc_tui_types.Form_refused detail
             | `Save (Masc_tui_http.Runtime_config_save_unconfirmed detail) ->
                 Masc_tui_types.Form_unconfirmed detail
             | `Kept_back refusal -> Masc_tui_types.Form_kept_back refusal)
      with
      | Eio.Cancel.Cancelled _ as exn ->
          finish (interrupted "Save worker interrupted");
          raise exn
      | exn -> Error (interrupted (Printexc.to_string exn))
    in
    finish
      (match result with
       | Ok receipt -> Masc_tui_types.Form_saved receipt
       | Error outcome -> outcome)
  in
  Log.Transport.info "tui_runtime_form_save started_ns=%Ld phase=checking"
    request.rfs_started_ns;
  match Eio_context.get_switch_opt () with
  | None -> finish (Masc_tui_types.Form_not_sent "Eio switch is unavailable")
  | Some sw -> (
      try
        Masc_tui_transport.Workspace_admission.fork_job state ~mailbox ~sw
          ~on_withdrawn:(fun () ->
            finish
              (Masc_tui_types.Form_not_sent
                 "Workspace withdrew before worker entry"))
          run
      with
      | Eio.Cancel.Cancelled _ as exn ->
          finish (interrupted "Save worker interrupted");
          raise exn
      | exn -> finish (interrupted (Printexc.to_string exn)))

let launch_runtime_params_load (state : Masc_tui_types.state) ~mailbox =
  if Masc_tui_types.server_authority_ready state then begin
    state.runtime_params_loading <- true;
    let host = Masc_tui_transport.Workspace_admission.server_peer_host in
    let port = state.port in
    Masc_tui_transport.Workspace_admission.launch_guarded_request state ~mailbox
      ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
      ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
      ~deliver:(fun result ->
        Masc_tui_async_protocol.Runtime_msg
          (Masc_tui_async_protocol.Runtime_params_loaded result))
      (fun () ->
        Masc_tui_loader.load_runtime_params ~host ~port
        |> Result.map_error (fun detail -> Masc_tui_types.Request_failed detail))
  end
