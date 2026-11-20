(** Queueing, /steer interruption, run-next reordering, and Keeper chat
    dispatch coordination. *)

module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission
module Request_notice = Masc_tui_transport.Request_notice
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Chat_queue = Masc_tui_keeper_chat_queue

let launch_keeper_interrupt (state : T.state) ~mailbox (request : Keeper_chat.request) =
  let enqueue_async = Admission.workspace_enqueue state in
  let authority = state.workspace_authority in
  let expected_control_token = List.assoc_opt request.keeper_name state.keeper_chat_control_tokens in
  let generation = T.begin_keeper_chat_control state request.keeper_name in
  let on_control_token token = enqueue_async mailbox
    (P.Keeper_msg (P.Keeper_chat_control_received (request.keeper_name, generation, token))) in
  let host = Admission.server_peer_host in
  let port = state.port in
  let keeper_name = request.Keeper_chat.keeper_name in
  let request_id = match T.inflight_entry_by_request_id state request.Keeper_chat.request_id with
    | Some (entry : T.inflight) when Keeper_chat.same_request_identity entry.sent_request request ->
      Keeper_chat_transcript.execution_id entry.T.log.tl_transcript
    | Some _ | None -> request.Keeper_chat.request_id in
  let run () =
    let result =
      try
        if authority <> state.workspace_authority then Error (T.Request_withdrawn T.Workspace_authority_withdrawn)
        else if not (T.server_authority_ready state) then Error (T.Request_withdrawn T.Workspace_identity_not_confirmed)
        else Masc_tui_http.post_keeper_turn_interrupt ~expected_control_token ~on_control_token ~host ~port ~keeper_name
          ~request_id
          |> Result.map_error (fun detail -> T.Request_failed detail)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (T.Request_failed (Printexc.to_string exn))
    in
    enqueue_async mailbox (P.Keeper_msg (P.Keeper_chat_interrupt_done (request, generation, result)))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Admission.fork_job state ~mailbox ~sw run
  | None ->
      enqueue_async mailbox
        (P.Keeper_msg (P.Keeper_chat_interrupt_done (request, generation,
           Error (T.Request_failed "Eio switch is unavailable"))))

let launch_keeper_observed_interrupt (state : T.state) ~mailbox ~keeper_name ~started_at ~interrupt_token =
  let enqueue_async = Admission.workspace_enqueue state in
  let authority = state.workspace_authority in
  match T.keeper_observed_interrupt state keeper_name started_at with
  | Some _ -> false
  | None ->
    let generation = T.begin_keeper_chat_control state keeper_name in
    let on_control_token token = enqueue_async mailbox
      (P.Keeper_msg (P.Keeper_chat_control_received (keeper_name, generation, token))) in
    let item = { T.oi_keeper = keeper_name; oi_token = interrupt_token; oi_started_at = started_at
      ; oi_sent_ns = Mtime_clock.elapsed_ns (); oi_status = T.Interrupt_sending } in
    state.keeper_observed_interrupts <- item ::
      List.filter (fun (old : T.observed_interrupt) -> old.oi_keeper <> keeper_name) state.keeper_observed_interrupts;
    let run () =
      let result =
        try
          if authority <> state.workspace_authority then Error (T.Request_withdrawn T.Workspace_authority_withdrawn)
          else if not (T.server_authority_ready state) then Error (T.Request_withdrawn T.Workspace_identity_not_confirmed)
          else Masc_tui_http.post_keeper_observed_turn_interrupt ~on_control_token ~host:Admission.server_peer_host
            ~port:state.port ~keeper_name ~interrupt_token
            |> Result.map_error (fun detail -> T.Request_failed detail)
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (T.Request_failed (Printexc.to_string exn))
      in
      enqueue_async mailbox (P.Keeper_msg (P.Keeper_observed_interrupt_done (keeper_name, interrupt_token, generation, result)))
    in
    (match Eio_context.get_switch_opt () with
     | Some sw -> Admission.fork_job state ~mailbox ~sw run
     | None -> enqueue_async mailbox
         (P.Keeper_msg (P.Keeper_observed_interrupt_done (keeper_name, interrupt_token, generation,
            Error (T.Request_failed "Eio switch is unavailable")))));
    true
;;

let interrupt_observed_keeper ?(explicit = false) (state : T.state) ~mailbox keeper_name =
  if explicit then
    state.keeper_observed_interrupts <- List.filter (fun (item : T.observed_interrupt) ->
      item.oi_keeper <> keeper_name || match item.oi_status with
        | T.Interrupt_failed _ | T.Interrupt_declined _ | T.Interrupt_kept_back _ -> false
        | T.Interrupt_sending | T.Interrupt_signalled -> true) state.keeper_observed_interrupts;
  match T.working_chat_for_keeper state keeper_name with
  | Some entry ->
    let action = T.working_chat_interrupt_action ~explicit
      ~now_ns:(Mtime_clock.elapsed_ns ()) state keeper_name entry in
    (match action with
     | Masc_tui_esc_interrupt.Launch_interrupt -> launch_keeper_interrupt state ~mailbox entry.sent_request; Some true
     | Masc_tui_esc_interrupt.Swallow -> Some true
     | Masc_tui_esc_interrupt.Leave -> Some false)
  | None -> match T.keeper_observed_interrupt_action state keeper_name with
  | None -> None
  | Some Masc_tui_esc_interrupt.Swallow -> Some true
  | Some Masc_tui_esc_interrupt.Leave -> Some false
  | Some Masc_tui_esc_interrupt.Launch_interrupt ->
    match T.keeper_observed_turn state keeper_name with
    | None -> Some false
    | Some (started_at, interrupt_token) ->
      Some (launch_keeper_observed_interrupt state ~mailbox ~keeper_name ~started_at ~interrupt_token)
