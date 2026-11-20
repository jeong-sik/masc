module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Tui_decode_asks = Masc.Tui_decode_asks
module Ask = Masc_tui_ask_projection
module Ask_followup_observation = Masc_tui_ask_followup_observation
module Ask_answer_observation = Masc_tui_types.Ask_answer_observation
module Ask_answer_receipt = Masc_tui_types.Ask_answer_receipt
module Ask_answer_completion = Masc_tui_types.Ask_answer_completion
module Snapshot_read = Masc_tui_types.Snapshot_read
module Kept_request = Masc_tui_words.Kept_request

(* The reads a full refresh tick sends beside its surface bundle. They go out
   while the bundle is still on the wire, so a bundle that moves the read
   authority withdraws them; [resume_reads_after_authority_change] sends
   them again from this same list. *)
let launch_ask_followup_load (state : T.state) ~mailbox =
  if state.T.view = T.Approvals && T.server_authority_ready state then begin
    let admission_started_ns=Mtime_clock.elapsed_ns () in
    match state.T.server_identity, T.begin_ask_followup_read state with
    | Some expected_workspace, Some (request, submission, keeper_name) ->
        let origin=Masc_tui_observation_origin.capture state.T.observation_instance ~expected_workspace in
        let admission_capture=Option.map (fun store ->
          Masc_tui_observation_store.record_admission store ~origin
            ~request:(Snapshot_read.request_id request) ~admission_started_ns) state.T.observation_store in
        let read=P.capture_ask_followup_read ~origin ~request ~submission
          ~admission_started_ns ~admission_capture in
        let host=Masc_tui_transport.Workspace_admission.server_peer_host and port=state.T.port in
        let clock=Eio_context.get_clock_opt () in
        let envelope=P.capture_workspace_message state in
        let superseded,resolve=Eio.Promise.create () in
        T.supersede_ask_followup_worker state
          (Some (request,fun detail -> ignore (Eio.Promise.try_resolve resolve detail)))
          ~detail:"answer follow-up observation superseded";
        let finish ()=T.finish_ask_followup_worker state request in
        Ask_followup_observation.emit read ~sources:(T.current_ask_followup state)
          Ask_followup_observation.Followup_read_started;
        Masc_tui_transport.Workspace_admission.launch_observation state ~mailbox
          ~on_not_run:finish ~boundary_error:(fun detail -> Ask.Followup_read_failed detail)
          ~observe_job:(fun event -> Ask_followup_observation.emit read ~sources:None (Ask_followup_observation.Followup_job_event event))
          ~not_started:(fun detail -> Ask.Followup_not_started detail)
          ~cancelled:(envelope (P.Ask_msg (P.Ask_followup_finished (read,Error Ask.Followup_cancelled))))
          ~progress:(fun (event,received_ns) -> envelope (P.Ask_msg (P.Ask_followup_observed (read,event,received_ns))))
          ~deliver:(fun result -> envelope (P.Ask_msg (P.Ask_followup_finished (read,result))))
          (fun publish -> Fun.protect ~finally:finish (fun () ->
            Ask_followup_observation.emit read ~sources:None Ask_followup_observation.Followup_worker_entered;
            let result=try match clock with
              | None -> Error (Ask.Followup_read_failed "Eio clock is unavailable for answer follow-up observation")
              | Some clock -> Eio.Fiber.first
                (fun () -> Masc_tui_http.observe_keeper_ask_followup ~clock ~expected_workspace
                  ~keeper_name ~ask_id:submission.T.as_ask_id ~host ~port
                  ~on_event:(fun event -> publish (event,Mtime_clock.elapsed_ns ()))
                  |> Result.map_error (fun detail -> Ask.Followup_read_failed detail))
                (fun () -> let _detail=Eio.Promise.await superseded in Error Ask.Followup_withdrawn)
              with
              | Eio.Cancel.Cancelled _ as exn ->
                let backtrace=Printexc.get_raw_backtrace () in
                Ask_followup_observation.emit read ~sources:None Ask_followup_observation.Followup_producer_cancelled;
                Printexc.raise_with_backtrace exn backtrace
              | exn -> Error (Ask.Followup_read_failed (Printexc.to_string exn)) in
            Ask_followup_observation.emit read ~sources:None (Ask_followup_observation.Followup_producer_returned result);
            result))
    | None, _ | Some _, None -> ()
  end

