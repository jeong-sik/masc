(** Pure Task lifecycle transition helper. Semantic completion is authorized by
    a request-local configured-LLM verdict, never by an actor hierarchy. *)

type invalid =
  | Completion_verdict_required
  | Completion_rejected of string
  | Completion_verdict_unavailable of string
  | Completion_verdict_action_mismatch
  | Invalid_transition

type decision =
  { new_status : Masc_domain.task_status
  ; set_current : string option
  }

let option_of_non_empty value = if String.equal value "" then None else Some value
let ok ?set_current new_status = Ok { new_status; set_current }

let done_status ~assignee ~now ~notes =
  Masc_domain.Done
    { assignee; completed_at = now; notes = option_of_non_empty notes }
;;

let cancelled_status ~agent_name ~now ~reason =
  Masc_domain.Cancelled
    { cancelled_by = agent_name; cancelled_at = now; reason = option_of_non_empty reason }
;;

type claim_resolution =
  | Worker_claim of Masc_domain.task_status
  | Verifier_claim of Masc_domain.task_status
  | Self_owned
  | Held_by_other of string
  | Held_terminal of Masc_domain.task_status

let resolve_claim ~same_actor ~agent_name ~now (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Todo ->
    Worker_claim (Masc_domain.Claimed { assignee = agent_name; claimed_at = now })
  | Masc_domain.AwaitingVerification { assignee; submitted_at; verification_id; _ } ->
    (* This binding is scheduling metadata only. It never authorizes the
       completion verdict, so binding the submitting worker is valid. *)
    Verifier_claim
      (Masc_domain.bind_verifier
         ~verifier:agent_name
         ~assignee
         ~submitted_at
         ~verification_id)
  | Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ } ->
    if same_actor assignee then Self_owned else Held_by_other assignee
  | Masc_domain.Done _ -> Held_terminal task.task_status
  | Masc_domain.Cancelled { cancelled_by; _ } -> Held_by_other cancelled_by
;;

let completion_pass = function
  | None -> Error Completion_verdict_required
  | Some { Masc_domain.decision = Masc_domain.Completion_pass; _ } -> Ok ()
  | Some { decision = Masc_domain.Completion_reject reason; _ } ->
    Error (Completion_rejected reason)
  | Some { decision = Masc_domain.Completion_verdict_unavailable reason; _ } ->
    Error (Completion_verdict_unavailable reason)
;;

