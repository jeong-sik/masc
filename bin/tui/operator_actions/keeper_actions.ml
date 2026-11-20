module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Keeper_control = Masc_tui_keeper_control
module Snapshot_read = Masc_tui_types.Snapshot_read
module Kept_request = Masc_tui_words.Kept_request

(* Run one lifecycle action's steps against the server.

   The steps come from [Keeper_control.plan]; this only performs them and
   reports the first answer that ends the sequence. The 409 branch is the one
   piece of routing here: /boot refuses a keeper whose owner is durably
   paused, and the pause only clears through the directive endpoint, so a
   conflict on an action that names a recovery continues into it instead of
   surfacing as a failure. Recovery runs once — a conflict raised by the
   recovery itself is the operator's to read. *)
let run_keeper_action_steps ~check_request ~kept_back ~later_step_kept_back ~host ~port ~keeper_name
    ~operator_operation_id ~expected_workspace action =
  (* The transport answers in text, not HTTP; what it says is carried as it
     came. *)
  let unanswered result = Result.map_error (fun text -> Keeper_control.No_answer text) result in
  (* Before the first step leaves, a guard refusal is kept back: nothing was
     sent. A refusal of a later step stops an action whose earlier step did
     leave, so it is kept back as that later step, never as a step with no
     answer. *)
  let sent = ref false in
  let admit () =
    match check_request () with
    | Ok () -> Ok ()
    | Error refusal when not !sent -> Error (kept_back refusal)
    | Error refusal -> Error (later_step_kept_back refusal)
  in
  let perform = function
    | Keeper_control.Lifecycle lifecycle_action ->
        unanswered
          (Masc_tui_http.post_keeper_lifecycle ~host ~port ~keeper_name
             ~action:lifecycle_action ~expected_workspace)
    | Keeper_control.Directive directive_action ->
        unanswered
          (Masc_tui_http.post_keeper_directive ~host ~port ~keeper_name
             ~action:directive_action ~operator_operation_id ~expected_workspace)
    | Keeper_control.Purge ->
        unanswered
          (Masc_tui_http.post_keeper_purge ~host ~port ~keeper_name ~expected_workspace)
  in
  let rec walk ~recovery_available last_outcome steps =
    match steps with
    | [] -> (
        match last_outcome with
        | Some outcome -> Ok outcome
        | None ->
            (* [plan] never returns an empty step list; if it ever did, an
               empty walk must not read as success. *)
            Error Keeper_control.Empty_plan)
    | step :: rest -> (
        match Result.bind (admit ()) (fun () -> sent := true; perform step) with
        | Error failure -> Error failure
        | Ok (status, body) -> (
            let outcome = match step with
              | Keeper_control.Purge -> Keeper_control.classify_purge_response ~keeper_name ~status ~body
              | Keeper_control.Lifecycle _ | Keeper_control.Directive _ -> Keeper_control.classify_response ~status ~body in
            match outcome with
            | (Keeper_control.Accepted _ | Keeper_control.Purge_accepted _) as outcome ->
                walk ~recovery_available (Some outcome) rest
            | Keeper_control.Committed_followup_failed detail as outcome -> (
                match rest with
                | _ :: _ -> walk ~recovery_available (Some outcome) rest
                | [] -> Error (Keeper_control.Followup_failed detail))
            | Keeper_control.Paused_owner_conflict detail -> (
                match
                  ( recovery_available
                  , Keeper_control.recovers_from_conflict action )
                with
                | true, Some recovery_steps ->
                    walk ~recovery_available:false last_outcome recovery_steps
                | true, None | false, _ ->
                    Error (Keeper_control.Refused { status; detail }))
            | Keeper_control.Rejected { status; detail } ->
                Error (Keeper_control.Refused { status; detail })
            | Keeper_control.Unbound_purge_receipt { status } ->
                Error (Keeper_control.Unbound_receipt status)))
  in
  walk ~recovery_available:true None (Keeper_control.plan action)

let apply_keeper_action_result (state : T.state) ~base_path ~mailbox keeper_name action result =
  state.T.keeper_action_inflight <- None;
  let ko = state.T.ui_language = T.Lang_ko in
  let label = Keeper_control.action_label ~ko action in
  (match result with
   | Ok (Keeper_control.Purge_accepted { operation_id }) ->
       Masc_tui_loader.report_action state "system"
         (Printf.sprintf
            (if ko then "%s 삭제 접수됨 (요청 %s) · 종료와 정리는 아직 확인 전"
             else "%s deletion requested (operation %s); shutdown and cleanup are not yet confirmed")
            keeper_name operation_id)
   | Ok (Keeper_control.Accepted { already_live = true }) ->
       Masc_tui_loader.report_action state "system"
         (Printf.sprintf
            (if ko then "%s 이미 실행 중 · 새로 띄우지 않고 깨움"
             else "%s was already running; woke it instead of starting a second fiber")
            keeper_name)
   | Ok (Keeper_control.Accepted { already_live = false }) ->
       Masc_tui_loader.report_action state "system"
         (Printf.sprintf (if ko then "%s %s 접수됨" else "%s %s accepted") keeper_name label)
   | Ok (Keeper_control.Paused_owner_conflict detail)
   | Ok (Keeper_control.Committed_followup_failed detail)
   | Ok (Keeper_control.Rejected { detail; _ }) ->
       (* [run_keeper_action_steps] returns these as [Error]; keeping the
          branch exhaustive rather than wildcarded means a future outcome
          member has to be answered here too. *)
       Masc_tui_loader.report_action state "error"
         (Printf.sprintf (if ko then "%s %s 거절: %s" else "%s %s refused: %s")
            keeper_name label detail)
   | Ok (Keeper_control.Unbound_purge_receipt { status }) ->
       Masc_tui_loader.report_action state "error"
         (Printf.sprintf (if ko then "%s %s 거절: %s" else "%s %s refused: %s")
            keeper_name label
            (Keeper_control.failure_text ~ko (Keeper_control.Unbound_receipt status)))
   | Error (Keeper_control.Kept_back notice) ->
       (* Not sent: the kept-back notice alone, with the Keeper after it
          (RFC §2). *)
       Masc_tui_loader.report_action state "error" (notice ^ " · " ^ keeper_name)
   | Error (Keeper_control.Later_step_kept_back notice) ->
       (* The later step's kept-back notice, the Keeper, and that an earlier
          step was sent (RFC §2). *)
       Masc_tui_loader.report_action state "error"
         (notice ^ " · " ^ keeper_name ^ " · " ^ Keeper_control.earlier_step_sent ~ko)
   | Error
       (( Keeper_control.Empty_plan | Keeper_control.Followup_failed _
        | Keeper_control.Refused _ | Keeper_control.Unbound_receipt _
        | Keeper_control.No_answer _ ) as failure) ->
       Masc_tui_loader.report_action state "error"
         (Printf.sprintf (if ko then "%s %s 실패: %s" else "%s %s failed: %s")
            keeper_name label (Keeper_control.failure_text ~ko failure)));
  (* The accepted action may change Keeper metadata and release Task work.
     Each local source starts a fresh owned read; the HTTP roster refresh is
     independent and no directory scan runs in this result handler. *)
  Masc_tui_transport.Local_sources.launch_workspace_read state ~mailbox ~intent:Snapshot_read.Refresh base_path

let start_keeper_action (state : T.state) ~base_path:_ ~mailbox keeper_name action =
  let refuse () =
    state.T.keeper_action_pending <- None;
    Masc_tui_transport.Request_notice.report_kept_back state ~request:Kept_request.Keeper_action Masc_tui_words.workspace_identity_unconfirmed Masc_tui_words.Nothing_kept in
  (* The requests carry the identity this admission confirmed. *)
  match state.T.server_identity with
  | None -> refuse ()
  | Some _ when not (T.server_authority_ready state) -> refuse ()
  | Some expected_workspace ->
  let origin = state.T.server_identity in
  let enqueue_async = Masc_tui_transport.Workspace_admission.workspace_enqueue state in
  let authority = state.T.workspace_authority in
  let identity = state.T.server_identity in
  state.T.keeper_action_inflight <- Some (keeper_name, action);
  state.T.keeper_action_pending <- None;
  Masc_tui_loader.report_action ~show_in_footer:false state "system"
    (let ko = state.T.ui_language = T.Lang_ko in
     let gerund = Keeper_control.action_gerund ~ko action in
     if ko then Printf.sprintf "%s %s" keeper_name gerund
     else Printf.sprintf "%s %s" gerund keeper_name);
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.T.port in
  let operator_operation_id =
    Keeper_control.mint_operation_id ()
  in
  let check_request =
    Masc_tui_transport.Workspace_admission.admission_sequence state ~mailbox ~authority ~identity ~host ~port
  in
  let kept_back refusal =
    Keeper_control.Kept_back
      (T.workspace_refusal_text ~ko:(state.T.ui_language = T.Lang_ko)
         ~request:Kept_request.Keeper_action refusal)
  in
  let later_step_kept_back refusal =
    Keeper_control.Later_step_kept_back
      (T.workspace_refusal_text ~ko:(state.T.ui_language = T.Lang_ko)
         ~request:Kept_request.Keeper_action_step refusal)
  in
  let run_action () =
    let result =
      try
        run_keeper_action_steps ~check_request ~kept_back ~later_step_kept_back ~host ~port ~keeper_name
          ~operator_operation_id ~expected_workspace action
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Keeper_control.No_answer (Printexc.to_string exn))
    in
    enqueue_async mailbox (P.Keeper_msg (P.Keeper_action_done (origin, keeper_name, action, result)))
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Masc_tui_transport.Workspace_admission.fork_job state ~mailbox ~sw run_action
  | None ->
      let result =
        try
          run_keeper_action_steps ~check_request ~kept_back ~later_step_kept_back ~host ~port ~keeper_name
            ~operator_operation_id ~expected_workspace action
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Keeper_control.No_answer (Printexc.to_string exn))
      in
      enqueue_async mailbox (P.Keeper_msg (P.Keeper_action_done (origin, keeper_name, action, result)))

