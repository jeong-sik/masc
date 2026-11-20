module T = Masc_tui_types
module Kept_request = Masc_tui_words.Kept_request
module Terminal_text = Masc_tui_ansi.Terminal_text

let skill_template ~composition =
  if composition then {|---
name: ""
description: ""
---

```toml composition
[[compositions]]
name = ""
execution = "inline"
plan_json = "{\"nodes\":[],\"exports\":[],\"branch_failure_policy\":\"fail_fast\"}"
```

<!-- Set the same package name in frontmatter and composition. Author the
nodes, JSON inputs, after dependencies and named outputs in plan_json.
The server validates tool contracts; this empty plan cannot be published.
Add instructions below the closed executable declaration. -->
|}
  else {|---
name: ""
description: ""
---

<!-- Describe the procedure, expected result and verification here.
Agents discover the name and description first; the body loads on demand.
Use relative paths for resources already held in the package. -->
|}

let edit_new_skill (state : T.state) ~mailbox ~terminal_session ~origin
    ~composition ~source_id ~check ~port =
  let same_draft (draft : T.skill_create_draft) =
    draft.T.scd_composition = composition
    && String.equal draft.T.scd_source_id source_id
    && draft.T.scd_origin = origin
  in
  let source_text =
    match List.find_opt same_draft state.T.tools_skill_create_drafts with
    | Some draft -> draft.T.scd_source_text
    | None -> skill_template ~composition
  in
  match Masc_tui_editor.editor_command () with
  | None ->
      Masc_tui_shell.Editor_notice.report_unset state
        ~form:Masc_tui_shell.Editor_notice.Skill_creation
  | Some _ -> (
      match
        Masc_tui_editor.roundtrip
          ~restore:(fun () ->
            Masc_tui_shell.Terminal_session.hand_off terminal_session)
          ~reenter:(fun () ->
            Masc_tui_shell.Terminal_session.take_back terminal_session)
          ~suffix:".md" source_text
      with
      | Error abort ->
          Masc_tui_shell.Editor_notice.report_abort state
            ~form:Masc_tui_shell.Editor_notice.Skill_creation abort
      | Ok source_text -> (
          state.T.tools_skill_create_drafts <-
            { T.scd_source_id = source_id
            ; scd_composition = composition
            ; scd_source_text = source_text
            ; scd_origin = origin
            }
            :: List.filter
                 (fun draft -> not (same_draft draft))
                 state.T.tools_skill_create_drafts;
          match Agent_core.Skill_document.decode_authored source_text with
          | Agent_core.Skill_document.Unloadable diagnostics ->
              Masc_tui_loader.report_action state "error"
                (Terminal_text.single_line
                   ("Draft retained: "
                    ^ String.concat "; "
                        (List.map Agent_core.Skill_document.diagnostic_to_string
                           diagnostics)))
          | Agent_core.Skill_document.Loaded document -> (
              let package_id = document.Agent_core.Skill_document.name in
              let report kind text =
                Masc_tui_loader.report_action state kind
                  (Terminal_text.single_line text)
              in
              match check () with
              | Error refusal ->
                  (* Not sent: the kept-back notice with the draft it kept
                     (RFC §2). *)
                  Masc_tui_transport.Request_notice.report_kept_back state
                    ~request:Kept_request.Skill_creation
                    (fun ~ko -> T.workspace_refusal_reason ~ko refusal)
                    Masc_tui_words.Draft_kept
              | Ok () -> (
                  match
                    Masc_tui_http.post_skill_editor_create
                      ~host:Masc_tui_transport.Workspace_admission.server_peer_host
                      ~port ~composition ~source_id ~package_id ~source_text
                  with
                  | Error (Masc_tui_http.Skill_write_refused detail) ->
                      report "error"
                        ("Create refused; draft retained: " ^ detail)
                  | Error (Masc_tui_http.Skill_write_unconfirmed detail) ->
                      report "error"
                        ("Create effect not confirmed; draft retained. Read the package before retrying: " ^ detail)
                  | Ok receipt ->
                      state.T.tools_skill_create_drafts <-
                        List.filter
                          (fun draft -> not (same_draft draft))
                          state.T.tools_skill_create_drafts;
                      (match receipt.Masc_tui_http.sec_status with
                       | Masc_tui_http.Skill_created_and_published ->
                           report "system"
                             (Printf.sprintf "created and published · %s/%s"
                                source_id package_id)
                       | Masc_tui_http.Skill_created_but_shadowed winner ->
                           report "error"
                             (Printf.sprintf
                                "shadowed by %s/%s: %s/%s was created; Keepers see the earlier source by name"
                                (Skill_reference.identity_source_id_to_string
                                   winner)
                                (Skill_reference.identity_package_id_to_string
                                   winner)
                                source_id package_id)
                       | Masc_tui_http.Skill_created_but_unpublished reason ->
                           report "error"
                             (Printf.sprintf
                                "%s/%s created but NOT published: %s" source_id
                                package_id reason));
                      Masc_tui_work_requests.Tools_task_requests.launch_tools_load
                        state ~mailbox))))

