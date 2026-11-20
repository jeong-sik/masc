module T = Masc_tui_types
module Connectors = Masc.Tui_decode_connectors
module Kept_request = Masc_tui_words.Kept_request
module Terminal_text = Masc_tui_ansi.Terminal_text

(* Connector bind/unbind: the highlighted transport owns the route. The
   form edits only the route body, so its visible selection and mutation
   target cannot disagree. *)
let handle_connector_form ?fixed_channel_id ~change ~connector
    ~required_fields ~stem ~post (state : T.state) ~mailbox ~terminal_session =
  let form = Masc_tui_shell.Editor_notice.Connector_form change in
  (* The form's other notices are still English; they move with the
     connector screen's own sentences. *)
  let action = Masc_tui_shell.Editor_notice.form_name ~ko:false form in
  let authority = state.T.workspace_authority in
  let identity = state.T.server_identity in
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.T.port in
  match Masc_tui_editor.editor_command () with
  | None -> Masc_tui_shell.Editor_notice.report_unset state ~form
  | Some _ -> (
      match
        Masc_tui_editor.roundtrip
          ~restore:(fun () ->
            Masc_tui_shell.Terminal_session.hand_off terminal_session)
          ~reenter:(fun () ->
            Masc_tui_shell.Terminal_session.take_back terminal_session)
          stem
      with
      | Error abort -> Masc_tui_shell.Editor_notice.report_abort state ~form abort
      | Ok body -> (
          match Yojson.Safe.from_string body with
          | exception Yojson.Json_error e ->
              Masc_tui_loader.report_action state "error"
                (action ^ ": body is not JSON: " ^ e)
          | json -> (
              let field key =
                match json with
                | `Assoc fields -> (
                    match List.assoc_opt key fields with
                    | Some (`String value) when String.trim value <> "" ->
                        Some (String.trim value)
                    | Some _ | None -> None)
                | _ -> None
              in
              match
                List.find_opt
                  (fun key -> Option.is_none (field key))
                  required_fields
              with
              | Some key ->
                  Masc_tui_loader.report_action state "error"
                    (Printf.sprintf "%s: %S is required" action key)
              | None -> (
                  match fixed_channel_id with
                  | Some expected when field "channel_id" <> Some expected ->
                      Masc_tui_loader.report_action state "error"
                        (action ^ ": channel_id must remain the selected binding")
                  | Some _ | None -> (
                      match
                        Masc_tui_transport.Workspace_admission.admit_request
                          state ~mailbox ~authority ~identity ~host ~port ()
                      with
                      | Error refusal ->
                          (* Not sent: the kept-back notice, never the route's
                             own answer (RFC §2). *)
                          let request =
                            match change with
                            | Masc_tui_shell.Editor_notice.Channel_bind ->
                                Kept_request.Connector_bind
                            | Masc_tui_shell.Editor_notice.Channel_unbind ->
                                Kept_request.Connector_unbind
                            | Masc_tui_shell.Editor_notice.Channel_binding_edit ->
                                Kept_request.Connector_binding_edit
                          in
                          Masc_tui_transport.Request_notice.report_withdrawn
                            state ~request refusal
                      | Ok () -> (
                          match post ~connector ~json with
                          | Ok _ ->
                              state.T.connector_unbind_armed <- None;
                              Masc_tui_loader.report_action state "system"
                                (action ^ ": ok (" ^ connector ^ ")");
                              Masc_tui_surface_requests
                              .Connector_volume_requests
                              .reload_connectors_after_write state ~mailbox
                          | Error detail ->
                              Masc_tui_loader.report_action state "error"
                                (action ^ ": " ^ detail)))))))

let selected_connector (state : T.state) =
  Option.bind state.T.connectors (fun (snapshot : Connectors.connector_snapshot) ->
      List.nth_opt snapshot.Connectors.cs_connectors state.T.connectors_cursor)

let selected_connector_binding (state : T.state)
    (connector : Connectors.connector) =
  List.nth_opt connector.Connectors.cn_bindings state.T.connectors_binding_cursor