let inspect_selected_ask_origin (state : T.state) ~mailbox =
  if not (T.server_authority_ready state) then
    Masc_tui_loader.report_action state "system"
      (let ko = state.T.ui_language = T.Lang_ko in
       Masc_tui_words.kept_back ~ko ~request:Kept_request.Ask_source (Masc_tui_words.workspace_identity_unconfirmed ~ko) Masc_tui_words.Nothing_kept)
  else match T.selected_ask_origin state with
  | None -> Masc_tui_loader.report_action state "system" "No question source is available"
  | Some origin ->
      (match origin.Ask.ao_source_turn_ref with
       | None -> Masc_tui_loader.report_action state "system" "The question did not record a calling turn"
       | Some turn_ref ->
           state.T.ask_origin <- Some (state.T.workspace_authority, origin);
           Masc_tui_chat_dispatch.Chat_journals.open_context_inspector ~target:(Masc_tui_context_inspector.Pinned turn_ref)
             state ~mailbox ~keeper_name:origin.Ask.ao_keeper_name;
           Log.Transport.info "tui_ask_source_inspect=%s"
             (Yojson.Safe.to_string (`Assoc
               [ "requested_ns", `String (Int64.to_string (Mtime_clock.elapsed_ns ()))
               ; "origin", Ask.origin_to_json origin ])))

(* Leaving the mode drops the draft. An answer half-written against a question
   the operator walked away from is not a thing to restore later; the Keeper
   is still waiting either way, and the row says so. *)
let leave_ask_answering state = Masc_tui_home.clear_ask_answering state

let enter_ask_answering (state : T.state) =
  match T.selected_ask_row state with
  | None -> (
      (* Nothing is selected while asks are open: the cursor was released,
         or it points past the list. Either way [ or ] selects one. *)
      match T.open_ask_rows state with
      | _ :: _ -> Masc_tui_loader.report_action state "system" "Choose a question with [ or ] first"
      | [] -> Masc_tui_loader.report_action state "system" "No question is waiting on you")
  | Some (row : Tui_decode_asks.ask_row) ->
      (* The answer flow is drawn by the approvals list. With an approval's
         detail open that surface is not on screen, so [a] used to set the mode
         and change nothing an operator could see -- the keypress landed and
         the questions stayed hidden. Close the detail, which is where the
         operator asked to go. *)
      state.T.approval_detail_open <- false;
      state.T.approval_value_reading <- None;
      state.T.ask_answer_mode <- T.Ask_answering { aam_ask = Tui_decode_asks.ask_key row };
      state.T.ask_question_cursor <- 0;
      state.T.ask_question_scroll <- 0;
      state.T.ask_draft <- Some (Ask.draft_for state.T.ask_draft ~row);
      T.disarm_ask_submit state

(* Walking to another ask starts a new draft rather than carrying the old one
   across: [draft_for] keys on the ask, so the answer cannot land under a
   question the operator never read. *)
let move_ask_cursor (state : T.state) delta =
  let rows = T.open_ask_rows state in
  let next = Ask.move_cursor rows state.T.ask_cursor ~delta in
  if next <> state.T.ask_cursor then begin
    state.T.ask_cursor <- next;
    state.T.ask_origin <- None;
    state.T.ask_question_cursor <- 0;
    state.T.ask_question_scroll <- 0;
    T.disarm_ask_submit state;
    match (state.T.ask_answer_mode, Ask.selected_row rows next) with
    (* Walking the list while browsing is not answering. Opening a draft
       here would make [ and ] commit to a question the operator was only
       looking at, and [a] is the key that says they mean it. *)
    | T.Ask_browsing, _ -> ()
    | T.Ask_answering _, None -> ()
    | T.Ask_answering _, Some (row : Tui_decode_asks.ask_row) ->
        state.T.ask_answer_mode <- T.Ask_answering { aam_ask = Tui_decode_asks.ask_key row };
        state.T.ask_draft <- Some (Ask.draft_for state.T.ask_draft ~row)
  end

let move_ask_question_cursor (state : T.state) delta =
  match T.selected_ask_row state with
  | None -> ()
  | Some (row : Tui_decode_asks.ask_row) ->
      let count = List.length row.Tui_decode_asks.ar_questions in
      if count > 0 then begin
        state.T.ask_question_cursor <-
          max 0 (min (count - 1) (state.T.ask_question_cursor + delta));
        state.T.ask_question_scroll <- 0
      end

