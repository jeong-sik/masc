(** Approval audit and presentation effects, separate from queue persistence. *)
open Keeper_approval_queue_rules_types
open Keeper_approval_queue_result

let approval_sse_pending_event = "approval:pending"
let approval_sse_resolved_event = "approval:resolved"
let approval_sse_summary_event = "approval:summary_updated"

let input_preview_of_json (json : Yojson.Safe.t) =
  (* Per-leaf marker-aware truncation: a naive [String.sub] on the
     serialized form would chop a [masc:blob ...] marker mid-field and
     leave sha256/bytes/mime malformed so the approval-queue viewer
     cannot round-trip the preview. *)
  let json = Observability_redact.preview_json_strings ~max_len:200 json in
  let raw = Yojson.Safe.to_string json in
  Observability_redact.redact_preview ~max_len:200 raw
;;

let pending_entry_json_fields
      ?(include_input = false)
      (entry : pending_approval)
  =
  [ "id", `String entry.id
  ; "keeper_name", `String entry.keeper_name
  ; "tool_name", `String entry.tool_name
  ; "input_hash", `String entry.input_hash
  ; "sequence", `Int entry.sequence
  ; "requested_at", `Float entry.requested_at
  ; "waiting_s", `Float (Unix.gettimeofday () -. entry.requested_at)
  ; "turn_id", Json_util.int_opt_to_json entry.turn_id
  ; "task_id", Json_util.string_opt_to_json entry.task_id
  ; "goal_id", Json_util.string_opt_to_json entry.goal_id
  ]
  @ (if include_input
     then
       [ "input", entry.input
       ; "input_preview", `String (input_preview_of_json entry.input)
       ]
     else [])
    (* The [include_input] conditional stays parenthesized so the trailing
       canonical [summary_status] field is present in every wire shape. *)
    @ [ "summary_status", summary_status_to_yojson entry.summary_status
      ; "exact_attempt", exact_attempt_state_to_yojson entry.exact_attempt
      ; ( "summary_attempt_disposition"
        , summary_attempt_disposition_to_yojson
            entry.summary_attempt_disposition )
      ; ( "phase"
        , approval_queue_phase_to_yojson
            (phase_of_disposition_and_summary
               ~disposition:entry.summary_attempt_disposition
               ~summary_status:entry.summary_status) )
      ]
;;

