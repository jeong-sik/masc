module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Approval = Masc_tui_operator_projection
module Ask = Masc_tui_ask_projection
module Kept_request = Masc_tui_words.Kept_request

let settle_pending_confirms_read (state : T.state) = function
  | Ok _ -> state.T.pending_confirms_owed <- Masc_tui_owed_read.succeeded state.T.pending_confirms_owed
  | Error _ -> state.T.pending_confirms_owed <- Owed_retry.failed_read state.T.pending_confirms_owed

let settle_asks_read (state : T.state) = function
  | Ok _ -> state.T.asks_owed <- Masc_tui_owed_read.succeeded state.T.asks_owed
  | Error _ -> state.T.asks_owed <- Owed_retry.failed_read state.T.asks_owed

let apply_approvals_load (state : T.state) result =
  (* Recovery and refresh publications already share Listing_order tickets.
     An admitted older refresh must not retire a newer recovery request;
     late older answers are refused by apply_approval_observation instead.
     Workspace withdrawal still invalidates the recovery's ownership. *)
  match result with
  | Ok (snapshot : T.approval_snapshot) ->
      (* The cursor indexes the merged list; the operator rows sit after the
         keeper tool rows, so reconciliation by token happens in operator
         coordinates and the keeper prefix length converts both ways. A
         cursor on a keeper row is not touched by an operator refresh. *)
      let keeper_prefix = List.length state.T.keeper_tool_approvals in
      let operator_cursor = state.T.approval_cursor - keeper_prefix in
      let approval_cursor =
        if operator_cursor < 0 then state.T.approval_cursor
        else
          keeper_prefix
          + Approval.reconcile_cursor
              ~current_items:(Masc_tui_approvals_model.operator_approval_items state)
              ~cursor:operator_cursor ~next_items:snapshot.T.aps_items
      in
      state.T.approval_snapshot <- Some snapshot;
      state.T.approvals_error <- None;
      state.T.approval_cursor <- approval_cursor;
      (match state.T.pending_approval_action with
       | Some pending
         when not
                (List.exists
                   (fun (item : Approval.approval_item) -> String.equal item.T.ap_token pending.T.paa_token)
                   snapshot.T.aps_items) ->
           state.T.pending_approval_action <- None
       | Some _ | None -> ())
  | Error failure ->
      state.T.approval_snapshot <- None;
      state.T.approval_cursor <- 0;
      state.T.approval_list_scroll <- 0;
      state.T.pending_approval_action <- None;
      (* A read the workspace guard kept back settles as a failed read, and
         its event is the kept-back notice alone, not unreliable data
         (RFC §2). The event is added once per changed error, as
         [remember_surface_error] does. *)
      let changed = not (Option.equal ( = ) state.T.approvals_error (Some failure)) in
      state.T.approvals_error <- Some failure;
      if changed then
        Masc_tui_loader.add_event state "error"
          (match failure with
           | T.Request_failed err -> Printf.sprintf "approvals data unreliable: %s" err
           | T.Request_withdrawn refusal ->
               T.workspace_refusal_text ~ko:(state.T.ui_language = T.Lang_ko)
                 ~request:Kept_request.Confirmations_read refusal)

(* A read that fails leaves the last snapshot in place rather than blanking
   the pane: an operator mid-decision should not lose the question they were
   reading because one refresh could not reach the server. *)
(* A new question can arrive while the operator is on another surface. The
   bell reaches every terminal; OSC 9 adds a desktop banner on the terminals
   that read it (iTerm2, WezTerm, kitty) and is ignored elsewhere. Neither
   moves the cursor, so this writes out of band rather than through the frame.
   The banner names the Keeper or the installation so it says who is waiting. *)
let notify_new_asks (arrived : Masc.Tui_decode_asks.ask_key list) =
  let payload = Printf.sprintf "\x07\x1b]9;%s\x07" (Ask.arrival_notification arrived) in
  let payload =
    match Sys.getenv_opt "TMUX" with
    | Some _ -> Masc_tui_graphics.tmux_wrapped payload
    | None -> payload
  in
  Masc_tui_terminal_out.write payload;
  Masc_tui_terminal_out.flush ()

let record_applied_asks (snapshot : Masc.Tui_decode_asks.asks_snapshot) =
  if Masc_tui_frame_timing.enabled then begin
    let rows = List.map (fun (row : Masc.Tui_decode_asks.ask_row) ->
      let owner = match row.Masc.Tui_decode_asks.ar_asker with
        | Masc.Tui_decode_asks.Ask_keeper name -> Masc_tui_frame_timing.Keeper name
        | Masc.Tui_decode_asks.Ask_installation {ai_declaration_id;_} ->
            Masc_tui_frame_timing.Installation ai_declaration_id in
      let is_open = match row.Masc.Tui_decode_asks.ar_resolution with
        | Masc.Tui_decode_asks.Ask_open -> true
        | Masc.Tui_decode_asks.Ask_answered _ | Masc.Tui_decode_asks.Ask_withdrawn _ -> false in
      Masc_tui_frame_timing.{owner;ask_id=row.Masc.Tui_decode_asks.ar_id;
        source_turn_ref=Option.map Ids.Turn_ref.to_string row.Masc.Tui_decode_asks.ar_source_turn_ref;is_open})
      snapshot.Masc.Tui_decode_asks.asn_rows in
    Masc_tui_frame_timing.note_asks_application
      (Masc_tui_frame_timing.Applied {open_count=snapshot.Masc.Tui_decode_asks.asn_open_count;rows})
  end

let apply_asks_load (state : T.state) = function
  | Ok snapshot ->
      (* The delta against the last snapshot, so a poll that re-reads the same
         asks stays silent and only a question that just arrived rings. *)
      let arrived =
        Ask.newly_opened_asks ~previous:state.T.asks_snapshot ~current:snapshot
      in
      let current_rows =
        Option.fold ~none:[] ~some:Ask.open_rows state.T.asks_snapshot
      in
      let next_rows = Ask.open_rows snapshot in
      state.T.ask_cursor <- Ask.reconcile_cursor ~current_rows
        ~cursor:state.T.ask_cursor ~next_rows;
      (match state.T.ask_answer_mode with
       | T.Ask_browsing -> ()
       | T.Ask_answering { aam_ask } ->
           (match List.find_index
                    (fun row -> Masc.Tui_decode_asks.(equal_ask_key aam_ask (ask_key row))) next_rows with
            | Some index -> state.T.ask_cursor <- Ask.On index
            | None when state.T.workspace_identity = T.Workspace_identity_match ->
                Masc_tui_home.clear_ask_answering state
            | None -> ()));

      state.T.asks_snapshot <- Some snapshot;
      record_applied_asks snapshot;
      state.T.asks_error <- None;
      (* Silent while the operator is on the Approvals surface -- the panel is
         already in front of them there. A question that arrives on any other
         surface rings, since nothing else on that surface would show it. *)
      let watching_asks = match state.T.view with
        | T.Approvals -> true
        | T.Overview | T.Acting | T.Metrics | T.Keepers _ | T.Memory | T.Lanes | T.Clients
        | T.Board | T.Planning | T.Schedules | T.Verification | T.Harness | T.Fusion
        | T.Repositories | T.Code | T.Changes | T.Connectors | T.Runtime | T.Config
        | T.Resources | T.Tools | T.System_logs -> false in
      if
        Ask.should_ring_for_new_ask ~arrived
          ~operator_is_watching_asks:watching_asks
      then notify_new_asks arrived
  | Error err ->
      Owed_retry.remember_surface_error state ~surface:"asks" ~current_error:state.T.asks_error
        ~set_error:(fun value -> state.T.asks_error <- value)
        err

(* A read of the questions: what it found, and whether the owed read is
   settled or waits to retry. *)
let settle_asks (state : T.state) result =
  settle_asks_read state result;
  apply_asks_load state result

(* The background read of the questions, which zone 4 also hears about. The
   guard's refusal is said as kept back, never as the read's failure
   (RFC §2). The reread that follows an answer is that action's outcome and
   goes to [settle_asks] alone. *)
let apply_asks_read (state : T.state) result =
  Owed_retry.note_read state Masc_tui_read_failure.Asks result;
  settle_asks state
    (Result.map_error
       (T.request_failure_text ~ko:(state.T.ui_language = T.Lang_ko) ~request:Kept_request.Questions_read)
       result)

let apply_asks_observation (state : T.state) observation =
  Option.iter (apply_asks_read state)
    (T.take_asks_observation state observation)

(* Whether the listing ticket still owns the confirmations it read. *)
let admit_approval_listing (state : T.state) ticket =
  let order, admitted =
    Approval.Listing_order.admit state.T.approvals_order state.T.approval_flow ticket
  in
  state.T.approvals_order <- order;
  admitted

let take_approval_observation (state : T.state) (observation : P.approval_observation) =
  if admit_approval_listing state observation.P.ao_ticket then Some observation.P.ao_result else None

(* A read of the confirmations: what it found, and whether the owed read is
   settled or waits to retry. *)
let apply_approvals_read (state : T.state) result =
  settle_pending_confirms_read state result;
  apply_approvals_load state result

let apply_approval_observation (state : T.state) observation =
  Option.iter (fun result ->
    apply_approvals_read state (Result.map_error (fun detail -> T.Request_failed detail) result))
    (take_approval_observation state observation)

(* The confirm queue's own answer, which zone 4 also hears about.
   [apply_approvals_read] alone also takes an error put in place of a read --
   a booting server, an account server, a refresh that raised -- and that is
   no failed read (RFC §2). *)
let apply_approvals_answer (state : T.state) result =
  Owed_retry.note_read state Masc_tui_read_failure.Confirmations result;
  apply_approvals_read state result

let apply_approval_answer_observation (state : T.state) observation =
  Option.iter (fun result ->
    apply_approvals_answer state (Result.map_error (fun detail -> T.Request_failed detail) result))
    (take_approval_observation state observation)

(* The held-call listing goes out from both the full and the scoped refresh,
   which run on separate in-flight flags, so two of its fetches can overlap.
   No ticket while a press is open: the panel is about to change underneath
   this fetch. *)
let dispatch_approvals_listing (state : T.state) =
  if Approval.Flow.action_inflight state.T.approval_flow then None
  else begin
    let order, ticket =
      Approval.Listing_order.dispatch state.T.approvals_order state.T.approval_flow
    in
    state.T.approvals_order <- order;
    Some ticket
  end

(* The recovery read's answer, ticketed outside the refresh bundle. Same
   ownership rule as every Snapshot_read source: only the read still pending
   publishes, and the workspace it named must still be the current one.
   Its Listing_order ticket guards against stale answers superseding a newer
   refresh pass or an action committed while the recovery read was in flight. *)
let apply_approvals_summary_load (state : T.state) ~listing_ticket ~expected_workspace request result =
  match T.Snapshot_read.settle state.T.approvals_summary_read request with
  | None -> ()
  | Some read ->
    state.T.approvals_summary_read <- read;
    if state.T.workspace_identity = T.Workspace_identity_match
       && Option.exists (Masc_tui_transport.Workspace_admission.same_server_workspace expected_workspace) state.T.server_identity
    then
      (* Carried as [request_failure], so a read the guard kept back is drawn
         as kept back and not as a failed read (RFC §2). *)
      if admit_approval_listing state listing_ticket then apply_approvals_answer state result

(* The operator confirm-queue read, on the same terms the held-call listing
   reads: identity must match first, the request names the expected
   workspace, and the read skips itself when one is already on the wire or
   the count is already drawn. Its Listing_order ticket binds the recovery
   read to the current action flow and sequence. *)
let launch_approvals_summary_load (state : T.state) ~mailbox =
  let refresh_ticket = state.T.http_refresh_order in
  let enqueue_async = Masc_tui_transport.Workspace_admission.workspace_enqueue state in
  let authority = state.T.workspace_authority in
  if Masc_tui_approvals_model.confirm_queue_reading state = Masc_tui_approvals_model.List_read then ()
  else if state.T.workspace_identity <> T.Workspace_identity_match then ()
  else if T.Snapshot_read.in_flight state.T.approvals_summary_read then ()
  else
    match state.T.server_identity with
    | None -> ()
    | Some expected_workspace ->
        match dispatch_approvals_listing state with
        | None -> ()
        | Some listing_ticket ->
            let read, request =
              T.Snapshot_read.start ~intent:T.Snapshot_read.Join
                state.T.approvals_summary_read
            in
            state.T.approvals_summary_read <- read;
            match request with
            | None -> ()
            | Some request ->
                let host = Masc_tui_transport.Workspace_admission.server_peer_host in
                let port = state.T.port in
                Masc_tui_transport.Workspace_admission.launch_async_read_with state ~mailbox
                  ~boundary_error:(fun detail -> T.Request_failed detail)
                  ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
                  ~deliver:(fun result ->
                    enqueue_async mailbox
                      (P.Approvals_msg (P.Approvals_summary_loaded
                         (request, listing_ticket, expected_workspace, result))))
                  (fun () ->
                    let open Result.Syntax in
                    let check_identity ?prior_contact () =
                      Masc_tui_transport.Workspace_admission.admit_request ?prior_contact ~refresh_ticket state ~mailbox ~authority
                        ~identity:(Some expected_workspace) ~host ~port ()
                      |> Result.map_error (fun refusal -> T.Request_withdrawn refusal)
                    in
                    let* () = check_identity () in
                    let snapshot = Masc_tui_loader.load_approvals ~host ~port in
                    (* The first successful identity check already reached the
                       server. A failed GET still needs the trailing check. *)
                    let* () = check_identity
                      ~prior_contact:Masc_tui_server_lifecycle.Server_reached ()
                      |> Result.map_error (Masc_tui_transport.Request_notice.request_failure_after_read state ~request:Kept_request.Confirmations_read) in
                    Result.map_error (fun detail -> T.Request_failed detail) snapshot)

(* The owed read of the confirmations, also when their count is drawn: that
   count is what changed. Its answer names the workspace it was read from, so
   no [/health] check brackets it, and a read made while only the observer
   stream vouches for the server cannot turn an unanswered [/health] into a
   lost workspace. *)
let launch_pending_confirms_read (state : T.state) ~mailbox =
  if state.T.workspace_identity <> T.Workspace_identity_match then false
  else if T.Snapshot_read.in_flight state.T.approvals_summary_read then false
  else
    match state.T.server_identity with
    | None -> false
    | Some expected_workspace ->
      match dispatch_approvals_listing state with
      | None -> false
      | Some listing_ticket ->
        let read, request =
          T.Snapshot_read.start ~intent:T.Snapshot_read.Refresh state.T.approvals_summary_read
        in
        state.T.approvals_summary_read <- read;
        match request with
        | None -> false
        | Some request ->
          let enqueue_async = Masc_tui_transport.Workspace_admission.workspace_enqueue state in
          let host = Masc_tui_transport.Workspace_admission.server_peer_host and port = state.T.port in
          Masc_tui_transport.Workspace_admission.launch_async_read_with state ~mailbox
            ~boundary_error:(fun detail -> T.Request_failed detail)
            ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
            ~deliver:(fun result ->
              enqueue_async mailbox
                (P.Approvals_msg (P.Approvals_summary_loaded (request, listing_ticket, expected_workspace, result))))
            (fun () -> Masc_tui_loader.load_workspace_approvals ~expected_workspace ~host ~port
              |> Result.map_error (fun detail -> T.Request_failed detail));
          true

(* Runs on every loop iteration. A read already on the wire is let finish
   first; one that will not deliver, or whose answer the listing refused,
   leaves the confirmations owed again. *)
let launch_owed_pending_confirms (state : T.state) ~mailbox =
  let reading = T.Snapshot_read.in_flight state.T.approvals_summary_read in
  let read =
    if reading then state.T.pending_confirms_owed
    else Masc_tui_owed_read.abandoned state.T.pending_confirms_owed
  in
  state.T.pending_confirms_owed <- read;
  if Masc_tui_owed_read.due ~now:(Masc_tui_wake.Mono.now ()) read
     && T.server_authority_ready state
     && not reading
     && launch_pending_confirms_read state ~mailbox
  then state.T.pending_confirms_owed <- Masc_tui_owed_read.started read