let with_ask_draft (state : T.state) f =
  match (T.selected_ask_row state, T.selected_ask_question state) with
  | Some row, Some question ->
      let draft = Ask.draft_for state.T.ask_draft ~row in
      state.T.ask_draft <- Some (f draft question);
      (* Editing after arming means the armed answer is not the one on screen
         any more, so the next press arms again rather than sending. *)
      T.disarm_ask_submit state
  | (Some _ | None), _ -> ()

let toggle_ask_choice state index =
  match T.selected_ask_question state with
  | None -> ()
  | Some (question : Tui_decode_asks.ask_question) -> (
      match List.nth_opt question.Tui_decode_asks.aq_choices index with
      | None -> ()
      | Some choice ->
          with_ask_draft state (fun draft question ->
              Ask.toggle_choice draft ~question ~choice))

(* Open the editor on the question under the cursor.

   A question can arrive with no choices at all -- the domain accepts one as
   long as it welcomes free text -- and on those the digits answer nothing.
   Until this key existed the panel drew "free text welcome" beside a keyboard
   that had no way to write any, so the only answer the terminal could give
   such a question was [s]: skipped. The dashboard has had a textarea for it
   since the surface shipped.

   Reopening on an answer already written starts from that text rather than
   from blank: a typo in a long answer should cost a backspace, not the whole
   sentence. *)
let begin_ask_text_entry (state : T.state) =
  match (T.selected_ask_row state, T.selected_ask_question state) with
  | Some row, Some question ->
      let slot = Ask.free_text_slot ~ask:(Tui_decode_asks.ask_key row) question in
      let existing =
        match Ask.response_for (Ask.draft_for state.T.ask_draft ~row) ~question with
        | Some (Ask.Draft_wrote text) -> text
        | Some (Ask.Draft_chose _) | Some Ask.Draft_skipped | None -> ""
      in
      state.T.ask_text_entry <- Some { T.ate_slot = slot; ate_text = existing }
  | (Some _ | None), _ -> ()

(* Typing edits the buffer alone. The draft is written once, on the key that
   closes the editor, so a half-typed answer is never a response the submit
   gate would count as answered. *)
let edit_ask_text (state : T.state) f =
  match state.T.ask_text_entry with
  | None -> ()
  | Some entry -> state.T.ask_text_entry <- Some { entry with T.ate_text = f entry.T.ate_text }

let commit_ask_text_entry (state : T.state) =
  match state.T.ask_text_entry with
  | None -> ()
  | Some entry ->
      (* Through the slot, which names its own ask and question: a snapshot
         arriving while the operator typed may have moved the cursor, even to
         another ask whose question carries the same id (masc_ask numbers
         every ask from q1), and the answer belongs to the question the editor
         was opened on. So the ask is looked up by the slot's key, not taken
         from the cursor. Blank text clears the response rather than recording
         one -- an editor emptied by backspaces means unanswered, and the
         domain refuses a blank write. *)
      let ask = Ask.free_text_ask entry.T.ate_slot in
      (match
         List.find_opt
           (fun row -> Tui_decode_asks.(equal_ask_key ask (ask_key row)))
           (T.open_ask_rows state)
       with
       | Some row ->
           let draft = Ask.draft_for state.T.ask_draft ~row in
           state.T.ask_draft <- Some (Ask.set_text draft ~slot:entry.T.ate_slot ~text:entry.T.ate_text);
           T.disarm_ask_submit state
       | None ->
           Masc_tui_loader.report_action state "system"
             "The question you were writing to is no longer open; the text was not recorded");
      state.T.ask_text_entry <- None

let cancel_ask_text_entry (state : T.state) = state.T.ask_text_entry <- None

let skip_ask_question state =
  with_ask_draft state (fun draft question -> Ask.skip draft ~question)

let clear_ask_question state =
  with_ask_draft state (fun draft question -> Ask.clear draft ~question)

let log_ask_answer_observation observation =
  Log.Transport.info "tui_ask_answer_lifecycle=%s"
    (Yojson.Safe.to_string (Ask_answer_observation.to_json observation))