let decide
      ~new_verification_id
      ~same_agent
      ~agent_name
      ~task_id
      ~task_status
      ~action
      ~now
      ~configured_llm_verdict
      ~notes
      ~reason
  =
  match action, task_status with
  | Masc_domain.Claim, Masc_domain.Todo ->
    ok
      ~set_current:task_id
      (Masc_domain.Claimed { assignee = agent_name; claimed_at = now })
  | ( Masc_domain.Claim
    , (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _}) ) ->
    if same_agent assignee then ok task_status else Error Invalid_transition
  | Masc_domain.Claim, Masc_domain.Done _ -> ok task_status
  | ( Masc_domain.Claim
    , Masc_domain.AwaitingVerification { assignee; submitted_at; verification_id; _ } ) ->
    ok
      ~set_current:task_id
      (Masc_domain.bind_verifier
         ~verifier:agent_name
         ~assignee
         ~submitted_at
         ~verification_id)
  | Masc_domain.Claim, Masc_domain.Cancelled _ -> Error Invalid_transition
  | Masc_domain.Start, Masc_domain.Claimed { assignee; _ } ->
    if same_agent assignee
    then
      ok
        ~set_current:task_id
        (Masc_domain.InProgress { assignee; started_at = now })
    else Error Invalid_transition
  | Masc_domain.Start, Masc_domain.InProgress { assignee; _ } ->
    if same_agent assignee then ok task_status else Error Invalid_transition
  | Masc_domain.Start, Masc_domain.Done _ -> ok task_status
  | ( Masc_domain.Start
    , (Masc_domain.Todo | Masc_domain.AwaitingVerification _ | Masc_domain.Cancelled _) ) ->
    Error Invalid_transition
  | ( Masc_domain.Done_action
    , ( Masc_domain.Claimed { assignee; _ }
      | Masc_domain.InProgress { assignee; _ } ) ) ->
    if not (same_agent assignee)
    then Error Invalid_transition
    else
      let open Result.Syntax in
      let* () = completion_pass configured_llm_verdict in
      ok (done_status ~assignee ~now ~notes)
  | Masc_domain.Done_action, Masc_domain.Done _ -> ok task_status
  | ( Masc_domain.Done_action
    , ( Masc_domain.Todo
      | Masc_domain.AwaitingVerification _
      | Masc_domain.Cancelled _ ) ) ->
    Error Invalid_transition
  | Masc_domain.Cancel, Masc_domain.Cancelled _ -> ok task_status
  | Masc_domain.Cancel, Masc_domain.Todo ->
    ok (cancelled_status ~agent_name ~now ~reason)
  | ( Masc_domain.Cancel
    , (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _}) ) ->
    if same_agent assignee
    then ok (cancelled_status ~agent_name ~now ~reason)
    else Error Invalid_transition
  | Masc_domain.Cancel, Masc_domain.AwaitingVerification { assignee; _ } ->
    if same_agent assignee
    then ok (cancelled_status ~agent_name ~now ~reason)
    else Error Invalid_transition
  | Masc_domain.Cancel, Masc_domain.Done _ -> Error Invalid_transition
  | ( Masc_domain.Release
    , (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _}) ) ->
    if same_agent assignee then ok Masc_domain.Todo else Error Invalid_transition
  | Masc_domain.Release, Masc_domain.Todo -> ok task_status
  | ( Masc_domain.Release
    , (Masc_domain.AwaitingVerification _ | Masc_domain.Done _ | Masc_domain.Cancelled _) ) ->
    Error Invalid_transition
  | ( Masc_domain.Submit_for_verification
    , (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _}) ) ->
    if same_agent assignee
    then
      ok
        (Masc_domain.AwaitingVerification
           { assignee
           ; submitted_at = now
           ; verification_id = new_verification_id ()
           ; phase = Masc_domain.Awaiting_verifier
           })
    else Error Invalid_transition
  | ( Masc_domain.Submit_for_verification
    , ( Masc_domain.Todo
      | Masc_domain.AwaitingVerification _
      | Masc_domain.Done _
      | Masc_domain.Cancelled _ ) ) ->
    Error Invalid_transition
  | ( Masc_domain.Approve_verification
    , Masc_domain.AwaitingVerification { assignee; verification_id; _ } ) ->
    let open Result.Syntax in
    let* () = completion_pass configured_llm_verdict in
    ok
      (Masc_domain.Done
         { assignee
         ; completed_at = now
         ; notes =
             Some
               (Printf.sprintf
                  "Configured LLM approved (vrf:%s)%s"
                  verification_id
                  (if String.equal notes "" then "" else " — " ^ notes))
         })
  | ( Masc_domain.Approve_verification
    , ( Masc_domain.Todo
      | Masc_domain.Claimed _
      | Masc_domain.InProgress _
      | Masc_domain.Done _
      | Masc_domain.Cancelled _ ) ) ->
    Error Invalid_transition
  | Masc_domain.Reject_verification, Masc_domain.AwaitingVerification { assignee; _ } ->
    (match configured_llm_verdict with
     | Some { decision = Masc_domain.Completion_reject _; _ } ->
       ok (Masc_domain.InProgress { assignee; started_at = now })
     | Some { decision = Masc_domain.Completion_pass; _ } ->
       Error Completion_verdict_action_mismatch
     | Some { decision = Masc_domain.Completion_verdict_unavailable reason; _ } ->
       Error (Completion_verdict_unavailable reason)
     | None -> Error Completion_verdict_required)
  | ( Masc_domain.Reject_verification
    , ( Masc_domain.Todo
      | Masc_domain.Claimed _
      | Masc_domain.InProgress _
      | Masc_domain.Done _
      | Masc_domain.Cancelled _ ) ) ->
    Error Invalid_transition
;;

let valid_next_actions ~same_agent ~task_status =
  let same_agent_pred _ = same_agent in
  let try_action action =
    let decision =
      match action with
      | Masc_domain.Reject_verification -> Masc_domain.Completion_reject "preview"
      | Masc_domain.Claim
      | Masc_domain.Start
      | Masc_domain.Done_action
      | Masc_domain.Cancel
      | Masc_domain.Release
      | Masc_domain.Submit_for_verification
      | Masc_domain.Approve_verification -> Masc_domain.Completion_pass
    in
    match
      decide
        ~new_verification_id:(fun () -> "")
        ~same_agent:same_agent_pred
        ~agent_name:""
        ~task_id:""
        ~task_status
        ~action
        ~now:""
        ~configured_llm_verdict:
          (Some
             { Masc_domain.decision
             ; runtime_id = "preview"
             ; rationale = None
             ; evaluated_at = ""
             })
        ~notes:""
        ~reason:""
    with
    | Ok _ -> true
    | Error _ -> false
  in
  List.filter try_action Masc_domain.all_task_actions
;;