;;

(* Interrupt the active turn of the Keeper currently shown in chat (RFC §3.4:
   Ctrl-C interrupts a running turn, while Esc always closes/leaves without
   accidentally stopping the turn). Returns true when Ctrl-C was spent on the
   turn (or swallowed inside the grace window) so the caller withdraws quit
   arming. *)
let interrupt_active_chat_turn (state : T.state) ~mailbox =
  match Option.bind state.msg_target_keeper_name
    (interrupt_observed_keeper state ~mailbox) with
  | Some handled -> handled
  | None ->
    (match state.msg_live with
     | Some live
       when state.msg_target_keeper_name = Some (T.turn_log_keeper_name live) ->
         (match
            Masc_tui_esc_interrupt.action
              ~now_ns:(Mtime_clock.elapsed_ns ())
              (Keeper_chat_transcript.interrupt live.tl_transcript)
          with
          | Masc_tui_esc_interrupt.Launch_interrupt ->
            (match
               T.inflight_by_request_id state (T.turn_log_request_id live)
             with
             | Some request ->
               launch_keeper_interrupt state ~mailbox request;
               true
             | None -> false)
          | Masc_tui_esc_interrupt.Swallow -> true
          | Masc_tui_esc_interrupt.Leave -> false)
     | Some _ | None -> false)
;;

(* Ask the server to run this queued message next. Run-next only reorders
   the queue: it carries no interrupt token, so the turn the Keeper is on --
   its own autonomous turn or another operator's message -- runs to its end
   and the promoted message takes the slot after it. A promoted line (a
   queued line sent again, /run-next, or Enter while the Keeper's chat
   control token had not arrived) never cancels the running turn. Stopping a
   turn is an explicit act: Esc, or /steer, which interrupts before it
   queues. *)
let run_next_busy_for (state : T.state) keeper_name =
  let same_keeper (request : Keeper_chat.request) =
    String.equal request.keeper_name keeper_name in
  List.exists same_keeper state.keeper_run_next_pending
  || List.exists same_keeper state.keeper_run_next_ready
  || List.exists same_keeper state.keeper_run_next_inflight
  || List.exists (fun (item : Chat_queue.item) ->
       String.equal item.request.keeper_name keeper_name
       && match item.intent with
          | Chat_queue.Run_next _ -> true
          | Chat_queue.Next | Chat_queue.Next_without_auto_priority
          | Chat_queue.Steer_after_interrupt | Chat_queue.Steer_without_priority -> false)
       (Chat_queue.waiting state.msg_queued)
;;

let queue_run_next_on_admission ?(automatic = false) (state : T.state) (request : Keeper_chat.request) =
  if not (List.exists (Keeper_chat.same_request_identity request)
            state.keeper_run_next_pending) then
    state.keeper_run_next_pending <- state.keeper_run_next_pending @ [request];
  if automatic then
    state.keeper_auto_priority_pending <-
      (request.keeper_name, request.request_id) ::
      List.filter (fun (name, id) ->
        not (String.equal name request.keeper_name
             && String.equal id request.request_id))
        state.keeper_auto_priority_pending
;;

let add_auto_priority_request (state : T.state) (request : Keeper_chat.request) =
  let keeper_name = request.keeper_name in
  let previous = Option.value ~default:[]
    (List.assoc_opt keeper_name state.keeper_auto_priority_requests) in
  if not (List.mem request.request_id previous) then
    state.keeper_auto_priority_requests <-
      (keeper_name, previous @ [request.request_id]) ::
      List.remove_assoc keeper_name state.keeper_auto_priority_requests
;;

let keeper_queue_change_inflight (state : T.state) keeper_name =
  List.mem keeper_name state.keeper_queue_inflight
  && not (List.mem keeper_name state.keeper_queue_readings)
;;

let launch_keeper_run_next ?(automatic = false) (state : T.state) ~mailbox (request : Keeper_chat.request) =
  let enqueue_async = Admission.workspace_enqueue state in
  let authority = state.workspace_authority in
  if keeper_queue_change_inflight state request.Keeper_chat.keeper_name then begin
    if not (List.exists (Keeper_chat.same_request_identity request) state.keeper_run_next_ready) then
      state.keeper_run_next_ready <- state.keeper_run_next_ready @ [request]
  end else if List.exists (fun (inflight : Keeper_chat.request) ->
       String.equal inflight.keeper_name request.Keeper_chat.keeper_name)
       state.keeper_run_next_inflight then ()
  else begin
    let keeper_name = request.Keeper_chat.keeper_name in
    let request_id = request.Keeper_chat.request_id in
    T.update_queue_panel state ~keeper_name (fun (panel : T.queue_panel) ->
      { panel with T.qp_reading = (match panel.qp_reading with
          | T.Queue_loading -> T.Queue_loading | T.Queue_current | T.Queue_unavailable -> T.Queue_unavailable);
        qp_refresh_after_priority=true;
        qp_notice=Some (T.Queue_info "A message priority update is in progress")});
    state.keeper_run_next_inflight <- request :: state.keeper_run_next_inflight;
    state.keeper_run_next_receipts <- List.filter (fun (old, _) ->
      not (Keeper_chat.same_request_identity old request)) state.keeper_run_next_receipts;
    let priority_predecessors =
      if automatic then
        let rec earlier reversed = function
          | [] -> List.rev reversed
          | id :: _ when String.equal id request_id -> List.rev reversed
          | id :: rest -> earlier (id :: reversed) rest in
        Some (earlier [] (Option.value ~default:[]
          (List.assoc_opt keeper_name state.keeper_auto_priority_requests)))
      else None in
    let run () =
      let result =
        try
          if authority <> state.workspace_authority then Error (T.Request_withdrawn T.Workspace_authority_withdrawn)
          else if not (T.server_authority_ready state) then Error (T.Request_withdrawn T.Workspace_identity_not_confirmed)
          else Masc_tui_http.post_keeper_run_next ?priority_predecessors ~host:Admission.server_peer_host
            ~port:state.port ~keeper_name ~request_id ()
            |> Result.map_error (fun detail -> T.Request_failed detail)
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (T.Request_failed (Printexc.to_string exn))
      in
      enqueue_async mailbox (P.Keeper_msg (P.Keeper_run_next_done (request, result))) in
    match Eio_context.get_switch_opt () with
    | Some sw -> Admission.fork_job state ~mailbox ~sw run
    | None -> enqueue_async mailbox (P.Keeper_msg (P.Keeper_run_next_done (request,
        Error (T.Request_failed "Eio switch is unavailable"))))
  end