let observe_ask_answer_call submission call operation =
  let started_ns = Mtime_clock.elapsed_ns () in
  log_ask_answer_observation (Ask_answer_observation.make submission ~at_ns:started_ns (Ask_answer_observation.Call_started call));
  match operation () with
  | result ->
    log_ask_answer_observation (Ask_answer_observation.make submission ~at_ns:(Mtime_clock.elapsed_ns ())
      (Ask_answer_observation.Call_finished {call; started_ns; outcome=Ask_answer_observation.outcome_of_result result}));
    result
  | exception error ->
    let backtrace = Printexc.get_raw_backtrace () in
    let outcome = match error with Eio.Cancel.Cancelled _ -> Ask_answer_observation.Cancelled
      | _ -> Ask_answer_observation.Raised in
    let emit () =
      log_ask_answer_observation (Ask_answer_observation.make submission ~at_ns:(Mtime_clock.elapsed_ns ())
        (Ask_answer_observation.Call_finished {call; started_ns; outcome})) in
    (match Fs_compat.execution_context () with
     | Fs_compat.Non_eio -> emit ()
     | Fs_compat.Eio_fiber -> Eio.Cancel.protect emit);
    Printexc.raise_with_backtrace error backtrace

let observe_ask_answer_receipt state (submission : T.ask_submission) result =
  Option.iter (fun feedback ->
    Log.Transport.info "tui_ask_answer_receipt=%s"
      (Yojson.Safe.to_string (`Assoc
        [ "phase", `String "receipt_admitted"
        ; "submission_started_ns", `String (Int64.to_string submission.T.as_started_ns)
        ; "result_observed_ns", (match Ask_answer_receipt.read submission.T.as_receipt with
            | Ask_answer_receipt.Returned observation -> `String (Int64.to_string observation.Ask_answer_receipt.observed_ns)
            | Ask_answer_receipt.Waiting | Ask_answer_receipt.Closed_without_result -> `Null)
        ; "admitted_ns", `String (Int64.to_string (Mtime_clock.elapsed_ns ()))
        ; "receipt", Ask.answer_feedback_to_json feedback ])))
    (T.retain_ask_answer_feedback state submission result)

let apply_ask_answer_receipt state submission ~mailbox =
  match T.take_ask_answer_receipt state submission with
  | None -> ()
  | Some (owner, observation) ->
    observe_ask_answer_receipt state owner observation.Ask_answer_receipt.result;
    if T.owns_ask_submission state owner then
      launch_ask_followup_load state ~mailbox

let apply_ask_answer_completion ~settle_asks (state : T.state) (submission : T.ask_submission) result asks =
  let answered_label = submission.T.as_answered_label in
  observe_ask_answer_receipt state submission result;
  Option.iter log_ask_answer_observation
    (T.observe_ask_reread_completion state submission
      ~at_ns:(Mtime_clock.elapsed_ns ()) asks);
  state.T.ask_submit_inflight <- false;
  T.disarm_ask_submit state;
  let close_draft () =
    state.T.ask_draft <- None;
    state.T.ask_answer_mode <- T.Ask_browsing
  in
  let report_delivery ~already = function
    | Tui_decode_asks.Ask_wake_stored ->
        Masc_tui_loader.report_action state "system"
          (if already then "Question already answered; keeper wake stored"
           else Printf.sprintf "Answer recorded; keeper wake stored: %s" answered_label)
    | Tui_decode_asks.Ask_wake_pending detail ->
        Masc_tui_loader.report_action state "error"
          (if already then
             Printf.sprintf "Question already answered; delivery pending, automatic recovery will retry: %s" detail
           else
             Printf.sprintf "Answer recorded; delivery pending: %s; automatic recovery will retry: %s"
               answered_label detail)
  in
  (match result with
   | Ok (Tui_decode_asks.Keeper_answer_receipt (Tui_decode_asks.Ask_answer_recorded delivery)) ->
       close_draft ();
       report_delivery ~already:false delivery
   | Ok (Tui_decode_asks.Keeper_answer_receipt (Tui_decode_asks.Ask_answer_already_recorded { aar_delivery; _ })) ->
       close_draft ();
       report_delivery ~already:true aar_delivery
   | Ok (Tui_decode_asks.Keeper_answer_receipt (Tui_decode_asks.Ask_answer_written_unconfirmed detail)) ->
       Masc_tui_loader.report_action state "error"
         (Printf.sprintf "Answer log write confirmed; winning answer unconfirmed: %s" detail)
   | Ok (Tui_decode_asks.Keeper_answer_receipt (Tui_decode_asks.Ask_answer_refused detail))
   | Ok (Tui_decode_asks.Installation_answer_receipt (Tui_decode_asks.Installation_answer_refused detail)) ->
       Masc_tui_loader.report_action state "error" (Printf.sprintf "Answer refused: %s" detail)
   | Ok (Tui_decode_asks.Installation_answer_receipt Tui_decode_asks.Installation_answer_recorded) ->
       close_draft ();
       Masc_tui_loader.report_action state "system" (Printf.sprintf "Answer recorded: %s" answered_label)
   | Ok (Tui_decode_asks.Installation_answer_receipt (Tui_decode_asks.Installation_answer_already_answered _)) ->
       close_draft ();
       Masc_tui_loader.report_action state "system" "Question already answered; the earlier answer stands"
   | Ok (Tui_decode_asks.Installation_answer_receipt (Tui_decode_asks.Installation_answer_withdrawn _)) ->
       close_draft ();
       Masc_tui_loader.report_action state "system" "The installation withdrew this question"
   | Error (T.Request_failed err) ->
       (* A lost or invalid response cannot establish that the write did not
          land. Keep the draft and read the canonical questions again. *)
       Masc_tui_loader.report_action state "error" (Printf.sprintf "Answer recording unconfirmed: %s" err)
   | Error (T.Request_withdrawn refusal) ->
       (* The guard stopped the answer before it left: kept back, with the
          draft it kept, never an unconfirmed recording (RFC §2). *)
       Masc_tui_transport.Request_notice.report_kept_back state ~request:Kept_request.Ask_answer
         (fun ~ko -> T.workspace_refusal_reason ~ko refusal) Masc_tui_words.Draft_kept);
  settle_asks state asks