let handle_skill_create (state : T.state) ~mailbox ~terminal_session
    ~composition =
  let check =
    Masc_tui_transport.Workspace_admission.capture_admission state ~mailbox
  in
  let port = state.T.port in
  let origin = T.workspace_input_identity_of_server state.T.server_identity in
  match check () with
  | Error refusal ->
      Masc_tui_transport.Request_notice.report_withdrawn state
        ~request:Kept_request.Skill_sources_read refusal
  | Ok () -> (
      match
        Masc_tui_http.fetch_skill_editor_sources
          ~host:Masc_tui_transport.Workspace_admission.server_peer_host ~port
      with
      | Error detail ->
          Masc_tui_loader.report_action state "error"
            ("Skill sources failed: " ^ detail)
      | Ok [] ->
          Masc_tui_loader.report_action state "error"
            "No ready read-write Skill source"
      | Ok [ source_id ] -> (
          match origin with
          | None ->
              Masc_tui_transport.Request_notice.report_kept_back state
                ~request:Kept_request.Skill_creation
                Masc_tui_words.workspace_identity_unconfirmed
                Masc_tui_words.Nothing_kept
          | Some origin ->
              edit_new_skill state ~mailbox ~terminal_session ~origin
                ~composition ~source_id ~check ~port)
      | Ok sources ->
          state.T.search <- None;
          T.tools_task_user_scroll state 0;
          state.T.tools_skill_source_picker <-
            Some
              { T.ssp_sources = sources
              ; ssp_composition = composition
              ; ssp_list = Masc_tui_pick_list.closed
              ; ssp_authority = state.T.workspace_authority
              ; ssp_identity = state.T.server_identity
              ; ssp_port = port
              })

