(** Spec-preserving task lifecycle transition helper. *)

type drift = Claimed_to_done_skip

type invalid =
  | Self_approval
  | Self_rejection
  | Verification_disabled
  | Verification_required_use_submit
  | Invalid_transition

type decision =
  { new_status : Masc_domain.task_status
  ; set_current : string option
  ; drift : drift option
  }

let option_of_non_empty value = if String.equal value "" then None else Some value
let ok ?drift ?set_current new_status = Ok { new_status; set_current; drift }

let done_status ~agent_name ~now ~notes =
  Masc_domain.Done
    { assignee = agent_name; completed_at = now; notes = option_of_non_empty notes }
;;

let cancelled_status ~agent_name ~now ~reason =
  Masc_domain.Cancelled
    { cancelled_by = agent_name; cancelled_at = now; reason = option_of_non_empty reason }
;;

let verification_deadline ~now ~timeout_seconds =
  let submitted_at = Masc_domain.parse_iso8601 ~default_time:(Time_compat.now ()) now in
  Some (Masc_domain.iso8601_of_unix_seconds (submitted_at +. timeout_seconds))
;;

(** RFC-0220 §3.5: the outcome of [agent_name] claiming a task in [status].
    Shared by the explicit ([Workspace_task_claim.claim_task_r]) and auto
    ([Workspace_task_schedule.claim_next_r]) claim writers so they never
    diverge on the same claimable status — the divergence flagged in §3.5 was
    that auto-claim overwrote [AwaitingVerification] with [Claimed], clobbering
    the verification obligation. [same_actor] normalizes actor identity (keeper
    alias vs nickname); both writers pass
    [Workspace_task_classify.same_task_actor config _ agent_name], so the
    self-block lives here once, in one equality semantics. *)