;;

let dispatch_ready_run_next (state : T.state) ~mailbox keeper_name =
  if not (T.server_authority_ready state)
     || keeper_queue_change_inflight state keeper_name
     || List.mem_assoc keeper_name state.keeper_chat_control_pending
     || List.exists (fun (request : Keeper_chat.request) ->
       String.equal request.keeper_name keeper_name)
       state.keeper_run_next_inflight then ()
  else
    match List.find_opt (fun (request : Keeper_chat.request) ->
      String.equal request.keeper_name keeper_name)
      state.keeper_run_next_ready with
    | None -> ()
    | Some request ->
      state.keeper_run_next_ready <- List.filter (fun item ->
        not (Keeper_chat.same_request_identity item request))
        state.keeper_run_next_ready;
      (* A control keeps preserved requests in [ready] until its outcome is
         known; an actual pause/resume clears superseded requests itself. *)
      let automatic = List.mem request.request_id
        (Option.value ~default:[]
           (List.assoc_opt keeper_name state.keeper_auto_priority_requests)) in
      launch_keeper_run_next ~automatic state ~mailbox request
;;


let inflight_for (state : T.state) keeper_name =
  Option.map (fun (entry : T.inflight) -> entry.sent_request)
    (T.blocking_inflight_for_keeper state keeper_name)
;;

(* POST the request. There is no durable claim to take first: the server keys
   every chat operation by this request's id and refuses a second submission of
   it ([Keeper_chat_operation_store.submit] answers [Existing] for a repeat and
   [Idempotency_conflict] for the same id with different content), so a resend
   cannot produce a second turn. The client used to hold its own five-phase
   fence to prevent exactly that, and the price was one un-acknowledged POST
   per workspace — talking to one keeper stopped every other. *)
(* Request construction only borrows the composer payload. Transfer ownership
   after queue admission succeeds: a full queue, duplicate steer, or refused
   edit must leave text, attachment bytes, references, and staging time intact. *)
let pending_attachments (state : T.state) =
  (state.msg_attachments, state.msg_references)
;;

let launch_keeper_request ~(promoted : Chat_queue.item) ?(admission_intent = Keeper_chat.Queue_only) (state : T.state) ~mailbox (request : Keeper_chat.request) =
  let enqueue_async = Admission.workspace_enqueue state in
  let authority = state.workspace_authority in
  let identity = state.server_identity in
  let host = Admission.server_peer_host in
  let port = state.port in
  let check_request =
    Admission.admission_sequence state ~mailbox ~authority ~identity ~host ~port
  in
  match state.workspace_identity, state.server_identity with
  | T.Workspace_identity_match, Some expected_workspace ->
  if T.keeper_available_for_new_message state request.Keeper_chat.keeper_name then begin
  state.keeper_interactive_waiting <- List.filter (fun (_, id, _) ->
    id <> request.Keeper_chat.request_id) state.keeper_interactive_waiting;
  let control_generation = match admission_intent with
    | Keeper_chat.Interactive _ ->
      state.keeper_observed_interrupts <- List.filter (fun (item : T.observed_interrupt) ->
        item.oi_keeper <> request.Keeper_chat.keeper_name) state.keeper_observed_interrupts;
      T.advance_keeper_interactive_control state request.Keeper_chat.keeper_name
    | Keeper_chat.Queue_only -> T.keeper_chat_control_generation state request.Keeper_chat.keeper_name in
  let submitted_at = promoted.Chat_queue.submitted_at in
  let log =
    T.turn_log_create
      ~keeper_name:request.Keeper_chat.keeper_name
      ~request_id:request.request_id
      ~started_at:(Unix.gettimeofday ())
  in
  state.msg_inflight <-
    { T.sent_request = request
    ; submitted_at
    ; sent_at = Unix.gettimeofday ()
    ; control_generation
    ; phase = T.Turn_preflight promoted
    ; log
    }
    :: state.msg_inflight;
  if
    Option.exists
      (String.equal request.Keeper_chat.keeper_name)
      state.msg_target_keeper_name
  then state.msg_live <- Some log;
  let run () =
    let start_first_post () =
      Chat_watching.enqueue_dispatch_start ~enqueue:enqueue_async mailbox request false
    in
    let follow_kept_back refusal =
      Keeper_chat.Follow_kept_back
        (T.workspace_refusal_text ~ko:(state.ui_language = T.Lang_ko)
           ~request:Masc_tui_words.Kept_request.Keeper_reply_follow refusal)
    in
    let result =
      try
        Chat_watching.post_keeper_chat_watching ~waiting_inventory:state.waiting_inventory ~expected_workspace ~check_request ~start_first_post
          ~follow_kept_back ~enqueue:enqueue_async ~control_generation ~admission_intent ~mailbox ~port
          ~log:log.tl_log request
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> T.Keeper_chat_answered (Error (Keeper_chat.Transport_error (Printexc.to_string exn)))
    in
    Chat_watching.enqueue_dispatch_ack ~enqueue:enqueue_async mailbox (fun acknowledge ->
      P.Keeper_msg (P.Keeper_chat_done (request, false, result, acknowledge)))
  in
  (match Eio_context.get_switch_opt () with
  | Some sw ->
      Admission.fork_job state ~mailbox ~sw run
  | None ->
      enqueue_async mailbox
        (P.Keeper_msg (P.Keeper_chat_dispatch_blocked
           (request, "Eio switch is unavailable"))))
  end
  | (T.Workspace_identity_match, None)
  | ((T.Workspace_identity_unread | (T.Workspace_identity_match_unconfirmed _ | T.Workspace_identity_mismatch _)), _) -> enqueue_async mailbox
      (P.Keeper_msg (P.Keeper_chat_dispatch_blocked (request, "workspace identity is not verified")))