(* TEL-OK: the TUI-local submit gate emits user-visible events here; the
   ask-answer endpoint owns the durable answer telemetry. *)
let start_ask_answer (state : T.state) ~asker ~ask_id ~source_turn_ref ~answered_label ~answers ~mailbox =
  let authority = state.T.workspace_authority in
  let reading = if T.server_authority_ready state then Some state.T.workspace_read_authority else None in
  let identity = state.T.server_identity in
  let submission = { T.as_request = ref (); as_started_ns = Mtime_clock.elapsed_ns ();
    as_receipt = Ask_answer_receipt.create ();
    as_completion = Ask_answer_completion.create ();
    as_authority = authority; as_reading = reading; as_asker = asker;
    as_ask_id = ask_id; as_source_turn_ref = source_turn_ref; as_answered_label = answered_label } in
  if state.T.workspace_identity <> T.Workspace_identity_match then
    Masc_tui_transport.Request_notice.report_kept_back state ~request:Kept_request.Ask_answer Masc_tui_words.workspace_identity_unconfirmed Masc_tui_words.Draft_kept
  else begin
  Masc_tui_work_requests.Approval_gate_requests.supersede_home_decision_receipt state;

  (match state.T.task_inspection_reader with
   | Some {T.tci_original=T.Answered_ask_owner _;_} -> Masc_tui_chat_dispatch.Task_dispatch.cancel_task_inspection_read state
   | Some {tci_original=T.Created_task_owner _;_} | None -> ());
  T.begin_ask_submission_state ~submission state;
  log_ask_answer_observation (Ask_answer_observation.make submission ~at_ns:submission.T.as_started_ns Ask_answer_observation.Submitted);
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.T.port in
  let check = Masc_tui_transport.Workspace_admission.admission_sequence state ~mailbox ~authority ~identity ~host ~port in
  let run_action () =
    Fun.protect ~finally:(fun () -> T.close_ask_submission submission) (fun () ->
    let result =
      try
        let open Result.Syntax in
        (* A refusal of the workspace guard stays typed: the answer was not
           sent (RFC §2). *)
        let* () = observe_ask_answer_call submission Ask_answer_observation.Workspace_check (fun () ->
          check () |> Result.map_error (fun refusal -> T.Request_withdrawn refusal)) in
        observe_ask_answer_call submission Ask_answer_observation.Answer_post (fun () ->
          (* The asker decides the route; each route's receipt keeps its kind. *)
          let result = match asker with
            | Tui_decode_asks.Ask_keeper keeper_name ->
                Masc_tui_http.post_keeper_ask_answer ~host ~port ~keeper_name ~ask_id ~answers ~session_id:None
                |> Result.map (fun receipt -> Tui_decode_asks.Keeper_answer_receipt receipt)
            | Tui_decode_asks.Ask_installation { ai_declaration_id; _ } ->
                Masc_tui_http.post_installation_ask_answer ~host ~port ~declaration_id:ai_declaration_id
                  ~ask_id ~answers ~session_id:None
                |> Result.map (fun receipt -> Tui_decode_asks.Installation_answer_receipt receipt) in
          let result = Result.map_error (fun detail -> T.Request_failed detail) result in
          (* Keep the actual POST result before even the observation logger can
             yield. The outer publication also covers pre-POST failures. *)
          ignore (Ask_answer_receipt.publish submission.T.as_receipt
            ~observed_ns:(Mtime_clock.elapsed_ns ()) result);
          result)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (T.Request_failed (Printexc.to_string exn))
    in
    (* Publish before any queue wait. UI drain owns admission; the original
       operation proceeds straight to canonical reread, even with a full mailbox. *)
    ignore (Ask_answer_receipt.publish submission.T.as_receipt
      ~observed_ns:(Mtime_clock.elapsed_ns ()) result);
    let publish_completion asks =
      ignore (Ask_answer_completion.publish submission.T.as_completion
        ~observed_ns:(Mtime_clock.elapsed_ns ()) ~receipt:result ~asks);
      asks in
    let asks =
      try
        let open Result.Syntax in
        let* expected_workspace = match identity with
          | Some identity -> Ok identity
          | None -> Error "Server workspace identity is unavailable" in
        observe_ask_answer_call submission Ask_answer_observation.Asks_reread (fun () ->
          let asks = Masc_tui_http.fetch_asks ~expected_workspace ~host ~port () in
          publish_completion asks)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error ("asks reload failed: " ^ Printexc.to_string exn)
    in
    ignore (publish_completion asks))
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Masc_tui_transport.Workspace_admission.fork_job state ~mailbox ~sw
      ~on_withdrawn:(fun () -> T.close_ask_submission submission) run_action
  | None -> run_action ()
  end

let handle_ask_submit (state : T.state) ~mailbox =
  if state.T.workspace_identity <> T.Workspace_identity_match then
    Masc_tui_transport.Request_notice.report_kept_back state ~request:Kept_request.Ask_answer Masc_tui_words.workspace_identity_unconfirmed Masc_tui_words.Draft_kept
  else
  match state.T.asks_error with
  | Some _ -> Masc_tui_loader.report_action state "error" "Question source unavailable; refresh before answering"
  | None ->
  match T.selected_ask_row state with
  | None -> ()
  | Some (row : Tui_decode_asks.ask_row) -> (
      let draft = Ask.draft_for state.T.ask_draft ~row in
      match Ask.readiness draft ~row with
      | Ask.Not_open ->
          Masc_tui_loader.report_action state "system" "That question already has an answer"
      | Ask.Missing questions ->
          (* Every gap at once: the domain reports them together, so an
             operator does not learn about the second one after fixing the
             first. *)
          Masc_tui_loader.report_action state "system"
            (Printf.sprintf "Still unanswered: %s"
               (String.concat ", "
                  (List.map
                     (fun (q : Tui_decode_asks.ask_question) -> q.Tui_decode_asks.aq_header)
                     questions)))
      | Ask.Ready answers -> (
          (* Name the Keeper and what was chosen, not the ask's opaque id. The
             arming press says it too: the second press sends whatever is on
             this line, so it is the last place to see which question and
             which choice it is before the answer settles. *)
          let asker_label = Tui_decode_asks.ask_asker_label row.Tui_decode_asks.ar_asker in
          let answered_label =
            match Ask.summarize_answer draft ~row with
            | "" -> asker_label
            | chosen -> Printf.sprintf "%s: %s" asker_label chosen
          in
          match
            Ask.gate_transition ~inflight:state.T.ask_submit_inflight
              ~pending:state.T.pending_ask_submit ~ask:(Tui_decode_asks.ask_key row)
          with
          | Ask.Ask_gate_blocked_inflight ->
              T.disarm_ask_submit state;
              Masc_tui_loader.report_action state "system" "An answer is already on its way"
          | Ask.Ask_gate_arm ask ->
              state.T.pending_ask_submit <- Some ask;
              Masc_tui_loader.report_action state "system" (T.armed_ask_submit_notice answered_label)
          | Ask.Ask_gate_submit ->
              start_ask_answer state ~asker:row.Tui_decode_asks.ar_asker
                ~ask_id:row.Tui_decode_asks.ar_id
                ~source_turn_ref:row.Tui_decode_asks.ar_source_turn_ref
                ~answered_label ~answers ~mailbox))