let handle_skill_source_key (state : T.state) ~mailbox ~terminal_session ~page
    key =
  T.tools_task_user_scroll state 0;
  match state.T.tools_skill_source_picker with
  | None -> ()
  | Some picker -> (
      match
        Masc_tui_pick_list.action_of_key ~close_keys:[] picker.T.ssp_list key
      with
      | None -> ()
      | Some action -> (
          match
            Masc_tui_pick_list.apply ~page ~label:Fun.id
              picker.T.ssp_sources picker.T.ssp_list action
          with
          | Masc_tui_pick_list.Stay list ->
              state.T.tools_skill_source_picker <-
                Some { picker with T.ssp_list = list }
          | Masc_tui_pick_list.Dismissed ->
              state.T.tools_skill_source_picker <- None
          | Masc_tui_pick_list.Chosen source_id -> (
              state.T.tools_skill_source_picker <- None;
              let check =
                Masc_tui_transport.Workspace_admission.admission_sequence state
                  ~mailbox ~authority:picker.T.ssp_authority
                  ~identity:picker.T.ssp_identity
                  ~host:Masc_tui_transport.Workspace_admission.server_peer_host
                  ~port:picker.T.ssp_port
              in
              match check () with
              | Error refusal ->
                  Masc_tui_transport.Request_notice.report_withdrawn state
                    ~request:Kept_request.Skill_creation refusal
              | Ok () -> (
                  match
                    T.workspace_input_identity_of_server picker.T.ssp_identity
                  with
                  | None ->
                      Masc_tui_transport.Request_notice.report_kept_back state
                        ~request:Kept_request.Skill_creation
                        Masc_tui_words.workspace_identity_unconfirmed
                        Masc_tui_words.Nothing_kept
                  | Some origin ->
                      edit_new_skill state ~mailbox ~terminal_session ~origin
                        ~composition:picker.T.ssp_composition ~source_id ~check
                        ~port:picker.T.ssp_port))))

let handle_async_request_lookup (state : T.state) ~mailbox ~terminal_session =
  let authority = state.T.workspace_authority in
  let reading = state.T.workspace_read_authority in
  let target =
    match state.T.tools_async_selection with
    | Some (target : Masc.Tui_decode_async_request.target) ->
        `Assoc
          [ "submitted_by", `String target.Masc.Tui_decode_async_request.submitted_by
          ; "request_id", `String target.Masc.Tui_decode_async_request.request_id
          ; "keeper_name", `String target.Masc.Tui_decode_async_request.keeper_name
          ]
    | None ->
        `Assoc
          [ "submitted_by", `String ""
          ; "request_id", `String ""
          ; "keeper_name", `String ""
          ]
  in
  match
    Masc_tui_editor.roundtrip
      ~restore:(fun () ->
        Masc_tui_shell.Terminal_session.hand_off terminal_session)
      ~reenter:(fun () ->
        Masc_tui_shell.Terminal_session.take_back terminal_session)
      ~suffix:".json"
      (Yojson.Safe.pretty_to_string target ^ "\n")
  with
  | Error abort ->
      Masc_tui_shell.Editor_notice.report_abort state
        ~form:Masc_tui_shell.Editor_notice.Original_request_lookup abort
  | Ok text -> (
      let decoded =
        match Yojson.Safe.from_string text with
        | json -> Masc.Tui_decode_async_request.target_of_json json
        | exception Yojson.Json_error detail -> Error detail
      in
      match decoded with
      | Error detail -> Masc_tui_loader.report_action state "error" detail
      | Ok _
        when authority <> state.T.workspace_authority
             || reading != state.T.workspace_read_authority ->
          Masc_tui_loader.report_action state "error"
            "Original lookup workspace was withdrawn"
      | Ok target ->
          Masc_tui_work_requests.Tools_task_requests.close_tools_async_detail
            state;
          if
            not
              (Option.equal Masc.Tui_decode_async_request.equal_target
                 state.T.tools_async_selection (Some target))
          then
            state.T.tools_async_last_logical <- None;
          state.T.tools_async_selection <- Some target;
          state.T.tools_async_detail_open <- true;
          Masc_tui_work_requests.Tools_task_requests.launch_tools_async_detail
            state ~mailbox)

(* Each of the read, the preview and the save asks the workspace guard
   first; one it stops was not sent and is said as kept back (RFC §2). *)
