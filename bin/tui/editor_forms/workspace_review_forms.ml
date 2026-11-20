module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Kept_request = Masc_tui_words.Kept_request

(* [run_with_eio_context] owns the UI switch. An unavailable async context
   must not turn an operator action into blocking HTTP on the key path. *)
let with_async_switch (state : T.state) ~action start =
  match Eio_context.get_switch_opt () with
  | Some sw -> start sw
  | None ->
      Masc_tui_loader.report_action state "error"
        (action ^ ": asynchronous runtime unavailable")

(* The verdict row under the Harness cursor, when the list has one. *)
let harness_cursor_verdict (state : T.state) =
  Option.bind state.T.harness (fun snapshot ->
      List.nth_opt snapshot.Masc.Tui_decode.hs_verdicts state.T.harness_cursor)

(* Operator label on a harness verdict. [y] records the machine's side as
   the human's; [n] records the opposite side and takes its reason through
   $EDITOR, because the reason is the text the divergence teaches the judge
   as a few-shot example. The machine's side is read off the closed
   verdict serialization ("approve" | "approve:<reason>" | "reject:<reason>"). *)
let harness_machine_approved (row : Masc.Tui_decode.harness_verdict) =
  (* [Task] and [Eval_calibration] live in the masc library, which the
     executable reaches through [Masc] -- the mli spells them the library's
     way because it sits inside it (#33116 built red on the bare names). *)
  match Masc.Eval_calibration.verdict_of_string row.Masc.Tui_decode.hv_verdict with
  | Some (Masc.Task.Anti_rationalization.Approve _) -> Some true
  | Some (Masc.Task.Anti_rationalization.Reject _) -> Some false
  | None -> None

let start_harness_label (state : T.state) ~mailbox ~notes_hash
    ~(verdict : [ `Approve | `Reject ]) ~reason ~described =
  if Write_guard.workspace_write_ready state ~request:Kept_request.Harness_label
  then
    let check =
      Masc_tui_transport.Workspace_admission.capture_admission state ~mailbox
    in
    let enqueue_async =
      Masc_tui_transport.Workspace_admission.workspace_enqueue state
    in
    let host = Masc_tui_transport.Workspace_admission.server_peer_host in
    let port = state.T.port in
    let run () =
      let result =
        match check () with
        | Error refusal -> Error (T.Request_withdrawn refusal)
        | Ok () -> (
            match
              Masc_tui_http.post_harness_label ~host ~port ~notes_hash ~verdict
                ~reason
            with
            | Error err -> Error (T.Request_failed err)
            | Ok _json -> Ok described)
      in
      enqueue_async mailbox (P.Harness_msg (P.Harness_label_done result))
    in
    with_async_switch state ~action:"Harness label" (fun sw ->
        Masc_tui_transport.Workspace_admission.fork_job state ~mailbox ~sw run)

let handle_harness_agree (state : T.state) ~mailbox =
  match harness_cursor_verdict state with
  | None -> ()
  | Some row -> (
      match harness_machine_approved row with
      | None ->
          Masc_tui_loader.report_action state "error"
            "cannot label: unrecognized verdict format"
      | Some approved ->
          start_harness_label state ~mailbox
            ~notes_hash:row.Masc.Tui_decode.hv_notes_hash
            ~verdict:(if approved then `Approve else `Reject)
            ~reason:""
            ~described:
              (Printf.sprintf "labelled %s: the %s stands"
                 row.Masc.Tui_decode.hv_task_id
                 (if approved then "approve" else "reject")))

let handle_harness_overrule (state : T.state) ~mailbox ~terminal_session =
  if Write_guard.workspace_write_ready state ~request:Kept_request.Harness_label
  then
    match harness_cursor_verdict state with
    | None -> ()
    | Some row -> (
        match Masc_tui_editor.editor_command () with
        | None ->
            Masc_tui_shell.Editor_notice.report_unset state
              ~form:Masc_tui_shell.Editor_notice.Harness_overrule
        | Some _ -> (
            let stem = "{\n  \"reason\": \"\"\n}\n" in
            match
              Masc_tui_editor.roundtrip
                ~restore:(fun () ->
                  Masc_tui_shell.Terminal_session.hand_off terminal_session)
                ~reenter:(fun () ->
                  Masc_tui_shell.Terminal_session.take_back terminal_session)
                stem
            with
            | Error abort ->
                Masc_tui_shell.Editor_notice.report_abort state
                  ~form:Masc_tui_shell.Editor_notice.Harness_overrule abort
            | Ok body -> (
                match Yojson.Safe.from_string body with
                | exception Yojson.Json_error e ->
                    Masc_tui_loader.report_action state "error"
                      ("overrule: body is not JSON: " ^ e)
                | json -> (
                    let reason =
                      match json with
                      | `Assoc fields -> (
                          match List.assoc_opt "reason" fields with
                          | Some (`String s) -> String.trim s
                          | Some _ | None -> "")
                      | _ -> ""
                    in
                    if String.equal reason "" then
                      Masc_tui_loader.report_action state "system"
                        "overrule cancelled (empty reason)"
                    else
                      match harness_machine_approved row with
                      | None ->
                          Masc_tui_loader.report_action state "error"
                            "cannot overrule: unrecognized verdict format"
                      | Some approved ->
                          start_harness_label state ~mailbox
                            ~notes_hash:row.Masc.Tui_decode.hv_notes_hash
                            ~verdict:(if approved then `Reject else `Approve)
                            ~reason
                            ~described:
                              (Printf.sprintf "overruled %s: %s was wrong"
                                 row.Masc.Tui_decode.hv_task_id
                                 (if approved then "the approve"
                                  else "the reject"))))))

