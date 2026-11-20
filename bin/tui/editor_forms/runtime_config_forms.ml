module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Addons = Masc_tui_lane_addons
module Edit = Masc_tui_runtime_config_edit
module Config_view = Masc_tui_runtime_config_view

(* Load memory-recall standing keyed by the form's read
   generation, so the answer for a form the operator already left is dropped
   ([Masc_tui_types.finish_memory_recall_standing_read]). *)
let launch_memory_recall_standing_load (state : T.state) ~mailbox =
  let generation = T.begin_memory_recall_standing_read state in
  if T.server_authority_ready state then begin
    let enqueue_async =
      Masc_tui_transport.Workspace_admission.workspace_enqueue state
    in
    let host = Masc_tui_transport.Workspace_admission.server_peer_host in
    let port = state.T.port in
    Masc_tui_transport.Workspace_admission.launch_async_read state ~mailbox
      ~deliver:(fun result ->
        enqueue_async mailbox
          (P.Memory_msg (P.Memory_recall_standing_loaded (generation, result))))
      (fun () -> Masc_tui_loader.load_memory_recall_standing ~host ~port)
  end
  else
    T.stop_waiting_for_memory_recall_standing state
      (T.ui_text state ~ko:"서버 신원을 아직 확인하지 못했어요"
         ~en:"Server identity not verified yet")

