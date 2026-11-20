let ( let* ) = Result.bind

type mailbox = {
  notifications :
    Masc_tui_async_protocol.async_msg Masc_tui_async_protocol.mailed Eio.Stream.t;
  workspace_results :
    Masc_tui_async_protocol.async_msg Masc_tui_workspace_result.t;
}

let server_peer_host = Masc_network_defaults.masc_http_loopback_peer

let enqueue mailbox msg =
  Masc_tui_async_protocol.mail mailbox.notifications msg

let same_server_workspace (expected : Masc.Tui_decode.server_identity)
    (actual : Masc.Tui_decode.server_identity) =
  expected.sid_state_ready <> Some false
  && actual.sid_state_ready <> Some false
  && not (Masc.Tui_decode.Canonical_path.is_empty expected.sid_base_path)
  && not (Masc.Tui_decode.Canonical_path.is_empty expected.sid_masc_root)
  && Masc.Tui_decode.Canonical_path.equal expected.sid_base_path actual.sid_base_path
  && Masc.Tui_decode.Canonical_path.equal expected.sid_masc_root actual.sid_masc_root

let read_server_identity_unscoped ~host ~port =
  Masc_tui_workspace_precondition.without (fun () ->
      Masc_tui_loader.load_server_identity ~host ~port)

let probe_expected_workspace ~host ~port expected =
  if Masc_tui_workspace_precondition.expects expected then Ok ()
  else
    let* actual = read_server_identity_unscoped ~host ~port in
    if same_server_workspace expected actual then Ok ()
    else Error "workspace changed before the action completed"

let same_workspace_identity expected current =
  match expected, current with
  | Some before, Some after -> same_server_workspace before after
  | None, _ | Some _, None -> false

let workspace_enqueue state =
  let envelope = Masc_tui_async_protocol.capture_workspace_message state in
  fun mailbox message -> enqueue mailbox (envelope message)

let deliver_code state =
  let enqueue_scoped = workspace_enqueue state in
  fun mailbox answer ->
    match Masc_tui_code_results.answer_kind answer with
    | Masc_tui_code_results.Read ->
        enqueue_scoped mailbox (Masc_tui_async_protocol.Code_msg answer)
    | Masc_tui_code_results.Save ->
        enqueue mailbox (Masc_tui_async_protocol.Code_msg answer)

let deliver_context state =
  let enqueue_scoped = workspace_enqueue state in
  fun mailbox answer ->
    match Masc_tui_context_results.answer_kind answer with
    | Masc_tui_context_results.Read ->
        enqueue_scoped mailbox (Masc_tui_async_protocol.Context_msg answer)

let deliver_fleet state =
  let enqueue_scoped = workspace_enqueue state in
  fun mailbox answer ->
    match Masc_tui_fleet_results.answer_kind answer with
    | Masc_tui_fleet_results.Read ->
        enqueue_scoped mailbox (Masc_tui_async_protocol.Fleet_msg answer)

let wrap_original answer =
  match Masc_tui_original_results.answer_kind answer with
  | Masc_tui_original_results.Read -> Masc_tui_async_protocol.Original_msg answer

let report_workspace_reading (state : Masc_tui_types.state) ~mailbox ~authority
    ~reading_authority ~prior_contact ~refresh_ticket ~refusal reading =
  if Masc_tui_types.Http_refresh_order.is_current state.http_refresh_order refresh_ticket then
    enqueue mailbox
      (Masc_tui_async_protocol.Workspace_scoped
         ( authority
         , Some reading_authority
         , Masc_tui_async_protocol.Workspace_msg
             (Masc_tui_async_protocol.Workspace_identity_unconfirmed
                { refusal; latest = reading; prior_contact; refresh_ticket }) ))

let admit_request ?schedule_form_change ?refresh_ticket
    ?(prior_contact = Masc_tui_server_lifecycle.Nothing_answered)
    (state : Masc_tui_types.state) ~mailbox ~authority ~identity ~host ~port () =
  let refresh_ticket =
    Option.value refresh_ticket ~default:state.http_refresh_order
  in
  if authority <> state.workspace_authority then
    Error Masc_tui_types.Workspace_authority_withdrawn
  else if not (Masc_tui_types.server_authority_ready state) then
    Error Masc_tui_types.Workspace_identity_not_confirmed
  else
    match identity with
    | Some expected when Masc_tui_workspace_precondition.expects expected -> Ok ()
    | Some _ | None ->
        let reading_authority = state.workspace_read_authority in
        let reading =
          Masc_tui_workspace_read.without_binding (fun () ->
              read_server_identity_unscoped ~host ~port)
        in
        if authority <> state.workspace_authority then
          Error Masc_tui_types.Workspace_authority_withdrawn
        else if
          reading_authority != state.workspace_read_authority
          || not (Masc_tui_types.server_authority_ready state)
        then Error Masc_tui_types.Workspace_identity_not_confirmed
        else if Masc_tui_types.server_workspace_matches ~expected:identity reading then
          Ok ()
        else begin
          let refusal = Masc_tui_types.Workspace_identity_changed in
          Option.iter
            (fun change ->
              enqueue mailbox
                (Masc_tui_async_protocol.Workspace_scoped
                   ( authority
                   , None
                   , Masc_tui_async_protocol.Schedule_msg
                       (Masc_tui_async_protocol.Schedule_form_authority_refused
                          { change
                          ; refusal
                          ; workspace =
                              Masc_tui_types.workspace_input_identity_of_server
                                identity
                          }) )))
            schedule_form_change;
          report_workspace_reading state ~mailbox ~authority ~reading_authority
            ~prior_contact ~refresh_ticket ~refusal reading;
          Error refusal
        end