let handle_skill_edit (state : T.state) ~mailbox ~terminal_session =
  let check =
    Masc_tui_transport.Workspace_admission.capture_admission state ~mailbox
  in
  match T.selected_tools_skill_profile state with
  | None ->
      Masc_tui_loader.report_action state "error" "no published Skill selected"
  | Some profile -> (
      let name = profile.Masc.Tui_decode_tools.esp_name in
      let host = Masc_tui_transport.Workspace_admission.server_peer_host in
      let port = state.T.port in
      match check () with
      | Error refusal ->
          Masc_tui_transport.Request_notice.report_withdrawn state
            ~request:Kept_request.Skill_read refusal
      | Ok () -> (
          match
            Masc_tui_http.post_skill_editor_read ~host ~port
              profile.Masc.Tui_decode_tools.esp_reference
          with
          | Error detail ->
              Masc_tui_loader.report_action state "error"
                ("Skill read failed: " ^ detail)
          | Ok { Masc_tui_http.sel_access = Skill_source_config.Read_only; _ } ->
              Masc_tui_loader.report_action state "error"
                (name ^ " belongs to a read-only Skill source")
          | Ok ({ Masc_tui_http.sel_access = Skill_source_config.Read_write; _ } as loaded) -> (
              match Masc_tui_editor.editor_command () with
              | None ->
                  Masc_tui_shell.Editor_notice.report_unset state
                    ~form:(Masc_tui_shell.Editor_notice.Skill_source name)
              | Some _ -> (
                  match
                    Masc_tui_editor.roundtrip
                      ~restore:(fun () ->
                        Masc_tui_shell.Terminal_session.hand_off terminal_session)
                      ~reenter:(fun () ->
                        Masc_tui_shell.Terminal_session.take_back terminal_session)
                      ~suffix:".md" loaded.Masc_tui_http.sel_source_text
                  with
                  | Error abort ->
                      Masc_tui_shell.Editor_notice.report_abort state
                        ~form:(Masc_tui_shell.Editor_notice.Skill_source name)
                        abort
                  | Ok edited
                    when String.equal edited loaded.Masc_tui_http.sel_source_text ->
                      Masc_tui_loader.report_action state "system"
                        (name ^ " unchanged")
                  | Ok edited -> (
                      match check () with
                      | Error refusal ->
                          Masc_tui_transport.Request_notice.report_withdrawn state
                            ~request:Kept_request.Skill_preview refusal
                      | Ok () -> (
                          match
                            Masc_tui_http.post_skill_editor_preview ~host ~port
                              ~reference:loaded.Masc_tui_http.sel_reference
                              ~source_text:edited
                          with
                          | Error detail ->
                              Masc_tui_loader.report_action state "error"
                                ("Skill preview rejected: " ^ detail)
                          | Ok _ -> (
                              match check () with
                              | Error refusal ->
                                  Masc_tui_transport.Request_notice
                                  .report_withdrawn state
                                    ~request:Kept_request.Skill_save refusal
                              | Ok () -> (
                                  match
                                    Masc_tui_http.post_skill_editor_save ~host ~port
                                      ~reference:loaded.Masc_tui_http.sel_reference
                                      ~source_text:edited
                                  with
                                  | Error (Masc_tui_http.Skill_write_refused detail) ->
                                      Masc_tui_loader.report_action state "error"
                                        (Terminal_text.single_line
                                           ("Skill save refused: " ^ detail))
                                  | Error (Masc_tui_http.Skill_write_unconfirmed detail) ->
                                      Masc_tui_loader.report_action state "error"
                                        (Terminal_text.single_line
                                           ("Skill save effect not confirmed; read the current package before retrying: " ^ detail))
                                  | Ok receipt -> (
                                      match receipt.Masc_tui_http.ses_status with
                                      | Masc_tui_http.Skill_unchanged ->
                                          Masc_tui_loader.report_action state
                                            "system" (name ^ " unchanged")
                                      | Masc_tui_http.Skill_saved_and_published ->
                                          let revision =
                                            Skill_reference
                                            .content_revision_to_string
                                              receipt.Masc_tui_http.ses_reference
                                              .Skill_reference.content_revision
                                          in
                                          let revision_short =
                                            String.sub revision 0
                                              (min 12 (String.length revision))
                                          in
                                          Masc_tui_loader.report_action state
                                            "system"
                                            (Printf.sprintf
                                               "%s saved + published · %s%s" name
                                               revision_short
                                               (match
                                                  receipt.Masc_tui_http
                                                  .ses_snapshot_revision
                                                with
                                                | None -> ""
                                                | Some snapshot ->
                                                    " · snapshot "
                                                    ^ String.sub snapshot 0
                                                        (min 12
                                                           (String.length
                                                              snapshot))));
                                          Masc_tui_work_requests
                                          .Tools_task_requests.launch_tools_load
                                            state ~mailbox
                                      | Masc_tui_http.Skill_saved_but_unpublished reason ->
                                          Masc_tui_loader.report_action state
                                            "error"
                                            (name
                                             ^ " was saved but NOT published: "
                                             ^ reason))))))))))

