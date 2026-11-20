let launch_prompts_load (state : Masc_tui_types.state) ~mailbox =
  if Masc_tui_types.server_authority_ready state then begin
    let enqueue_async =
      Masc_tui_transport.Workspace_admission.workspace_enqueue state
    in
    match Masc_tui_fetched.start ~equal:Unit.equal state.prompts ~key:() with
    | Masc_tui_fetched.Already_loading -> ()
    | Masc_tui_fetched.Started (next, request) ->
        state.prompts <- next;
        let host = Masc_tui_transport.Workspace_admission.server_peer_host in
        let port = state.port in
        Masc_tui_transport.Workspace_admission.launch_async_read state ~mailbox
          ~deliver:(fun result ->
            enqueue_async mailbox
              (Masc_tui_async_protocol.Prompts_loaded (request, result)))
          (fun () -> Masc_tui_loader.load_prompts ~host ~port)
  end

(* A /preset call runs off the input loop like the prompt catalog load; its
   answer comes back as a chat notice for the pane that asked, so [wrap]
   carries that pane's keeper. *)
let launch_preset_call (state : Masc_tui_types.state) ~mailbox ~call ~wrap =
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.port in
  let failed detail = Masc_tui_types.Request_failed detail in
  Masc_tui_transport.Workspace_admission.launch_guarded_request state ~mailbox
    ~boundary_error:failed
    ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
    ~deliver:wrap
    (fun () -> Result.map_error failed (call ~host ~port))

let launch_preset_save (state : Masc_tui_types.state) ~mailbox
    ~(sink : Masc_tui_async_protocol.preset_sink) ~name ~description ~chat_input
    ~also_pane =
  let identity = state.server_identity
  and authority = state.workspace_authority in
  let reading = state.workspace_read_authority in
  let workspace = Masc_tui_types.workspace_input_identity_of_server identity in
  let observe ~observation (pending : Masc_tui_types.preset_save_pending) =
    let pending =
      match sink with
      | Masc_tui_async_protocol.Preset_to_pane ->
          { pending with
            Masc_tui_types.psp_pane_observer = Some (authority, observation)
          }
      | Masc_tui_async_protocol.Preset_to_chat target ->
          let others =
            List.filter
              (fun (owner, keeper, _) -> owner <> authority || keeper <> target)
              pending.Masc_tui_types.psp_chat_observers
          in
          { pending with
            Masc_tui_types.psp_chat_observers =
              (authority, target, observation) :: others
          }
    in
    if also_pane then
      { pending with
        Masc_tui_types.psp_pane_observer = Some (authority, observation)
      }
    else pending
  in
  let existing =
    match workspace with
    | None -> None
    | Some _ ->
        List.find_opt
          (fun (pending : Masc_tui_types.preset_save_pending) ->
            pending.psp_workspace = workspace
            && Masc_tui_types.same_preset_save_name pending.psp_name name)
          state.preset_save_pending
  in
  match existing with
  | Some pending ->
      state.preset_save_pending <-
        List.map
          (fun (current : Masc_tui_types.preset_save_pending) ->
            if current.psp_token == pending.psp_token then
              observe ~observation:Masc_tui_types.Preset_save_shared current
            else current)
          state.preset_save_pending;
      Masc_tui_loader.report_action state "system"
        (Printf.sprintf
           (if state.ui_language = Masc_tui_types.Lang_ko then
              "%s 저장 대기 · 새 요청 미전송 · 입력 유지"
            else "Waiting for %s · no new request sent · input retained")
           pending.psp_name)
  | None ->
      let token = ref () in
      let phase = Atomic.make Masc_tui_types.Preset_save_preparing in
      let host = Masc_tui_transport.Workspace_admission.server_peer_host
      and port = state.port in
      let pending =
        observe ~observation:Masc_tui_types.Preset_save_original
          { Masc_tui_types.psp_token = token
          ; psp_workspace = workspace
          ; psp_name = name
          ; psp_description = description
          ; psp_chat_input = chat_input
          ; psp_authority = authority
          ; psp_reading = reading
          ; psp_host = host
          ; psp_port = port
          ; psp_phase = phase
          ; psp_pane_observer = None
          ; psp_chat_observers = []
          }
      in
      state.preset_save_pending <- pending :: state.preset_save_pending;
      let boundary_error detail =
        match Atomic.get phase with
        | Masc_tui_types.Preset_save_preparing ->
            Masc_tui_types.Preset_save_not_sent detail
        | Masc_tui_types.Preset_save_dispatching ->
            Masc_tui_types.Preset_save_unconfirmed detail
        | Masc_tui_types.Preset_save_auth_refused ->
            Masc_tui_types.Preset_save_auth_retry_not_sent detail
      in
      (* Workspace withdrawal must not cancel the original POST or discard
         its receipt. It never grants the old request authority over a new
         workspace; the worker still checks its captured identity before send. *)
      Masc_tui_transport.Workspace_admission.launch_session state ~mailbox
        ~boundary_error
        ~deliver:(fun result ->
          Masc_tui_async_protocol.Preset_msg
            (Masc_tui_async_protocol.Preset_saved (pending, result)))
        (fun () ->
          (* The guard's refusal, and a retired reading or an unread identity
             it would refuse the same way, is kept back: the save was not
             sent (RFC §2). *)
          match
            Masc_tui_transport.Workspace_admission.admit_request state ~mailbox
              ~authority ~identity ~host ~port ()
          with
          | Error refusal -> Error (Masc_tui_types.Preset_save_kept_back refusal)
          | Ok () -> (
              match workspace with
              | None ->
                  Error
                    (Masc_tui_types.Preset_save_kept_back
                       Masc_tui_types.Workspace_identity_not_confirmed)
              | Some expected_workspace ->
                  Masc_tui_loader.save_preset ~host ~port ~name ~description
                    ~expected_workspace
                    ~after_auth_refused:(fun () ->
                      Atomic.set phase Masc_tui_types.Preset_save_auth_refused)
                    ~before_dispatch:(fun () ->
                      if reading != state.workspace_read_authority then
                        Error
                          (Masc_tui_types.Preset_save_kept_back
                             Masc_tui_types.Workspace_identity_not_confirmed)
                      else
                        match
                          Masc_tui_transport.Workspace_admission.admit_request
                            state ~mailbox ~authority ~identity ~host ~port ()
                        with
                        | Error refusal ->
                            Error (Masc_tui_types.Preset_save_kept_back refusal)
                        | Ok () when reading != state.workspace_read_authority ->
                            Error
                              (Masc_tui_types.Preset_save_kept_back
                                 Masc_tui_types.Workspace_identity_not_confirmed)
                        | Ok () ->
                            Atomic.set phase Masc_tui_types.Preset_save_dispatching;
                            Ok ())))

let launch_chat_command_read (state : Masc_tui_types.state) ~mailbox ~label ~call
    ~wrap =
  if not (Masc_tui_types.server_authority_ready state) then
    Masc_tui_loader.report_action state "error"
      (Masc_tui_transport.Request_notice.kept_back_until_reconnect
         ~ko:(state.ui_language = Masc_tui_types.Lang_ko)
         ~request:(Masc_tui_words.Kept_request.Command label))
  else begin
    let ticket = ref () in
    state.chat_command_reads <-
      (ticket, state.workspace_read_authority, label)
      :: state.chat_command_reads;
    launch_preset_call state ~mailbox ~call ~wrap:(fun result ->
        Masc_tui_async_protocol.Chat_command_read_completed (ticket, wrap result))
  end

let settle_retired_chat_command_reads (state : Masc_tui_types.state) =
  let retired, current =
    List.partition
      (fun (_, reading, _) -> reading != state.workspace_read_authority)
      state.chat_command_reads
  in
  state.chat_command_reads <- current;
  List.iter
    (fun (_, _, label) ->
      Masc_tui_loader.report_action state "error"
        (label
         ^ " was interrupted by workspace reconnection; retry after reconnecting"))
    retired

(* A revoked invite's link opens nothing, so its card goes, whether or not it
   is the one on screen. The card carries the name the server sent, made safe
   to draw, so the name asked for is compared in the same form. *)
let forget_play_invite (state : Masc_tui_types.state) ~name =
  state.play_invite <-
    Masc_tui_types.play_invite_forget state.play_invite
      (Masc.Tui_terminal_text.sanitize_terminal_text name)

let launch_presets_load (state : Masc_tui_types.state) ~mailbox =
  if Masc_tui_types.server_authority_ready state then begin
    state.presets_error <- None;
    launch_preset_call state ~mailbox
      ~call:(fun ~host ~port -> Masc_tui_loader.load_presets ~host ~port)
      ~wrap:(fun result ->
        Masc_tui_async_protocol.Preset_msg
          (Masc_tui_async_protocol.Presets_listed
             (Masc_tui_async_protocol.Preset_to_pane, result)))
  end

let preset_rows_for_state (state : Masc_tui_types.state) =
  match state.presets_snapshot with
  | None -> []
  | Some snapshot -> snapshot.Masc.Tui_decode.pss_presets

let selected_preset_for_state state =
  let rows = preset_rows_for_state state in
  List.nth_opt rows
    (max 0 (min state.presets_cursor (List.length rows - 1)))

(* The selected preset's contents. [start] answers [Already_loading] when a
   request for the same name is already in flight, so the pane redrawing per
   keystroke asks once per preset rather than once per frame. *)
let ensure_preset_detail state ~mailbox =
  match selected_preset_for_state state with
  | None -> ()
  | Some (m : Masc.Tui_decode.preset_manifest) -> (
      let name = m.Masc.Tui_decode.pm_name in
      match Masc_tui_types.begin_preset_detail_read state ~name with
      | None -> ()
      | Some request ->
          launch_preset_call state ~mailbox
            ~call:(fun ~host ~port ->
              Masc_tui_loader.load_preset_detail ~host ~port ~name)
            ~wrap:(fun result ->
              Masc_tui_async_protocol.Preset_msg
                (Masc_tui_async_protocol.Preset_detail_loaded (request, result))))

(* The catalog if one has landed, including the last good one after a failed
   refresh: the rows, the cursor and the edit target stay on it. Waiting and a
   first read that failed have no rows, and the pane says which below the list
   rather than here. *)
let prompts_snapshot (state : Masc_tui_types.state) =
  Masc_tui_fetched.value
    (Masc_tui_fetched.view_for ~equal:Unit.equal state.prompts ~key:())

let prompt_rows_for_state state =
  match prompts_snapshot state with
  | Some snapshot ->
      Masc.Tui_decode.prompt_rows_for_operator
        ~show_fragments:state.prompts_show_fragments snapshot
  | None -> []

let runtime_prompt_assets_for_state state =
  match prompts_snapshot state with
  | Some snapshot -> snapshot.Masc.Tui_decode.ps_runtime_assets
  | None -> []

let prompt_catalog_count_for_state state =
  if state.prompts_show_runtime_assets then
    List.length (runtime_prompt_assets_for_state state)
  else List.length (prompt_rows_for_state state)

let selected_prompt_for_state state =
  List.nth_opt (prompt_rows_for_state state) state.prompts_cursor

let launch_librarian_input_load (state : Masc_tui_types.state) ~mailbox
    ~prompt_key =
  if Masc_tui_types.server_authority_ready state then begin
    let enqueue_async =
      Masc_tui_transport.Workspace_admission.workspace_enqueue state
    in
    let host = Masc_tui_transport.Workspace_admission.server_peer_host in
    let port = state.port in
    let same_prompt =
      match state.prompts_librarian_input with
      | Some (key, _) -> String.equal key prompt_key
      | None -> false
    in
    if not same_prompt then begin
      state.prompts_librarian_input <- None;
      state.prompts_librarian_input_error <- None
    end;
    state.prompts_librarian_input_loading <- true;
    state.prompts_librarian_input_requested <- Some prompt_key;
    Masc_tui_transport.Workspace_admission.launch_async_read state ~mailbox
      ~deliver:(fun result ->
        enqueue_async mailbox
          (Masc_tui_async_protocol.Librarian_input_loaded (prompt_key, result)))
      (fun () -> Masc_tui_http.fetch_latest_librarian_input ~host ~port)
  end