let admission_sequence state ~mailbox ~authority ~identity ~host ~port =
  let prior_contact = ref Masc_tui_server_lifecycle.Nothing_answered in
  fun () ->
    let result =
      admit_request ~prior_contact:!prior_contact state ~mailbox ~authority
        ~identity ~host ~port ()
    in
    (match result with
     | Ok () -> prior_contact := Masc_tui_server_lifecycle.Server_reached
     | Error _ -> ());
    result

let capture_admission (state : Masc_tui_types.state) ~mailbox =
  admission_sequence state ~mailbox ~authority:state.workspace_authority
    ~identity:state.server_identity ~host:server_peer_host ~port:state.port

let in_request_scope ~kind (state : Masc_tui_types.state) ~mailbox ~authority
    ~identity ~host ~port ~withdrawn request =
  match identity with
  | None -> request ()
  | Some expected ->
      let reading_authority = state.workspace_read_authority in
      let refresh_ticket = state.http_refresh_order in
      let refusal = Masc_tui_types.Workspace_identity_changed in
      Masc_tui_workspace_precondition.run ~kind ~host ~port ~expected
        ~on_workspace_refused:(fun (_ : Masc_tui_workspace_precondition.refusal) ->
          let reading = read_server_identity_unscoped ~host ~port in
          if
            authority = state.workspace_authority
            && reading_authority == state.workspace_read_authority
            && Masc_tui_types.server_authority_ready state
          then
            report_workspace_reading state ~mailbox ~authority
              ~reading_authority
              ~prior_contact:Masc_tui_server_lifecycle.Server_reached
              ~refresh_ticket ~refusal reading)
        ~withdrawn:(fun () -> withdrawn refusal)
        request

let in_current_scope ~kind (state : Masc_tui_types.state) ~mailbox ~withdrawn =
  let authority = state.workspace_authority in
  let identity = state.server_identity in
  let host = server_peer_host and port = state.port in
  fun request ->
    in_request_scope ~kind state ~mailbox ~authority ~identity ~host ~port
      ~withdrawn request

let workspace_scope_refused_english =
  "Workspace identity changed or is unavailable; request withdrawn"

let workspace_scope_kind ~operation =
  if operation then Masc_tui_workspace_precondition.Operation
  else Masc_tui_workspace_precondition.Observation

let capture_scope_runner ~kind ?withdrawn state ~mailbox ~boundary_error =
  let on_withdrawn =
    match withdrawn with
    | Some handler -> handler
    | None ->
        fun (_ : Masc_tui_types.workspace_refusal) ->
          boundary_error workspace_scope_refused_english
  in
  in_current_scope ~kind state ~mailbox
    ~withdrawn:(fun refusal -> Error (on_withdrawn refusal))

let fork_job ?(observation = false) ?kind ?key ?on_withdrawn ?observe state
    ~mailbox ~sw run =
  let kind =
    match kind with
    | Some kind -> kind
    | None -> workspace_scope_kind ~operation:(not observation)
  in
  let in_scope =
    in_current_scope ~kind state ~mailbox
      ~withdrawn:(fun (_ : Masc_tui_types.workspace_refusal) -> ())
  in
  Masc_tui_workspace_job.fork ~observation ?key ?on_withdrawn ?observe state ~sw
    (fun () -> in_scope run)

let launch_result ?key ?(operation = false) ?(observation = false) ?cancelled
    ?cancelled_by ?observe_job ?(on_not_run = fun () -> ()) ?withdrawn state
    ~mailbox ~boundary_error ~deliver perform =
  let envelope = Masc_tui_async_protocol.capture_workspace_message state in
  let scoped message =
    envelope
      (if operation then Masc_tui_async_protocol.Workspace_operation message
       else message)
  in
  let cancelled = Option.map scoped cancelled in
  let cancelled_by = Option.map (fun message () -> scoped (message ())) cancelled_by in
  let in_scope =
    capture_scope_runner ~kind:(workspace_scope_kind ~operation) ?withdrawn state
      ~mailbox ~boundary_error
  in
  Masc_tui_workspace_result.launch ?key ~observation ?cancelled ?cancelled_by
    ?observe_job ~on_not_run state ~results:mailbox.workspace_results
    ~boundary_error ~deliver:(fun result -> scoped (deliver result))
    (fun () -> in_scope perform)

