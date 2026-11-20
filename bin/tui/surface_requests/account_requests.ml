let account_login_resume_path (state : Masc_tui_types.state) =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path:state.local_base_path)
    Common.tui_account_login_filename

let encode_resume_payload ~host ~port ~integration_id ~login_id =
  Yojson.Safe.to_string
    (`Assoc
       [ "host", `String host
       ; "port", `Int port
       ; "integration_id", `String integration_id
       ; "login_id", `String login_id
       ])

let decode_resume_payload ~expected_host ~expected_port json =
  let open Yojson.Safe.Util in
  if
    json |> member "host" = `String expected_host
    && json |> member "port" = `Int expected_port
  then
    let integration_id = json |> member "integration_id" |> to_string in
    let login_id = json |> member "login_id" |> to_string in
    Some (integration_id, login_id)
  else None

let remember_account_login (state : Masc_tui_types.state)
    (view : Masc_tui_account_login.t) =
  match view.provider, view.login_id with
  | Some provider, Some login_id -> (
      try
        Auth.save_private_text_file
          (account_login_resume_path state)
          (encode_resume_payload
             ~host:Masc_tui_transport.Workspace_admission.server_peer_host
             ~port:state.port ~integration_id:provider.Masc_tui_account_login.id
             ~login_id)
      with Unix.Unix_error _ | Sys_error _ ->
        view.notice <-
          Masc_tui_types.ui_text state
            ~ko:"로그인 복구 위치를 저장하지 못했습니다. 창을 닫기 전에 완료 상태를 확인하세요."
            ~en:"Could not save login recovery state. Verify completion before closing this dialog.")
  | Some _, None | None, _ -> ()

let restore_account_login (state : Masc_tui_types.state)
    (view : Masc_tui_account_login.t) =
  try
    let json = Yojson.Safe.from_file (account_login_resume_path state) in
    match
      decode_resume_payload
        ~expected_host:Masc_tui_transport.Workspace_admission.server_peer_host
        ~expected_port:state.port json
    with
    | None -> ()
    | Some (integration, login_id) -> (
        match
          List.find_opt
            (fun (p : Masc_tui_account_login.provider) -> p.id = integration)
            view.providers
        with
        | Some provider
          when Auth.is_generated_token_shape login_id
               && Masc_tui_account_login.requested_matches view provider ->
            view.provider <- Some provider;
            view.login_id <- Some login_id;
            view.notice <-
              Masc_tui_types.ui_text state
                ~ko:"이전 로그인 기록이 있습니다. r로 상태를 확인하거나 n으로 새 계정을 추가하세요."
                ~en:"Found a previous login session. Press r to check status or n to add a new account."
        | Some _ | None -> ())
  with
  | Unix.Unix_error _ | Sys_error _ | Yojson.Json_error _
  | Yojson.Safe.Util.Type_error _ -> ()

let launch_account_login_action (state : Masc_tui_types.state) ~mailbox
    (view : Masc_tui_account_login.t) action =
  let module Login = Masc_tui_account_login in
  view.ko <- state.ui_language = Masc_tui_types.Lang_ko;
  let needs_identity =
    match action with
    | Login.Nothing | Login.Close | Login.Cancel | Login.Cancel_prepare -> false
    | Login.Inventory | Login.Activate_saved _ | Login.Refresh_saved _
    | Login.Refresh_retry | Login.Select_existing _ | Login.Start _
    | Login.Input _ | Login.Recover | Login.Discover | Login.Refresh_models
    | Login.Prepare _ | Login.Prepare_batch _ | Login.Save _
    | Login.Preview_removal _ | Login.Remove _ | Login.Refresh_removed _
    | Login.Refresh_list _ -> true
  in
  if action = Login.Nothing then ()
  else if needs_identity && not (Masc_tui_types.server_authority_ready state) then begin
    if Masc_tui_async_protocol.account_login_action_is_read action then begin
      state.account_login_readings <-
        List.filter (fun (reading, _, _) -> reading != view)
          state.account_login_readings;
      state.account_login_read_resume <-
        (view, view.generation, action)
        :: List.filter
             (fun (pending, _, _) -> pending != view)
             state.account_login_read_resume;
      Masc_tui_types.suspend_account_login_read view
    end
    else begin
      view.input_pending <- false;
      match action with
      | Login.Activate_saved saved ->
          (* This follow-up has not entered start_job or issued a POST. *)
          state.account_login_activation_resume <-
            (view, view.generation, saved)
            :: List.filter
                 (fun (pending, _, _) -> pending != view)
                 state.account_login_activation_resume;
          view.notice <-
            "Saved configuration is waiting for workspace reconfirmation before activation."
      | Login.Prepare _ ->
          let ko = state.ui_language = Masc_tui_types.Lang_ko in
          Login.prepare_interrupted view
            (Masc_tui_words.kept_back ~ko
               ~request:Masc_tui_words.Kept_request.Account_login
               (Masc_tui_words.workspace_identity_unconfirmed ~ko)
               Masc_tui_words.Nothing_kept)
      | Login.Prepare_batch batch ->
          if
            batch.Login.completed = 0 && batch.Login.failed = []
            && view.phase = Login.Models
          then view.selected_models <- batch.Login.previous_selected;
          let ko = state.ui_language = Masc_tui_types.Lang_ko in
          Login.prepare_interrupted view
            (Masc_tui_words.kept_back ~ko
               ~request:Masc_tui_words.Kept_request.Account_login
               (Masc_tui_words.workspace_identity_unconfirmed ~ko)
               Masc_tui_words.Nothing_kept)
      | Login.Inventory | Login.Refresh_retry | Login.Cancel
      | Login.Cancel_prepare | Login.Recover | Login.Discover
      | Login.Refresh_models | Login.Close | Login.Nothing
      | Login.Refresh_saved _ | Login.Select_existing _ | Login.Start _
      | Login.Input (_, _) | Login.Save _ | Login.Preview_removal _
      | Login.Remove _ | Login.Refresh_removed _ | Login.Refresh_list _ ->
          view.notice <-
            (let ko = state.ui_language = Masc_tui_types.Lang_ko in
             Masc_tui_words.kept_back ~ko
               ~request:Masc_tui_words.Kept_request.Account_login
               (Masc_tui_words.workspace_identity_unconfirmed ~ko)
               Masc_tui_words.Nothing_kept)
    end
  end
  else begin
    let host = Masc_tui_transport.Workspace_admission.server_peer_host
    and port = state.port in
    (* The guard's refusal travels as [Request_withdrawn], apart from the
       request's own failure, so the panel says it as kept back (RFC §2). *)
    let check_workspace =
      Masc_tui_transport.Workspace_admission.capture_admission state ~mailbox
    in
    let check_workspace () =
      Result.map_error
        (fun refusal -> Masc_tui_types.Request_withdrawn refusal)
        (check_workspace ())
    in
    let failed result =
      Result.map_error (fun detail -> Masc_tui_types.Request_failed detail) result
    in
    let enqueue_async =
      Masc_tui_transport.Workspace_admission.workspace_enqueue state
    in
    (match action with
     | Login.Input _ | Login.Nothing -> ()
     | Login.Close when Login.activation_incomplete view -> ()
     | Login.Inventory | Login.Activate_saved _ | Login.Refresh_saved _
     | Login.Refresh_retry | Login.Select_existing _ | Login.Start _
     | Login.Cancel | Login.Cancel_prepare | Login.Recover | Login.Discover
     | Login.Refresh_models | Login.Prepare _ | Login.Prepare_batch _
     | Login.Save _ | Login.Close | Login.Preview_removal _ | Login.Remove _
     | Login.Refresh_removed _ | Login.Refresh_list _ ->
         view.generation <- view.generation + 1;
         Option.iter (fun stop -> stop ()) view.cancel_stream;
         view.cancel_stream <- None);
    let generation = view.generation in
    state.account_login_readings <-
      List.filter (fun (reading, _, _) -> reading != view)
        state.account_login_readings;
    state.account_login_read_resume <-
      List.filter
        (fun (pending, _, _) -> pending != view)
        state.account_login_read_resume;
    if not (action = Login.Close && Login.activation_incomplete view) then
      state.account_login_activation_resume <-
        List.filter
          (fun (pending, _, _) -> pending != view)
          state.account_login_activation_resume;
    if Masc_tui_async_protocol.account_login_action_is_read action then
      state.account_login_readings <-
        (view, generation, action) :: state.account_login_readings;
    let post path body =
      Result.bind (check_workspace ()) (fun () ->
          failed
            (Masc_tui_http.post_json ~host ~port ~path
               ~body:(Yojson.Safe.to_string body)))
    in
    let post_setup path body =
      Result.bind (check_workspace ()) (fun () ->
          failed
            (Masc_tui_http.post_setup_json ~host ~port ~path
               ~body:(Yojson.Safe.to_string body)))
    in
    let login_path id = "/api/v1/setup/accounts/login/" ^ id in
    let enqueue result =
      enqueue_async mailbox
        (Masc_tui_async_protocol.Account_msg
           (Masc_tui_async_protocol.Account_login_json
              (view, generation, action, result)))
    in
    let start_job f =
      match Eio_context.get_switch_opt () with
      | None ->
          enqueue
            (Error (Masc_tui_types.Request_failed "Login requires the TUI runtime."))
      | Some sw ->
          Eio.Fiber.fork_daemon ~sw (fun () ->
              if generation = view.generation then (
                try
                  Eio.Cancel.sub (fun cancellation ->
                      (match action with
                       | Login.Input _ -> ()
                       | Login.Inventory | Login.Refresh_retry | Login.Cancel
                       | Login.Cancel_prepare | Login.Recover | Login.Discover
                       | Login.Refresh_models | Login.Close | Login.Nothing
                       | Login.Activate_saved _ | Login.Refresh_saved _
                       | Login.Select_existing _ | Login.Start _
                       | Login.Prepare _ | Login.Prepare_batch _ | Login.Save _
                       | Login.Preview_removal _ | Login.Remove _
                       | Login.Refresh_removed _ | Login.Refresh_list _ ->
                           view.cancel_stream <-
                             Some
                               (fun () ->
                                 Eio.Cancel.cancel cancellation
                                   (Failure "login panel superseded")));
                      Fun.protect
                        ~finally:(fun () ->
                          if generation = view.generation then
                            match action with
                            | Login.Input _ -> ()
                            | Login.Inventory | Login.Activate_saved _
                            | Login.Refresh_saved _ | Login.Refresh_retry
                            | Login.Select_existing _ | Login.Start _
                            | Login.Cancel | Login.Cancel_prepare
                            | Login.Recover | Login.Discover
                            | Login.Refresh_models | Login.Prepare _
                            | Login.Prepare_batch _ | Login.Save _
                            | Login.Close | Login.Nothing
                            | Login.Preview_removal _ | Login.Remove _
                            | Login.Refresh_removed _ | Login.Refresh_list _ ->
                                view.cancel_stream <- None)
                        (fun () ->
                          match check_workspace () with
                          | Error failure -> enqueue (Error failure)
                          | Ok () -> f ()))
                with
                | Eio.Cancel.Cancelled _ as exn ->
                    if generation = view.generation then raise exn
                | Unix.Unix_error _ | Sys_error _ | Eio.Io _ | Yojson.Json_error _
                  ->
                    enqueue
                      (Error
                         (Masc_tui_types.Request_failed
                            "The account request did not complete. Recheck its state.")));
              `Stop_daemon)
    in
    let now = Unix.gettimeofday () in
    match action with
    | Login.Nothing -> ()
    | Login.Close ->
        state.account_login_detached <-
          Login.retain_activation view state.account_login_detached;
        view.draft <- "";
        state.account_login <- None
    | Login.Cancel ->
        Option.iter (fun stop -> stop ()) view.cancel_stream;
        view.cancel_stream <- None;
        view.draft <- "";
        view.phase <- Login.Failed;
        view.activity_started_at <- None;
        view.notice <-
          Masc_tui_types.ui_text state
            ~ko:"로그인을 취소했습니다. r로 저장된 상태를 확인하세요."
            ~en:"Login cancelled. Press r to check saved status."
    | Login.Cancel_prepare -> Login.cancel_prepare view
    | Login.Select_existing provider ->
        view.phase <- Login.Loading;
        Login.note_activity_started ~at:now view;
        view.notice <-
          Masc_tui_types.ui_text state
            ~ko:"저장된 계정의 모델을 읽고 있습니다."
            ~en:"Loading models for saved account.";
        let path =
          if provider.Login.client = Login.Antigravity then
            "/api/v1/setup/accounts/antigravity"
          else "/api/v1/setup/accounts/select"
        in
        start_job (fun () ->
            enqueue (post path (`Assoc [ "integration_id", `String provider.id ])))
    | Login.Start { provider; existing } ->
        let previous = Login.begin_attempt view provider ~existing in
        Login.note_activity_started ~at:now view;
        start_job (fun () ->
            let selected =
              if not existing || Option.is_some previous then Ok previous
              else
                let path =
                  if provider.Login.client = Login.Antigravity then
                    "/api/v1/setup/accounts/antigravity"
                  else "/api/v1/setup/accounts/select"
                in
                match post path (`Assoc [ "integration_id", `String provider.id ]) with
                | Error _ as error -> error
                | Ok (`Assoc fields) -> (
                    match List.assoc_opt "account_ref" fields with
                    | Some (`String reference) -> Ok (Some reference)
                    | Some _ | None ->
                        Error
                          (Masc_tui_types.Request_failed "No account selected."))
                | Ok _ ->
                    Error (Masc_tui_types.Request_failed "No account selected.")
            in
            match selected, Eio_context.get_clock_opt () with
            | Error failure, _ -> enqueue (Error failure)
            | Ok _, None ->
                enqueue
                  (Error
                     (Masc_tui_types.Request_failed "Login requires the TUI clock."))
            | Ok reference, Some clock -> (
                let on_chunk, complete =
                  Login.decoder ~integration_id:provider.id (fun event ->
                      enqueue_async mailbox
                        (Masc_tui_async_protocol.Account_msg
                           (Masc_tui_async_protocol.Account_login_event
                              (view, generation, event))))
                in
                let body =
                  `Assoc
                    ([ "integration_id", `String provider.id ]
                     @
                     match reference with
                     | Some r -> [ "account_ref", `String r ]
                     | None -> [])
                  |> Yojson.Safe.to_string
                in
                let result =
                  Result.bind (check_workspace ()) (fun () ->
                      failed
                        (Masc_tui_http.post_setup_login_streaming ~clock ~host
                           ~port ~body ~on_chunk))
                in
                match result with
                | Ok () when complete () -> ()
                (* The login was not sent; it is kept back, not unanswered. *)
                | Error (Masc_tui_types.Request_withdrawn _ as failure) ->
                    enqueue (Error failure)
                | Ok () | Error (Masc_tui_types.Request_failed _) ->
                    enqueue
                      (Error
                         (Masc_tui_types.Request_failed
                            (Masc_tui_types.ui_text state
                               ~ko:"로그인 결과를 받지 못했습니다. r로 상태를 다시 확인하세요."
                               ~en:"Did not receive login result. Press r to check status again.")))))
    | Login.Input (_, json) -> (
        match view.login_id with
        | None ->
            view.input_pending <- false;
            view.activity_started_at <- None
        | Some id ->
            Login.note_activity_started ~at:now view;
            start_job (fun () -> enqueue (post (login_path id ^ "/input") json)))
    | Login.Inventory | Login.Refresh_saved _ | Login.Refresh_retry
    | Login.Refresh_list _ ->
        (match action with
         | Login.Inventory | Login.Refresh_list _ ->
             view.phase <- Login.Loading;
             Login.note_activity_started ~at:now view;
             view.notice <-
               Masc_tui_types.ui_text state
                 ~ko:"계정 목록을 읽고 있습니다."
                 ~en:"Loading account list."
         | Login.Refresh_retry ->
             view.phase <- Login.Loading;
             Login.note_activity_started ~at:now view;
             view.notice <-
               Masc_tui_types.ui_text state
                 ~ko:"최신 설정을 읽고 있습니다."
                 ~en:"Loading latest settings."
         | Login.Activate_saved _ | Login.Refresh_saved _
         | Login.Select_existing _ | Login.Start _ | Login.Input _
         | Login.Cancel | Login.Cancel_prepare | Login.Recover | Login.Discover
         | Login.Refresh_models | Login.Prepare _ | Login.Prepare_batch _
         | Login.Save _ | Login.Close | Login.Nothing
         | Login.Preview_removal _ | Login.Remove _ | Login.Refresh_removed _ ->
             ());
        start_job (fun () ->
            enqueue
              (failed
                 (Masc_tui_http.get_json ~host ~port
                    ~path:"/api/v1/setup/inventory")))
    | Login.Recover -> (
        match view.login_id with
        | None ->
            view.notice <-
              Masc_tui_types.ui_text state
                ~ko:"조회할 로그인 세션이 없습니다. n으로 새 로그인을 시작하세요."
                ~en:"No login session to check. Press n to start a new login."
        | Some id ->
            view.phase <- Login.Loading;
            Login.note_activity_started ~at:now view;
            view.notice <-
              Masc_tui_types.ui_text state
                ~ko:"로그인 상태를 확인하고 있습니다."
                ~en:"Checking login status.";
            start_job (fun () ->
                enqueue (failed (Masc_tui_http.get_json ~host ~port ~path:(login_path id)))))
    | Login.Discover | Login.Refresh_models ->
        (match action with
         | Login.Refresh_models ->
             Login.refreshing_models view;
             Login.note_activity_started ~at:now view
         | Login.Discover ->
             view.phase <- Login.Loading;
             Login.note_activity_started ~at:now view
         | Login.Inventory | Login.Activate_saved _ | Login.Refresh_saved _
         | Login.Refresh_retry | Login.Select_existing _ | Login.Start _
         | Login.Input _ | Login.Cancel | Login.Cancel_prepare | Login.Recover
         | Login.Prepare _ | Login.Prepare_batch _ | Login.Save _
         | Login.Close | Login.Nothing | Login.Preview_removal _
         | Login.Remove _ | Login.Refresh_removed _ | Login.Refresh_list _ ->
             ());
        let source = Login.source view in
        start_job (fun () -> enqueue (post_setup "/api/v1/setup/models" source))
    | Login.Prepare model ->
        Login.preparing view model;
        Login.note_activity_started ~at:now view;
        let body =
          `Assoc
            [ "source", Login.source view
            ; "model", `String model.Login.id
            ; "load", `Bool false
            ]
        in
        start_job (fun () -> enqueue (post_setup "/api/v1/setup/context" body))
    | Login.Prepare_batch batch ->
        Login.preparing_batch ~at:now view batch;
        let body =
          `Assoc
            [ "source", Login.source view
            ; "model", `String batch.Login.current.Login.id
            ; "load", `Bool false
            ]
          |> Yojson.Safe.to_string
        in
        start_job (fun () ->
            let outcome =
              match check_workspace () with
              | Error (Masc_tui_types.Request_withdrawn refusal) -> Error refusal
              | Error (Masc_tui_types.Request_failed detail) ->
                  Ok (Masc_tui_http.Setup_transport_error detail)
              | Ok () ->
                  Ok
                    (Masc_tui_http.post_setup_json_classified ~host ~port
                       ~path:"/api/v1/setup/context" ~body)
            in
            enqueue_async mailbox
              (Masc_tui_async_protocol.Account_msg
                 (Masc_tui_async_protocol.Account_login_batch_step
                    (view, generation, batch, outcome))))
    | Login.Save models ->
        view.phase <- Login.Saving;
        Login.note_activity_started ~at:now view;
        let count = List.length models in
        view.notice <-
          Masc_tui_types.ui_text state
            ~ko:(Printf.sprintf "모델 %d개 검증 중 · 응답과 도구 호출을 확인합니다." count)
            ~en:(Printf.sprintf "Verifying %s · checking responses and tool calling."
                   (Masc_tui_message_layout.count_noun count "model"));
        let body = Login.save_body view models in
        start_job (fun () ->
            enqueue (post_setup "/api/v1/setup/connections" body))
    | Login.Activate_saved saved ->
        Login.activating view saved;
        Login.note_activity_started ~at:now view;
        start_job (fun () ->
            let result =
              match check_workspace () with
              | Error _ as error -> error
              | Ok () -> post_setup "/api/v1/runtime/setup/resume" (`Assoc [])
            in
            enqueue result)
    | Login.Preview_removal { provider; _ } ->
        view.phase <- Login.Loading;
        Login.note_activity_started ~at:now view;
        view.notice <-
          Masc_tui_types.ui_text state
            ~ko:"지울 내용을 읽고 있습니다."
            ~en:"Loading removal preview.";
        start_job (fun () ->
            enqueue
              (post "/api/v1/setup/accounts/removal"
                 (`Assoc [ "integration_id", `String provider.id ])))
    | Login.Remove { provider; revision; login_store } ->
        view.phase <- Login.Removing;
        Login.note_activity_started ~at:now view;
        view.notice <-
          Masc_tui_types.ui_text state
            ~ko:"선택한 공급자 연결을 지우고 있습니다."
            ~en:"Removing selected provider link.";
        let body =
          `Assoc
            [ "integration_id", `String provider.id
            ; "revision", `String revision
            ]
          |> Yojson.Safe.to_string
        in
        start_job (fun () ->
            let outcome =
              Masc_tui_http.post_json_outcome ~host ~port
                ~path:"/api/v1/setup/accounts/remove" ~body
            in
            enqueue_async mailbox
              (Masc_tui_async_protocol.Account_msg
                 (Masc_tui_async_protocol.Account_login_removal
                    (view, generation, provider, login_store, outcome))))
    | Login.Refresh_removed _ ->
        view.phase <- Login.Loading;
        Login.note_activity_started ~at:now view;
        start_job (fun () ->
            enqueue
              (failed
                 (Masc_tui_http.get_json ~host ~port
                    ~path:"/api/v1/setup/inventory")))
  end