(* Said by every keypress gate that finds nothing under the cursor. One name
   rather than the sentence written twice: the two gates have to answer the
   same way, and a test can ask whether each of them reaches this. *)
let no_keeper_under_cursor ~ko =
  if ko then "커서 아래 키퍼 없음 · r 로 목록 다시 읽기"
  else "no keeper under the cursor; r to reload the roster"

(* The keypress path. The reading decides which actions exist at all, so a key
   that names an action the reading does not offer says why instead of sending
   a request the server would refuse. *)
let handle_keeper_action (state : T.state) ~base_path ~mailbox action =
  match state.T.workspace_identity with
  | T.Workspace_identity_unread ->
      Masc_tui_transport.Request_notice.report_kept_back state ~request:Kept_request.Keeper_action Masc_tui_words.workspace_identity_unread Masc_tui_words.Nothing_kept
  | T.Workspace_identity_match_unconfirmed _ ->
      Masc_tui_transport.Request_notice.report_kept_back state ~request:Kept_request.Keeper_action Masc_tui_words.workspace_identity_unconfirmed Masc_tui_words.Nothing_kept
  | T.Workspace_identity_match | T.Workspace_identity_mismatch _ ->
  match T.selected_keeper state with
  | None ->
    (* A keypress with nothing under the cursor said nothing at all, which
       reads as a key that does not exist. The comment above already holds
       this rule for the next gate -- an action the reading does not offer
       says why -- and this gate is the one the operator reaches first. *)
    Masc_tui_loader.report_action state "system" (no_keeper_under_cursor ~ko:(state.T.ui_language = T.Lang_ko))
  | Some keeper ->
      let reading = T.keeper_reading state keeper in
      let ko = state.T.ui_language = T.Lang_ko in
      let label = Keeper_control.action_label ~ko action in
      if not (List.mem action (Keeper_control.available reading)) then
        Masc_tui_loader.report_action state "system"
          (Printf.sprintf
             (if ko then "%s 지금 %s 불가 (%s)" else "%s cannot %s right now (%s)")
             keeper.T.k_name label
             (Keeper_control.status_label ~ko reading
              ^ (match reading.Keeper_control.liveness with
                 | Keeper_control.Invalid detail -> ": " ^ detail
                 | Keeper_control.Unobserved | Keeper_control.Absent
                 | Keeper_control.Present _ -> "")))
      else
        match
          Keeper_control.gate_transition
            ~inflight:(Option.is_some state.T.keeper_action_inflight)
            ~pending:state.T.keeper_action_pending ~keeper:keeper.T.k_name action
        with
        | Keeper_control.Gate_blocked_inflight ->
            Masc_tui_loader.report_action state "system"
              (if ko then "키퍼 동작 이미 진행 중" else "A keeper action is already in progress")
        | Keeper_control.Gate_arm pending ->
            state.T.keeper_action_pending <- Some pending;
            let key = Keeper_control.action_key action in
            Masc_tui_loader.report_action ~show_in_footer:false state "system"
              (if ko then Printf.sprintf "%s 한 번 더 누르면 %s %s" key keeper.T.k_name label
               else Printf.sprintf "Press %s again to %s %s" key label keeper.T.k_name);

            (* Shutdown is undone by a boot. Delete is not undone at all, so
               the arm names what goes -- the same list the dashboard shows
               before its own purge. *)
            if action = Keeper_control.Delete then
              Masc_tui_loader.report_action state "system"
                ((if ko then "삭제하면 키퍼를 멈추고 레인 종료를 기다린 뒤 지움: "
                  else "Delete stops the Keeper and waits for lane shutdown before removing: ")
                 ^ String.concat ", " (Keeper_control.purge_artifacts ~ko))
        | Keeper_control.Gate_submit ->
            start_keeper_action state ~base_path ~mailbox keeper.T.k_name action