(* Deleting a Skill is the editor DELETE route, which no $EDITOR roundtrip
   covers: the first [d] arms the selected identity, and only a second [d]
   on the same row sends the delete. The read that precedes the write is
   what the edit flow does too -- it yields the fresh exact reference the
   server's revision CAS demands and refuses read-only sources up front. *)
let handle_skill_delete (state : T.state) ~mailbox =
  let check =
    Masc_tui_transport.Workspace_admission.capture_admission state ~mailbox
  in
  match T.selected_tools_skill_profile state with
  | None ->
      Masc_tui_loader.report_action state "error" "no published Skill selected"
  | Some profile ->
      let name = profile.Masc.Tui_decode_tools.esp_name in
      let identity =
        profile.Masc.Tui_decode_tools.esp_reference.Skill_reference.identity
      in
      let host = Masc_tui_transport.Workspace_admission.server_peer_host in
      let port = state.T.port in
      if state.T.tools_skill_delete_armed <> Some identity then begin
        state.T.tools_skill_delete_armed <- Some identity;
        Masc_tui_loader.report_action state "system"
          (Printf.sprintf "press d again to delete %s" name)
      end else begin
        state.T.tools_skill_delete_armed <- None;
        (* The read and the delete each ask the workspace guard first; one it
           stops was not sent and is said as kept back (RFC §2). *)
        match check () with
        | Error refusal ->
            Masc_tui_transport.Request_notice.report_withdrawn state
              ~request:Kept_request.Skill_read refusal
        | Ok () -> (
            match
              Masc_tui_http.post_skill_editor_read ~host ~port
                profile.Masc.Tui_decode_tools.esp_reference
            with
            | Error detail ->
                Masc_tui_loader.report_action state "error"
                  ("Skill read failed: " ^ detail)
            | Ok { Masc_tui_http.sel_access = Skill_source_config.Read_only; _ } ->
                Masc_tui_loader.report_action state "error"
                  (name ^ " belongs to a read-only Skill source")
            | Ok ({ Masc_tui_http.sel_access = Skill_source_config.Read_write; _ } as loaded) -> (
                match check () with
                | Error refusal ->
                    Masc_tui_transport.Request_notice.report_withdrawn state
                      ~request:Kept_request.Skill_delete refusal
                | Ok () -> (
                    match
                      Masc_tui_http.delete_skill_editor ~host ~port
                        ~reference:loaded.Masc_tui_http.sel_reference
                    with
                    | Error (Masc_tui_http.Skill_write_refused detail) ->
                        Masc_tui_loader.report_action state "error"
                          (Terminal_text.single_line
                             ("Skill delete refused: " ^ detail))
                    | Error (Masc_tui_http.Skill_write_unconfirmed detail) ->
                        Masc_tui_loader.report_action state "error"
                          (Terminal_text.single_line
                             ("Skill delete effect not confirmed; read the current package before retrying: " ^ detail))
                    | Ok receipt -> (
                        match receipt.Masc_tui_http.sed_status with
                        | Masc_tui_http.Skill_deleted_and_published ->
                            Masc_tui_loader.report_action state "system"
                              (Printf.sprintf "%s deleted + published · recovery %s"
                                 name receipt.Masc_tui_http.sed_recovery_id);
                            Masc_tui_work_requests.Tools_task_requests
                            .launch_tools_load state ~mailbox
                        | Masc_tui_http.Skill_deleted_but_unpublished reason ->
                            Masc_tui_loader.report_action state "error"
                              (name ^ " was deleted but NOT published: " ^ reason)))))
      end

(* A prompt is edited the way runtime.toml is: $EDITOR over the text a turn
   actually gets, and the server persists what comes back. The effective
   text is the stem rather than the file's, because an overridden prompt is
   what the keeper reads and editing the file underneath it would change
   nothing the operator can see. *)
let selected_prompt (state : T.state) =
  Masc_tui_surface_requests.Prompt_preset_requests.selected_prompt_for_state state

let handle_librarian_input_read (state : T.state) ~mailbox =
  match selected_prompt state with
  | None ->
      Masc_tui_loader.report_action state "error"
        "prompts not loaded yet; r to reload"
  | Some row
    when not (String.equal row.Masc.Tui_decode.pr_category "librarian") ->
      Masc_tui_loader.report_action state "error"
        "actual input is available on the Librarian prompt"
  | Some row ->
      Masc_tui_surface_requests.Prompt_preset_requests
      .launch_librarian_input_load state ~mailbox
        ~prompt_key:row.Masc.Tui_decode.pr_key

let handle_prompt_edit (state : T.state) ~mailbox ~terminal_session =
  if Write_guard.workspace_write_ready state ~request:Kept_request.Prompt_save then
    let check =
      Masc_tui_transport.Workspace_admission.capture_admission state ~mailbox
    in
    match selected_prompt state with
    | None ->
        Masc_tui_loader.report_action state "error"
          "prompts not loaded yet; r to reload"
    | Some row -> (
        match Masc_tui_editor.editor_command () with
        | None ->
            Masc_tui_shell.Editor_notice.report_unset state
              ~form:(Masc_tui_shell.Editor_notice.Prompt_text row.Masc.Tui_decode.pr_key)
        | Some _ -> (
            match
              Masc_tui_editor.roundtrip
                ~restore:(fun () ->
                  Masc_tui_shell.Terminal_session.hand_off terminal_session)
                ~reenter:(fun () ->
                  Masc_tui_shell.Terminal_session.take_back terminal_session)
                row.Masc.Tui_decode.pr_effective
            with
            | Error abort ->
                Masc_tui_shell.Editor_notice.report_abort state
                  ~form:
                    (Masc_tui_shell.Editor_notice.Prompt_text
                       row.Masc.Tui_decode.pr_key)
                  abort
            | Ok edited -> (
                match check () with
                | Error refusal ->
                    (* Not sent: the kept-back notice, with the prompt after it,
                       never a failed save (RFC §2). *)
                    Masc_tui_loader.report_action state "error"
                      (T.workspace_refusal_text ~ko:(state.T.ui_language = T.Lang_ko)
                         ~request:Kept_request.Prompt_save refusal
                       ^ " · " ^ row.Masc.Tui_decode.pr_key)
                | Ok () -> (
                    match
                      Masc_tui_http.post_prompt_override
                        ~host:Masc_tui_transport.Workspace_admission.server_peer_host
                        ~port:state.T.port ~key:row.Masc.Tui_decode.pr_key
                        ~value:edited
                    with
                    | Ok _ ->
                        Masc_tui_loader.report_action state "system"
                          (row.Masc.Tui_decode.pr_key ^ ": prompt saved");
                        Masc_tui_surface_requests.Prompt_preset_requests
                        .launch_prompts_load state ~mailbox
                    | Error detail ->
                        Masc_tui_loader.report_action state "error"
                          (row.Masc.Tui_decode.pr_key ^ ": save failed: " ^ detail)))))

(* Clearing is not editing to empty: it returns the prompt to the file's
   words, which is a different outcome from an override holding "". *)
let handle_prompt_clear (state : T.state) ~mailbox =
  if Write_guard.workspace_write_ready state ~request:Kept_request.Prompt_clear then
    let check =
      Masc_tui_transport.Workspace_admission.capture_admission state ~mailbox
    in
    match selected_prompt state with
    | None ->
        Masc_tui_loader.report_action state "error"
          "prompts not loaded yet; r to reload"
    | Some row -> (
        match row.Masc.Tui_decode.pr_source with
        | Masc.Tui_decode.Prompt_file | Masc.Tui_decode.Prompt_missing ->
            Masc_tui_loader.report_action state "system"
              (row.Masc.Tui_decode.pr_key ^ ": no override to clear")
        | Masc.Tui_decode.Prompt_override -> (
            match check () with
            | Error refusal ->
                (* Not sent: the kept-back notice, with the prompt after it, never
                   a failed clear (RFC §2). *)
                Masc_tui_loader.report_action state "error"
                  (T.workspace_refusal_text ~ko:(state.T.ui_language = T.Lang_ko)
                     ~request:Kept_request.Prompt_clear refusal
                   ^ " · " ^ row.Masc.Tui_decode.pr_key)
            | Ok () -> (
                match
                  Masc_tui_http.post_prompt_clear
                    ~host:Masc_tui_transport.Workspace_admission.server_peer_host
                    ~port:state.T.port ~key:row.Masc.Tui_decode.pr_key
                with
                | Ok _ ->
                    Masc_tui_loader.report_action state "system"
                      (row.Masc.Tui_decode.pr_key ^ ": override cleared");
                    Masc_tui_surface_requests.Prompt_preset_requests
                    .launch_prompts_load state ~mailbox
                | Error detail ->
                    Masc_tui_loader.report_action state "error"
                      (row.Masc.Tui_decode.pr_key ^ ": clear failed: " ^ detail))))

let open_prepared_keeper_settings_editor (state : T.state) ~mailbox
    ~terminal_session (request : T.keeper_settings_request)
    (snapshot : T.keeper_settings_snapshot) =
  let key = Masc_tui_fetched.request_key request.T.ksr_request in
  let keeper_name = key.T.ksk_keeper in
  let observed = snapshot.T.kss_observed in
  let format = request.T.ksr_format in
  (* The same frozen snapshot supplies the editor text and guarded patch. *)
  let rec edit_round ?prior_reason stem =
    match
      Masc_tui_editor.roundtrip
        ~restore:(fun () ->
          Masc_tui_shell.Terminal_session.hand_off terminal_session)
        ~reenter:(fun () ->
          Masc_tui_shell.Terminal_session.take_back terminal_session)
        ~suffix:(Masc_tui_keeper_config.editor_suffix format)
        stem
    with
    | Error abort ->
        Masc_tui_shell.Editor_notice.report_abort state
          ~form:(Masc_tui_shell.Editor_notice.Keeper_settings keeper_name) abort
    | Ok edited ->
        let reopen reason =
          if String.equal edited stem then
            Masc_tui_loader.report_action state "error"
              (keeper_name ^ ": " ^ reason ^ " (settings unchanged)")
          else
            edit_round ~prior_reason:reason
              (Masc_tui_keeper_config.reopened_stem ~format ?prior_reason ~reason
                 edited)
        in
        (match Masc_tui_keeper_config.parse_editor ~format edited with
         | Error detail -> reopen detail
         | Ok edited_json -> apply_edit ~reopen ~edited edited_json)
  and apply_edit ~reopen ~edited edited_json =
    match
      Masc_tui_keeper_config.patch_of_edit ~before:observed ~after:edited_json
    with
    | Error (Masc_tui_keeper_config.Fix_in_editor reason) -> reopen reason
    | Error (Masc_tui_keeper_config.Cannot_send detail) ->
        Masc_tui_loader.report_action state "error" detail
    | Ok (`Assoc []) ->
        Masc_tui_loader.report_action state "system"
          (keeper_name ^ ": no settings changed")
    | Ok patch -> (
        let draft =
          { T.ksd_snapshot = snapshot; ksd_text = edited; ksd_patch = patch }
        in
        match
          T.begin_keeper_settings_save state ~origin:request ~draft
            ~started_ns:(Mtime_clock.elapsed_ns ())
        with
        | Error detail -> Masc_tui_loader.report_action state "error" detail
        | Ok request ->
            Masc_tui_surface_requests.Runtime_config_requests
            .launch_keeper_settings_save state ~mailbox request)
  in
  let stem =
    match T.keeper_settings_recovery state key with
    | None -> Ok snapshot.T.kss_stem
    | Some retained ->
        Masc_tui_keeper_config.reopen_edit_on_current ~format
          ~patch:retained.T.ksd_patch ~current:observed
  in
  match stem with
  | Ok stem -> edit_round stem
  | Error refusal ->
      Masc_tui_loader.report_action state "error"
        (Masc_tui_keeper_config.edit_refusal_to_string refusal)

let handle_keeper_settings_edit (state : T.state) ~mailbox ~format =
  match T.selected_keeper state with
  | None ->
      Masc_tui_loader.report_action state "system"
        (Masc_tui_operator_actions.Keeper_actions.no_keeper_under_cursor
           ~ko:(state.T.ui_language = T.Lang_ko))
  | Some (keeper : Masc.Tui_decode.keeper) -> (
      match Masc_tui_editor.editor_command () with
      | None ->
          Masc_tui_shell.Editor_notice.report_unset state
            ~form:
              (Masc_tui_shell.Editor_notice.Keeper_settings
                 keeper.Masc.Tui_decode.k_name)
      | Some _ -> (
          match
            T.begin_keeper_settings_editor state ~format
              ~available:
                (Masc_tui_surface_requests.Keeper_surface_requests
                 .keeper_settings_editor_available state)
              ~started_ns:(Mtime_clock.elapsed_ns ())
          with
          | Some request ->
              Masc_tui_surface_requests.Keeper_surface_requests
              .launch_keeper_settings_editor_read state ~mailbox request
          | None -> (
              match
                (match T.keeper_settings_editor_notice state with
                 | Some _ as notice -> notice
                 | None -> T.keeper_settings_save_notice state)
              with
              | Some notice -> Masc_tui_loader.report_action state "info" notice
              | None ->
                  Masc_tui_loader.report_action state "error"
                    "Settings editor preparation requires current workspace and focus")))

let continue_keeper_settings_editor (state : T.state) ~mailbox ~terminal_session
    ~input_pending =
  match
    T.take_ready_keeper_settings_editor state
      ~available:
        (Masc_tui_surface_requests.Keeper_surface_requests
         .keeper_settings_editor_available state)
      ~input_pending
  with
  | None -> ()
  | Some (request, snapshot) ->
      Masc_tui_surface_requests.Keeper_surface_requests.log_keeper_settings_read
        ~phase:"editor_opened" request ~outcome:"snapshot_handed_off";
      open_prepared_keeper_settings_editor state ~mailbox ~terminal_session
        request snapshot

(* An absolute shortcut owns its profile immediately. The worker reads a
   fresh composite revision before preparing the single-field CAS patch. *)
let set_sandbox_backend (state : T.state) ~mailbox ~profile =
  match
    T.begin_keeper_sandbox_save state ~profile
      ~started_ns:(Mtime_clock.elapsed_ns ())
  with
  | Ok request ->
      Masc_tui_surface_requests.Runtime_config_requests
      .launch_keeper_settings_save state ~mailbox request
  | Error detail -> Masc_tui_loader.report_action state "error" detail