(* The joined line keeps the request identity the history row already carries,
   so the row is rewritten rather than duplicated. [append_user_history_once]
   matches on identity AND text, so a changed text would otherwise append a
   second row for the same queue item. *)
let update_queued_history_text (state : T.state) (request : Keeper_chat.request) =
  let text =
    Keeper_chat.terminal_safe_text ~preserve_newlines:true request.message
  in
  state.msg_history <-
    List.map
      (fun (entry : T.msg_entry) ->
        if
          (match entry.me_role with
            | T.Message_user _ -> true
            | T.Message_keeper | T.Message_autonomous | T.Message_status | T.Message_local | T.Message_error
            | T.Message_tool | T.Message_skill _ | T.Message_thinking | T.Message_memory -> false)
          && String.equal entry.me_request_id request.Keeper_chat.request_id
          && String.equal entry.me_keeper_name request.keeper_name
        then { entry with T.me_text = text;
          me_images = Masc_tui_image_preview.in_message_previews ~text:request.message
            ~attachments:(List.map (fun a -> Masc_tui_image_preview.Staged a) request.attachments) }
        else entry)
      state.msg_history

type queued_message_origin = New_input of float | Joined_input of string
type queued_message_receipt = { qmr_id : string; qmr_origin : queued_message_origin }

let queue_keeper_message (state : T.state) (request : Keeper_chat.request) =
  let submitted_at = Unix.gettimeofday () in
  let joined =
    if not state.coalesce_queued_input
    then None
    else (
      match
        T.joinable_keeper_input state request.Keeper_chat.keeper_name
      with
      | None -> None
      | Some item ->
        let waiting_request = item.Chat_queue.request in
        let merged =
          { waiting_request with
            Keeper_chat.message =
              waiting_request.Keeper_chat.message
              ^ "\n"
              ^ request.Keeper_chat.message
          ; Keeper_chat.attachments =
              waiting_request.Keeper_chat.attachments
              @ request.Keeper_chat.attachments
          ; Keeper_chat.references =
              waiting_request.Keeper_chat.references @ request.Keeper_chat.references
          }
        in
        let source = Chat_queue.source_for_join item ~message:request.message in
        (match
           Chat_queue.replace_request ~source state.msg_queued
             ~request_id:merged.Keeper_chat.request_id merged
         with
         | Error _ -> None
         | Ok queue -> Some (queue, merged, waiting_request.message)))
  in
  match joined with
  | Some (queue, merged, prefix) ->
      state.msg_queued <- queue;
      Ok {qmr_id = merged.Keeper_chat.request_id; qmr_origin = Joined_input prefix}
  | None ->
      (match Chat_queue.push state.msg_queued ~submitted_at request with
       | Error _ as error -> error
       | Ok (queue, _) ->
           state.msg_queued <- queue;
           Ok {qmr_id = request.Keeper_chat.request_id; qmr_origin = New_input submitted_at})
;;

let queue_keeper_steer (state : T.state) ~causal_parent_request_id (request : Keeper_chat.request) =
  let submitted_at = Unix.gettimeofday () in
  match
    Chat_queue.push_steer state.msg_queued ~submitted_at
      ~causal_parent_request_id request
  with
  | Error _ as error -> error
  | Ok (queue, waiting) ->
      state.msg_queued <- queue;
      Ok (waiting, submitted_at)
;;

(* Publish the request-owned row only after any spill has its final payload. *)
let publish_queued_message_history (state : T.state) receipt (request : Keeper_chat.request) =
  match receipt.qmr_origin with
  | New_input submitted_at -> Chat_watching.append_user_history_once ~submitted_at state request
  | Joined_input _ -> update_queued_history_text state request

(* The queue owns the inline bytes before a file can become visible. Once a
   file is published, replace only that exact accepted payload; independent
   queue priority changes are preserved by [replace_recalled_request]. *)
