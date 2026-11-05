open Keeper_gate_types

(* Public Gate calls share the resolver's workspace identity before looking
   up a mode, pending row, worker claim, exact rule or audit destination. *)
let canonical_base_path base_path =
  Config_dir_resolver.canonical_base_path base_path
  |> Result.map_error Config_dir_resolver.canonical_base_path_error_to_string
;;

let auto_judge_resume_failure_code_to_string = Keeper_gate_projection.auto_judge_resume_failure_code_to_string
let completion_rejection_of_exact_attempt = Keeper_gate_projection.completion_rejection_of_exact_attempt
let completion_rejection_operator_detail = Keeper_gate_projection.completion_rejection_operator_detail
let status_label = Keeper_gate_projection.status_label
let authorization_source_to_string = Keeper_gate_projection.authorization_source_to_string
let unavailable_reason_to_string = Keeper_gate_projection.unavailable_reason_to_string
let authorization_subject_id = Keeper_gate_projection.authorization_subject_id
let decision_to_yojson = Keeper_gate_projection.decision_to_yojson
let authorization_metadata = Keeper_gate_projection.authorization_metadata

type cycle_grant_entry =
  { approval_id : string }

type cycle_grant_state =
  | Cycle_grant_available of cycle_grant_entry
  | Cycle_grant_consuming of cycle_grant_entry
  | Cycle_grant_consumed

type cycle_grant = cycle_grant_state Atomic.t

type cycle_grant_take_result =
  | Cycle_grant_authorized of string * Keeper_approval.Audit.receipt
  | Cycle_grant_not_applicable
  | Cycle_grant_temporarily_unavailable of string * unavailable_reason

let cycle_grant_of_resolution (resolution : Keeper_event_queue.hitl_resolution) =
  match resolution.decision with
  | Keeper_event_queue.Hitl_approved ->
    Some
      (Atomic.make
         (Cycle_grant_available { approval_id = resolution.approval_id }))
  | Keeper_event_queue.Hitl_rejected _ -> None
;;

let rec take_matching_cycle_grant grant request =
  match Atomic.get grant with
  | Cycle_grant_consumed -> Cycle_grant_not_applicable
  | Cycle_grant_consuming entry ->
    Cycle_grant_temporarily_unavailable
      ( entry.approval_id
      , Approval_grant_consumption_in_progress entry.approval_id )
  | Cycle_grant_available entry as current ->
    let reserved = Cycle_grant_consuming entry in
    if Atomic.compare_and_set grant current reserved
    then (
      match
        Keeper_approval_queue.consume_approved_resolution
        ~base_path:request.base_path
        ~id:entry.approval_id
        ~keeper_name:request.keeper_name
        ~tool_name:request.operation
        ~input:request.input
      with
      | Error error ->
        Atomic.set grant current;
        Cycle_grant_temporarily_unavailable
          (entry.approval_id, Approval_grant_unavailable error)
      | Ok Keeper_approval_queue_result.Consumption_not_matching ->
        Atomic.set grant current;
        Cycle_grant_not_applicable
      | Ok Keeper_approval_queue_result.Consumption_already_committed ->
        Atomic.set grant Cycle_grant_consumed;
        Cycle_grant_not_applicable
      | Ok (Keeper_approval_queue_result.Consumption_committed audit_receipt) ->
        Atomic.set grant Cycle_grant_consumed;
        Cycle_grant_authorized (entry.approval_id, audit_receipt))
    else take_matching_cycle_grant grant request
;;

let request_turn_id request =
  Option.bind request.causal_context (fun context -> context.turn_id)
;;

let approval_sse_audit_event = "approval:audit"

(* Authorization is already committed when these receipts exist.  A failed
   audit append therefore cannot turn [Allow] into an error or invite the tool
   caller to retry the external effect.  Publish only the failed receipts as
   observation; the append boundary has already recorded the same failure in
   logs and metrics if no Dashboard SSE client is connected. *)