(* Verification reject: the reason is required, and $EDITOR is the form we
   already have. The editor is the confirmation step -- a non-zero exit or
   an empty reason leaves the task unjudged, so no arming gate sits in
   front of it the way one sits in front of the single-key approve. *)
let handle_verification_reject (state : T.state) ~mailbox ~terminal_session =
  match
    Masc_tui_work_actions.Verification_actions.verification_cursor_row state
  with
  | None -> ()
  | Some row -> (
      let task_id = row.Masc.Tui_decode.vr_task_id in
      match Masc_tui_editor.editor_command () with
      | None ->
          Masc_tui_shell.Editor_notice.report_unset state
            ~form:Masc_tui_shell.Editor_notice.Verification_rejection
      | Some _ -> (
          let stem = "{\n  \"reason\": \"\"\n}\n" in
          match
            Masc_tui_editor.roundtrip
              ~restore:(fun () ->
                Masc_tui_shell.Terminal_session.hand_off terminal_session)
              ~reenter:(fun () ->
                Masc_tui_shell.Terminal_session.take_back terminal_session)
              stem
          with
          | Error abort ->
              Masc_tui_shell.Editor_notice.report_abort state
                ~form:Masc_tui_shell.Editor_notice.Verification_rejection abort
          | Ok body -> (
              match Yojson.Safe.from_string body with
              | exception Yojson.Json_error e ->
                  Masc_tui_loader.report_action state "error"
                    ("reject: body is not JSON: " ^ e)
              | json ->
                  let reason =
                    match json with
                    | `Assoc fields -> (
                        match List.assoc_opt "reason" fields with
                        | Some (`String s) -> String.trim s
                        | Some _ | None -> "")
                    | _ -> ""
                  in
                  if String.equal reason "" then
                    Masc_tui_loader.report_action state "system"
                      "reject cancelled (empty reason)"
                  else
                    Masc_tui_work_actions.Verification_actions
                    .start_verification_verdict state ~mailbox ~task_id
                      ~verification_id:row.Masc.Tui_decode.vr_request_id
                      ~verdict:(`Reject reason))))

(* Task cancel: same form discipline as the verification reject — the
   reason is required, $EDITOR is the form, and a non-zero exit or an
   empty reason leaves the task untouched. The server's FSM decides
   whether the task is still cancellable. *)
let handle_task_cancel (state : T.state) ~mailbox ~terminal_session =
  let authority = state.T.workspace_authority in
  let identity = state.T.server_identity in
  match
    Masc_tui_task_selection.detail_row ~detail_id:state.T.task_detail_id
      ~tasks:(T.task_domain_values state)
  with
  | None -> ()
  | Some (task : Masc_domain.task) -> (
      let task_id = task.Masc_domain.id in
      match Masc_tui_editor.editor_command () with
      | None ->
          Masc_tui_shell.Editor_notice.report_unset state
            ~form:Masc_tui_shell.Editor_notice.Task_cancellation
      | Some _ -> (
          let stem =
            Yojson.Safe.pretty_to_string (`Assoc [ "reason", `String "" ])
            ^ "\n"
          in
          match
            Masc_tui_editor.roundtrip
              ~restore:(fun () ->
                Masc_tui_shell.Terminal_session.hand_off terminal_session)
              ~reenter:(fun () ->
                Masc_tui_shell.Terminal_session.take_back terminal_session)
              stem
          with
          | Error abort ->
              Masc_tui_shell.Editor_notice.report_abort state
                ~form:Masc_tui_shell.Editor_notice.Task_cancellation abort
          | Ok body -> (
              match Yojson.Safe.from_string body with
              | exception Yojson.Json_error e ->
                  Masc_tui_loader.report_action state "error"
                    ("cancel: body is not JSON: " ^ e)
              | json ->
                  let reason =
                    match json with
                    | `Assoc fields -> (
                        match List.assoc_opt "reason" fields with
                        | Some (`String s) -> String.trim s
                        | Some _ | None -> "")
                    | _ -> ""
                  in
                  if String.equal reason "" then
                    Masc_tui_loader.report_action state "system"
                      "cancel cancelled (empty reason)"
                  else
                    Masc_tui_work_requests.Tools_task_requests.launch_task_cancel
                      state ~mailbox ~authority ~identity ~task_id ~reason)))

(* A creation keeps its operation receipt even after its workspace withdraws.
   Only the result handler may use current authority to refresh or open chat. *)
let launch_keeper_creation (state : T.state) ~mailbox
    ~(request : T.keeper_creation_request) ~declaration =
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.T.port in
  let check =
    Masc_tui_transport.Workspace_admission.admission_sequence state ~mailbox
      ~authority:request.T.kcr_authority
      ~identity:(Some request.T.kcr_workspace) ~host ~port
  in
  let deliver status =
    if
      T.publish_keeper_creation_status request
        ~observed_ns:(Mtime_clock.elapsed_ns ()) status
    then
      Masc_tui_transport.Workspace_admission.enqueue mailbox
        (P.Keeper_msg (P.Keeper_creation_changed (request, status)))
  in
  let interrupted sent detail =
    if sent then T.Creation_unconfirmed detail else T.Creation_not_sent detail
  in
  let sent = ref false in
  let run () =
    let outcome =
      try
        match check () with
        | Error refusal -> T.Creation_kept_back refusal
        | Ok () -> (
            deliver T.Creation_posting;
            sent := true;
            match
              Masc_tui_http.post_keeper_up ~host ~port
                ~keeper_name:request.T.kcr_keeper
                ~expected_workspace:(Some request.T.kcr_workspace)
                ~declaration_json:declaration
            with
            | Masc_tui_http.Post_refused detail -> T.Creation_refused detail
            | Masc_tui_http.Post_unanswered detail ->
                T.Creation_unconfirmed detail
            | Masc_tui_http.Post_answered receipt -> (
                match
                  Masc_cli_keeper_create.creation_receipt
                    ~keeper_name:request.T.kcr_keeper receipt
                with
                | Masc_cli_keeper_create.Created _ -> T.Creation_created
                | Masc_cli_keeper_create.Reconfigured { name } ->
                    T.Creation_unconfirmed
                      (name
                       ^ ": server reported reconfiguration instead of creation; inspect its configuration")
                | Masc_cli_keeper_create.Refused detail
                | Masc_cli_keeper_create.Unauthorized detail
                | Masc_cli_keeper_create.Unreachable detail ->
                    T.Creation_unconfirmed detail
                | Masc_cli_keeper_create.Revision_conflict ->
                    T.Creation_unconfirmed "Creation revision conflict"))
      with
      | Eio.Cancel.Cancelled _ as exn ->
          deliver
            (T.Creation_finished
               (interrupted !sent "Creation request was interrupted"));
          raise exn
      | exn -> interrupted !sent (Printexc.to_string exn)
    in
    deliver (T.Creation_finished outcome)
  in
  Log.Transport.info
    "tui_keeper_creation keeper=%s started_ns=%Ld phase=checking"
    request.T.kcr_keeper request.T.kcr_started_ns;
  match Eio_context.get_switch_opt () with
  | None ->
      ignore
        (T.publish_keeper_creation_status request
           ~observed_ns:(Mtime_clock.elapsed_ns ())
           (T.Creation_finished
              (T.Creation_not_sent "Eio switch is unavailable")))
  | Some sw -> (
      match
        Masc_tui_transport.Workspace_admission.fork_job state ~mailbox ~sw run
      with
      | () -> ()
      | exception (Eio.Cancel.Cancelled _ as exn) ->
          deliver
            (T.Creation_finished
               (interrupted !sent "Creation worker was interrupted"));
          raise exn
      | exception exn ->
          deliver
            (T.Creation_finished
               (interrupted !sent (Printexc.to_string exn))))

let handle_keeper_create ?(return_to = T.Keeper_chat_return_list)
    (state : T.state) ~mailbox ~terminal_session ~show_keeper_list =
  if state.T.workspace_identity <> T.Workspace_identity_match then
    Masc_tui_transport.Request_notice.report_kept_back state
      ~request:Kept_request.Keeper_creation
      Masc_tui_words.workspace_identity_unconfirmed Masc_tui_words.Draft_kept
  else
    let return_to =
      Option.value state.T.keeper_creation_return ~default:return_to
    in
    match Masc_tui_editor.editor_command () with
    | None ->
        Masc_tui_shell.Editor_notice.report_unset state
          ~form:Masc_tui_shell.Editor_notice.Keeper_creation
    | Some _ -> (
        (* Which fields a creation cannot omit is [parse]'s business, so the
           stem comes from there rather than being restated here. Restating it
           is what went wrong: this form carried two fields across the whole
           time [sandbox_profile] was required, and every keeper made through
           it came back 400. *)
        let stem =
          match state.T.keeper_creation_draft with
          | Some declaration -> declaration
          | None ->
              Option.value
                (T.keeper_creation_recovery_draft state)
                ~default:Masc.Keeper_turn_up_args.creation_stem
        in
        match
          Masc_tui_editor.roundtrip
            ~restore:(fun () ->
              Masc_tui_shell.Terminal_session.hand_off terminal_session)
            ~reenter:(fun () ->
              Masc_tui_shell.Terminal_session.take_back terminal_session)
            stem
        with
        | Error abort ->
            Masc_tui_shell.Editor_notice.report_abort state
              ~form:Masc_tui_shell.Editor_notice.Keeper_creation abort
        | Ok declaration -> (
            state.T.keeper_creation_draft <- Some declaration;
            state.T.keeper_creation_draft_owner <- ref ();
            state.T.keeper_creation_return <- Some return_to;
            let refuse detail =
              show_keeper_list ();
              Masc_tui_loader.report_action state "error"
                (detail ^ " · press a to edit the retained declaration")
            in
            let declared_name =
              match Yojson.Safe.from_string declaration with
              | exception Yojson.Json_error detail ->
                  Error ("Keeper declaration is not JSON: " ^ detail)
              | `Assoc fields -> (
                  match List.assoc_opt "name" fields with
                  | Some (`String value) ->
                      Keeper_id.Keeper_name.of_string (String.trim value)
                      |> Result.map Keeper_id.Keeper_name.to_string
                  | Some _ | None ->
                      Error "declaration needs a non-empty name string")
              | _ -> Error "Keeper declaration must be a JSON object"
            in
            match declared_name with
            | Error detail -> refuse detail
            | Ok declared_name -> (
                (* The editor suspends observations. Revalidate the captured server
                   in the worker; the mutation itself also carries that workspace. *)
                if
                  List.exists
                    (fun (keeper : Masc.Tui_decode.keeper) ->
                       String.equal keeper.Masc.Tui_decode.k_name declared_name)
                    state.T.keepers
                then
                  refuse
                    (declared_name
                     ^ ": Keeper already exists; choose a new name.")
                else
                  let create_declaration =
                    match Yojson.Safe.from_string declaration with
                    | `Assoc fields ->
                        Yojson.Safe.to_string
                          (`Assoc
                            (("create_only", `Bool true)
                             :: List.remove_assoc "create_only" fields))
                    | json -> Yojson.Safe.to_string json
                  in
                  state.T.http_refresh_order <-
                    T.Http_refresh_order.dispatch state.T.http_refresh_order;
                  match
                    T.begin_keeper_creation state ~keeper_name:declared_name
                      ~declaration ~return_to
                      ~started_ns:(Mtime_clock.elapsed_ns ())
                  with
                  | Error detail -> refuse detail
                  | Ok request ->
                      launch_keeper_creation state ~mailbox ~request
                        ~declaration:create_declaration;
                      Masc_tui_loader.report_action state "system"
                        (declared_name
                         ^ ": checking workspace before creation; declaration retained"))))

(* Same shape as [handle_keeper_create]: several fields at once go through
   $EDITOR rather than a modal the TUI does not otherwise have. The stem
   names every field the route reads, with the two that have no sensible
   default left empty. *)
let handle_repository_add (state : T.state) ~mailbox ~terminal_session =
  if
    Write_guard.workspace_write_ready state ~request:Kept_request.Repository_add
  then
    let host = Masc_tui_transport.Workspace_admission.server_peer_host in
    let port = state.T.port in
    let check =
      Masc_tui_transport.Workspace_admission.capture_admission state ~mailbox
    in
    match Masc_tui_editor.editor_command () with
    | None ->
        Masc_tui_shell.Editor_notice.report_unset state
          ~form:Masc_tui_shell.Editor_notice.Repository_addition
    | Some _ -> (
        let stem =
          String.concat "\n"
            [ "{"
            ; "  \"name\": \"\","
            ; "  \"url\": \"\","
            ; "  \"default_branch\": \"main\","
            ; "  \"auto_sync\": false,"
            ; "  \"sync_interval\": 300"
            ; "}"
            ; ""
            ]
        in
        match
          Masc_tui_editor.roundtrip
            ~restore:(fun () ->
              Masc_tui_shell.Terminal_session.hand_off terminal_session)
            ~reenter:(fun () ->
              Masc_tui_shell.Terminal_session.take_back terminal_session)
            stem
        with
        | Error abort ->
            Masc_tui_shell.Editor_notice.report_abort state
              ~form:Masc_tui_shell.Editor_notice.Repository_addition abort
        | Ok declaration ->
            let declared field =
              match Yojson.Safe.from_string declaration with
              | `Assoc fields -> (
                  match List.assoc_opt field fields with
                  | Some (`String value) -> String.trim value
                  | Some _ | None -> "")
              | _ -> ""
            in
            let name = declared "name" in
            let url = declared "url" in
            if String.length name = 0 || String.length url = 0 then
              Masc_tui_loader.report_action state "error"
                "declaration needs non-empty \"name\" and \"url\" strings; nothing was added"
            else (
              match check () with
              | Error refusal ->
                  Masc_tui_transport.Request_notice.report_withdrawn state
                    ~request:Kept_request.Repository_add refusal
              | Ok () -> (
                  match
                    Masc_tui_http.post_repository_add ~host ~port
                      ~declaration_json:declaration
                  with
                  | Ok _ ->
                      Masc_tui_loader.report_action state "system"
                        (name ^ ": repository added");
                      (* The server announces the repositories dataset for this write
                         too; owing the read lets that announcement fold into the one
                         read the loop launches instead of starting a second. *)
                      state.T.repositories_owed <-
                        Masc_tui_owed_read.changed state.T.repositories_owed
                  | Error detail ->
                      Masc_tui_loader.report_action state "error" detail)))