let stage_accepted_spill (state : T.state) ~keeper_name ~prefix ~prepared
    (accepted : Chat_queue.item) =
  match prepared with
  | None -> Ok accepted
  | Some { Masc_tui_chat_input.Paste_spill.ps_spill = spill; ps_source = saved; ps_directory = staging_dir} ->
      state.msg_spill <- None;
      let staged = Masc_tui_chat_input.Paste_spill.place_spilled_paste state ~keeper_name ~staging_dir saved in
      let message = match prefix with None -> staged | Some prior -> prior ^ "\n" ^ staged in
      let request = {accepted.Chat_queue.request with Keeper_chat.message} in
      let source = Chat_queue.source_for_staging accepted ~message in
      (match Chat_queue.replace_recalled_request ~source
               state.msg_queued ~original:accepted request with
       | Error detail ->
           state.msg_spill <- Some spill;
           Error detail
       | Ok queue ->
           state.msg_queued <- queue;
           match Chat_queue.find queue ~request_id:request.request_id with
           | Some item -> Ok item
           | None -> Error "accepted input disappeared while staging the paste")
;;

(* Hands the Keeper's next authorised queued input to the server. An input
   found to hand off leaves the queue and the waiting marks the chat draws,
   so that is [Drawn_changed]; finding none is [Drawn_unchanged]. *)
let dispatch_waiting_keeper_input (state : T.state) ~mailbox ~keeper_name =
  if state.workspace_identity = T.Workspace_identity_match
     && T.keeper_available_for_new_message state keeper_name
     && not (List.mem_assoc keeper_name state.keeper_chat_control_pending) then begin
    (* Every Enter send, including one without a control token, waits for the
       previous server acceptance. Concurrent HTTP fibers may otherwise reach
       the durable queue in the opposite order. *)
    if T.keeper_admission_pending state keeper_name then T.Drawn_unchanged
    else
      let generation = T.keeper_chat_control_generation state keeper_name in
      let ready = T.next_authorized_keeper_input state keeper_name in
      match ready with
      | None -> T.Drawn_unchanged
      | Some (item, target) ->
        let request_id = item.Chat_queue.request.request_id in
        let explicitly_queued = List.exists (fun (name, id, _) ->
          String.equal name keeper_name && String.equal id request_id)
          state.keeper_interactive_waiting in
        state.keeper_interactive_waiting <- List.filter (fun (_, id, _) -> id <> request_id)
          state.keeper_interactive_waiting;
        (match Chat_queue.take state.msg_queued ~request_id with
         | None -> ()
         | Some (_, rest) ->
           state.msg_queued <- rest;
           let promoted =
             if explicitly_queued then
               Chat_queue.prepare_for_admission ~automatic:state.user_input_priority_next item
             else item in
           let admission_intent =
             match explicitly_queued, List.assoc_opt keeper_name state.keeper_chat_control_tokens with
             | true, Some control_token -> Keeper_chat.Interactive {control_token;target}
             | (true, None) | (false, _) -> Keeper_chat.Queue_only
           in
           (* Both admission intents enter the durable FIFO queue. Automatic
              priority is a separate request, sent only if admission reports
              Queued; a message that started or settled needs no reordering. *)
           (match promoted.intent with
            | Chat_queue.Steer_after_interrupt -> queue_run_next_on_admission state item.request
            | Chat_queue.Run_next {automatic} ->
                queue_run_next_on_admission ~automatic state item.request
            | Chat_queue.Next | Chat_queue.Next_without_auto_priority
            | Chat_queue.Steer_without_priority -> ());
           launch_keeper_request ~promoted ~admission_intent
             state ~mailbox item.request;
           let next_generation = T.keeper_chat_control_generation state keeper_name in
           state.keeper_interactive_waiting <- List.map (fun (name, id, intervention) ->
             let intervention = match intervention with
               | T.Awaiting_control held
                 when String.equal name keeper_name && held.generation = generation ->
                 T.Awaiting_control {held with generation = next_generation}
               | T.Awaiting_control _ | T.Retained_after_stop | T.Retained_before_dispatch -> intervention in
             name, id, intervention) state.keeper_interactive_waiting);
        T.Drawn_changed
  end else T.Drawn_unchanged
;;

(* For callers whose own arm already asks for a frame. *)
let launch_waiting_keeper_input (state : T.state) ~mailbox ~keeper_name =
  let (_ : T.drawn_effect) = dispatch_waiting_keeper_input state ~mailbox ~keeper_name in
  ()
;;