type claim_resolution =
  | Worker_claim of Masc_domain.task_status
      (** [Todo] -> [Claimed] by this agent. *)
  | Verifier_claim of Masc_domain.task_status
      (** [AwaitingVerification] submitted by another actor -> the obligation is
          preserved with this agent bound as verifier ([phase]). *)
  | Self_owned
      (** This actor already holds the task (own [Claimed]/[InProgress]) or
          submitted the obligation (own [AwaitingVerification]); claiming is a
          no-op, never a self-verification. *)
  | Held_by_other of string
      (** Held by another actor, or unreclaimable terminal [Cancelled]; the
          string names the current holder for the caller's error message. *)
  | Blocked_by_reclaim_policy of string
      (** Typed reclaim policy closed the claim gate. *)

let resolve_claim ~same_actor ~agent_name ~now (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Todo ->
    Worker_claim (Masc_domain.Claimed { assignee = agent_name; claimed_at = now })
  | Masc_domain.AwaitingVerification { assignee; submitted_at; verification_id; _ } ->
    if same_actor assignee
    then Self_owned
    else
      Verifier_claim
        (Masc_domain.bind_verifier
           ~verifier:agent_name ~assignee ~submitted_at ~verification_id)
  | Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ } ->
    if same_actor assignee then Self_owned else Held_by_other assignee
  | Masc_domain.Done { assignee; _ } ->
    (match Masc_domain.task_claim_decision task with
     | Masc_domain.Claim_available Masc_domain.Claim_ready ->
       Worker_claim (Masc_domain.Claimed { assignee = agent_name; claimed_at = now })
     | Masc_domain.Claim_unavailable (Masc_domain.Claim_block_reclaim_policy reason) ->
       Blocked_by_reclaim_policy reason
     | Masc_domain.Claim_unavailable (Masc_domain.Claim_block_not_todo _) ->
       Held_by_other assignee)
  | Masc_domain.Cancelled { cancelled_by; _ } -> Held_by_other cancelled_by
;;

(* RFC-0262: a transition that overrides the assignee guard is permitted when
   the caller IS the assignee, or holds Operator/System authority (which
   override ownership). Exhaustive match — adding an authority forces every
   guarded arm to declare it (CLAUDE.md FSM sparse-match fix on the authority
   dimension). Phase 1 is behavior-preserving: Operator/System bypass ownership
   exactly as the old [force=true] did; per-authority evidence-gate divergence
   is RFC-0262 Phase 3 (RFC-0199). *)
let owner_authorized ~authority ~same_agent assignee =
  match (authority : Masc_domain.completion_authority) with
  | Assignee -> same_agent assignee
  | Operator | System -> true
;;

let decide
      ~verification_enabled
      ~verification_timeout_seconds
      ~new_verification_id
      ~same_agent
      ~agent_name
      ~task_id
      ~task_status
      ~action
      ~now
      ~authority
      ~notes
      ~reason
  =
  match action, task_status with
  (* ── Claim ────────────────────────────────────── *)
  | Masc_domain.Claim, Masc_domain.Todo ->
    ok
      ~set_current:task_id
      (Masc_domain.Claimed { assignee = agent_name; claimed_at = now })
  | ( Masc_domain.Claim
    , (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ }) ) ->
    if same_agent assignee then ok task_status else Error Invalid_transition
  | Masc_domain.Claim, Masc_domain.Done _ -> ok task_status
  | ( Masc_domain.Claim
    , Masc_domain.AwaitingVerification { assignee; submitted_at; verification_id; _ } ) ->
    (* Cross-agent verification dispatch (#19314): a verifier — not the
       submitter — claims the obligation. RFC-0220 §3.5: preserve the
       [AwaitingVerification] status and bind the verifier in [phase] so the
       satisfier is recorded in the task FSM (single authority) instead of a
       separate store. [set_current] points the verifier at the task, matching
       the explicit claim path. Self-claim is blocked: the submitter cannot
       verify their own work. *)
    if same_agent assignee
    then Error Invalid_transition
    else
      ok
        ~set_current:task_id
        (Masc_domain.bind_verifier
           ~verifier:agent_name ~assignee ~submitted_at ~verification_id)
  | Masc_domain.Claim, Masc_domain.Cancelled _ ->
    Error Invalid_transition
  (* ── Start ────────────────────────────────────── *)
  | Masc_domain.Start, Masc_domain.Claimed { assignee; _ } ->
    if owner_authorized ~authority ~same_agent assignee
    then
      ok
        ~set_current:task_id
        (Masc_domain.InProgress { assignee = agent_name; started_at = now })
    else Error Invalid_transition
  | Masc_domain.Start, Masc_domain.InProgress { assignee; _ } ->
    if same_agent assignee then ok task_status else Error Invalid_transition
  | Masc_domain.Start, Masc_domain.Done _ -> ok task_status
  | ( Masc_domain.Start
    , (Masc_domain.Todo | Masc_domain.AwaitingVerification _ | Masc_domain.Cancelled _) )
    -> Error Invalid_transition
  (* ── Done ─────────────────────────────────────── *)
  | Masc_domain.Done_action, Masc_domain.Claimed { assignee; _ } ->
    if owner_authorized ~authority ~same_agent assignee
    then ok ~drift:Claimed_to_done_skip (done_status ~agent_name ~now ~notes)
    else Error Invalid_transition
  | Masc_domain.Done_action, Masc_domain.InProgress { assignee; _ } ->
    if owner_authorized ~authority ~same_agent assignee
    then ok (done_status ~agent_name ~now ~notes)
    else Error Invalid_transition
  | Masc_domain.Done_action, Masc_domain.Done _ -> ok task_status
  | ( Masc_domain.Done_action
    , (Masc_domain.Todo | Masc_domain.AwaitingVerification _ | Masc_domain.Cancelled _) )
    -> Error Invalid_transition
  (* ── Cancel ───────────────────────────────────── *)
  | Masc_domain.Cancel, Masc_domain.Cancelled _ -> ok task_status
  | Masc_domain.Cancel, Masc_domain.Todo -> ok (cancelled_status ~agent_name ~now ~reason)
  | ( Masc_domain.Cancel
    , (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ }) ) ->
    if owner_authorized ~authority ~same_agent assignee
    then ok (cancelled_status ~agent_name ~now ~reason)
    else Error Invalid_transition
  | Masc_domain.Cancel, Masc_domain.AwaitingVerification _ ->
    (* No assignee self-cancel of an in-flight verification; only an override
       authority may expire it (was bare [if force]). *)
    (match (authority : Masc_domain.completion_authority) with
     | Operator | System -> ok (cancelled_status ~agent_name ~now ~reason)
     | Assignee -> Error Invalid_transition)
  | Masc_domain.Cancel, Masc_domain.Done _ -> Error Invalid_transition
  (* ── Release ──────────────────────────────────── *)
  | ( Masc_domain.Release
    , (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ }) ) ->
    if owner_authorized ~authority ~same_agent assignee
    then ok Masc_domain.Todo
    else Error Invalid_transition
  | Masc_domain.Release, Masc_domain.Todo -> ok task_status
  | ( Masc_domain.Release
    , (Masc_domain.AwaitingVerification _ | Masc_domain.Done _ | Masc_domain.Cancelled _)
    ) -> Error Invalid_transition
  (* ── Submit for verification ──────────────────── *)
  | Masc_domain.Submit_for_verification, Masc_domain.Todo ->
    if verification_enabled then Error Invalid_transition else Error Verification_disabled
  | ( Masc_domain.Submit_for_verification
    , (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ }) ) ->
    if not verification_enabled
    then Error Verification_disabled
    else if same_agent assignee
    then
      ok
        (Masc_domain.AwaitingVerification
           { assignee
           ; submitted_at = now
           ; verification_id = new_verification_id ()
           (* RFC-0220: a fresh submission has no verifier yet. [deadline]
              dropped per I2 (no per-obligation wall-clock deadline). *)
           ; phase = Masc_domain.Awaiting_verifier
           })
    else Error Invalid_transition
  | ( Masc_domain.Submit_for_verification
    , (Masc_domain.AwaitingVerification _ | Masc_domain.Done _ | Masc_domain.Cancelled _)
    ) ->
    if verification_enabled then Error Invalid_transition else Error Verification_disabled
  (* ── Approve verification ─────────────────────── *)
  | ( Masc_domain.Approve_verification
    , Masc_domain.AwaitingVerification { assignee; verification_id; _ } ) ->
    if same_agent assignee
    then Error Self_approval
    else if verification_enabled
    then
      ok
        (Masc_domain.Done
           { assignee
           ; completed_at = now
           ; notes =
               Some
                 (Printf.sprintf
                    "Approved by %s (vrf:%s)%s"
                    agent_name
                    verification_id
                    (if String.equal notes "" then "" else " — " ^ notes))
           })
    else Error Verification_disabled
  | ( Masc_domain.Approve_verification
    , ( Masc_domain.Todo
      | Masc_domain.Claimed _
      | Masc_domain.InProgress _
      | Masc_domain.Done _
      | Masc_domain.Cancelled _ ) ) ->
    if verification_enabled then Error Invalid_transition else Error Verification_disabled
  (* ── Reject verification ──────────────────────── *)
  | Masc_domain.Reject_verification, Masc_domain.AwaitingVerification { assignee; _ } ->
    if same_agent assignee
    then Error Self_rejection
    else if verification_enabled
    then ok (Masc_domain.InProgress { assignee; started_at = now })
    else Error Verification_disabled
  | ( Masc_domain.Reject_verification
    , ( Masc_domain.Todo
      | Masc_domain.Claimed _
      | Masc_domain.InProgress _
      | Masc_domain.Done _
      | Masc_domain.Cancelled _ ) ) ->
    if verification_enabled then Error Invalid_transition else Error Verification_disabled
;;

(* Enumerate the actions that [decide] would accept for the given status under
   ~same_agent / ~force / ~verification_enabled. Pure function over the decide
   table; closes the workaround posture noted in
   lib/task_transition_state/task_transition_state.ml header. Pass [~same_agent]
   reflecting whether the caller is the task's current assignee (irrelevant for
   Todo / AwaitingVerification approver checks but [decide] still routes
   through it for [Claim] / [Start] / [Done_action] / [Cancel] / [Release] /
   [Submit_for_verification]). *)
let valid_next_actions
      ~verification_enabled
      ~same_agent
      ~authority
      ~task_status
  =
  let same_agent_pred _ = same_agent in
  let try_action action =
    match
      decide
        ~verification_enabled
        ~verification_timeout_seconds:0.0
        ~new_verification_id:(fun () -> "")
        ~same_agent:same_agent_pred
        ~agent_name:""
        ~task_id:""
        ~task_status
        ~action
        ~now:""
        ~authority
        ~notes:""
        ~reason:""
    with
    | Ok _ -> true
    | Error _ -> false
  in
  List.filter try_action Masc_domain.all_task_actions
;;