let handle_connector_bind (state : T.state) ~mailbox ~terminal_session =
  state.T.connector_unbind_armed <- None;
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.T.port in
  let keeper_name =
    match state.T.view, T.selected_keeper state with
    | T.Keepers T.Keeper_detail, Some (keeper : Masc.Tui_decode.keeper) ->
        keeper.Masc.Tui_decode.k_name
    | (T.Overview, _) | (T.Acting, _) | (T.Metrics, _)
    | (T.Keepers (T.Keeper_list | T.Keeper_detail | T.Keeper_logs | T.Keeper_calls
                | T.Keeper_message | T.Keeper_runtime_pick), _)
    | (T.Memory, _) | (T.Lanes, _)
    | (T.Clients, _) | (T.Board, _) | (T.Approvals, _) | (T.Planning, _) | (T.Schedules, _)
    | (T.Verification, _) | (T.Harness, _) | (T.Fusion, _) | (T.Repositories, _) | (T.Code, _)
    | (T.Changes, _) | (T.Connectors, _) | (T.Runtime, _) | (T.Config, _) | (T.Resources, _)
    | (T.Tools, _) | (T.System_logs, _) -> ""
  in
  match selected_connector state with
  | None ->
      Masc_tui_loader.report_action state "error"
        "bind: select a transport first"
  | Some selected ->
      handle_connector_form
        ~change:Masc_tui_shell.Editor_notice.Channel_bind
        ~connector:selected.Connectors.cn_id
        ~required_fields:[ "channel_id"; "keeper_name" ]
        ~stem:
          (Yojson.Safe.pretty_to_string
             (`Assoc
               [ "channel_id", `String ""
               ; "keeper_name", `String keeper_name
               ])
           ^ "\n")
        ~post:(fun ~connector ~json ->
          Masc_tui_http.post_connector_bind ~host ~port ~connector
            ~body_json:(Yojson.Safe.to_string json))
        state ~mailbox ~terminal_session

let handle_connector_unbind (state : T.state) ~mailbox ~terminal_session =
  let authority = state.T.workspace_authority in
  let identity = state.T.server_identity in
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.T.port in
  match selected_connector state with
  | None ->
      Masc_tui_loader.report_action state "error"
        "unbind: select a transport first"
  | Some selected ->
      let submit channel_id =
        handle_connector_form
          ~change:Masc_tui_shell.Editor_notice.Channel_unbind
          ~connector:selected.Connectors.cn_id
          ~required_fields:[ "channel_id" ]
          ~stem:
            (Yojson.Safe.pretty_to_string
               (`Assoc [ "channel_id", `String channel_id ])
             ^ "\n")
          ~post:(fun ~connector ~json ->
            Masc_tui_http.post_connector_unbind ~host ~port ~connector
              ~body_json:(Yojson.Safe.to_string json))
          state ~mailbox ~terminal_session
      in
      (match state.T.view with
       | T.Keepers T.Keeper_detail -> (
           match selected_connector_binding state selected with
           | None ->
               Masc_tui_loader.report_action state "error"
                 "unbind: select a binding with J/K"
           | Some binding ->
               let exact =
                 ( selected.Connectors.cn_id
                 , binding.Connectors.cb_channel_id
                 , binding.Connectors.cb_keeper_name )
               in
               (* The footer sentences this label goes into are English. *)
               let label =
                 Masc_tui_connector_unbind.channel_label ~ko:false
                   ~channel_id:binding.Connectors.cb_channel_id
                   ~channel_name:binding.Connectors.cb_channel_name
               in
               if state.T.connector_unbind_armed = Some exact then begin
                 state.T.connector_unbind_armed <- None;
                 match
                   Masc_tui_transport.Workspace_admission.admit_request state
                     ~mailbox ~authority ~identity ~host ~port ()
                 with
                 | Error refusal ->
                     Masc_tui_transport.Request_notice.report_withdrawn state
                       ~request:Kept_request.Connector_unbind refusal
                 | Ok () -> (
                     match
                       Masc_tui_http.post_connector_unbind ~host ~port
                         ~connector:selected.Connectors.cn_id
                         ~body_json:
                           (Yojson.Safe.to_string
                              (`Assoc
                                [ "channel_id", `String binding.Connectors.cb_channel_id
                                ; "keeper_name", `String binding.Connectors.cb_keeper_name
                                ]))
                     with
                     | Ok _ ->
                         Masc_tui_loader.report_action state "system"
                           ("unbind: removed " ^ label);
                         Masc_tui_surface_requests.Connector_volume_requests
                         .reload_connectors_after_write state ~mailbox
                     | Error detail ->
                         Masc_tui_loader.report_action state "error"
                           ("unbind: " ^ detail))
               end else begin
                 state.T.connector_unbind_armed <- Some exact;
                 Masc_tui_loader.report_action state "system"
                   (Printf.sprintf
                      "unbind armed: press u again to remove %s → %s"
                      label binding.Connectors.cb_keeper_name)
               end)
       | T.Keepers (T.Keeper_list | (T.Keeper_logs | (T.Keeper_calls | (T.Keeper_message | T.Keeper_runtime_pick))))
       | T.Overview | T.Acting | T.Metrics | T.Memory | T.Lanes | T.Clients | T.Board
       | T.Approvals | T.Planning | T.Schedules | T.Verification | T.Harness | T.Fusion
       | T.Repositories | T.Code | T.Changes | T.Connectors | T.Runtime | T.Config
       | T.Resources | T.Tools | T.System_logs -> submit "")