let start_keeper_steer ?keeper_name ?spill (state : T.state) ~base_path ~mailbox text =
  let target =
    match keeper_name with
    | Some _ as named -> named
    | None -> state.msg_target_keeper_name
  in
  match target with
  | None -> Masc_tui_loader.report_action state "error" "/steer needs a Keeper selected"
  | Some _ when state.workspace_identity <> T.Workspace_identity_match ->
      Request_notice.report_kept_back state ~request:(Masc_tui_words.Kept_request.Command "/steer") Masc_tui_words.workspace_identity_unconfirmed Masc_tui_words.Draft_kept
  | Some keeper_name when not (T.keeper_available_for_new_message state keeper_name) ->
      Masc_tui_loader.report_action state "error"
        (Printf.sprintf "Cannot steer: Keeper %s is unavailable"
           (Keeper_chat.terminal_safe_text keeper_name))
  | Some keeper_name when T.keeper_admission_pending state keeper_name ->
      Masc_tui_loader.report_action state "error"
        "Cannot steer until the earlier admission is observed · draft retained"
  | Some keeper_name when List.mem_assoc keeper_name state.keeper_chat_control_pending ->
      Masc_tui_loader.report_action state "error"
        "Cannot steer until the stop or resume is confirmed · draft retained"
  | Some keeper_name -> (
      match inflight_for state keeper_name, T.live_for_keeper state keeper_name with
      | None, _ | _, None ->
          Masc_tui_loader.report_action state "error"
            "/steer needs a turn currently streaming for this Keeper"
      | Some active_request, Some _live ->
          (match Masc_tui_chat_input.Paste_spill.prepare_spilled_paste state ~base_path ~keeper_name
              ~still_allowed:(fun () ->
                state.workspace_identity = T.Workspace_identity_match
                && T.keeper_available_for_new_message state keeper_name
                && not (T.keeper_admission_pending state keeper_name)
                && not (List.mem_assoc keeper_name state.keeper_chat_control_pending)
                && Option.exists (( = ) active_request) (inflight_for state keeper_name)
                 && Option.is_some (T.live_for_keeper state keeper_name)) spill with
           | Error detail -> Masc_tui_loader.report_action state "error" detail
           | Ok prepared ->
          let text = Masc_tui_chat_input.Paste_spill.inline_spilled_paste spill text in
          let request =
            let attachments, references = pending_attachments state in
            Keeper_chat.create_request ~attachments ~references
              ~keeper_name ~message:text ()
          in
          (match
             queue_keeper_steer state
               ~causal_parent_request_id:active_request.Keeper_chat.request_id
               request
           with
           | Error detail -> Masc_tui_loader.report_action state "error" detail
           | Ok (waiting, submitted_at) ->
             (match Chat_queue.find state.msg_queued ~request_id:request.request_id with
              | None -> Masc_tui_loader.report_action state "error" "Accepted steer is no longer in the local queue"
              | Some accepted ->
               match stage_accepted_spill state ~keeper_name
                   ~prefix:None ~prepared accepted with
               | Error detail ->
                   (match Chat_queue.find state.msg_queued ~request_id:accepted.Chat_queue.request.request_id with
                    | Some current when current.Chat_queue.request = accepted.Chat_queue.request ->
                        Chat_watching.append_user_history_once ~submitted_at state current.Chat_queue.request
                    | Some _ | None -> ());
                   Masc_tui_chat_input.Paste_spill.protect_recovered_paste_for_current_keeper state;
                   Masc_tui_loader.report_action state "error"
                     ("Steer was accepted but changed while staging; inspect the queue before retrying: " ^ detail)
               | Ok staged ->
               Chat_watching.append_user_history_once ~submitted_at state staged.request;
               Masc_tui_chat_input.Message_draft_recall.clear_staged_attachments state;
               Masc_tui_chat_input.Message_draft_recall.clear_current_message_draft state;
               Masc_tui_loader.report_action state "message"
                 (Printf.sprintf
                    "Steer staged for %s (related request %s; %d waiting); priority requested if queued"
                    (Keeper_chat.terminal_safe_text keeper_name)
                    active_request.Keeper_chat.request_id waiting);
               if run_next_busy_for state keeper_name then
                 Masc_tui_loader.report_action state "info" "A run-next request is pending; this steer remains queued"
               else
                 match Chat_queue.take state.msg_queued ~request_id:staged.request.request_id with
                 | None -> Masc_tui_loader.report_action state "error" "Steer queue changed before submission"
                 | Some (item, rest) ->
                   state.msg_queued <- rest;
                   queue_run_next_on_admission state item.request;
                   launch_keeper_request ~promoted:item state ~mailbox item.request))))
;;
(* Send one line to one keeper.

   The refusals here are about whether the message can be delivered at all: no
   keeper selected, a roster this build could not read, a keeper that is no
   longer registered. *)
