let ( let* ) = Result.bind

type item_revision_snapshot =
  (string
  * (string option, string) result
  * Candle_decay_basis.keeper option
  * (Masc.Tui_decode.Canonical_path.t
    * Masc.Tui_decode.Canonical_path.t
    * bool option) option) option

let catch_non_cancel ~on_error f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> on_error (Printexc.to_string exn)

let launch_keeper_deletions (state : Masc_tui_types.state) ~mailbox ?retry () =
  let enqueue_async =
    Masc_tui_transport.Workspace_admission.workspace_enqueue state
  in
  let authority = state.workspace_authority in
  let identity = state.server_identity in
  match Masc_tui_types.begin_keeper_deletions_read state with
  | None -> ()
  | Some generation -> (
      let host = Masc_tui_transport.Workspace_admission.server_peer_host
      and port = state.port in
      let run () =
        let ko = state.ui_language = Masc_tui_types.Lang_ko in
        let result =
          let failed_error detail = Error (Masc_tui_types.Request_failed detail) in
          catch_non_cancel ~on_error:failed_error (fun () ->
              (* The guard's refusal, and the moved workspace or unconfirmed
                 identity it would refuse the same way, travel as
                 [Request_withdrawn], apart from the read's own failure (RFC §2). *)
              let failed result =
                Result.map_error
                  (fun detail -> Masc_tui_types.Request_failed detail)
                  result
              in
              let check_authority () =
                if authority <> state.workspace_authority then
                  Error
                    (Masc_tui_types.Request_withdrawn
                       Masc_tui_types.Workspace_authority_withdrawn)
                else if generation <> state.keeper_deletions_generation then
                  Error
                    (Masc_tui_types.Request_failed
                       "Deletion inventory request superseded")
                else if not (Masc_tui_types.server_authority_ready state) then
                  Error
                    (Masc_tui_types.Request_withdrawn
                       Masc_tui_types.Workspace_identity_not_confirmed)
                else Ok ()
              in
              let admit () =
                Masc_tui_transport.Workspace_admission.admit_request state
                  ~mailbox ~authority ~identity ~host ~port ()
                |> Result.map_error (fun refusal ->
                       Masc_tui_types.Request_withdrawn refusal)
              in
              let* () = check_authority () in
              let* () = admit () in
              let* () =
                match retry with
                | None -> Ok ()
                | Some (row : Masc_tui_keeper_control.deletion_row) ->
                    let keeper_name =
                      Masc_tui_keeper_control.deletion_keeper_name row
                    in
                    let operation_id =
                      Masc.Keeper_shutdown_types.Operation_id.to_string
                        (Masc_tui_keeper_control.deletion_operation_id row)
                    in
                    let path =
                      match row.operation with
                      | Masc_tui_keeper_control.Runtime_shutdown _ ->
                          "/api/v1/dashboard/keepers/deletions/retry"
                      | Masc_tui_keeper_control.Configuration_removal _ ->
                          "/api/v1/dashboard/keepers/configuration-deletions/retry"
                    in
                    let* () = check_authority () in
                    let receipt =
                      catch_non_cancel ~on_error:failed_error (fun () ->
                          match identity with
                          | None ->
                              Error
                                (Masc_tui_types.Request_withdrawn
                                   Masc_tui_types.Workspace_identity_not_confirmed)
                          | Some expected_workspace ->
                              let* status, body =
                                failed
                                  (Masc_tui_http.post_keeper_deletion_retry ~host
                                     ~port ~path ~keeper_name ~operation_id
                                     ~expected_workspace)
                              in
                              failed
                                (match
                                   Masc_tui_keeper_control.classify_purge_response
                                     ~keeper_name ~status ~body
                                 with
                                 | Masc_tui_keeper_control.Purge_accepted
                                     { operation_id = returned }
                                   when String.equal returned operation_id ->
                                     Ok ()
                                 | Masc_tui_keeper_control.Rejected
                                     { detail; _ }
                                 | Masc_tui_keeper_control.Paused_owner_conflict
                                     detail
                                 | Masc_tui_keeper_control.Committed_followup_failed
                                     detail ->
                                     Error detail
                                 | Masc_tui_keeper_control.Unbound_purge_receipt
                                     { status } ->
                                     Error
                                       (Masc_tui_keeper_control.failure_text ~ko
                                          (Masc_tui_keeper_control.Unbound_receipt
                                             status))
                                 | Masc_tui_keeper_control.Accepted _
                                 | Masc_tui_keeper_control.Purge_accepted _ ->
                                     Error
                                       (if ko then
                                          "삭제 재시도 응답이 요청 ID 를 밝히지 않음"
                                        else
                                          "deletion retry response did not identify the requested operation")))
                    in
                    (* The admitted POST result has operation authority. The GET
                       below retains its separate, revocable observation stamp. *)
                    enqueue_async mailbox
                      (Masc_tui_async_protocol.Keeper_msg
                         (Masc_tui_async_protocol.Keeper_deletion_retry_done
                            (operation_id, receipt)));
                    receipt
              in
              let* () = check_authority () in
              let* json =
                failed
                  (Masc_tui_http.get_json ~host ~port
                     ~path:"/api/v1/dashboard/keepers/deletions")
              in
              let* inventory =
                failed
                  (Masc_tui_keeper_control.decode_deletion_inventory json)
              in
              let* () =
                check_authority ()
                |> Result.map_error
                     (Masc_tui_transport.Request_notice.request_failure_after_read
                        state
                        ~request:Masc_tui_words.Kept_request.Keeper_deletions_read)
              in
              let* () =
                admit ()
                |> Result.map_error
                     (Masc_tui_transport.Request_notice.request_failure_after_read
                        state
                        ~request:Masc_tui_words.Kept_request.Keeper_deletions_read)
              in
              Ok inventory)
        in
        enqueue_async mailbox
          (Masc_tui_async_protocol.Keeper_msg
             (Masc_tui_async_protocol.Keeper_deletions_loaded
                (generation, result)))
      in
      match Eio_context.get_switch_opt () with
      | Some sw ->
          Masc_tui_transport.Workspace_admission.fork_job state ~mailbox ~sw run
      | None ->
          enqueue_async mailbox
            (Masc_tui_async_protocol.Keeper_msg
               (Masc_tui_async_protocol.Keeper_deletions_loaded
                  ( generation
                  , Error
                      (Masc_tui_types.Request_failed
                         "Eio switch is unavailable") ))))

let mark_detail_read_started state ~tab ~keeper =
  Masc_tui_types.mark_detail_read_started state ~tab ~keeper
    ~now_ns:(Mtime_clock.elapsed_ns ())

let launch_keeper_config_view (state : Masc_tui_types.state) ~mailbox
    keeper_name =
  if Masc_tui_types.server_authority_ready state then begin
    let enqueue_async =
      Masc_tui_transport.Workspace_admission.workspace_enqueue state
    in
    let request =
      mark_detail_read_started state ~tab:Masc_tui_types.Detail_instructions
        ~keeper:keeper_name
    in
    let host = Masc_tui_transport.Workspace_admission.server_peer_host in
    let port = state.port in
    let ko = state.ui_language = Masc_tui_types.Lang_ko in
    Masc_tui_transport.Workspace_admission.launch_async_read state ~mailbox
      ~deliver:(fun result ->
        enqueue_async mailbox
          (Masc_tui_async_protocol.Keeper_msg
             (Masc_tui_async_protocol.Keeper_config_view_loaded
                (request, result))))
      (fun () ->
        Masc_tui_loader.load_keeper_config_view ~ko ~host ~port ~keeper_name)
  end

let withdraw_keeper_items (state : Masc_tui_types.state) =
  state.item_account <- None;
  state.item_account_error <- None;
  (* Removing the pending receipt rejects its late answer. A later read uses
     the existing monotonic detail generation, including after A -> B -> A. *)
  state.detail_reads <-
    List.filter
      (fun (request : Masc_tui_types.detail_read_request) ->
        request.drr_tab <> Masc_tui_types.Detail_items)
      state.detail_reads

let keeper_item_revision (state : Masc_tui_types.state) keeper_name =
  match
    Masc_tui_keeper_control.liveness_of_roster state.keeper_roster keeper_name
  with
  | Masc_tui_keeper_control.Present runtime ->
      runtime.Masc.Tui_decode.kr_candle_account_revision
  | Masc_tui_keeper_control.Unobserved | Masc_tui_keeper_control.Invalid _
  | Masc_tui_keeper_control.Absent ->
      Error "Keeper account revision is not observed in the current roster"

let keeper_settings_editor_available (state : Masc_tui_types.state) =
  not (Masc_tui_types.modal_owns_keys state)
  && Option.is_none
       (Masc_tui_types.text_input_target state ~compact_viewport:false)
  && not
       (state.image_open || state.msx_open || state.palette_open
      || state.answering_open || state.keeper_navigation_open
      || state.approval_detail_open || state.link_modal_open
      || state.composer_focused)

let log_keeper_settings_read ~phase
    (request : Masc_tui_types.keeper_settings_request) ~outcome =
  let key = Masc_tui_fetched.request_key request.ksr_request in
  Log.Transport.info "tui_keeper_settings_read=%s"
    (Yojson.Safe.to_string
       (`Assoc
          [ "phase", `String phase
          ; "outcome", `String outcome
          ; "keeper", `String key.Masc_tui_types.ksk_keeper
          ; "base_path", `String key.ksk_base_path
          ; "masc_root", `String key.ksk_masc_root
          ; ( "request"
            , `Intlit
                (Int64.to_string
                   (Masc_tui_fetched.request_id request.ksr_request)) )
          ; "started_ns", `Intlit (Int64.to_string request.ksr_started_ns)
          ; "observed_ns", `Intlit (Int64.to_string (Mtime_clock.elapsed_ns ()))
          ]))

let launch_keeper_settings_editor_read (state : Masc_tui_types.state) ~mailbox
    (request : Masc_tui_types.keeper_settings_request) =
  let key = Masc_tui_fetched.request_key request.ksr_request in
  let host = Masc_tui_transport.Workspace_admission.server_peer_host
  and port = state.port in
  let authority = key.Masc_tui_types.ksk_authority
  and identity = Some request.ksr_expected in
  (* The guard's refusal stays typed apart from the read's own failure, so it
     is said as kept back (RFC §2). *)
  let check =
    Masc_tui_transport.Workspace_admission.admission_sequence state ~mailbox
      ~authority ~identity ~host ~port
  in
  let check () =
    Result.map_error (fun refusal -> Masc_tui_types.Request_withdrawn refusal) (check ())
  in
  let enqueue_async =
    Masc_tui_transport.Workspace_admission.workspace_enqueue state
  in
  let deliver result =
    enqueue_async mailbox
      (Masc_tui_async_protocol.Keeper_msg
         (Masc_tui_async_protocol.Keeper_settings_editor_loaded
            (request, result)))
  in
  let superseded, resolve = Eio.Promise.create () in
  Masc_tui_types.supersede_keeper_settings_read state
    (Some
       ( request.ksr_owner
       , fun () -> ignore (Eio.Promise.try_resolve resolve ()) ));
  log_keeper_settings_read ~phase:"started" request ~outcome:"pending";
  let run () =
    Fun.protect
      ~finally:(fun () ->
        Masc_tui_types.finish_keeper_settings_worker state request)
      (fun () ->
        let result =
          try
            Eio.Fiber.first
              (fun () ->
                let* () = check () in
                let* observed, stem =
                  Masc_tui_loader.load_keeper_config_editor ~host ~port
                    ~keeper_name:key.ksk_keeper ~format:request.ksr_format
                  |> Result.map_error (fun detail ->
                         Masc_tui_types.Request_failed detail)
                in
                let* () =
                  check ()
                  |> Result.map_error
                       (Masc_tui_transport.Request_notice.request_failure_after_read
                          state
                          ~request:
                            Masc_tui_words.Kept_request.Keeper_settings_read)
                in
                Ok
                  { Masc_tui_types.kss_observed = observed; kss_stem = stem })
              (fun () ->
                Eio.Promise.await superseded;
                log_keeper_settings_read ~phase:"superseded" request
                  ~outcome:"cancel_requested";
                Error
                  (Masc_tui_types.Request_failed
                     "Settings editor preparation cancelled"))
          with
          | Eio.Cancel.Cancelled _ as exn ->
              log_keeper_settings_read ~phase:"cancelled" request
                ~outcome:"cancelled";
              raise exn
          | exn ->
              Error (Masc_tui_types.Request_failed (Printexc.to_string exn))
        in
        log_keeper_settings_read ~phase:"read_completed" request
          ~outcome:(match result with Ok _ -> "received" | Error _ -> "unconfirmed");
        Masc_tui_types.finish_keeper_settings_worker state request;
        deliver result)
  in
  match Eio_context.get_switch_opt () with
  | None ->
      Masc_tui_types.finish_keeper_settings_worker state request;
      deliver
        (Error
           (Masc_tui_types.Request_failed
              "Eio switch is unavailable for settings editor preparation"))
  | Some sw -> (
      try
        Masc_tui_transport.Workspace_admission.fork_job ~observation:true state
          ~mailbox ~sw run
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          Masc_tui_types.finish_keeper_settings_worker state request;
          deliver (Error (Masc_tui_types.Request_failed (Printexc.to_string exn))))

let launch_keeper_items ?(keep_observed_account = false)
    (state : Masc_tui_types.state) ~mailbox keeper_name =
  if Masc_tui_types.server_authority_ready state then begin
    let observed_account =
      match state.item_account with
      | Some (name, _) as account
        when keep_observed_account && String.equal name keeper_name ->
          account
      | Some _ | None -> None
    in
    withdraw_keeper_items state;
    match state.workspace_identity, state.server_identity with
    | ( ( Masc_tui_types.Workspace_identity_unread
        | Masc_tui_types.Workspace_identity_match_unconfirmed _
        | Masc_tui_types.Workspace_identity_mismatch _ )
      , _ )
    | Masc_tui_types.Workspace_identity_match, None ->
        state.item_account_error <-
          Some
            "Server workspace identity is unavailable or differs from the local workspace"
    | Masc_tui_types.Workspace_identity_match, Some _
      when not (Masc_tui_types.server_authority_ready state) ->
        state.item_account_error <-
          Some
            "Server workspace identity is unavailable or differs from the local workspace"
    | Masc_tui_types.Workspace_identity_match, Some _
      when Masc_tui_keeper_control.roster_view state.keeper_roster
           = Masc_tui_keeper_control.Roster_unobserved ->
        state.item_account_error <-
          Some "Keeper roster authority is unavailable"
    | Masc_tui_types.Workspace_identity_match, Some identity -> (
        (* The read-state Item endpoint owns account authority. Public roster
           currency observations require CanAdmin and may legitimately be absent;
           the roster itself must have been successfully observed before this read.
           A partial roster's silence is not absence: past the cap the roster says
           nothing about a locally known Keeper, and [Unobserved] is exactly that
           silence -- the authoritative read proceeds and the endpoint itself
           answers for a Keeper that is truly gone. A complete roster's [Absent]
           and this Keeper's own decode failure remain refusals. *)
        match
          Masc_tui_keeper_control.liveness_of_roster state.keeper_roster
            keeper_name
        with
        | Masc_tui_keeper_control.Invalid _ | Masc_tui_keeper_control.Absent ->
            state.item_account_error <-
              Some "Keeper is not observed in the current roster"
        | Masc_tui_keeper_control.Present _
        | Masc_tui_keeper_control.Unobserved ->
            (* A cadence read under unchanged authority refreshes an observed account
               without blanking it while the request is pending. Refusals above and a
               failed endpoint response still withdraw it. *)
            state.item_account <- observed_account;
            let enqueue_async =
              Masc_tui_transport.Workspace_admission.workspace_enqueue state
            in
            let request =
              mark_detail_read_started state ~tab:Masc_tui_types.Detail_items
                ~keeper:keeper_name
            in
            let host = Masc_tui_transport.Workspace_admission.server_peer_host in
            let port = state.port in
            Masc_tui_transport.Workspace_admission.launch_async_read state
              ~mailbox
              ~deliver:(fun result ->
                enqueue_async mailbox
                  (Masc_tui_async_protocol.Keeper_msg
                     (Masc_tui_async_protocol.Keeper_items_loaded
                        (request, result))))
              (fun () ->
                let path =
                  "/api/v1/keepers/"
                  ^ Masc_tui_http.percent_encode_path_segment keeper_name
                  ^ "/items?expected_workspace="
                  ^ Masc_tui_http.percent_encode_query_value
                      (Masc.Tui_decode.Canonical_path.to_string
                         identity.Masc.Tui_decode.sid_base_path)
                in
                let* json = Masc_tui_http.get_json ~host ~port ~path in
                Masc_tui_keeper_items.decode ~keeper_name json))
  end

let visible_item_revision (state : Masc_tui_types.state) :
    item_revision_snapshot =
  match
    state.view, state.detail_tab, Masc_tui_types.selected_keeper state
  with
  | ( Masc_tui_types.Keepers Masc_tui_types.Keeper_detail
    , Masc_tui_types.Detail_items
    , Some (keeper : Masc.Tui_decode.keeper) ) ->
      (* The Keeper's last balance event, not its balance: the balance falls
         with time, and only a ledger change moves the Items account. *)
      let balance =
        Masc_tui_candle.keeper_basis state.candle_observation
          ~keeper:keeper.k_name
      in
      Some
        ( keeper.k_name
        , keeper_item_revision state keeper.k_name
        , balance
        , Option.map
            (fun (identity : Masc.Tui_decode.server_identity) ->
              ( identity.sid_base_path
              , identity.sid_masc_root
              , identity.sid_state_ready ))
            state.server_identity )
  | Masc_tui_types.Keepers Masc_tui_types.Keeper_detail, Masc_tui_types.Detail_items, None
  | ( Masc_tui_types.Keepers Masc_tui_types.Keeper_detail
    , Masc_tui_types.(
        ( Detail_info | Detail_sandbox | Detail_instructions | Detail_secrets
        | Detail_github | Detail_identity | Detail_channels | Detail_automation
        | Detail_runs | Detail_terminal ))
    , _ )
  | ( Masc_tui_types.Keepers
        Masc_tui_types.(
          ( Keeper_list | Keeper_logs | Keeper_calls | Keeper_message
          | Keeper_runtime_pick ))
    , _
    , _ )
  | ( Masc_tui_types.(
        ( Overview | Acting | Metrics | Memory | Lanes | Clients | Board
        | Approvals | Planning | Schedules | Verification | Harness | Fusion
        | Repositories | Code | Changes | Connectors | Runtime | Config
        | Resources | Tools | System_logs ))
    , _
    , _ ) ->
      None

let refresh_changed_keeper_items (state : Masc_tui_types.state) ~mailbox
    ~roster_refreshed (previous : item_revision_snapshot) =
  let current = visible_item_revision state in
  (* A capped roster can stop reporting this Keeper's public revision without
     changing the authority of its private account or pending Item read. *)
  let partial_same_authority =
    match previous, current with
    | ( Some (previous_keeper, _, _, previous_workspace)
      , Some (keeper, _, _, workspace) ) ->
        roster_refreshed && String.equal previous_keeper keeper
        && previous_workspace = workspace
        && Masc_tui_keeper_control.liveness_of_roster state.keeper_roster keeper
           = Masc_tui_keeper_control.Unobserved
    | None, _ | _, None -> false
  in
  let revision_changed = current <> previous && not partial_same_authority in
  let read_pending =
    List.exists
      (fun (request : Masc_tui_types.detail_read_request) ->
        request.drr_tab = Masc_tui_types.Detail_items)
      state.detail_reads
  in
  let retry_settled_failure =
    Option.is_some state.item_account_error && not read_pending
  in
  if
    revision_changed || retry_settled_failure
    || (roster_refreshed && not read_pending)
  then
    match current with
    | Some (keeper_name, _, _, _) ->
        launch_keeper_items ~keep_observed_account:(not revision_changed) state
          ~mailbox keeper_name
    | None -> ()

let launch_keeper_sandbox_view (state : Masc_tui_types.state) ~mailbox
    keeper_name =
  if Masc_tui_types.server_authority_ready state then begin
    let enqueue_async =
      Masc_tui_transport.Workspace_admission.workspace_enqueue state
    in
    let request =
      mark_detail_read_started state ~tab:Masc_tui_types.Detail_sandbox
        ~keeper:keeper_name
    in
    let host = Masc_tui_transport.Workspace_admission.server_peer_host in
    let port = state.port in
    state.keeper_sandbox_view <-
      Some (keeper_name, Masc_tui_keeper_sandbox.empty_partial);
    let kept_back refusal =
      Masc_tui_keeper_sandbox.Lookup_kept_back
        (Masc_tui_types.workspace_refusal_text
           ~ko:(state.ui_language = Masc_tui_types.Lang_ko)
           ~request:Masc_tui_words.Kept_request.Sandbox_read refusal)
    in
    let guarded read =
      let read =
        Masc_tui_transport.Workspace_admission.capture_json_read state read
      in
      fun () ->
        match read () with
        | Ok result ->
            Result.map_error
              (fun detail -> Masc_tui_keeper_sandbox.Lookup_failed detail)
              result
        | Error refusal -> Error (kept_back refusal)
    in
    let inventory =
      guarded (fun () ->
          Masc_tui_loader.load_keeper_sandbox_view ~host ~port ~keeper_name)
    in
    let name =
      guarded (fun () ->
          Masc_tui_loader.load_keeper_sandbox_name ~host ~port ~keeper_name)
    in
    Masc_tui_transport.Workspace_admission.launch_async_read_pair state ~mailbox
      ~boundary_error:(fun cause -> Masc_tui_keeper_sandbox.Lookup_failed cause)
      ~withdrawn:kept_back
      ~deliver_first:(fun result ->
        enqueue_async mailbox
          (Masc_tui_async_protocol.Keeper_msg
             (Masc_tui_async_protocol.Keeper_sandbox_view_loaded
                (request, Masc_tui_keeper_sandbox.Inventory_result result))))
      ~deliver_second:(fun result ->
        enqueue_async mailbox
          (Masc_tui_async_protocol.Keeper_msg
             (Masc_tui_async_protocol.Keeper_sandbox_view_loaded
                (request, Masc_tui_keeper_sandbox.Name_result result))))
      inventory name
  end

let launch_keeper_sandbox_logs (state : Masc_tui_types.state) ~mailbox
    keeper_name =
  Masc_tui_types.retain_sandbox_log_read state ~keeper_name;
  if Masc_tui_types.server_authority_ready state then begin
    let enqueue_async =
      Masc_tui_transport.Workspace_admission.workspace_enqueue state
    in
    let host = Masc_tui_transport.Workspace_admission.server_peer_host in
    let port = state.port in
    state.keeper_sandbox_logs_generation <-
      state.keeper_sandbox_logs_generation + 1;
    let generation = state.keeper_sandbox_logs_generation in
    state.keeper_sandbox_logs_inflight <-
      Some
        { Masc_tui_types.slr_keeper = keeper_name
        ; slr_generation = generation
        ; slr_started_ns = Mtime_clock.elapsed_ns ()
        };
    let run () =
      let result =
        catch_non_cancel ~on_error:Result.error (fun () ->
            Masc_tui_loader.load_keeper_sandbox_logs ~host ~port ~keeper_name
              ~tail:200)
      in
      enqueue_async mailbox
        (Masc_tui_async_protocol.Keeper_msg
           (Masc_tui_async_protocol.Keeper_sandbox_logs_loaded
              (keeper_name, generation, result)))
    in
    match Eio_context.get_switch_opt () with
    | Some sw ->
        Eio.Fiber.fork_daemon ~sw (fun () ->
            run ();
            `Stop_daemon)
    | None ->
        enqueue_async mailbox
          (Masc_tui_async_protocol.Keeper_msg
             (Masc_tui_async_protocol.Keeper_sandbox_logs_loaded
                (keeper_name, generation, Error "Eio switch is unavailable")))
  end

(* The Info tab's Board-attention rows. [start] answers [Already_loading] for a
   read already in flight for this Keeper, so the tab asks once per visit; a
   read for a Keeper already on screen keeps its rows up while it runs. *)
let launch_keeper_board_quarantines (state : Masc_tui_types.state) ~mailbox
    keeper_name =
  if Masc_tui_types.server_authority_ready state then begin
    let enqueue_async =
      Masc_tui_transport.Workspace_admission.workspace_enqueue state
    in
    match
      Masc_tui_fetched.start ~equal:String.equal state.keeper_board_quarantines
        ~key:keeper_name
    with
    | Masc_tui_fetched.Already_loading -> ()
    | Masc_tui_fetched.Started (next, request) -> (
        state.keeper_board_quarantines <- next;
        let host = Masc_tui_transport.Workspace_admission.server_peer_host in
        let port = state.port in
        let run () =
          let result =
            catch_non_cancel ~on_error:Result.error (fun () ->
                Masc_tui_loader.load_keeper_board_quarantines ~host ~port
                  ~keeper_name)
          in
          enqueue_async mailbox
            (Masc_tui_async_protocol.Keeper_msg
               (Masc_tui_async_protocol.Keeper_board_quarantines_loaded
                  (request, result)))
        in
        match Eio_context.get_switch_opt () with
        | Some sw ->
            Eio.Fiber.fork_daemon ~sw (fun () ->
                run ();
                `Stop_daemon)
        | None ->
            enqueue_async mailbox
              (Masc_tui_async_protocol.Keeper_msg
                 (Masc_tui_async_protocol.Keeper_board_quarantines_loaded
                    (request, Error "Eio switch is unavailable"))))
  end

(* The Info tab's month of efficiency. One answer holds every Keeper of the
   month, so [start] is keyed by the month: moving between Keepers while the
   month is being read asks nothing more, and the answer serves each of them.
   The first read of a month is slow on the server, hence its own timeout. *)
let launch_keeper_efficiency (state : Masc_tui_types.state) ~mailbox =
  if Masc_tui_types.server_authority_ready state then
    let month = Masc_tui_keeper_efficiency.month_of ~now:(Unix.gettimeofday ()) in
    match
      Masc_tui_fetched.start ~equal:String.equal state.keeper_efficiency
        ~key:month
    with
    | Masc_tui_fetched.Already_loading -> ()
    | Masc_tui_fetched.Started (next, request) ->
        state.keeper_efficiency <- next;
        let host = Masc_tui_transport.Workspace_admission.server_peer_host
        and port = state.port in
        Masc_tui_transport.Workspace_admission.launch_json_read state ~mailbox
          ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
          ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
          ~deliver:(fun result ->
            Masc_tui_async_protocol.Keeper_msg
              (Masc_tui_async_protocol.Keeper_efficiency_loaded (request, result)))
          (fun () ->
            Result.map_error
              (fun detail -> Masc_tui_types.Request_failed detail)
            @@
            let* json =
              Masc_tui_http.get_json_decoded
                ~timeout_sec:(Some Masc_tui_keeper_efficiency.timeout_sec)
                ~decode:Masc_tui_http.decode_json ~host ~port
                ~path:(Masc_tui_keeper_efficiency.path ~month)
            in
            Masc_tui_keeper_efficiency.decode json)

(* How many rows of a requeue batch the workspace guard did not send, after
   the batch's other counts; nothing when it sent them all. *)
let board_requeue_kept_back_count ~ko kept_back =
  if kept_back = 0 then ""
  else Printf.sprintf ", %d %s" kept_back (Masc_tui_words.not_sent ~ko)

(* Q acknowledges the oldest partition through its exact quarantine CAS. *)
let launch_board_quarantine_requeue (state : Masc_tui_types.state) ~mailbox
    ~keeper_name
    (item : Masc.Keeper_board_attention_quarantine_command.inventory_item) =
  let enqueue_async =
    Masc_tui_transport.Workspace_admission.workspace_enqueue state
  in
  let authority = state.workspace_authority in
  let partition_id = item.partition_id in
  state.board_quarantine_requeue_inflight <- Some partition_id;
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.port in
  let request = Masc_tui_board_quarantine.requeue_request item in
  let run () =
    let outcome =
      catch_non_cancel
        ~on_error:(fun detail -> Ok (Masc_tui_http.Post_unanswered detail))
        (fun () ->
          match Masc_tui_types.write_authority_refusal state authority with
          | Some refusal -> Error refusal
          | None ->
              Ok
                (Masc_tui_http.post_board_quarantine_requeue ~host ~port
                   ~keeper_name ~partition_id ~request))
    in
    enqueue_async mailbox
      (Masc_tui_async_protocol.Board_msg
         (Masc_tui_async_protocol.Board_quarantine_requeued
            (keeper_name, partition_id, outcome)))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Masc_tui_transport.Workspace_admission.fork_job state ~mailbox ~sw run
  | None ->
      enqueue_async mailbox
        (Masc_tui_async_protocol.Board_msg
           (Masc_tui_async_protocol.Board_quarantine_requeued
              ( keeper_name
              , partition_id
              , Ok (Masc_tui_http.Post_unanswered "Eio switch is unavailable") )))

(* B is one operator action over the inventory snapshot, with a separate
   authenticated CAS command and audit row per candidate. Partial outcomes
   remain visible: a stale or unanswered request does not silently count as
   recovered, and later candidates are still attempted. *)
let launch_board_quarantines_bulk_requeue (state : Masc_tui_types.state) ~mailbox
    ~keeper_name items =
  let enqueue_async =
    Masc_tui_transport.Workspace_admission.workspace_enqueue state
  in
  let authority = state.workspace_authority in
  Masc_tui_loader.report_action state "system"
    (Printf.sprintf "Board requeue %s: 0/%d attempted"
       (Masc.Tui_terminal_text.sanitize_terminal_text keeper_name)
       (List.length items));
  state.board_quarantine_requeue_inflight <-
    Some (Printf.sprintf "batch of %d partitions" (List.length items));
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.port in
  let run () =
    let outcomes =
      Masc_tui_board_quarantine.requeue_all
        ~send:(fun ~partition_id ~request ->
          catch_non_cancel
            ~on_error:(fun detail -> Ok (Masc_tui_http.Post_unanswered detail))
            (fun () ->
              match Masc_tui_types.write_authority_refusal state authority with
              | Some refusal -> Error refusal
              | None ->
                  Ok
                    (Masc_tui_http.post_board_quarantine_requeue ~host ~port
                       ~keeper_name ~partition_id ~request)))
        ~classify:(function
          | Ok (Masc_tui_http.Post_answered _) ->
              Masc_tui_board_quarantine.Accepted
          | Ok (Masc_tui_http.Post_refused _) ->
              Masc_tui_board_quarantine.Refused
          | Ok (Masc_tui_http.Post_unanswered _) ->
              Masc_tui_board_quarantine.Uncertain
          | Error _ -> Masc_tui_board_quarantine.Kept_back)
        ~progress:(fun (counts : Masc_tui_board_quarantine.batch_counts) ->
          enqueue_async mailbox
            (Masc_tui_async_protocol.Board_msg
               (Masc_tui_async_protocol.Board_quarantines_bulk_progress
                  (keeper_name, counts))))
        items
    in
    enqueue_async mailbox
      (Masc_tui_async_protocol.Board_msg
         (Masc_tui_async_protocol.Board_quarantines_bulk_requeued
            (keeper_name, outcomes)))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Masc_tui_transport.Workspace_admission.fork_job state ~mailbox ~sw run
  | None ->
      enqueue_async mailbox
        (Masc_tui_async_protocol.Board_msg
           (Masc_tui_async_protocol.Board_quarantines_bulk_requeued
              ( keeper_name
              , List.map
                  (fun (item :
                         Masc.Keeper_board_attention_quarantine_command.inventory_item) ->
                    ( item.partition_id
                    , Ok
                        (Masc_tui_http.Post_unanswered
                           "Eio switch is unavailable") ))
                  items )))