(* [U] twice: every binding the selected Keeper holds, on every transport.
   The first press arms, and the Channels tab names each channel while the
   arm stands; the second sends exactly those, each
   conditional on the Keeper still owning it. A snapshot that changed in
   between re-arms with the new list instead of sending a list the operator
   never read. *)
let handle_connector_unbind_all (state : T.state) ~mailbox =
  state.T.connector_unbind_armed <- None;
  (* The selected Keeper decides, and a second press confirms only an arm
     for that same Keeper. *)
  let keeper_name =
    Option.map
      (fun (keeper : Masc.Tui_decode.keeper) -> keeper.Masc.Tui_decode.k_name)
      (T.selected_keeper state)
  in
  match keeper_name, state.T.connectors with
  | None, (Some _ | None) ->
      state.T.connector_unbind_all_armed <- None;
      Masc_tui_loader.report_action state "error"
        "unbind all: select a Keeper first"
  | Some _, None ->
      state.T.connector_unbind_all_armed <- None;
      Masc_tui_loader.report_action state "error"
        "unbind all: channel transports have not been read yet"
  | Some keeper_name, Some snapshot -> (
      let targets =
        Masc_tui_connector_unbind.targets ~keeper_name
          snapshot.Connectors.cs_connectors
      in
      let unreadable =
        Masc_tui_connector_unbind.unreadable_transports
          snapshot.Connectors.cs_connectors
      in
      match
        Masc_tui_connector_unbind.next_press
          ~named:state.T.connector_unbind_all_armed ~keeper_name targets
      with
      | Masc_tui_connector_unbind.Nothing_bound ->
          state.T.connector_unbind_all_armed <- None;
          Masc_tui_loader.report_action state "system"
            (Masc_tui_connector_unbind.nothing_to_unbind ~keeper_name
               ~unreadable)
      | Masc_tui_connector_unbind.Sends targets ->
          state.T.connector_unbind_all_armed <- None;
          Masc_tui_surface_requests.Connector_volume_requests
          .launch_connector_unbind_all state ~mailbox ~keeper_name targets
      | Masc_tui_connector_unbind.Asks targets ->
          state.T.connector_unbind_all_armed <- Some (keeper_name, targets);
          Masc_tui_loader.report_action state "system"
            (Masc_tui_connector_unbind.arm_prompt ~keeper_name
               ~confirm_key:Masc_tui_connector_unbind.unbind_all_key
               ~unreadable targets))