let start_keeper_message ?keeper_name ?spill (state : T.state) ~base_path ~mailbox text =
  match
    match keeper_name with
    | Some _ -> keeper_name
    | None -> state.msg_target_keeper_name
  with
  | None -> Masc_tui_loader.report_action state "error" "Cannot send: no Keeper is selected"
  | Some _ when
        (match state.workspace_identity with
         | T.Workspace_identity_unread | T.Workspace_identity_mismatch _ -> true
         | T.Workspace_identity_match_unconfirmed _ | T.Workspace_identity_match -> false) ->
      (* Unread and mismatched workspaces refuse. An unconfirmed match keeps
         the last confirmed match, so the line queues and waits for the
         resume that a confirming read runs. *)
      Request_notice.report_kept_back state ~request:Masc_tui_words.Kept_request.Message Masc_tui_words.workspace_identity_unconfirmed Masc_tui_words.Draft_kept
  | Some target when Option.is_some state.keepers_error
                     && not (T.keeper_available_for_new_message state target) ->
      Masc_tui_loader.report_action state "error"
        "Cannot send while the Keeper roster is unavailable"
  | Some target when T.keeper_creation_matches state target
                     && not (T.keeper_available_for_new_message state target) ->
      Masc_tui_loader.report_action state "error"
        "Creation accepted; waiting for the current Keeper roster · draft retained · Esc then r to refresh"
  | Some target when not (T.keeper_available_for_new_message state target) ->
      Masc_tui_loader.report_action state "error"
        (Printf.sprintf "Cannot send: Keeper %s is no longer registered"
           (Keeper_chat.terminal_safe_text target))
  | Some target -> (
      (* Admission borrows the whole paste inline. Its file is staged only
         after this Keeper's queue accepts the request. *)
      match Masc_tui_chat_input.Paste_spill.prepare_spilled_paste state ~base_path ~keeper_name:target
          ~still_allowed:(fun () ->
            state.workspace_identity = T.Workspace_identity_match
             && T.keeper_available_for_new_message state target) spill with
      | Error detail -> Masc_tui_loader.report_action state "error" detail
      | Ok prepared ->
       let text = Masc_tui_chat_input.Paste_spill.inline_spilled_paste spill text in
      match T.current_recall_edit state with
      | Some editing
        when String.equal editing.Chat_queue.request.Keeper_chat.keeper_name
               target ->
          let original = editing.Chat_queue.request in
          let source = Chat_queue.source_for_edit editing ~message:text in
          let request =
            let attachments, references = pending_attachments state in
            { original with
              Keeper_chat.message = text
            ; attachments
            ; references
            }
          in
          (match
             Chat_queue.replace_recalled_request ~source state.msg_queued
               ~original:editing request
           with
           | Error detail -> Masc_tui_loader.report_action state "error" detail
           | Ok queue ->
               state.msg_queued <- queue;
               (match Chat_queue.find queue ~request_id:request.request_id with
                | None -> Masc_tui_loader.report_action state "error" "Accepted edit is no longer in the local queue"
                | Some accepted ->
                 match stage_accepted_spill state ~keeper_name:target
                     ~prefix:None ~prepared accepted with
                 | Error detail ->
                     (match Chat_queue.find state.msg_queued ~request_id:accepted.Chat_queue.request.request_id with
                      | Some current when current.Chat_queue.request = accepted.Chat_queue.request ->
                          update_queued_history_text state current.Chat_queue.request
                      | Some _ | None -> ());
                     Masc_tui_chat_input.Paste_spill.protect_recovered_paste_for_current_keeper state;
                     Masc_tui_loader.report_action state "error"
                       ("Edit was accepted but changed while staging; inspect the queue before retrying: " ^ detail)
                 | Ok staged ->
               let request = staged.Chat_queue.request in
               let text = request.Keeper_chat.message in
               Masc_tui_chat_input.Message_draft_recall.clear_staged_attachments state;
               T.clear_current_recall_edit state;
               let safe_text =
                 Keeper_chat.terminal_safe_text ~preserve_newlines:true text
               in
               state.msg_history <-
                 List.map
                   (fun (entry : T.msg_entry) ->
                     if
                       String.equal entry.me_request_id request.request_id
                       && String.equal entry.me_keeper_name request.keeper_name
                       &&
                       match entry.me_role with
                       | T.Message_user (T.Sent_by_operator _) -> true
                       | T.Message_user (T.Sent_by_other _) | T.Message_keeper
                       | T.Message_autonomous | T.Message_status | T.Message_local
                       | T.Message_error | T.Message_tool | T.Message_skill _
                       | T.Message_thinking | T.Message_memory -> false
                     then { entry with T.me_text = safe_text;
                       me_images = Masc_tui_image_preview.in_message_previews ~text:request.message
                         ~attachments:(List.map (fun a -> Masc_tui_image_preview.Staged a) request.attachments) }
                     else entry)
                   state.msg_history;
               Masc_tui_chat_input.Message_draft_recall.clear_current_message_draft state;
               Masc_tui_loader.report_action state "message"
                 (Printf.sprintf "Updated queued %s for %s"
                    (match staged.Chat_queue.intent with
                     | Chat_queue.Next | Chat_queue.Next_without_auto_priority -> "NEXT"
                     | Chat_queue.Run_next _ -> "RUN-NEXT"
                     | Chat_queue.Steer_after_interrupt | Chat_queue.Steer_without_priority -> "STEER")
                    (Keeper_chat.terminal_safe_text target));
               (* Enter on a recalled retained line explicitly releases that
                  line, while its place among other sendable lines is kept. *)
               let request_id = request.Keeper_chat.request_id in
               state.keeper_interactive_waiting <-
                 (target, request_id,
                  T.Awaiting_control {
                    generation = T.keeper_chat_control_generation state target;
                    target = None
                  }) ::
                 List.filter (fun (_, id, _) -> id <> request_id)
                   state.keeper_interactive_waiting;
               (* Editing keeps the item's queue position. A newer recalled
                  line cannot pass an older one while its admission is held. *)
               launch_waiting_keeper_input state ~mailbox ~keeper_name:target))
      | Some _ ->
          Masc_tui_loader.report_action state "error"
            "Queued edit belongs to another Keeper; switch back or press Ctrl-U"
      | None ->
        let request =
          let attachments, references = pending_attachments state in
          Keeper_chat.create_request ~attachments ~references ~keeper_name:target
            ~message:text () in
        (* Enter admits the line in queue order and interrupts nothing: the
           server's interactive admission signals only the target it is given,
           and the target is none.
           Until 2026-09-14 this derived the running chat operation or the
           observed autonomous turn as the target, so every line typed while
           the Keeper worked cancelled that work -- the footer promised "Enter
           queues your line" while the send did the opposite, and a Keeper
           mid-game lost minutes of tool work per question. Stopping a turn is
           an explicit act: Esc, or /steer. *)
        let observed_target = None in
        (* Staging keeps the accepted text and attachments together. A control
           receipt can arrive after Enter; hold only until that receipt, never
           until the previous model turn finishes. A later Esc revokes this
           pending admission while retaining the queued message itself. *)
        (match queue_keeper_message state request with
         | Error detail -> Masc_tui_loader.report_action state "error" detail
         | Ok receipt ->
           let prefix = match receipt.qmr_origin with
             | New_input _ -> None | Joined_input prefix -> Some prefix in
           (match Chat_queue.find state.msg_queued ~request_id:receipt.qmr_id with
            | None -> Masc_tui_loader.report_action state "error" "Message staging changed before submission"
            | Some accepted ->
             match stage_accepted_spill state ~keeper_name:target
                 ~prefix ~prepared accepted with
             | Error detail ->
                 (match Chat_queue.find state.msg_queued ~request_id:accepted.Chat_queue.request.request_id with
                  | Some current when current.Chat_queue.request = accepted.Chat_queue.request ->
                      publish_queued_message_history state receipt current.Chat_queue.request
                  | Some _ | None -> ());
                 Masc_tui_chat_input.Paste_spill.protect_recovered_paste_for_current_keeper state;
                 Masc_tui_loader.report_action state "error"
                   ("Input was accepted but changed while staging; inspect the queue before retrying: " ^ detail)
             | Ok item ->
              publish_queued_message_history state receipt item.request;
              Masc_tui_chat_input.Message_draft_recall.clear_staged_attachments state;
              state.keeper_observed_interrupts <- List.filter (fun (observed : T.observed_interrupt) -> observed.oi_keeper <> target)
                state.keeper_observed_interrupts;
              let request_id = item.Chat_queue.request.request_id in
              state.keeper_interactive_waiting <-
                (target, request_id, T.Awaiting_control {generation = T.keeper_chat_control_generation state target; target = observed_target}) ::
                List.filter (fun (_, id, _) -> id <> request_id) state.keeper_interactive_waiting;
              Masc_tui_chat_input.Message_draft_recall.clear_current_message_draft state;
              (match List.assoc_opt target state.keeper_chat_control_tokens with
               | Some _ ->
                 launch_waiting_keeper_input state ~mailbox ~keeper_name:target;
                 if Chat_queue.holds state.msg_queued ~request_id then
                   Masc_tui_loader.report_action state "info"
                     "Input retained locally; waiting for earlier input or control"
               | None when List.mem_assoc target state.keeper_chat_control_pending ->
                 Masc_tui_loader.report_action state "info" "Input retained; waiting for the stop or resume acknowledgement";
                 Chat_watching.launch_keeper_turns_load state ~mailbox
               | None ->
                 launch_waiting_keeper_input state ~mailbox ~keeper_name:target;
                 Masc_tui_loader.report_action state "info"
                   (if Chat_queue.holds state.msg_queued ~request_id then
                      "Input retained locally; waiting for earlier input or control"
                    else
                      "Message queued for dispatch without interruption; refreshing chat controls");
                 Chat_watching.launch_keeper_turns_load state ~mailbox))))

;;

let drain_queued_message (state : T.state) ~base_path:_ ~mailbox =
  (* Send everything that can go now, oldest first, skipping lines whose own
     keeper still has a turn running. Sending sets that keeper's in-flight, so
     the next pass will not pick it again and the walk terminates.

     Taking strictly from the front would stall the queue behind a busy
     keeper — and permanently, because the lines behind it are addressed to
     keepers that are idle and so have no settle coming to drain them.

     Recursion stays inside so the exported name has no self-call: a wiring
     test that counts calls to it would otherwise be satisfied by this
     function calling itself, and pass with nothing else calling it at all. *)
  let rec next () =
    match
      Chat_queue.take_first_sendable state.msg_queued ~sendable:(fun keeper_name ->
        T.keeper_available_for_new_message state keeper_name
        && not (T.keeper_admission_pending state keeper_name)
        && Option.is_none (inflight_for state keeper_name)
        && not (List.mem_assoc keeper_name state.keeper_chat_control_pending)
        && not (List.exists (fun (name, _, _) -> String.equal name keeper_name)
          state.keeper_interactive_waiting)
        && not (T.composing_for_keeper state keeper_name)
        && not (T.recalling_for_keeper state keeper_name))
    with
    | None -> ()
    | Some (item, rest) ->
        let request = item.Chat_queue.request in
        let keeper_name = request.Keeper_chat.keeper_name in
        if T.keeper_available_for_new_message state keeper_name
        then (
          state.msg_queued <- rest;
          (* The request that waited is the request that goes. It was built
             when the operator pressed Enter, so dispatch neither re-reads the
             staged attachments nor mints a second identity for a line the
             conversation already shows. *)
          (match item.intent with
           | Chat_queue.Steer_after_interrupt -> queue_run_next_on_admission state request
           | Chat_queue.Run_next {automatic} -> queue_run_next_on_admission ~automatic state request
           | Chat_queue.Next | Chat_queue.Next_without_auto_priority
           | Chat_queue.Steer_without_priority -> ());
          launch_keeper_request ~promoted:item state ~mailbox request;
          next ())
        else
          (* Availability is an observation, not operator cancellation. The
             queue still owns the original request until dispatch or explicit
             edit/cancel; no receipt exists that would authorize its removal. *)
          ()
  in
  if state.workspace_identity = T.Workspace_identity_match
     && Option.is_none state.keepers_error then begin
    (* Releasing a recalled edit may be the only event after its predecessor
       was accepted. Revisit explicit Enter admission as well as unmarked
       input; the admission path still owns control and transport checks. *)
    let waiting_keepers = Chat_queue.waiting state.msg_queued
      |> List.map (fun (item : Chat_queue.item) -> item.request.keeper_name)
      |> List.sort_uniq String.compare in
    List.iter (fun keeper_name ->
      launch_waiting_keeper_input state ~mailbox ~keeper_name) waiting_keepers;
    next ()
  end
;;