let broadcast_pending entry audit_receipt =
  try
    Sse.broadcast
      (`Assoc
          [ "type", `String approval_sse_pending_event
          ; ( "payload"
            , `Assoc
                (pending_entry_json_fields
                   ~include_input:true
                   entry
                 @ [ "audit", Keeper_approval.Audit.receipt_to_yojson audit_receipt ]) )
          ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Keeper_approval_queue_rules.record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_pending"
      ~id:entry.id
      ~event_type:(Keeper_approval.Audit.event_to_string Keeper_approval.Audit.Pending)
      exn
;;

let publish_chat_projection_append ~keeper_name = function
  | Error _ as error -> error
  | Ok (Keeper_chat_store.Already_present _) -> Ok ()
  | Ok (Keeper_chat_store.Appended _) ->
    Keeper_chat_broadcast.chat_appended
      ~keeper_name
      ~source:"approval_lifecycle"
      ();
    Ok ()
;;

let append_chat_projection ~base_path ~keeper_name lifecycle =
  Keeper_chat_store.append_approval_lifecycle_once
    ~base_dir:base_path
    ~keeper_name
    ~lifecycle
  |> publish_chat_projection_append ~keeper_name
;;

let record_pending ~call_summary (entry : pending_approval) =
  Log.Keeper.info
    "HITL_APPROVAL_PENDING: id=%s sequence=%d keeper=%s tool=%s"
    entry.id
    entry.sequence
    entry.keeper_name
    entry.tool_name;
  let audit_receipt =
    Keeper_approval.Audit.record
      ~base_path:entry.audit_base_path
      ~event_type:Keeper_approval.Audit.Pending
      ~id:entry.id
      ~keeper_name:entry.keeper_name
      ~tool_name:entry.tool_name
      ?turn_id:entry.turn_id
      ?task_id:entry.task_id
      ?goal_id:entry.goal_id
      ()
  in
  broadcast_pending entry audit_receipt;
  (* The parked call becomes visible before its answer does. The turn that
     asked keeps running, so without this row the operator sees a tool call
     and then nothing at all until the resolution lands. A projection failure
     is logged and dropped: it must not stop the approval from being queued.
     [call_summary] is the producer's own one-line statement of the call,
     carried on the Gate request; this queue never derives one from the
     input. *)
  (match
     append_chat_projection
       ~base_path:entry.audit_base_path
       ~keeper_name:entry.keeper_name
       { Keeper_chat_store.approval_id = entry.id
       ; tool_name = Some entry.tool_name
       ; phase = Keeper_approval_lifecycle.Approval_requested
       ; artifact_ref = None
       ; call_summary
       }
   with
   | Ok () -> ()
   | Error detail ->
     Log.Keeper.error
       "approval request chat projection failed approval=%s: %s"
       entry.id
       detail);
  audit_receipt
;;

let summary_audit_extras (entry : pending_approval) : (string * Yojson.Safe.t) list =
  match entry.summary_status with
  | Summary_available summary -> [ "model_run_id", `String summary.model_run_id ]
  | Summary_failed { reason } -> [ "failure_reason", `String reason ]
  | Summary_not_requested | Summary_pending -> []
;;

let record_summary_updated ~now (entry : pending_approval) =
  let event_ts =
    match entry.summary_status with
    | Summary_available summary -> summary.generated_at
    | Summary_not_requested | Summary_pending | Summary_failed _ -> now
  in
  (* See Keeper_approval.Audit.record: it logs write failures; the summary broadcast must still run. *)
  ignore
    (Keeper_approval.Audit.record
       ~base_path:entry.audit_base_path
       ~event_type:Keeper_approval.Audit.Summary_updated
       ~id:entry.id
       ~keeper_name:entry.keeper_name
       ~tool_name:entry.tool_name
       ~summary_status:entry.summary_status
       ~exact_attempt:entry.exact_attempt
       ~summary_attempt_disposition:entry.summary_attempt_disposition
       ~timestamp:event_ts
       ~extra_fields:(summary_audit_extras entry)
       ());
  try
    Sse.broadcast
      (`Assoc
         [ "type", `String approval_sse_summary_event
         ; ( "payload"
           , `Assoc
               (pending_entry_json_fields
                  ~include_input:false
                  entry) )
         ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Keeper_approval_queue_rules.record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_summary"
      ~id:entry.id
      ~event_type:approval_sse_summary_event
      exn
;;

let resolve_entry
      ?(before_terminal_publish = fun () -> ())
      ~base_path
      (entry : pending_approval)
      ~(source : decision_source)
      ?actor
      (decision : decision)
  =
  let decision_str = approval_decision_to_string decision in
  Log.Keeper.info
    "HITL_APPROVAL_RESOLVED: id=%s keeper=%s tool=%s decision=%s"
    entry.id
    entry.keeper_name
    entry.tool_name
    decision_str;
  let audit_receipt =
    Keeper_approval.Audit.record
      ~base_path
      ~event_type:Keeper_approval.Audit.Resolved
      ~id:entry.id
      ~keeper_name:entry.keeper_name
      ~tool_name:entry.tool_name
      ?turn_id:entry.turn_id
      ?task_id:entry.task_id
      ?goal_id:entry.goal_id
      ?actor
      ~decision_source:source
      ~decision
      ~summary_status:entry.summary_status
      ~exact_attempt:entry.exact_attempt
      ()
  in
  before_terminal_publish ();
  (try
     Sse.broadcast
       (`Assoc
           [ "type", `String approval_sse_resolved_event
           ; ( "payload"
             , `Assoc
                 [ "id", `String entry.id
                 ; "keeper_name", `String entry.keeper_name
                 ; "tool_name", `String entry.tool_name
                 ; "decision", `String decision_str
                 ; "audit", Keeper_approval.Audit.receipt_to_yojson audit_receipt
                 ] )
           ])
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Keeper_approval_queue_rules.record_queue_failure
       ~keeper_name:entry.keeper_name
       ~site:"broadcast_resolved"
       ~id:entry.id
       ~event_type:(Keeper_approval.Audit.event_to_string Keeper_approval.Audit.Resolved)
       exn);
  audit_receipt
;;

(* Every phase row after the request copies the request row's line. The
   producer stated it once, on the Gate request, and only [record_pending] had
   it in hand; a resolution, replay, or continuation writer has the approval id
   and nothing of the producer, so it reads the stored statement back rather
   than deriving one from the input. [None] when the request row is absent or
   carried none. *)
let requested_call_summary ~base_path ~keeper_name ~approval_id =
  Keeper_chat_store.approval_request_call_summary
    ~base_dir:base_path
    ~keeper_name
    ~approval_id
;;

let ensure_resolution_chat_projection
      ~base_path
      ~keeper_name
      ~approval_id
      ~tool_name
      ~decision
  =
  let phase =
    match decision with
    | Decision.Approve -> Keeper_approval_lifecycle.Approval_resolved_approved
    | Decision.Reject _ -> Keeper_approval_lifecycle.Approval_resolved_rejected
  in
  append_chat_projection
    ~base_path
    ~keeper_name
    { Keeper_chat_store.approval_id
    ; tool_name
    ; phase
    ; artifact_ref = None
    ; call_summary = requested_call_summary ~base_path ~keeper_name ~approval_id
    }
;;

let ensure_replay_chat_projection
      ~base_path
      ~keeper_name
      ~approval_id
      ~tool_name
      ~outcome
  =
  let call_summary = requested_call_summary ~base_path ~keeper_name ~approval_id in
  let phase, artifact_ref =
    match outcome with
    | Replay_applied artifact_ref ->
      Keeper_approval_lifecycle.Approval_replay_applied, artifact_ref
    | Replay_applied_with_warning artifact_ref ->
      Keeper_approval_lifecycle.Approval_replay_applied_with_warning, artifact_ref
    | Replay_failed artifact_ref ->
      Keeper_approval_lifecycle.Approval_replay_failed, artifact_ref
    | Replay_indeterminate artifact_ref ->
      Keeper_approval_lifecycle.Approval_replay_indeterminate, artifact_ref
  in
  Keeper_chat_store.reconcile_approval_replay_lifecycle_once
    ~base_dir:base_path
    ~keeper_name
    ~lifecycle:
      { Keeper_chat_store.approval_id
      ; tool_name
      ; phase
      ; artifact_ref = Some artifact_ref
      ; call_summary
      }
  |> publish_chat_projection_append ~keeper_name
;;

let continuation_settled_chat_projection_present
      ~base_path
      ~keeper_name
      ~approval_id
  =
  Keeper_chat_store.approval_continuation_settled
    ~base_dir:base_path
    ~keeper_name
    ~approval_id
;;

type continuation_projection_append =
  | Continuation_appended of Keeper_chat_store.append_once_result
  | Continuation_not_ready

let project_settled_continuation
      ~base_path
      ~keeper_name
      ~approval_id
      ~readiness
      ~phase
  =
  match readiness with
  | Continuation_waiting_for_replay -> Ok Continuation_not_ready
  | Continuation_ready tool_name ->
    Result.map
      (fun result -> Continuation_appended result)
      (Keeper_chat_store.append_approval_lifecycle_once
         ~base_dir:base_path
         ~keeper_name
         ~lifecycle:
           { Keeper_chat_store.approval_id
           ; tool_name
           ; phase
           ; artifact_ref = None
           ; call_summary =
               requested_call_summary ~base_path ~keeper_name ~approval_id
           })
;;

let publish_settled_continuation ~keeper_name = function
  | Error _ as error -> error
  | Ok Continuation_not_ready -> Ok Continuation_projection_not_ready
  | Ok (Continuation_appended result) ->
    Result.map
      (fun () -> Continuation_projection_recorded)
      (publish_chat_projection_append ~keeper_name (Ok result))
;;

let record_settled_continuation ~base_path ~keeper_name ~approval_id ~readiness =
  project_settled_continuation
    ~base_path ~keeper_name ~approval_id ~readiness
    ~phase:Keeper_approval_lifecycle.Approval_continuation_recorded
  |> publish_settled_continuation ~keeper_name
;;

(* #32956: the turn that received the replay failed after the provider
   answered, so the model has already seen the evidence. The receipt settles
   the continuation slot as failed; the intake then retires the queued wake
   instead of carrying the same evidence into every later cycle. The WARN is
   written once, when the row is appended, and names the route, so a fleet
   grep counts failed continuations by route rather than calls. *)
let record_failed_continuation
      ~base_path
      ~keeper_name
      ~approval_id
      ~readiness
      ~(route : Keeper_runtime_failure_route.route)
  =
  let projected =
    project_settled_continuation
      ~base_path
      ~keeper_name
      ~approval_id
      ~readiness
      ~phase:Keeper_approval_lifecycle.Approval_continuation_failed
  in
  (match projected with
   | Ok (Continuation_appended (Keeper_chat_store.Appended _)) ->
     Log.Keeper.warn
       "HITL_APPROVAL_CONTINUATION_FAILED: id=%s keeper=%s route=%s class=%s"
       approval_id
       keeper_name
       (Keeper_runtime_failure_route.route_kind_label route)
       (Keeper_runtime_failure_route.route_class_label route)
   | Ok (Continuation_appended (Keeper_chat_store.Already_present _))
   | Ok Continuation_not_ready
   | Error _ -> ());
  publish_settled_continuation ~keeper_name projected
;;