(* The pause offer's one key. It sends only what the offer named, for the
   Keeper it named: a roster refresh can move the selection, and a
   snapshot read since can hold other bindings. A changed list is offered
   again rather than sent unread. *)
let handle_connector_unbind_offer_accept (state : T.state) ~mailbox
    (offer : Masc_tui_connector_unbind.offer) =
  state.T.connector_unbind_offer <- None;
  state.T.connector_unbind_armed <- None;
  state.T.connector_unbind_all_armed <- None;
  let keeper_name = offer.Masc_tui_connector_unbind.offer_keeper in
  let still_selected =
    match T.selected_keeper state with
    | Some (keeper : Masc.Tui_decode.keeper) ->
        String.equal keeper.Masc.Tui_decode.k_name keeper_name
    | None -> false
  in
  match still_selected, state.T.connectors with
  | false, (Some _ | None) ->
      Masc_tui_loader.report_action state "error"
        (Printf.sprintf
           "unbind all: %s is no longer the selected Keeper; nothing removed"
           (Terminal_text.single_line keeper_name))
  | true, None ->
      Masc_tui_loader.report_action state "error"
        "unbind all: channel transports have not been read yet"
  | true, Some snapshot -> (
      let targets =
        Masc_tui_connector_unbind.targets ~keeper_name
          snapshot.Connectors.cs_connectors
      in
      let unreadable =
        Masc_tui_connector_unbind.unreadable_transports
          snapshot.Connectors.cs_connectors
      in
      match
        Masc_tui_connector_unbind.next_press
          ~named:
            (Some
               ( offer.Masc_tui_connector_unbind.offer_keeper
               , offer.Masc_tui_connector_unbind.offer_targets ))
          ~keeper_name targets
      with
      | Masc_tui_connector_unbind.Nothing_bound ->
          Masc_tui_loader.report_action state "system"
            (Masc_tui_connector_unbind.nothing_to_unbind ~keeper_name
               ~unreadable)
      | Masc_tui_connector_unbind.Sends targets ->
          Masc_tui_surface_requests.Connector_volume_requests
          .launch_connector_unbind_all state ~mailbox ~keeper_name targets
      | Masc_tui_connector_unbind.Asks targets ->
          state.T.connector_unbind_offer <-
            Some
              { offer with
                Masc_tui_connector_unbind.offer_targets = targets
              ; offered_at = state.T.frames_presented
              };
          Masc_tui_loader.report_action state "system"
            (Masc_tui_connector_unbind.offer_prompt ~keeper_name ~unreadable
               targets))

let handle_connector_edit (state : T.state) ~mailbox ~terminal_session =
  state.T.connector_unbind_armed <- None;
  match selected_connector state, T.selected_keeper state with
  | None, (Some _ | None) ->
      Masc_tui_loader.report_action state "error"
        "edit: select a transport first"
  | Some _, None ->
      Masc_tui_loader.report_action state "error"
        "edit: select a Keeper first"
  | Some connector, Some (keeper : Masc.Tui_decode.keeper) -> (
      match selected_connector_binding state connector with
      | None ->
          Masc_tui_loader.report_action state "error"
            "edit: select a binding with J/K"
      | Some binding ->
          handle_connector_form
            ~fixed_channel_id:binding.Connectors.cb_channel_id
            ~change:Masc_tui_shell.Editor_notice.Channel_binding_edit
            ~connector:connector.Connectors.cn_id
            ~required_fields:[ "channel_id"; "keeper_name" ]
            ~stem:
              (Yojson.Safe.pretty_to_string
                 (`Assoc
                   [ "channel_id", `String binding.Connectors.cb_channel_id
                   ; "keeper_name", `String keeper.Masc.Tui_decode.k_name
                   ])
               ^ "\n")
            ~post:(fun ~connector ~json ->
              Masc_tui_http.post_connector_bind
                ~host:Masc_tui_transport.Workspace_admission.server_peer_host
                ~port:state.T.port ~connector
                ~body_json:(Yojson.Safe.to_string json))
            state ~mailbox ~terminal_session)
