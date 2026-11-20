module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Tui_decode = Masc.Tui_decode
module Goal_confirmation = Masc_tui_planning_detail
module Goal_confirmation_read = Masc_tui_fetched
module Kept_request = Masc_tui_words.Kept_request

(* A removed Goal renders the list, so its stale detail id owns no commands. *)
let goal_detail_on_screen (state : T.state) =
  match state.T.planning_mode, state.T.planning with
  | T.Planning_detail goal_id, Some snapshot ->
      List.find_opt (fun (goal : T.planning_goal) -> String.equal goal.T.pg_id goal_id)
        snapshot.T.pl_goals
  | T.Planning_list, _ | T.Planning_detail _, None -> None

(* The lifecycle request [key] sends from the open Goal detail, if that Goal
   accepts one under it. *)
let goal_detail_action (state : T.state) key =
  Option.bind (goal_detail_on_screen state) (fun goal ->
    T.planning_action_of_key ~offers:(T.planning_goal_offers_action goal) key)

(* A proof read is separate from the confirmation key: recovery must never
   replay the key's second-press mutation. *)
let launch_goal_confirmation_read (state : T.state) ~mailbox ~goal_id =
  if Result.is_ok (Goal_store.validate_goal_id goal_id) && T.server_authority_ready state then
    match state.T.server_identity with
    | None -> ()
    | Some expected_workspace ->
    match state.T.goal_confirmation with
    | Goal_confirmation.Submitting _ -> ()
    | Goal_confirmation.Inspecting read ->
        (match Goal_confirmation_read.start ~equal:String.equal read ~key:goal_id with
         | Goal_confirmation_read.Already_loading -> ()
         | Goal_confirmation_read.Started (loading, request) ->
             state.T.goal_confirmation <- Goal_confirmation.Inspecting loading;
             state.T.goal_confirmation_presented <- None;
             let host = Masc_tui_transport.Workspace_admission.server_peer_host and port = state.T.port in
             let workspace = Goal_confirmation.confirmation_workspace_of_identity expected_workspace in
             let ko = state.T.ui_language = T.Lang_ko in
             Masc_tui_transport.Workspace_admission.launch_guarded_request state ~mailbox
               ~boundary_error:(fun detail -> Goal_confirmation.Read_failed (None, detail))
               ~withdrawn:(fun refusal -> Goal_confirmation.Read_kept_back
                 (T.workspace_refusal_text ~ko ~request:Kept_request.Goal_confirmation_read refusal))
               ~deliver:(fun result -> P.Goal_msg (P.Goal_confirmation_loaded (request, result)))
               (fun () ->
                 let open Result.Syntax in
                 let credential = Masc_tui_http.bind_credential () in
                 let* runtime_instance_id = match expected_workspace.Tui_decode.sid_runtime_instance_id with
                   | Some instance when String.trim instance <> "" -> Ok instance
                   | Some _ | None -> Error (Goal_confirmation.Read_failed (Some credential.Masc_tui_http.bound_owner, "Server instance is unavailable; read the server identity again")) in
                 let* json = Masc_tui_workspace_read.with_binding ~host ~port ~expected:expected_workspace
                   ~proof:Masc_tui_workspace_read.Request_precondition (fun () ->
                     Masc_tui_http.fetch_goal_confirmation ~credential ~expected_instance:runtime_instance_id ~host ~port ~goal_id) in
                 let* confirmation = Goal_confirmation.decode_confirmation ~goal_id ~workspace
                   ~runtime_instance_id ~credential_headers:credential.Masc_tui_http.bound_headers ~credential_owner:credential.Masc_tui_http.bound_owner json
                   |> Result.map_error (fun detail -> Goal_confirmation.Read_failed (Some credential.Masc_tui_http.bound_owner, detail)) in
                 match confirmation.Goal_confirmation.phase with
                 | Goal_phase.Awaiting_confirmation | Goal_phase.Completed -> Ok confirmation
                 | Goal_phase.Executing | Goal_phase.Verifying
                 | Goal_phase.Dropped | Goal_phase.Paused _ | Goal_phase.Blocked _ -> Error (Goal_confirmation.Read_failed (Some credential.Masc_tui_http.bound_owner, "goal is not awaiting confirmation"))))

(* A Goal request the workspace guard kept back, with the Goal it was for
   after the notice. *)
let goal_kept_back_notice (state : T.state) ~goal_id ~current refusal =
  T.workspace_refusal_text ~ko:(state.T.ui_language = T.Lang_ko)
    ~request:Kept_request.Goal_transition refusal
  ^ " · Goal " ^ goal_id ^ (if current then "" else " (earlier request)")

(* Request a goal lifecycle change through the tools route. Runs in a fiber
   like the other writes; the outcome lands in the shared mailbox and the
   server's phase rules decide, so the TUI never pre-guesses a transition. *)
let start_goal_transition ?note ?retry_binding (state : T.state) ~mailbox ~(goal_id : string)
    ~(action : Goal_phase.Public_action.t) =
  (* The transition carries the workspace this terminal confirmed, and the
     server refuses one without it, so a server replaced on the same port
     cannot receive a transition meant for the Goal the operator read. *)
  match state.T.workspace_identity, state.T.server_identity with
  | T.Workspace_identity_match, Some expected_workspace ->
      Masc_tui_work_requests.Approval_gate_requests.supersede_home_decision_receipt state;
      let ticket = Random_id.uuid_v7 () in
      if not (T.note_goal_action_started state ~goal_id ~ticket) then
        Masc_tui_loader.report_action state "error" ("Goal " ^ goal_id ^ ": a request is still in progress")
      else begin
      let origin = Tui_decode.Canonical_path.to_string expected_workspace.Tui_decode.sid_base_path
        ^ " (masc root " ^ Tui_decode.Canonical_path.to_string expected_workspace.Tui_decode.sid_masc_root ^ ")" in
      let action_context = " (action " ^ Goal_phase.Public_action.to_string action in
      let proof_context = match retry_binding with
        | None -> action_context ^ ")"
        | Some binding ->
          action_context ^ "; criterion " ^ binding.Tui_decode.grb_criterion_revision
          ^ "; proof request " ^ Option.value ~default:"none" binding.Tui_decode.grb_request_id ^ ")" in
      let annotate_error error =
        "Goal request did not return a confirmed result; inspect the Goal before retrying: " ^ error ^ proof_context in
      Masc_tui_loader.report_action state "system"
        (Printf.sprintf "goal %s: %s" goal_id
           (Goal_phase.Public_action.to_string action));
      let host = Masc_tui_transport.Workspace_admission.server_peer_host in
      let port = state.T.port in
      Masc_tui_transport.Workspace_admission.launch_guarded_request ~operation:true state ~mailbox
        ~boundary_error:(fun detail -> T.Request_failed (annotate_error detail))
        ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
        ~cancelled:(P.Goal_msg (P.Goal_transition_done (goal_id, ticket, origin, Error (T.Request_failed (annotate_error "Request interrupted; its outcome is unknown. Inspect the Goal before retrying.")))))
        ~deliver:(fun result -> P.Goal_msg (P.Goal_transition_done (goal_id, ticket, origin, Result.map (fun message -> message ^ proof_context) result)))
        (fun () ->
          (match
            Masc_tui_http.post_goal_transition ~expected_workspace
              ~host ~port ~goal_id ~action ~note ~retry_binding
          with
          | Error err -> Error (annotate_error err)
          | Ok json -> Tui_decode.tool_envelope_outcome json |> Result.map_error annotate_error)
          |> Result.map_error (fun detail -> T.Request_failed detail))
      end
  | ( T.Workspace_identity_match | T.Workspace_identity_mismatch _
    | T.Workspace_identity_unread | T.Workspace_identity_match_unconfirmed _ ), _ ->
      Masc_tui_transport.Request_notice.report_kept_back state ~request:Kept_request.Goal_transition Masc_tui_words.workspace_identity_unconfirmed Masc_tui_words.Nothing_kept

(* Confirmation uses the operator route and the exact proof read here, never
   the public MCP action set or a proof obtained at the second keypress. *)
let handle_goal_confirmation_key (state : T.state) ~mailbox =
  if state.T.workspace_identity <> T.Workspace_identity_match then
    Masc_tui_transport.Request_notice.report_kept_back state ~request:Kept_request.Goal_transition Masc_tui_words.workspace_identity_unconfirmed Masc_tui_words.Nothing_kept
  else
  match state.T.planning_mode with
  | T.Planning_list -> ()
  | T.Planning_detail goal_id when Result.is_error (Goal_store.validate_goal_id goal_id) ->
      T.set_goal_action_error state ~goal_id "Cannot inspect confirmation for this Goal ID"
  | T.Planning_detail goal_id ->
      let host = Masc_tui_transport.Workspace_admission.server_peer_host and port = state.T.port in
      state.T.goal_action_pending <- None;
      (match state.T.goal_confirmation with
       | Goal_confirmation.Submitting _ -> ()
       | Goal_confirmation.Inspecting read when Goal_confirmation_read.in_flight read ->
           Masc_tui_loader.report_action state "system" "Goal proof is being refreshed; wait for the current result"
       | Goal_confirmation.Inspecting read ->
      match Goal_confirmation_read.view_for ~equal:String.equal read ~key:goal_id with
       | Goal_confirmation_read.Ready confirmation when not (Option.exists (fun identity ->
           Goal_confirmation.same_confirmation_workspace confirmation.Goal_confirmation.workspace
             (Goal_confirmation.confirmation_workspace_of_identity identity)
           && identity.Tui_decode.sid_runtime_instance_id = Some confirmation.Goal_confirmation.runtime_instance_id) state.T.server_identity) ->
           state.T.goal_confirmation_presented <- None;
           Masc_tui_loader.report_action state "error" "Goal confirmation workspace or server changed; read the proof again";
           T.clear_goal_confirmation_revalidation state ~goal_id;
           launch_goal_confirmation_read state ~mailbox ~goal_id
       | Goal_confirmation_read.Ready confirmation when not (Masc_tui_http.credential_owner_is_current confirmation.Goal_confirmation.credential_owner) ->
           state.T.goal_confirmation_presented <- None;
           Masc_tui_loader.report_action state "error" "Goal confirmation credential changed; read the proof again";
           T.clear_goal_confirmation_revalidation state ~goal_id;
           launch_goal_confirmation_read state ~mailbox ~goal_id
       | Goal_confirmation_read.Ready confirmation when confirmation.Goal_confirmation.phase = Goal_phase.Completed ->
           Masc_tui_loader.report_action state "system" "Goal confirmation is already recorded; no additional request sent"
       | Goal_confirmation_read.Ready confirmation when state.T.goal_confirmation_presented <> Some confirmation ->
           Masc_tui_loader.report_action state "system"
             (T.ui_text state
                ~ko:"증거를 끝까지 읽은 뒤 [a]를 눌러 주세요"
                ~en:"Read through the proof binding before confirming")
       | Goal_confirmation_read.Ready confirmation ->
           Masc_tui_work_requests.Approval_gate_requests.supersede_home_decision_receipt state;
           let ticket = Random_id.uuid_v7 () in
           if not (T.note_goal_action_started state ~goal_id ~ticket) then
             Masc_tui_loader.report_action state "error" ("Goal " ^ goal_id ^ ": a request is still in progress")
           else begin
           let origin = Option.fold ~none:"unconfirmed" ~some:(fun (identity : Tui_decode.server_identity) ->
             Tui_decode.Canonical_path.to_string identity.Tui_decode.sid_base_path
             ^ " (masc root " ^ Tui_decode.Canonical_path.to_string identity.Tui_decode.sid_masc_root ^ ")") state.T.server_identity
             ^ " (server instance " ^ confirmation.Goal_confirmation.runtime_instance_id ^ ")" in
           let verdict = confirmation.Goal_confirmation.verdict in
           let Goal_store.Criterion { revision; title = _; measure = _; procedure = _ } = verdict.Goal_verification.criterion in
           let proof_context = " (criterion " ^ revision
             ^ "; proof request " ^ verdict.Goal_verification.request_id
             ^ "; verification run " ^ verdict.Goal_verification.verification_run_id ^ ")" in
           let annotate_error error =
             "Goal confirmation did not return a confirmed result; inspect the Goal before retrying: " ^ error
             ^ proof_context in
           let receipt_authority = Goal_confirmation.confirmation_receipt_authority confirmation in
           state.T.goal_confirmation <- Goal_confirmation.Submitting
               (goal_id, Goal_confirmation.suspend_confirmation_read read);
           state.T.planning_scroll <- T.Planning_scroll_offset 0;
           let workspace_authority = state.T.workspace_authority in
           let workspace_read_authority = state.T.workspace_read_authority in
           let expected_workspace = state.T.server_identity in
           Masc_tui_transport.Workspace_admission.launch_guarded_request ~operation:true state ~mailbox
             ~boundary_error:(fun detail -> T.Request_failed detail)
             ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
             ~cancelled:(P.Goal_msg (P.Goal_confirmation_submitted (goal_id, ticket, origin, receipt_authority, Error (T.Request_failed (annotate_error "request interrupted")))))
             ~deliver:(fun result -> P.Goal_msg (P.Goal_confirmation_submitted (goal_id, ticket, origin, receipt_authority,
               result |> Result.map (fun message -> message ^ proof_context)
               |> Result.map_error (function
                 | T.Request_failed detail -> T.Request_failed (annotate_error detail)
                 | T.Request_withdrawn refusal -> T.Request_withdrawn refusal))))
             (fun () ->
               Result.map_error (fun detail -> T.Request_failed detail) @@
               let open Result.Syntax in
               let credential = Masc_tui_http.bind_credential () in
               let* () = if credential.Masc_tui_http.bound_owner == confirmation.Goal_confirmation.credential_owner then Ok ()
                 else Error "Goal confirmation credential changed; read the proof again" in
               let authority_current () = workspace_authority = state.T.workspace_authority
                 && workspace_read_authority == state.T.workspace_read_authority
                 && T.server_authority_ready state && state.T.port = port
                 && Option.exists (fun identity -> identity.Tui_decode.sid_runtime_instance_id = Some confirmation.Goal_confirmation.runtime_instance_id) state.T.server_identity
                 && Masc_tui_http.credential_owner_is_current confirmation.Goal_confirmation.credential_owner in
               let* expected_workspace = match expected_workspace with
                 | Some expected -> Ok expected
                 | None -> Error "Goal confirmation workspace is unavailable" in
               let* () = if authority_current () then Ok ()
                 else Error "Goal confirmation authority changed; read the proof again" in
               let* json = Masc_tui_http.post_goal_confirmation ~host ~port confirmation in
               let* confirmed = Goal_confirmation.decode_confirmation ~goal_id ~workspace:confirmation.Goal_confirmation.workspace
                 ~runtime_instance_id:confirmation.Goal_confirmation.runtime_instance_id ~credential_headers:confirmation.Goal_confirmation.credential_headers ~credential_owner:confirmation.Goal_confirmation.credential_owner json in
               let* () = if confirmed.Goal_confirmation.phase = Goal_phase.Completed
                   && Goal_confirmation.same_confirmation_binding confirmation confirmed
                 then Ok () else Error "goal confirmation: server did not confirm the inspected proof" in
               let* () = if authority_current () then Ok ()
                 else Error "Goal confirmation authority changed before readback" in
               let* readback_json = Masc_tui_workspace_read.with_binding ~host ~port ~expected:expected_workspace
                 ~proof:Masc_tui_workspace_read.Request_precondition (fun () ->
                   Masc_tui_http.fetch_goal_confirmation ~credential ~expected_instance:confirmation.Goal_confirmation.runtime_instance_id ~host ~port ~goal_id)
                 |> Result.map_error (function
                   | Goal_confirmation.Read_failed _ -> "Goal confirmation readback failed; inspect the current proof"
                   | Goal_confirmation.Read_http_error (_, status) -> Printf.sprintf "Goal confirmation readback failed (HTTP %d)" status
                   | Goal_confirmation.Server_changed _ -> "Goal confirmation server changed before readback"
                   | Goal_confirmation.Read_kept_back notice -> notice) in
               let* readback = Goal_confirmation.decode_confirmation ~goal_id ~workspace:confirmation.Goal_confirmation.workspace
                 ~runtime_instance_id:confirmation.Goal_confirmation.runtime_instance_id ~credential_headers:confirmation.Goal_confirmation.credential_headers ~credential_owner:confirmation.Goal_confirmation.credential_owner readback_json in
               if authority_current () && readback.Goal_confirmation.phase = Goal_phase.Completed
                  && Goal_confirmation.same_confirmation_binding confirmation readback
                  && Goal_confirmation.same_recorded_confirmation confirmed readback
               then Ok "completion confirmed by readback"
               else Error "goal confirmation: readback did not match the confirmed proof and operator record"
             )
           end
       | Goal_confirmation_read.Loading -> ()
       (* A confirmation read before a failed re-read is not the goal's
          current state; confirming it would act on what the server no longer
          answered. Ask again. *)
       | Goal_confirmation_read.Absent | Goal_confirmation_read.Stale _ | Goal_confirmation_read.Failed _ ->
           state.T.planning_scroll <- T.Planning_scroll_offset 0;
           T.clear_goal_confirmation_revalidation state ~goal_id;
           launch_goal_confirmation_read state ~mailbox ~goal_id)

(* The lifecycle keys on a goal detail. The first press names the action, the
   same press again submits it, and any other key disarms. A drop opens its
   reason instead: the Server refuses a drop that does not say why. *)
let handle_goal_action_key (state : T.state) ~mailbox ~(action : Goal_phase.Public_action.t) =
  match state.T.planning_mode with
  | T.Planning_detail goal_id when action = Goal_phase.Public_action.Drop ->
      state.T.goal_action_pending <- Some (T.Goal_drop_reason { goal_id; reason = "" });
      Masc_tui_loader.report_action state "system"
        (Printf.sprintf "type why goal %s is dropped" goal_id)
  | T.Planning_detail goal_id -> (
      match state.T.goal_action_pending with
      | Some (T.Goal_action_armed { goal_id = armed_goal_id; action = armed_action; phase = _; retry_binding })
        when String.equal armed_goal_id goal_id
             && armed_action = action ->
          state.T.goal_action_pending <- None;
          start_goal_transition ?retry_binding state ~mailbox ~goal_id ~action
      | Some (T.Goal_action_armed _ | T.Goal_drop_reason _) | None ->
          (match goal_detail_on_screen state with
          | None -> ()
          | Some goal ->
          let retry_binding = match action with
            | Goal_phase.Public_action.Request_complete -> goal.T.pg_retry_binding
            | Goal_phase.Public_action.Drop | Goal_phase.Public_action.Reopen
            | Goal_phase.Public_action.Pause | Goal_phase.Public_action.Resume
            | Goal_phase.Public_action.Block | Goal_phase.Public_action.Unblock -> None in
          state.T.goal_action_pending <- Some (T.Goal_action_armed { goal_id; action; phase=goal.T.pg_phase; retry_binding });
          Masc_tui_loader.report_action state "system"
            (Printf.sprintf "press %s again to %s goal %s"
               (T.planning_action_key action)
               (match action with
                | Goal_phase.Public_action.Request_complete ->
                    "request completion of"
                | Goal_phase.Public_action.Drop -> "drop"
                | Goal_phase.Public_action.Reopen -> "reopen"
                | Goal_phase.Public_action.Pause -> "pause"
                | Goal_phase.Public_action.Resume -> "resume"
                | Goal_phase.Public_action.Block -> "block"
                | Goal_phase.Public_action.Unblock -> "unblock")
               goal_id)))
  | T.Planning_list -> ()