let handle_lane_document_editor (state : T.state) ~terminal_session =
  match state.T.lane_addons with
  | None -> ()
  | Some view -> (
      state.T.lane_addons <- Some { view with Addons.editor_ready = false };
      match Addons.selected_document view with
      | None -> ()
      | Some session -> (
          match
            Masc_tui_editor.roundtrip
              ~restore:(fun () ->
                Masc_tui_shell.Terminal_session.hand_off terminal_session)
              ~reenter:(fun () ->
                Masc_tui_shell.Terminal_session.take_back terminal_session)
              ~suffix:".toml" session.Masc_tui_lane_declaration.text
          with
          (* The lane add-ons pane is still English, so the reason in it is
             too; the pane's own layer moves both. *)
          | Error abort ->
              Masc_tui_surface_requests.Lane_browser_requests.map_lane_addons
                state (fun view ->
                  { view with
                    Addons.error =
                      Masc_tui_surface_requests.Lane_browser_requests
                      .lane_addons_input_failure
                        (Masc_tui_editor.abort_detail ~ko:false abort
                         ^ "; TOML draft retained")
                  })
          | Ok text ->
              Masc_tui_surface_requests.Lane_browser_requests.map_lane_addons
                state (fun view ->
                  Addons.put_document
                    { view with Addons.error = None; scroll = 0 }
                    { session with
                      Masc_tui_lane_declaration.text
                    ; message =
                        Some "Draft edited; s saves through the shared TOML owner"
                    })))

let select_lane_document (state : T.state) ~mailbox (view : Addons.t) =
  let path = Addons.selected_source_path view in
  match path with
  | None ->
      state.T.lane_addons <-
        Some
          { view with
            Addons.error =
              Masc_tui_surface_requests.Lane_browser_requests
              .lane_addons_input_failure
                "Choose a current declaration .toml file; directory issues have no file to edit"
          }
  | Some path -> (
      match
        Masc_tui_lane_declaration.find_for_path ~path
          view.Addons.documents
      with
      | Ok (Some session) ->
          state.T.lane_addons <-
            Some
              (Addons.put_document
                 { view with Addons.editor_ready = true; scroll = 0 }
                 session)
      | Ok None ->
          Masc_tui_surface_requests.Lane_browser_requests.launch_lane_declaration
            state ~mailbox ~edit:true (Masc_tui_lane_declaration.Read path)
      | Error detail ->
          state.T.lane_addons <-
            Some
              { view with
                Addons.document_key = None
              ; editor_ready = false
              ; scroll = 0
              ; error =
                  Masc_tui_surface_requests.Lane_browser_requests
                  .lane_addons_input_failure detail
              })

(* Raw edits join the same owned operation as structured forms. Retain the
   exact session before dispatch; neither a duplicate nor a refusal loses it. *)
let save_runtime_config_edit_session (state : T.state) ~mailbox ~workspace session =
  T.put_runtime_config_edit state ~workspace session;
  let request =
    if T.runtime_config_workspace state <> Some workspace then
      Error "Draft belongs to another workspace; save not sent"
    else
      T.begin_runtime_form_save state ~draft:(T.Config_document_draft session)
        ~started_ns:(Mtime_clock.elapsed_ns ())
  in
  match request with
  | Ok request ->
      Masc_tui_surface_requests.Runtime_config_requests.launch_runtime_form_save
        state ~mailbox request
  | Error detail ->
      T.put_runtime_config_edit ~preserve_view:true state ~workspace
        (Edit.failed detail session);
      Masc_tui_loader.report_action state "error" (detail ^ "; draft retained")

(* The document an edit of runtime.toml starts from: the retained draft when
   there is one, else the file as the pane last read it. *)
let runtime_config_working_session (state : T.state) (reading : T.runtime_config_reading) =
  match T.runtime_config_edit_session state with
  | Some edit -> edit.T.rce_session
  | None ->
      Edit.open_document ?read_generation:state.T.runtime_config_observed_generation
        { Edit.path = reading.T.rcv_path
        ; source_text = reading.T.rcv_source_text
        ; source_revision =
            reading.T.rcv_metadata.Config_view.source_revision
        }

let handle_runtime_config_edit (state : T.state) ~mailbox ~terminal_session =
  match T.runtime_config_workspace state, state.T.runtime_config_view with
  | None, (Some _ | None) | Some _, None ->
      Masc_tui_loader.report_action state "error"
        (T.ui_text state ~ko:"설정 신원을 아직 불러오지 못했어요 · r로 다시 읽기"
           ~en:"config identity not loaded yet; r to reload")
  | Some workspace, Some reading -> (
      let session = runtime_config_working_session state reading in
      match
        Masc_tui_editor.roundtrip
          ~restore:(fun () ->
            Masc_tui_shell.Terminal_session.hand_off terminal_session)
          ~reenter:(fun () ->
            Masc_tui_shell.Terminal_session.take_back terminal_session)
          ~suffix:".toml" session.Edit.text
      with
      | Error abort ->
          Masc_tui_shell.Editor_notice.report_abort state
            ~form:Masc_tui_shell.Editor_notice.Runtime_config_text abort
      | Ok edited ->
          if String.equal edited session.Edit.base.Edit.source_text then begin
            T.release_runtime_document_recovery state ~workspace
              ~path:session.Edit.base.Edit.path;
            T.discard_runtime_config_edit state ~workspace
              ~path:session.Edit.base.Edit.path;
            Masc_tui_loader.report_action state "system"
              "No changes from the draft base; no file was written."
          end else
            save_runtime_config_edit_session state ~mailbox ~workspace
              (Edit.edit edited session))

let handle_runtime_config_draft (state : T.state) ~mailbox key =
  match T.runtime_config_edit_session state with
  | None ->
      Masc_tui_loader.report_action state "system"
        "No retained runtime.toml draft; e to edit."
  | Some edit -> (
      let session = edit.T.rce_session in
      match key with
      | "S" ->
          save_runtime_config_edit_session state ~mailbox
            ~workspace:edit.T.rce_workspace session
      | "X" ->
          T.release_runtime_document_recovery state
            ~workspace:edit.T.rce_workspace ~path:session.Edit.base.Edit.path;
          T.discard_runtime_config_edit state ~workspace:edit.T.rce_workspace
            ~path:session.Edit.base.Edit.path;
          Masc_tui_surface_requests.Runtime_config_requests
          .launch_runtime_config_load state ~mailbox;
          Masc_tui_loader.report_action state "system"
            "Local draft discarded; reading current runtime.toml."
      | "C" -> (
          let view =
            match edit.T.rce_view with
            | T.Config_edit_current _ -> Ok T.Config_edit_draft
            | T.Config_edit_draft -> (
                match session.Edit.current with
                | None -> Error "Read the current file with r before comparing."
                | Some current ->
                    Ok
                      (T.Config_edit_current
                         (T.runtime_config_source_rows ~path:current.Edit.path
                            current.Edit.source_text)))
          in
          match view with
          | Error message -> Masc_tui_loader.report_action state "error" message
          | Ok view ->
              state.T.runtime_config_edits <-
                List.map
                  (fun candidate ->
                     if candidate.T.rce_workspace = edit.T.rce_workspace
                        && String.equal
                             candidate.T.rce_session.Edit.base.Edit.path
                             session.Edit.base.Edit.path
                     then { candidate with T.rce_view = view }
                     else candidate)
                  state.T.runtime_config_edits;
              state.T.config_scroll <- 0;
              state.T.runtime_config_cursor <- 0)
      | "u" | "U" -> (
          let result =
            if key = "u" then Edit.adopt_current session
            else Edit.replace_with_current session
          in
          match result with
          | Error message -> Masc_tui_loader.report_action state "error" message
          | Ok session ->
              T.release_runtime_document_recovery state
                ~workspace:edit.T.rce_workspace
                ~path:session.Edit.base.Edit.path;
              T.put_runtime_config_edit state ~workspace:edit.T.rce_workspace
                session;
              state.T.config_scroll <- 0;
              state.T.runtime_config_cursor <- 0;
              Masc_tui_loader.report_action state "system"
                (if key = "u" then
                   "Current revision adopted; draft text retained. S to save."
                 else
                   "Draft replaced with the displayed current file. No file was written."))
      | _ -> ())

(* [a] on the runtime.toml pane opens the account form on the file as the
   pane shows it. *)
let handle_model_form_open (state : T.state) mode =
  if T.recover_runtime_form_save state ~account:false then ()
  else if Option.is_some state.T.runtime_model_jump then
    Masc_tui_loader.report_action state "info"
      "Loading the selected binding; Esc cancels"
  else
    match state.T.runtime_config_view, T.selected_config_model state with
    | Some { T.rcv_metadata = metadata; _ }, Ok row ->
        state.T.runtime_form_save_focus <- None;
        state.T.runtime_model_form <-
          Some
            (Masc_tui_model_form.create
               ~source_revision:metadata.Config_view.source_revision mode row)
    | None, (Ok _ | Error _) ->
        Masc_tui_loader.report_action state "error"
          "config not loaded yet; r to reload"
    | Some _, Error detail ->
        Masc_tui_loader.report_action state "error" detail

let handle_runtime_account_open (state : T.state) =
  if T.recover_runtime_form_save state ~account:true then ()
  else
    match state.T.runtime_config_view with
    | None ->
        Masc_tui_loader.report_action state "error"
          "config not loaded yet; r to reload"
    | Some reading -> (
        match
          Masc_tui_runtime_account_form.open_on
            ~source_revision:
              reading.T.rcv_metadata.Config_view.source_revision
            ?home_dir:(Sys.getenv_opt "HOME") reading.T.rcv_source_text
        with
        | Ok form ->
            state.T.runtime_form_save_focus <- None;
            state.T.runtime_account_form <- Some form
        | Error reason -> Masc_tui_loader.report_action state "error" reason)

(* [m] on the runtime.toml pane opens the recall form on the document an
   edit would start from, so a hand edit that is not saved yet is neither
   dropped nor written over. A save that is still out is not checked here:
   [begin_runtime_form_save] refuses a second one with its own reason when
   Enter reaches it, and the choice stays as a retained draft. *)
let handle_memory_recall_form_open (state : T.state) ~mailbox =
  match T.runtime_config_workspace state, state.T.runtime_config_view with
  | None, (Some _ | None) | Some _, None ->
      Masc_tui_loader.report_action state "error"
        (T.ui_text state ~ko:"설정 신원을 아직 불러오지 못했어요 · r로 다시 읽기"
           ~en:"config identity not loaded yet; r to reload")
  | Some _, Some reading -> (
      let session = runtime_config_working_session state reading in
      let module Form = Masc_tui_memory_recall_form in
      (* A paused Keeper, or one no fiber runs, is marked in the list. The
         reading is the Keepers surface's own, so the two say the same. A
         roster that could not be read says nothing: [Unknown] is not drawn. *)
      let roster_entry (keeper : Masc.Tui_decode.keeper) =
        let reading = T.keeper_reading state keeper in
        { Form.name = keeper.Masc.Tui_decode.k_name
        ; presence =
            (if reading.Masc_tui_keeper_control.paused then Form.Stopped
             else
               match Masc_tui_keeper_control.runs reading with
               | Some true -> Form.Running
               | Some false -> Form.Stopped
               | None -> Form.Unknown)
        }
      in
      match
        Form.open_on ~ko:(state.T.ui_language = T.Lang_ko)
          ~source_revision:session.Edit.base.Edit.source_revision
          ~keepers:(List.map roster_entry state.T.keepers)
          session.Edit.text
      with
      | Ok form ->
          state.T.memory_recall_form <- Some form;
          launch_memory_recall_standing_load state ~mailbox
      | Error reason -> Masc_tui_loader.report_action state "error" reason)

(* Enter on the recall form. Its text is the document it was opened on, so
   it goes to the save only while the pane's document is still that one;
   laid over another revision it would carry a choice made against a file
   it is not. The save is the raw edit's: the same preview, revision check
   and conflict handling as [e]. *)
let submit_memory_recall_form (state : T.state) ~mailbox form =
  let ko = state.T.ui_language = T.Lang_ko in
  let refuse reason =
    state.T.memory_recall_form <-
      Some (Masc_tui_memory_recall_form.refused form reason)
  in
  match T.runtime_config_workspace state, state.T.runtime_config_view with
  | None, (Some _ | None) | Some _, None ->
      refuse
        (T.ui_text state ~ko:"설정 신원을 아직 불러오지 못했어요 · r로 다시 읽기"
           ~en:"config identity not loaded yet; r to reload")
  | Some workspace, Some reading ->
      let session = runtime_config_working_session state reading in
      if
        not
          (Option.equal String.equal
             (Masc_tui_memory_recall_form.source_revision form)
             (Some session.Edit.base.Edit.source_revision))
      then
        refuse
          (T.ui_text state
             ~ko:
               "runtime.toml 이 폼을 연 뒤에 바뀌었어요. Esc 로 닫고 m 으로 다시 열어 주세요"
             ~en:
               "runtime.toml changed after this form opened. Press Esc to close and m to reopen.")
      else (
        match Masc_tui_memory_recall_form.text_on ~ko form with
        | Error form -> state.T.memory_recall_form <- Some form
        | Ok text ->
            state.T.memory_recall_form <- None;
            if String.equal text session.Edit.text then
              Masc_tui_loader.report_action state "system"
                (T.ui_text state ~ko:"바뀐 게 없어요. 파일에 쓰지 않았어요"
                   ~en:"No changes made; file was not written.")
            else
              save_runtime_config_edit_session state ~mailbox ~workspace
                (Edit.edit text session))

(* [x] on the runtime.toml pane: the exclusion form, opened on the file the
   pane shows, with a stopped Keeper marked the way the recall form marks it. *)
let handle_typesafeai_exclusion_form_open (state : T.state) =
  match T.runtime_config_workspace state, state.T.runtime_config_view with
  | None, (Some _ | None) | Some _, None ->
      Masc_tui_loader.report_action state "error"
        (T.ui_text state ~ko:"설정 신원을 아직 불러오지 못했어요 · r로 다시 읽기"
           ~en:"config identity not loaded yet; r to reload")
  | Some _, Some reading -> (
      let session = runtime_config_working_session state reading in
      let module Form = Masc_tui_typesafeai_exclusion_form in
      let roster_entry (keeper : Masc.Tui_decode.keeper) =
        let reading = T.keeper_reading state keeper in
        { Form.name = keeper.Masc.Tui_decode.k_name
        ; presence =
            (if reading.Masc_tui_keeper_control.paused then Form.Stopped
             else
               match Masc_tui_keeper_control.runs reading with
               | Some true -> Form.Running
               | Some false -> Form.Stopped
               | None -> Form.Unknown)
        }
      in
      match
        Form.open_on ~ko:(state.T.ui_language = T.Lang_ko)
          ~source_revision:session.Edit.base.Edit.source_revision
          ~keepers:(List.map roster_entry state.T.keepers)
          session.Edit.text
      with
      | Ok form -> state.T.typesafeai_exclusion_form <- Some form
      | Error reason -> Masc_tui_loader.report_action state "error" reason)

(* Enter on the exclusion form, saved the way the recall form's choice is:
   only while the pane still holds the document the form was opened on, and
   through the raw edit's preview, revision check and conflict handling. *)
let submit_typesafeai_exclusion_form (state : T.state) ~mailbox form =
  let module Form = Masc_tui_typesafeai_exclusion_form in
  let ko = state.T.ui_language = T.Lang_ko in
  let refuse reason =
    state.T.typesafeai_exclusion_form <- Some (Form.refused form reason)
  in
  match T.runtime_config_workspace state, state.T.runtime_config_view with
  | None, (Some _ | None) | Some _, None ->
      refuse
        (T.ui_text state ~ko:"설정 신원을 아직 불러오지 못했어요 · r로 다시 읽기"
           ~en:"config identity not loaded yet; r to reload")
  | Some workspace, Some reading ->
      let session = runtime_config_working_session state reading in
      if
        not
          (Option.equal String.equal (Form.source_revision form)
             (Some session.Edit.base.Edit.source_revision))
      then
        refuse
          (T.ui_text state
             ~ko:
               "runtime.toml 이 폼을 연 뒤에 바뀌었어요. Esc 로 닫고 x 로 다시 열어 주세요"
             ~en:
               "runtime.toml changed after this form opened. Press Esc to close and x to reopen.")
      else (
        match Form.text_on ~ko form with
        | Error form -> state.T.typesafeai_exclusion_form <- Some form
        | Ok text ->
            state.T.typesafeai_exclusion_form <- None;
            if String.equal text session.Edit.text then
              Masc_tui_loader.report_action state "system"
                (T.ui_text state ~ko:"바뀐 게 없어요. 파일에 쓰지 않았어요"
                   ~en:"No changes made; file was not written.")
            else
              save_runtime_config_edit_session state ~mailbox ~workspace
                (Edit.edit text session))

let open_runtime_model_settings (state : T.state) ~mailbox runtime_id =
  state.T.runtime_model_form <- None;
  state.T.runtime_model_jump <- Some runtime_id;
  state.T.runtime_config_jump_section <- None;
  state.T.view <- T.Config;
  state.T.config_pane <- T.Config_models;
  state.T.config_scroll <- 0;
  (* Read the authoritative source before choosing the exact account/binding;
     a pending catalogue or stale cursor cannot select a neighbour's model. *)
  Masc_tui_surface_requests.Runtime_config_requests.launch_runtime_config_load
    ~force:true state ~mailbox

let open_selected_slot_config (state : T.state) ~mailbox =
  match T.slot_editor_cursor_row state with
  | None -> state.T.lanes_action_error <- Some "No slot is selected"
  | Some { T.sr_kind = T.Media_route_slot; _ } ->
      state.T.lanes_action_error <- Some "Select an exact lane provider slot"
  | Some
      { T.sr_slot
      ; sr_kind = T.Catalog_slot | T.Official_client_slot
      ; _
      } ->
      state.T.lanes_action_error <- None;
      open_runtime_model_settings state ~mailbox sr_slot

let selected_runtime_param (state : T.state) =
  Option.bind state.T.runtime_params (fun rows ->
      List.nth_opt rows state.T.runtime_params_cursor)

let write_runtime_param (state : T.state) ~mailbox ~edit ~failure ~notice write =
  if not state.T.runtime_params_loading then begin
    state.T.runtime_params_loading <- true;
    Masc_tui_transport.Workspace_admission.launch_guarded_request state ~mailbox
      ~boundary_error:(fun detail -> T.Request_failed detail)
      ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
      ~deliver:(fun result -> P.Runtime_msg (P.Runtime_param_written (edit, result)))
      (fun () ->
        write ()
        |> Result.map (fun _ -> notice)
        |> Result.map_error (fun detail -> T.Request_failed (failure ^ detail)))
  end

let handle_runtime_param_edit_open (state : T.state) ~advanced =
  match selected_runtime_param state with
  | None ->
      state.T.runtime_params_notice <-
        Some (T.Params_said (false, "No runtime parameter is selected"))
  | Some row ->
      state.T.runtime_param_edit <-
        Some (T.runtime_param_edit_of_row ~advanced row);
      state.T.runtime_params_notice <- None

let handle_runtime_param_edit_apply (state : T.state) ~mailbox =
  match state.T.runtime_param_edit with
  | None -> ()
  | Some edit -> (
      match T.runtime_param_edit_value edit with
      | Error detail ->
          state.T.runtime_params_notice <- Some (T.Params_said (false, detail))
      | Ok value ->
          write_runtime_param state ~mailbox ~edit:(Some edit)
            ~failure:"Set failed: "
            ~notice:
              (Printf.sprintf "Set %s = %s" edit.T.rpe_key
                 (Yojson.Safe.to_string value))
            (fun () ->
              Masc_tui_http.post_runtime_param_set
                ~host:Masc_tui_transport.Workspace_admission.server_peer_host
                ~port:state.T.port ~key:edit.T.rpe_key ~value))

let handle_runtime_param_clear (state : T.state) ~mailbox =
  match selected_runtime_param state with
  | None ->
      state.T.runtime_params_notice <-
        Some (T.Params_said (false, "No runtime parameter is selected"))
  | Some row ->
      let key = row.Masc.Tui_decode.rpr_key in
      if not row.Masc.Tui_decode.rpr_has_override then
        state.T.runtime_params_notice <-
          Some (T.Params_said (true, key ^ " already uses its default"))
      else
        write_runtime_param state ~mailbox ~edit:None ~failure:"Reset failed: "
          ~notice:("Reset " ^ key ^ " to its default") (fun () ->
            Masc_tui_http.post_runtime_param_clear
              ~host:Masc_tui_transport.Workspace_admission.server_peer_host
              ~port:state.T.port ~key)