let handle_schedule_form (state : T.state) ~mailbox ~terminal_session ~change
    ~stem ~post =
  let form = Masc_tui_shell.Editor_notice.Schedule_form change in
  let ko = state.T.ui_language = T.Lang_ko in
  (* A refusal stays on the Schedules surface for the last-action window:
     the action line alone is lost under a workspace warning. A new
     attempt clears the previous one. *)
  state.T.schedule_form_refusal <- None;
  let authority = state.T.workspace_authority in
  let identity = state.T.server_identity in
  let report_form_refusal reason =
    let refusal =
      { T.sfr_change = change
      ; sfr_reason = reason
      ; sfr_at = Unix.gettimeofday ()
      ; sfr_workspace = T.workspace_input_identity_of_server identity
      }
    in
    state.T.schedule_form_refusal <- Some refusal;
    Masc_tui_loader.report_action state "error"
      (T.schedule_form_refusal_text ~ko refusal)
  in
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.T.port in
  match Masc_tui_editor.editor_command () with
  | None ->
      report_form_refusal
        (T.Schedule_form_editor
           (Masc_tui_editor.Editor_unavailable Masc_tui_editor.Unset))
  | Some _ -> (
      match
        Masc_tui_editor.roundtrip
          ~restore:(fun () ->
            Masc_tui_shell.Terminal_session.hand_off terminal_session)
          ~reenter:(fun () ->
            Masc_tui_shell.Terminal_session.take_back terminal_session)
          stem
      with
      | Error Masc_tui_editor.Cancelled ->
          Masc_tui_shell.Editor_notice.report_abort state ~form
            Masc_tui_editor.Cancelled
      | Error
          ((Masc_tui_editor.Editor_unavailable _
           | Masc_tui_editor.Form_unreadable _) as abort) ->
          report_form_refusal (T.Schedule_form_editor abort)
      | Ok declaration -> (
          match Yojson.Safe.from_string declaration with
          | exception Yojson.Json_error message ->
              report_form_refusal (T.Schedule_form_not_json message)
          | `Assoc _ -> (
              match
                Masc_tui_transport.Workspace_admission.admit_request
                  ~schedule_form_change:change state ~mailbox ~authority
                  ~identity ~host ~port ()
              with
              | Error refusal ->
                  report_form_refusal
                    (T.Schedule_form_request (T.Request_withdrawn refusal))
              | Ok () -> (
                  match post declaration with
                  | Error detail ->
                      report_form_refusal
                        (T.Schedule_form_request (T.Request_failed detail))
                  | Ok response -> (
                      match Masc.Tui_decode.tool_envelope_outcome response with
                      | Error detail ->
                          report_form_refusal
                            (T.Schedule_form_request (T.Request_failed detail))
                      | Ok message ->
                          Masc_tui_loader.report_action state "system"
                            (T.schedule_change_name ~ko change ^ ": " ^ message);
                          state.T.schedule_cancel_armed <- None;
                          state.T.schedule_cancel_error <- None;
                          (* Owed, as after a cancel: the [schedule_store_invalidated] this
                             write announces folds into the same read. *)
                          state.T.schedules_agenda_owed <-
                            Masc_tui_owed_read.changed
                              state.T.schedules_agenda_owed;
                          state.T.schedules_page_owed <-
                            Masc_tui_owed_read.changed
                              state.T.schedules_page_owed)))
          | _ -> report_form_refusal T.Schedule_form_not_an_object))

let handle_schedule_create (state : T.state) ~mailbox ~terminal_session =
  handle_schedule_form state ~mailbox ~terminal_session
    ~change:T.Schedule_create
    ~stem:(T.schedule_create_form_json ())
    ~post:(fun body_json ->
      Masc_tui_http.post_schedule_create_json
        ~host:Masc_tui_transport.Workspace_admission.server_peer_host
        ~port:state.T.port ~body_json)

let handle_schedule_modify (state : T.state) ~mailbox ~terminal_session =
  (* Every modify attempt retires the earlier refusal, including the ones
     refused before an editor opens; their reason goes to the footer. *)
  state.T.schedule_form_refusal <- None;
  match Masc_tui_work_actions.Board_schedule_actions.selected_schedule_row state with
  | None ->
      let ko = state.T.ui_language = T.Lang_ko in
      Masc_tui_loader.report_action state "error"
        (T.schedule_change_name ~ko T.Schedule_modify
         ^ ": "
         ^ (if ko then "커서 아래 일정 없음" else "no schedule under the cursor"))
  (* The refusal was always real; it just arrived after the operator had
     edited fifteen fields and saved. The status is on the screen before the
     key is pressed, so the answer is available here. *)
  | Some row -> (
      match T.schedule_update_form_json row with
      | Error reason ->
          let ko = state.T.ui_language = T.Lang_ko in
          Masc_tui_loader.report_action state "error"
            (T.schedule_change_name ~ko T.Schedule_modify
             ^ ": "
             ^ T.schedule_modify_refusal_text ~ko reason)
      | Ok stem ->
          handle_schedule_form state ~mailbox ~terminal_session
            ~change:T.Schedule_modify ~stem ~post:(fun body_json ->
              Masc_tui_http.post_schedule_update
                ~host:Masc_tui_transport.Workspace_admission.server_peer_host
                ~port:state.T.port ~body_json))