let launch_session state ~mailbox ~boundary_error ~deliver perform =
  let in_scope =
    capture_scope_runner ~kind:Masc_tui_workspace_precondition.Operation state
      ~mailbox ~boundary_error
  in
  Masc_tui_workspace_result.launch_session ~results:mailbox.workspace_results
    ~boundary_error ~deliver (fun () -> in_scope perform)

let launch_observation ?key ?observe_job ?on_not_run state ~mailbox
    ~boundary_error ~not_started ~cancelled ~progress ~deliver perform =
  let in_scope =
    capture_scope_runner ~kind:Masc_tui_workspace_precondition.Observation state
      ~mailbox ~boundary_error
  in
  Masc_tui_workspace_result.launch_observation ?key ?observe_job ?on_not_run
    state ~results:mailbox.workspace_results ~boundary_error ~not_started
    ~cancelled ~progress ~deliver (fun publish ->
      in_scope (fun () -> perform publish))

let launch_async_read ?source ?on_not_run state ~mailbox ~deliver read =
  let in_scope =
    in_current_scope ~kind:Masc_tui_workspace_precondition.Observation state
      ~mailbox ~withdrawn:(fun (_ : Masc_tui_types.workspace_refusal) ->
        Error workspace_scope_refused_english)
  in
  Masc_tui_async_read.launch ?source ?on_not_run ~deliver (fun () -> in_scope read)

let launch_async_read_with ?on_not_run ?withdrawn state ~mailbox
    ~boundary_error ~deliver read =
  let in_scope =
    capture_scope_runner ~kind:Masc_tui_workspace_precondition.Observation
      ?withdrawn state ~mailbox ~boundary_error
  in
  Masc_tui_async_read.launch_with ?on_not_run ~boundary_error ~deliver
    (fun () -> in_scope read)

let launch_async_read_pair state ~mailbox ~boundary_error ~withdrawn
    ~deliver_first ~deliver_second first second =
  launch_async_read_with state ~mailbox ~boundary_error ~withdrawn
    ~deliver:deliver_first first;
  launch_async_read_with state ~mailbox ~boundary_error ~withdrawn
    ~deliver:deliver_second second

let launch_guarded_request ?(operation = false) ?cancelled ?cancelled_by
    (state : Masc_tui_types.state) ~mailbox ~boundary_error ~withdrawn ~deliver
    read =
  let authority = state.workspace_authority in
  let identity = state.server_identity in
  let host = server_peer_host and port = state.port in
  launch_result ~operation ?cancelled ?cancelled_by ~withdrawn state ~mailbox
    ~boundary_error ~deliver (fun () ->
      match admit_request state ~mailbox ~authority ~identity ~host ~port () with
      | Error refusal -> Error (withdrawn refusal)
      | Ok () -> read ())

let capture_json_read (state : Masc_tui_types.state) read =
  let expected = state.server_identity in
  let authority = state.workspace_authority in
  let reading = state.workspace_read_authority in
  let host = server_peer_host and port = state.port in
  fun () ->
    let* expected =
      Option.to_result ~none:Masc_tui_types.Workspace_identity_not_confirmed
        expected
    in
    if authority <> state.workspace_authority then
      Error Masc_tui_types.Workspace_authority_withdrawn
    else if
      reading != state.workspace_read_authority
      || not (Masc_tui_types.server_authority_ready state)
    then Error Masc_tui_types.Workspace_identity_not_confirmed
    else if
      port <> state.port
      || not (same_workspace_identity (Some expected) state.server_identity)
    then Error Masc_tui_types.Workspace_identity_changed
    else
      Ok
        (Masc_tui_workspace_read.with_binding ~host ~port ~expected
           ~proof:Masc_tui_workspace_read.Request_precondition read)

let launch_json_read ?key ?on_not_run state ~mailbox ~boundary_error ~withdrawn
    ~deliver read =
  let read = capture_json_read state read in
  launch_result ?key ~observation:true ?on_not_run ~withdrawn state ~mailbox
    ~boundary_error ~deliver (fun () ->
      match read () with
      | Error refusal -> Error (withdrawn refusal)
      | Ok result -> result)

let attribute_request_failure source = function
  | Masc_tui_types.Request_failed detail -> (
      match Masc_tui_async_read.attribute source (Error detail) with
      | Error labelled -> Masc_tui_types.Request_failed labelled
      | Ok () -> Masc_tui_types.Request_failed detail)
  | Masc_tui_types.Request_withdrawn _ as failure -> failure

let launch_guarded_async_read ?source ?on_not_run state ~mailbox ~deliver read =
  let failed detail =
    match source with
    | None -> Masc_tui_types.Request_failed detail
    | Some source ->
        attribute_request_failure source (Masc_tui_types.Request_failed detail)
  in
  launch_async_read_with ?on_not_run state ~mailbox ~boundary_error:failed
    ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
    ~deliver (fun () ->
      match read () with
      | Error refusal -> Error (Masc_tui_types.Request_withdrawn refusal)
      | Ok result -> Result.map_error failed result)
