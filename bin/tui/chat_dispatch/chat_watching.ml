(** Chat operation sequence tracking, dispatch watchers, and Keeper
    preparation / waiting / turns launchers. *)

module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Waiting_inventory = Masc_tui_waiting_inventory
module Details = Masc_tui_preparation_details
module Admission = Masc_tui_transport.Workspace_admission
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_live = Masc_tui_keeper_chat_live
module Keeper_chat_log = Masc_tui_keeper_chat_log

let next_chat_operation_seq (state : T.state) request_id =
  List.fold_left
    (fun next (entry : T.msg_entry) ->
      if String.equal entry.me_request_id request_id
      then max next (entry.me_operation_seq + 1)
      else next)
    0
    (state.T.msg_loaded @ state.T.msg_history)
;;

let append_chat_history ?at ?submitted_at ?turn_phase ?operation_seq (state : T.state)
    request role text =
  let images = Masc_tui_image_preview.in_message_previews ~text
    ~attachments:(match role with
      | T.Message_user _ -> List.map (fun a -> Masc_tui_image_preview.Staged a) request.Keeper_chat.attachments
      | T.Message_keeper | T.Message_autonomous | T.Message_status | T.Message_local | T.Message_error
      | T.Message_tool | T.Message_thinking | T.Message_memory | T.Message_skill _ -> []) in
  let text = Keeper_chat.terminal_safe_text ~preserve_newlines:true text in
  let at = Option.value ~default:(Unix.gettimeofday ()) at in
  let turn_phase =
    Option.value ~default:(T.chat_turn_phase_of_role role) turn_phase
  in
  let operation_seq =
    Option.value
      ~default:(next_chat_operation_seq state request.Keeper_chat.request_id)
      operation_seq
  in
  state.msg_history <-
    state.T.msg_history
    @ [ {
          T.me_role = role;
          me_identity =
            T.Session_row
              { request_id = request.Keeper_chat.request_id
              ; turn_phase
              ; operation_seq
              };
          me_turn_phase = turn_phase;
          me_turn_sequence = None;
          me_operation_seq = operation_seq;
          me_text = text;
          me_images = images;
          me_media = [];
          me_memory_summary = None;
          me_memory_pass = Masc_tui_message_layout.No_pass;
          me_journal = [];
          me_gate = None;
          me_submitted_at = submitted_at;
          (* Session rows carry no tool or skill block: a turn's calls are
             drawn from its log, and a loaded row's block comes from the
             server ([msg_entry_of_history_row]). *)
          me_tool_block = None;
          me_skill_block = [];
          me_keeper_name = request.Keeper_chat.keeper_name;
          me_request_id = request.request_id;
          me_execution_source = Some (Keeper_chat_log.Operation request.request_id);
          me_at = at;
        } ]

let append_user_history_once ~submitted_at (state : T.state)
    (request : Keeper_chat.request) =
  let expected_text =
    Keeper_chat.terminal_safe_text ~preserve_newlines:true request.message
  in
  let already_present =
    List.exists
      (fun (entry : T.msg_entry) ->
        (match entry.me_role with
          | T.Message_user _ -> true
          | T.Message_keeper | T.Message_autonomous | T.Message_status | T.Message_local | T.Message_error
          | T.Message_tool | T.Message_skill _ | T.Message_thinking | T.Message_memory -> false)
        && String.equal entry.me_request_id request.Keeper_chat.request_id
        && String.equal entry.me_keeper_name request.keeper_name
        && String.equal entry.me_text expected_text)
      state.msg_history
  in
  if not already_present then
    append_chat_history ~at:submitted_at ~submitted_at state request
      (T.Message_user (T.Sent_by_operator { surface = None }))
      request.message

let enqueue_dispatch_ack ~enqueue mailbox make_message =
  let acknowledged, acknowledge = Eio.Promise.create () in
  enqueue mailbox (make_message acknowledge);
  Eio.Promise.await acknowledged

let enqueue_dispatch_start ~enqueue mailbox request was_replay =
  let acknowledged, acknowledge = Eio.Promise.create () in
  enqueue mailbox
    (P.Keeper_msg (P.Keeper_chat_dispatch_started (request, was_replay, acknowledge)));
  Eio.Promise.await acknowledged

(* Send the turn and read it as it arrives.

   Bounding the silence needs a clock. Without one the buffered send is used
   instead -- it is what shipped before this and stays correct, so a missing
   clock costs the live view and nothing else. It is said out loud rather than
   passed over: a pane that quietly stops drawing looks like a keeper that
   stopped working. *)