let broadcast_failed_authorization_audits ~keeper_name ~source receipts =
  let id = authorization_subject_id source in
  List.iter
    (fun (receipt : Keeper_approval.Audit.receipt) ->
       match receipt.write_result with
       | Ok () -> ()
       | Error _ ->
         (try
            Sse.broadcast
              (`Assoc
                  [ "type", `String approval_sse_audit_event
                  ; ( "payload"
                    , `Assoc
                        [ "id", Json_util.string_opt_to_json id
                        ; "audit", Keeper_approval.Audit.receipt_to_yojson receipt
                        ] )
                  ])
          with
          | Eio.Cancel.Cancelled _ as exn ->
            (* Authorization is already committed.  This observation lane must
               not turn cancellation into a lost [Allow] or consume a one-shot
               grant without giving the caller its authorization. *)
            Log.Keeper.warn
              ~keeper_name
              "approval audit failure SSE publish cancelled event=%s err=%s"
              (Keeper_approval.Audit.event_to_string receipt.event_type)
              (Printexc.to_string exn)
          | exn ->
            Log.Keeper.warn
              ~keeper_name
              "approval audit failure SSE publish failed event=%s err=%s"
              (Keeper_approval.Audit.event_to_string receipt.event_type)
              (Printexc.to_string exn)))
    receipts
;;

let allow request source audit_receipts =
  broadcast_failed_authorization_audits
    ~keeper_name:request.keeper_name
    ~source
    audit_receipts;
  Allow { source; audit_receipts }
;;

let observe_authorization_of_failed_result authorization =
  Log.Keeper.info
    "Gate-authorized tool call failed; authorization=%s"
    (Yojson.Safe.to_string (decision_to_yojson (Allow authorization)))
;;

(* The Gate's own [authorization_source] carries the identifier it resolved
   with; the audit event already records that identifier in its own fields, so
   what it is missing is the tag. Map to the payload-free contract variant
   rather than a string, so a new Gate authority cannot reach the audit log
   without this match being updated. *)
let audit_authorization_source
  : authorization_source -> Keeper_approval_queue_rules_types.authorization_source
  = function
  | One_shot_resolution _ -> Keeper_approval_queue_rules_types.One_shot_resolution
  | Exact_always_rule _ -> Keeper_approval_queue_rules_types.Exact_always_rule
  | Keeper_always_allow -> Keeper_approval_queue_rules_types.Keeper_always_allow
  | Workspace_always_allow ->
    Keeper_approval_queue_rules_types.Workspace_always_allow
  | Readonly_sandbox -> Keeper_approval_queue_rules_types.Readonly_sandbox
  | Local_output -> Keeper_approval_queue_rules_types.Local_output
  | Observed_in_box _ -> Keeper_approval_queue_rules_types.Observed_in_box
;;

let audit_allow request ?rule_match ?source_approval_id ?decision_source source =
  Keeper_approval.Audit.record
    ~base_path:request.base_path
    ~event_type:Keeper_approval.Audit.Gate_allowed
    ~authorization_source:(audit_authorization_source source)
    ~id:
      (match source with
       | One_shot_resolution approval_id -> approval_id
       | Exact_always_rule rule_id -> rule_id
       | Keeper_always_allow
       | Workspace_always_allow
       | Readonly_sandbox
       | Local_output
       | Observed_in_box _ ->
         Keeper_approval_queue.generate_id ())
    ~keeper_name:request.keeper_name
    ~tool_name:request.operation
    ?turn_id:(request_turn_id request)
    ?task_id:request.task_id
    ?rule_match
    ?source_approval_id
    ?decision_source
    ()
;;

let submit ?observation request =
  Keeper_approval_queue.submit_pending
    ~origin:(match request.causal_context with
      | Some context -> context.origin
      | None -> Keeper_approval_origin.unavailable)
    ~keeper_name:request.keeper_name
    ~tool_name:request.operation
    ~input:request.input
    ~call_summary:request.call_summary
    ~base_path:request.base_path
    ?turn_id:(request_turn_id request)
    ?request_context:(Option.map (fun context -> context.snapshot) request.causal_context)
    ?observation
    ?task_id:request.task_id
    ?continuation_channel:request.continuation_channel
    ()
;;

(* What the box refused, in the shape the row stores and the judge reads
   (RFC-0422). The stderr tail is bounded here, once, by the operator's knob,
   so the durable row and the keeper's own deferred receipt carry the same
   bytes. *)
let observed_refusal ~refusal_kind ~status ~stderr =
  Keeper_approval_queue_rules_types.observed_refusal
    ~max_stderr_bytes:(Keeper_config.keeper_hitl_observation_stderr_bytes ())
    ~refusal_kind
    ~status:
      (match status with
       | Unix.WEXITED code -> Keeper_approval_queue_rules_types.Observed_exit code
       | Unix.WSIGNALED signal -> Keeper_approval_queue_rules_types.Observed_signal signal
       | Unix.WSTOPPED signal -> Keeper_approval_queue_rules_types.Observed_stopped signal)
    ~stderr
;;