(* [log] is the request's event log: what carries across a reconnect. The
   decoder does not -- a stream cut right after an [id:] line leaves the seq
   armed and half a frame buffered, and the next stream opens with the
   id-less acceptance, which would inherit that seq while the leftover bytes
   glued onto the next chunk -- so each (re)connect starts a fresh one and
   asks the server to resume from the log's last seq instead. *)
exception Rejected_keeper_live_stream

let post_keeper_chat_watching ~waiting_inventory ~expected_workspace ~check_request ~start_first_post ~follow_kept_back ~enqueue ~control_generation ~admission_intent ~mailbox ~port ~log request =
  let enqueue_async = enqueue in
  let host = Admission.server_peer_host in
  (* Before the first POST a refusal is kept back: nothing left, so nothing
     can have been admitted. A refusal of a later re-POST stops a reconcile of
     a request that did leave, whose outcome stays unverified; [follow_kept_back]
     says that re-POST was not sent, apart from any transport failure. *)
  match Eio_context.get_clock_opt () with
  | None ->
      (match check_request () with
       | Error refusal -> T.Keeper_chat_kept_back refusal
       | Ok () ->
           if start_first_post () then begin
             enqueue_async mailbox
               (P.Keeper_msg (P.Keeper_chat_stream_unavailable
                  ( request
                  , "sending without a live view: no Eio clock to bound the stream" )));
             T.Keeper_chat_answered
               (Masc_tui_http.post_keeper_chat ~expected_workspace ~admission_intent ~host ~port request)
           end
           else T.Keeper_chat_kept_back T.Workspace_authority_withdrawn)
  | Some clock ->
      (* After the highest seq this watcher has handed to the mailbox. The
         log is folded by the main loop, so at the moment of a re-POST it may
         still be behind what arrived; the resume position is the later of
         the two, so the server is never asked for frames already in hand. *)
      let delivered = ref Masc.Keeper_chat_event_log.Whole_turn in
      let resume_position () =
        match Keeper_chat_log.resume_position log with
        | Masc.Keeper_chat_event_log.Whole_turn -> !delivered
        | Masc.Keeper_chat_event_log.After_seq held ->
            Masc.Keeper_chat_event_log.replay_position_advance !delivered held
      in
      let keeper_name = request.Keeper_chat.keeper_name in
      let rec watch ~first_post ~since_seq was_unverified =
        (* What the attempt starts from: a change heard or a frame delivered
           while it runs is news the next reconcile does not wait for. *)
        let inventory_seen = Waiting_inventory.generation waiting_inventory keeper_name in
        let position_at_start =
          Masc.Keeper_chat_event_log.replay_position_to_wire (resume_position ()) in
        match check_request () with
        | Error refusal when first_post -> T.Keeper_chat_kept_back refusal
        | Error refusal -> T.Keeper_chat_answered (Error (follow_kept_back refusal))
        | Ok () when first_post && not (start_first_post ()) ->
            T.Keeper_chat_kept_back T.Workspace_authority_withdrawn
        | Ok () ->
        let decoder = Keeper_chat_live.create ~request () in
        (* Each idempotent re-subscribe has its own SSE grammar state. The
           visible transcript remains request-owned, but an acceptance event
           at the head of the new stream is not a duplicate in that stream. *)
        let on_chunk chunk =
          (* Each delta travels with the journal seq of the frame that carried
             it; the request's log deduplicates on it, which is what absorbs
             the overlap between the server's replay and its live window. *)
          let deltas = Keeper_chat_live.feed decoder chunk in
          (match deltas with
          | [] -> ()
          | deltas ->
              List.iter (fun (item : Keeper_chat_live.observed_delta) -> match item.delta with
                | Keeper_chat_live.Accepted {interactive=Some receipt;_} ->
                  enqueue_async mailbox (P.Keeper_msg (P.Keeper_chat_control_received
                    (request.Keeper_chat.keeper_name, control_generation, receipt.Keeper_chat.chat_control_token)))
                | Keeper_chat_live.Accepted { interactive = None;_} | Keeper_chat_live.Run_started
                | Keeper_chat_live.Checkpoint | Keeper_chat_live.External_effect_completed
                | Keeper_chat_live.Run_finished | Keeper_chat_live.Batch_bound _
                | Keeper_chat_live.Runtime_attempt_started _
                | Keeper_chat_live.Provider_retry_observed _
                | Keeper_chat_live.Stream_model_started _
                | Keeper_chat_live.Model_content_activity _
                | Keeper_chat_live.Stream_model_stopped _ | Keeper_chat_live.Stream_details _
                | Keeper_chat_live.Text _ | Keeper_chat_live.Media _ | (Keeper_chat_live.Thinking _ | Keeper_chat_live.Thinking_snapshot _)
                | Keeper_chat_live.Native_tool_started _ | Keeper_chat_live.Native_tool_progress _
                | Keeper_chat_live.Native_tool_ended _ | Keeper_chat_live.Tool_started _ | Keeper_chat_live.Tool_admitted _
                | Keeper_chat_live.Tool_args _ | Keeper_chat_live.Tool_ended _
                | Keeper_chat_live.Tool_result _ | Keeper_chat_live.Stream_protocol_error _
                | Keeper_chat_live.Approval_requested _ | Keeper_chat_live.Approval_settled _
                | Keeper_chat_live.Reply_details _ | Keeper_chat_live.Run_failed _
                | Keeper_chat_live.Undecodable _ -> ()) deltas;
              List.iter
                (fun (item : Keeper_chat_live.observed_delta) ->
                  match item.seq with
                  | Some seq ->
                      delivered :=
                        Masc.Keeper_chat_event_log.replay_position_advance
                          !delivered seq
                  | None -> ())
                deltas;
              enqueue_async mailbox
                (P.Keeper_msg (P.Keeper_chat_stream_deltas (request, deltas))));
          (* A rejected frame can share a chunk with valid earlier frames.
             Deliver that prefix before closing, since live events need not
             all have reached the journal for a later replay. *)
          if Keeper_chat_live.requires_reconnect decoder then
            raise Rejected_keeper_live_stream
        in
        let result =
          try
            Masc_tui_http.post_keeper_chat_streaming ~expected_workspace ~admission_intent ~clock ~host ~port ~on_chunk
              ~since_seq request
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | _ when Keeper_chat_live.requires_reconnect decoder ->
              Eio.Fiber.check ();
              Error (Keeper_chat.Transport_error "live acceptance could not be verified")
        in
        let result =
          if Keeper_chat_live.requires_reconnect decoder then begin
            Eio.Fiber.check ();
            Error (Keeper_chat.Transport_error "live acceptance could not be verified")
          end
          else result in
        match result with
        | Ok (Keeper_chat.Turn_completed { turn_outcome = Keeper_chat.Continuation_checkpoint; _ }) ->
            (* A checkpoint closes this transport segment, not the durable
               request. Subscribe after its last journal sequence to receive
               the eventual answer under the same operation identity. *)
            watch ~first_post:false ~since_seq:(resume_position ()) false
        | Error error
          (* A re-POST follows a checkpoint (the operation was admitted) or
             an unverified attempt, so a refusal of this attempt does not
             show that nothing was admitted under the id. *)
          when Keeper_chat.error_certainty
                 ~was_unverified:(was_unverified || not first_post) error
               = Keeper_chat.Outcome_unverified ->
            if not was_unverified
            then
              enqueue_async mailbox
                (P.Keeper_msg (P.Keeper_chat_stream_unavailable
                   ( request
                   , Keeper_chat.unverified_retry_notice
                       ~request_id:request.Keeper_chat.request_id error )));
            (* Re-POSTing the same operation id is the server's idempotent
               subscribe/reconcile path. The in-flight owner stays held until
               one watcher observes terminal truth, so NEXT cannot overlap a
               turn whose first stream merely disappeared. *)
            let progressed =
              not
                (Option.equal Int.equal position_at_start
                   (Masc.Keeper_chat_event_log.replay_position_to_wire
                      (resume_position ())))
            in
            (* Held for the operator: no stream will announce the change, so
               only [/reconcile] or a reopened stream sends the next one. *)
            let hold_for_operator () =
              enqueue_async mailbox
                (P.Keeper_msg (P.Keeper_chat_stream_unavailable
                   ( request
                   , Keeper_chat.held_for_operator_notice
                       ~request_id:request.Keeper_chat.request_id )));
              Waiting_inventory.await_after waiting_inventory keeper_name inventory_seen
            in
            (match
               Keeper_chat.reconcile_pace ~attempt_was_reconcile:was_unverified
                 ~progressed ~hearing:(Waiting_inventory.hearing waiting_inventory)
             with
             | Keeper_chat.Reconcile_now -> ()
             | Keeper_chat.Reconcile_after_inventory_change ->
                 (match Waiting_inventory.await_news waiting_inventory keeper_name inventory_seen with
                  | Waiting_inventory.Heard_news -> ()
                  | Waiting_inventory.Stream_lost -> hold_for_operator ())
             | Keeper_chat.Reconcile_when_operator_asks -> hold_for_operator ());
            watch ~first_post:false ~since_seq:(resume_position ()) true
        | (Ok (Keeper_chat.Turn_completed
                 { turn_outcome =
                     ( Keeper_chat.Visible_reply | Keeper_chat.Terminal_effect_settled
                     | Keeper_chat.Awaiting_gate_approval | Keeper_chat.No_visible_reply );
                   _ }
              | Keeper_chat.Replayed_succeeded _)
          | Error _) as terminal -> T.Keeper_chat_answered terminal
      in
      watch ~first_post:true ~since_seq:Masc.Keeper_chat_event_log.Whole_turn false

let launch_keeper_preparation_load (state : T.state) ~mailbox =
  let selected = if T.server_authority_ready state then
    match T.keeper_message_preparation_selection state with
    | Some (_, Ok target) -> Some target | Some (_, Error _) | None -> None
    else None in
  let previous = state.msg_preparation_details in
  let current, request = Details.select selected previous in
  state.msg_preparation_details <- current;
  Option.iter (fun request ->
    let target = Details.requested_target request in
    let host = Admission.server_peer_host and port = state.port in
    Admission.launch_json_read state ~mailbox
      ~boundary_error:(fun detail -> T.Request_failed detail)
      ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
      ~deliver:(fun result -> P.Keeper_msg (P.Keeper_preparation_loaded (request,result)))
      (fun () -> Masc_tui_http.fetch_keeper_preparation_details ~host ~port target
        |> Result.map_error (fun detail -> T.Request_failed detail))) request;
  current != previous
;;

let launch_keeper_waiting_load ?change ?(exclusive = false) (state : T.state) ~mailbox =
  Option.iter (T.note_keeper_waiting_change state) change;
  if exclusive then
    state.keeper_waiting_read <- T.Keeper_waiting_read.exclusive state.keeper_waiting_read;
  if T.server_authority_ready state then begin
    let enqueue_async = Admission.workspace_enqueue state in
    let reading, request = T.Keeper_waiting_read.start state.keeper_waiting_read in
    state.keeper_waiting_read <- reading;
    Option.iter (fun request ->
      state.keeper_waiting_owed <- Masc_tui_owed_read.started state.keeper_waiting_owed;
      let host = Admission.server_peer_host and port = state.port in
      let snapshot = T.capture_keeper_waiting_snapshot state in
      Admission.launch_guarded_async_read state ~mailbox ~source:Masc_tui_async_read.Keeper_turns
        ~deliver:(fun result -> enqueue_async mailbox (P.Keeper_msg (P.Keeper_waiting_loaded (request, snapshot, result))))
        (Admission.capture_json_read state (fun () ->
          Masc_tui_loader.load_keeper_turns ~host ~port ~preparation_details_for:None))
    ) request
  end

let launch_keeper_turns_load (state : T.state) ~mailbox =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  if state.keeper_turns_inflight then ()
  else begin
    state.keeper_turns_inflight <- true;
    state.keeper_turns_owed <- Masc_tui_owed_read.started state.keeper_turns_owed;
    state.keeper_previews_unread <- [];
    let waiting_receipt = T.Keeper_waiting_read.poll_receipt state.keeper_waiting_read in
    let waiting_snapshot = T.capture_keeper_waiting_snapshot state in
    let generation = state.keeper_chat_control_generations in
    let host = Admission.server_peer_host in
    let port = state.port in
    let preparation_details_for =
      if state.view = T.Keepers T.Keeper_message && not state.msg_turn_folded
      then state.msg_target_keeper_name else None in
    Admission.launch_guarded_async_read state ~mailbox
      ~source:Masc_tui_async_read.Keeper_turns
      ~on_not_run:(fun () ->
        state.keeper_turns_inflight <- false;
        state.keeper_turns_owed <- Masc_tui_owed_read.abandoned state.keeper_turns_owed)
      ~deliver:(fun result ->
        enqueue_async mailbox (P.Keeper_msg (P.Keeper_turns_loaded (generation, waiting_snapshot, waiting_receipt, result))))
      (Admission.capture_json_read state (fun () ->
        Masc_tui_loader.load_keeper_turns ~host ~port ~preparation_details_for))
  end
  end
