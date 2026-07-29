(** LLM-backed keeper context compaction over the OAS exact-output surface.
    See keeper_compaction_llm_summarizer.mli. MASC owns the domain plan while
    OAS owns frozen target admission, dispatch, and receipt provenance. *)

module Schema = Keeper_structured_output_schema
module Exact_output = Agent_sdk.Exact_output
module String_set = Set.Make (String)

type message_text_source =
  { role : Agent_sdk.Types.role
  ; text_blocks : string list
  }

type closed_tool_cycle_source =
  { semantic_json : Yojson.Safe.t }

type eligible_payload =
  | Message_text of message_text_source
  | Closed_tool_cycle of closed_tool_cycle_source

type eligible_source =
  { source_index : int
  ; payload : eligible_payload
  }

type planning_window =
  { first_source : eligible_source
  ; remaining_sources : eligible_source list
  ; source_units : Keeper_compaction_unit.closed_unit list
  }

type compaction_plan =
  { window : planning_window
  ; summary : string
  ; keep_from_unit_index : int
  }

type exact_execution_evidence =
  { slot_id : string
  ; call_id : string
  ; target_identity_fingerprint : string
  ; catalog_generation_fingerprint : string
  ; catalog_evidence_sha256 : string
  ; plan_fingerprint : string
  ; receipt_request_body_sha256 : string
  }

type attempt_observation =
  { slot_id : string
  ; call_id : string
  ; catalog_generation_fingerprint : string
  ; receipt_plan_fingerprint : string
  ; receipt_request_body_sha256 : string
  }

type exact_write_outcome = Keeper_event_queue_persistence.exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string

type exact_execution_guard =
  { before_dispatch : attempt_observation -> (exact_write_outcome, string) result
  ; release_before_dispatch : attempt_observation -> (exact_write_outcome, string) result
  ; quarantine :
      Keeper_event_queue_state.exact_execution_terminal_cause ->
      attempt_observation ->
      (exact_write_outcome, string) result
  }

type before_dispatch_authority =
  attempt_observation -> (unit, string) result

type post_success_completion =
  { waiter : unit Eio.Promise.t
  ; resolve : unit -> unit
  }

type post_success_phase =
  | Open
  | Commit_claimed of post_success_completion
  | Installed_pending_valid of post_success_completion
  | Committed of (unit, string) result
  | Reject_claimed of
      Keeper_event_queue_state.exact_execution_terminal
      * post_success_completion
  | Rejected of
      Keeper_event_queue_state.exact_execution_terminal
      * (unit, string) result

type post_success_terminalizer =
  { keeper_name : string
  ; exact_execution_guard : exact_execution_guard option
  ; attempt_observation : attempt_observation
  ; disposition_mutex : Eio.Mutex.t
  ; mutable phase : post_success_phase
  ; mutable domain_valid_attempts : int
  ; mutable domain_rejected_attempts : int
  }

type post_success_terminalization =
  | Terminalized of Keeper_event_queue_state.exact_execution_terminal
  | Terminalization_persistence_failed of
      Keeper_event_queue_state.exact_execution_terminal * string
  | Terminalization_commit_in_progress of unit Eio.Promise.t
  | Terminalization_already_committed
  | Terminalization_invariant_failed of string

type post_success_commit_claim =
  | Commit_claim_acquired
  | Commit_claim_in_progress of unit Eio.Promise.t
  | Commit_claim_already_committed
  | Commit_claim_rejected of
      Keeper_event_queue_state.exact_execution_terminal
      * (unit, string) result

type 'a post_success_commit_boundary =
  | Post_success_commit_result of 'a
  | Post_success_commit_in_progress of unit Eio.Promise.t
  | Post_success_commit_already_committed
  | Post_success_commit_rejected of
      Keeper_event_queue_state.exact_execution_terminal
      * (unit, string) result

type post_success_phase_snapshot =
  | Phase_open
  | Phase_commit_claimed
  | Phase_installed_pending_valid
  | Phase_committed
  | Phase_reject_claimed
  | Phase_rejected

type post_success_snapshot =
  { phase : post_success_phase_snapshot
  ; domain_valid_attempts : int
  ; domain_rejected_attempts : int
  }

type completed_plan =
  { plan : compaction_plan
  ; exact_execution_evidence : exact_execution_evidence
  ; post_success_terminalizer : post_success_terminalizer
  }

type summarization_failure =
  | Exact_lane_unconfigured
  | Exact_target_selection_failed
  | Exact_admission_failed
  | Exact_attempt_start_failed
  | Exact_execution_context_unavailable
  | Exact_execution_authority_absent
  | Exact_execution_authority_rejected
  | Exact_execution_bind_failed
  | Exact_flow_already_started
  | Exact_execution_terminal of Keeper_event_queue_state.exact_execution_terminal
  | Invalid_plan

type summarizer =
  units:Keeper_compaction_unit.closed_unit list ->
  (completed_plan, summarization_failure) result

let message role text : Agent_sdk.Types.message = Agent_sdk.Types.text_message role text

let messages_of_unit = function
  | Keeper_compaction_unit.Ordinary_message message -> [ message ]
  | Keeper_compaction_unit.Closed_tool_cycle messages -> messages

let canonical_json =
  let rec canonicalize = function
    | `Assoc fields ->
      `Assoc
        (fields
         |> List.map (fun (key, value) -> key, canonicalize value)
         |> List.sort (fun (left, _) (right, _) -> String.compare left right))
    | `List values -> `List (List.map canonicalize values)
    | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value ->
      value
  in
  canonicalize

let option_json project = function
  | None -> `Null
  | Some value -> project value

let tool_failure_kind_string = function
  | Agent_sdk.Types.Validation_error -> "validation_error"
  | Agent_sdk.Types.Recoverable_tool_error -> "recoverable_tool_error"
  | Agent_sdk.Types.Non_retryable_tool_error -> "non_retryable_tool_error"
  | Agent_sdk.Types.Reported_tool_error -> "reported_tool_error"
  | Agent_sdk.Types.Unattributed_tool_error -> "unattributed_tool_error"

let tool_error_class_string = function
  | Agent_sdk.Types.Transient -> "transient"
  | Agent_sdk.Types.Deterministic -> "deterministic"
  | Agent_sdk.Types.Unknown -> "unknown"

let tool_result_outcome_json = function
  | Agent_sdk.Types.Tool_succeeded -> `Assoc [ "kind", `String "succeeded" ]
  | Agent_sdk.Types.Tool_failed { failure_kind; error_class } ->
    `Assoc
      [ "kind", `String "failed"
      ; "failure_kind", `String (tool_failure_kind_string failure_kind)
      ; ( "error_class"
        , option_json (fun value -> `String (tool_error_class_string value)) error_class )
      ]

type semantic_projection_error =
  | Unsupported_media

let rec semantic_content_blocks_json blocks =
  let rec loop projected_rev = function
    | [] -> Ok (`List (List.rev projected_rev))
    | Agent_sdk.Types.Text text :: rest ->
      loop
        (`Assoc [ "type", `String "text"; "text", `String text ] :: projected_rev)
        rest
    | ( Agent_sdk.Types.Thinking _
      | Agent_sdk.Types.ReasoningDetails _
      | Agent_sdk.Types.RedactedThinking _ )
      :: rest ->
      loop projected_rev rest
    | Agent_sdk.Types.ToolUse { id; name; input } :: rest ->
      loop
        (`Assoc
           [ "type", `String "tool_use"
           ; "id", `String id
           ; "name", `String name
           ; "input", canonical_json input
           ]
         :: projected_rev)
        rest
    | Agent_sdk.Types.ToolResult
        { tool_use_id; content; outcome; json; content_blocks }
      :: rest ->
      (match semantic_optional_content_blocks_json content_blocks with
       | Error _ as error -> error
       | Ok content_blocks_json ->
         loop
           (`Assoc
              [ "type", `String "tool_result"
              ; "tool_use_id", `String tool_use_id
              ; "content", `String content
              ; "outcome", tool_result_outcome_json outcome
              ; "json", option_json canonical_json json
              ; "content_blocks", content_blocks_json
              ]
            :: projected_rev)
           rest)
    | (Agent_sdk.Types.Image _ | Agent_sdk.Types.Document _ | Agent_sdk.Types.Audio _)
      :: _ ->
      Error Unsupported_media
  in
  loop [] blocks

and semantic_optional_content_blocks_json = function
  | None -> Ok `Null
  | Some blocks -> semantic_content_blocks_json blocks

let semantic_message_json (message : Agent_sdk.Types.message) =
  match semantic_content_blocks_json message.content with
  | Error _ as error -> error
  | Ok content_blocks ->
    Ok
      (`Assoc
         [ "role", `String (Agent_sdk.Types.role_to_string message.role)
         ; "content_blocks", content_blocks
         ; "name", option_json (fun value -> `String value) message.name
         ; "tool_call_id", option_json (fun value -> `String value) message.tool_call_id
         ])

let semantic_messages_json messages =
  let rec loop projected_rev = function
    | [] -> Ok (`List (List.rev projected_rev))
    | message :: rest ->
      (match semantic_message_json message with
       | Error _ as error -> error
       | Ok projected -> loop (projected :: projected_rev) rest)
  in
  loop [] messages

let message_text_source role blocks =
  let rec loop text_blocks_rev = function
    | [] ->
      let text_blocks = List.rev text_blocks_rev in
      if List.exists (fun text -> String.trim text <> "") text_blocks
      then Some { role; text_blocks }
      else None
    | Agent_sdk.Types.Text text :: rest ->
      loop (text :: text_blocks_rev) rest
    | ( Agent_sdk.Types.Thinking _
      | Agent_sdk.Types.ReasoningDetails _
      | Agent_sdk.Types.RedactedThinking _ )
      :: rest ->
      loop text_blocks_rev rest
    | ( Agent_sdk.Types.ToolUse _
      | Agent_sdk.Types.ToolResult _
      | Agent_sdk.Types.Image _
      | Agent_sdk.Types.Document _
      | Agent_sdk.Types.Audio _ )
      :: _ ->
      None
  in
  loop [] blocks

let cycle_has_tool_protocol messages =
  let has_tool_use =
    List.exists
      (fun (message : Agent_sdk.Types.message) ->
        List.exists
          (function Agent_sdk.Types.ToolUse _ -> true | _ -> false)
          message.content)
      messages
  in
  let has_tool_result =
    List.exists
      (fun (message : Agent_sdk.Types.message) ->
        List.exists
          (function Agent_sdk.Types.ToolResult _ -> true | _ -> false)
          message.content)
      messages
  in
  has_tool_use && has_tool_result

let eligible_source ~first_user_seen source_index = function
  | Keeper_compaction_unit.Ordinary_message
      ({ role = (Agent_sdk.Types.User | Agent_sdk.Types.Assistant)
       ; content
       ; name = None
       ; tool_call_id = None
       ; metadata = []
       } as message)
    when message.role <> Agent_sdk.Types.User || first_user_seen ->
    (match message_text_source message.role content with
     | Some source -> Some { source_index; payload = Message_text source }
     | None -> None)
  | Keeper_compaction_unit.Closed_tool_cycle messages
    when cycle_has_tool_protocol messages ->
    (match Keeper_compaction_unit.validate messages, semantic_messages_json messages with
     | Ok (), Ok semantic_json ->
       Some
         { source_index
         ; payload = Closed_tool_cycle { semantic_json }
         }
     | Error _, _ | _, Error _ -> None)
  | Keeper_compaction_unit.Ordinary_message _
  | Keeper_compaction_unit.Closed_tool_cycle _ ->
    None

let eligible_sources units =
  (* The first User message is the exact goal anchor. Later plain User messages
     are part of the typed conversation state: protecting every one would split
     a real Keeper history into one tiny window per turn and defeat boundary
     compaction. *)
  let rec loop source_index first_user_seen sources_rev = function
    | [] -> List.rev sources_rev
    | unit_ :: rest ->
      let source = eligible_source ~first_user_seen source_index unit_ in
      let first_user_seen =
        first_user_seen
        ||
        match unit_ with
        | Keeper_compaction_unit.Ordinary_message
            { role = Agent_sdk.Types.User; _ } -> true
        | Keeper_compaction_unit.Ordinary_message _
        | Keeper_compaction_unit.Closed_tool_cycle _ ->
          false
      in
      let sources_rev =
        match source with
        | None -> sources_rev
        | Some source -> source :: sources_rev
      in
      loop (source_index + 1) first_user_seen sources_rev rest
  in
  loop 0 false [] units

let has_eligible_units units = eligible_sources units <> []

let oldest_contiguous_run = function
  | [] -> []
  | first :: rest ->
    let rec loop previous_index sources_rev = function
      | source :: remaining when source.source_index = previous_index + 1 ->
        loop source.source_index (source :: sources_rev) remaining
      | _ -> List.rev sources_rev
    in
    loop first.source_index [ first ] rest

let planning_window_for_units source_units =
  match eligible_sources source_units |> oldest_contiguous_run with
  | [] -> Error "source contains no eligible contiguous compaction window"
  | first_source :: remaining_sources ->
    Ok { first_source; remaining_sources; source_units }

let planning_window_sources window =
  window.first_source :: window.remaining_sources

let planning_window_last_index window =
  List.fold_left
    (fun _ source -> source.source_index)
    window.first_source.source_index
    window.remaining_sources

let eligible_units_json sources =
  `List
    (List.map
       (fun source ->
         match source.payload with
         | Message_text { role; text_blocks } ->
           `Assoc
             [ Schema.compaction_plan_field_unit_index, `Int source.source_index
             ; "kind", `String "message_text"
             ; ( "role"
               , `String
                   (Agent_sdk.Types.role_to_string role) )
             ; "text_blocks", `List (List.map (fun text -> `String text) text_blocks)
             ]
         | Closed_tool_cycle { semantic_json; _ } ->
           `Assoc
             [ Schema.compaction_plan_field_unit_index, `Int source.source_index
             ; "kind", `String "closed_tool_cycle"
             ; "messages", semantic_json
             ])
       sources)

let messages_for_plan ~window =
  let sources = planning_window_sources window in
  let first_index = window.first_source.source_index in
  let last_index = planning_window_last_index window in
  let system =
    "You compact only the supplied contiguous window of atomic eligible units. \
     Choose one keep_from_unit_index. Every supplied unit below that boundary \
     is replaced in place by one faithful Assistant memory; the boundary and \
     later supplied units remain exact. Units outside this window remain exact \
     by construction. Each closed_tool_cycle is one indivisible unit. The \
     summary must preserve goals, constraints, decisions, evidence, tool \
     outcomes, unresolved work, corrections, and state needed by future turns. \
     Choose the latest boundary you can summarize faithfully; keep exact only \
     the minimal recent suffix whose details must remain verbatim. Do not \
     invent facts, reference unseen units, split tool cycles, emit markdown \
     fences, or enumerate per-unit decisions. Respond with one JSON object and \
     no other text."
  in
  let user =
    Printf.sprintf
      "window_first_unit_index=%d\nwindow_last_unit_index=%d\nwindow_units=%s\n\
       Return {\"%s\":string,\"%s\":integer}. The summary must be non-empty. \
       keep_from_unit_index must be in [%d,%d], so at least the oldest unit is \
       summarized."
      first_index
      last_index
      (eligible_units_json sources |> Yojson.Safe.to_string)
      Schema.compaction_plan_field_summary
      Schema.compaction_plan_field_keep_from_unit_index
      (first_index + 1)
      (last_index + 1)
  in
  [ message Agent_sdk.Types.System system; message Agent_sdk.Types.User user ]

let ( let* ) = Result.bind

let object_fields ~context ~expected = function
  | `Assoc fields ->
    let expected = String_set.of_list expected in
    let rec check seen = function
      | [] ->
        let missing = String_set.diff expected seen |> String_set.elements in
        if missing = []
        then Ok fields
        else Error (Printf.sprintf "%s missing fields: %s" context (String.concat "," missing))
      | (key, _) :: rest ->
        if not (String_set.mem key expected)
        then Error (Printf.sprintf "%s has unknown field %s" context key)
        else if String_set.mem key seen
        then Error (Printf.sprintf "%s has duplicate field %s" context key)
        else check (String_set.add key seen) rest
    in
    check String_set.empty fields
  | _ -> Error (context ^ " must be a JSON object")

let required_field key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error ("missing field " ^ key)

let int_value ~field = function
  | `Int value -> Ok value
  | _ -> Error (field ^ " must be an integer")

let string_value ~field = function
  | `String value -> Ok value
  | _ -> Error (field ^ " must be a string")

let plan_of_json ~window json =
  let expected =
    [ Schema.compaction_plan_field_summary
    ; Schema.compaction_plan_field_keep_from_unit_index
    ]
  in
  let* fields = object_fields ~context:"plan" ~expected json in
  let* summary_json = required_field Schema.compaction_plan_field_summary fields in
  let* summary =
    string_value ~field:Schema.compaction_plan_field_summary summary_json
  in
  let* () =
    if String.trim summary = ""
    then Error "summary must be non-empty"
    else Ok ()
  in
  let* keep_from_json =
    required_field Schema.compaction_plan_field_keep_from_unit_index fields
  in
  let* keep_from_unit_index =
    int_value
      ~field:Schema.compaction_plan_field_keep_from_unit_index
      keep_from_json
  in
  let first_index = window.first_source.source_index in
  let last_index = planning_window_last_index window in
  if keep_from_unit_index <= first_index || keep_from_unit_index > last_index + 1
  then
    Error
      (Printf.sprintf
         "keep_from_unit_index %d is outside [%d,%d]"
         keep_from_unit_index
         (first_index + 1)
         (last_index + 1))
  else Ok { window; summary; keep_from_unit_index }

let compaction_summary_metadata_key = "masc.compaction.bounded_summary"

let summary_message summary =
  (* Current-format derived state, not a compatibility marker. Eligibility
     already protects metadata-bearing messages, so this single field prevents
     the next pass from repeatedly compacting the same summary and advances the
     oldest-window scan. Its blast radius ends at [eligible_source]. *)
  { (message Agent_sdk.Types.Assistant summary) with
    metadata = [ compaction_summary_metadata_key, `Bool true ]
  }

let summarized_indices plan =
  planning_window_sources plan.window
  |> List.filter_map (fun source ->
    if source.source_index < plan.keep_from_unit_index
    then Some source.source_index
    else None)

let dropped_indices _ = []
let has_changes plan = summarized_indices plan <> []

let apply (plan : compaction_plan) =
  let first_index = plan.window.first_source.source_index in
  plan.window.source_units
  |> List.mapi (fun index unit_ -> index, unit_)
  |> List.concat_map (fun (index, unit_) ->
    if index = first_index
    then [ summary_message plan.summary ]
    else if index > first_index && index < plan.keep_from_unit_index
    then []
    else messages_of_unit unit_)

let exact_output_requirement =
  Exact_output.make_output_requirement
    ~schema:Schema.compaction_plan_output_schema
    ~minimum_guarantee:Exact_output.Json_syntax
;;

type prepared_lane =
  { window : planning_window
  ; registry_generation : int64
  ; ordered_slot_ids : string list
  ; flow_attempt : Exact_output.flow_attempt
  }

let call_id_to_string call_id = Exact_output.call_id_to_string call_id

let observe_flow_attempt_receipt
      (candidate : Exact_output.flow_attempt_receipt)
  =
  let receipt = candidate.receipt in
  let identity = candidate.visit.identity in
  { slot_id = identity.candidate_id
  ; call_id = receipt |> Exact_output.receipt_call_id |> call_id_to_string
  ; catalog_generation_fingerprint =
      identity.catalog_generation
      |> Exact_output.catalog_generation_fingerprint
  ; receipt_plan_fingerprint = Exact_output.receipt_plan_fingerprint receipt
  ; receipt_request_body_sha256 =
      Exact_output.receipt_request_body_sha256 receipt
  }
;;

let terminal_of_observation cause (observation : attempt_observation) =
  Keeper_event_queue_state.
    { cause
    ; slot_id = observation.slot_id
    ; call_id = observation.call_id
    ; plan_fingerprint = observation.receipt_plan_fingerprint
    ; request_body_sha256 = observation.receipt_request_body_sha256
    }
;;

let quarantine_exact_execution ~keeper_name ~exact_execution_guard ~cause observation =
  match exact_execution_guard with
  | None -> Error "exact execution guard is unavailable"
  | Some guard ->
    (match guard.quarantine cause observation with
     | Ok Fsync_completed -> Ok Fsync_completed
     | Ok (Visible_sync_unconfirmed detail as outcome) ->
       Log.Keeper.warn
         ~keeper_name
         "compaction exact terminal quarantine is visible but sync is unconfirmed slot=%s call_id=%s: %s"
         observation.slot_id
         observation.call_id
         detail;
       Ok outcome
     | Error detail ->
       Log.Keeper.error
         ~keeper_name
         "compaction exact terminal quarantine failed slot=%s call_id=%s: %s"
         observation.slot_id
         observation.call_id
         detail;
       Error detail)
;;

let terminal_after_quarantine
      ~keeper_name
      ~exact_execution_guard
      ~cause
      observation
  =
  ignore
    (quarantine_exact_execution
       ~keeper_name
       ~exact_execution_guard
       ~cause
       observation
     : (exact_write_outcome, string) result);
  terminal_of_observation cause observation
;;

let log_terminal_quarantine_failure
      (terminalizer : post_success_terminalizer)
      (terminal : Keeper_event_queue_state.exact_execution_terminal)
      detail
  =
  try
    Log.Keeper.warn
      ~keeper_name:terminalizer.keeper_name
      "post-success exact-execution quarantine failed; retaining canonical \
       terminal slot_id=%s call_id=%s: %s"
      terminal.Keeper_event_queue_state.slot_id
      terminal.call_id
      detail
  with
  | _ -> ()
;;

let make_post_success_completion () =
  let waiter, resolver = Eio.Promise.create () in
  { waiter
  ; resolve =
      (fun () ->
         match Eio.Promise.try_resolve resolver () with
         | true
         | false ->
           ())
  }
;;

let terminal_for terminalizer cause =
  Keeper_event_queue_state.
    { cause
    ; slot_id = terminalizer.attempt_observation.slot_id
    ; call_id = terminalizer.attempt_observation.call_id
    ; plan_fingerprint =
        terminalizer.attempt_observation.receipt_plan_fingerprint
    ; request_body_sha256 =
        terminalizer.attempt_observation.receipt_request_body_sha256
    }
;;

let with_disposition terminalizer callback =
  Eio.Mutex.use_rw ~protect:true terminalizer.disposition_mutex callback
;;

let rejected_terminalization terminal result =
  match result with
  | Ok () -> Terminalized terminal
  | Error detail -> Terminalization_persistence_failed (terminal, detail)
;;

let finish_rejection
      terminalizer
      (terminal : Keeper_event_queue_state.exact_execution_terminal)
      completion
  =
  Eio.Cancel.protect
  @@ fun () ->
  let result =
    match terminalizer.exact_execution_guard with
    | None -> Ok ()
    | Some _ ->
      (try
         match
           quarantine_exact_execution
             ~keeper_name:terminalizer.keeper_name
             ~exact_execution_guard:terminalizer.exact_execution_guard
             ~cause:terminal.cause
             terminalizer.attempt_observation
         with
         | Ok Fsync_completed -> Ok ()
         | Ok (Visible_sync_unconfirmed detail) ->
           Error
             ("post-success exact-execution quarantine sync is unconfirmed: "
              ^ detail)
         | Error detail ->
           Error
             ("post-success exact-execution quarantine failed: " ^ detail)
       with
       | exn ->
         Error
           ("post-success exact-execution quarantine raised: "
            ^ Printexc.to_string exn))
  in
  (match result with
   | Ok () -> ()
   | Error detail ->
     log_terminal_quarantine_failure terminalizer terminal detail);
  with_disposition terminalizer (fun () ->
    match terminalizer.phase with
    | Reject_claimed (claimed, _) when claimed = terminal ->
      terminalizer.phase <- Rejected (terminal, result)
    | Open
    | Commit_claimed _
    | Installed_pending_valid _
    | Committed _
    | Reject_claimed _
    | Rejected _ ->
      ());
  completion.resolve ();
  rejected_terminalization terminal result
;;

let claim_post_success_commit_current terminalizer =
  with_disposition terminalizer (fun () ->
    match terminalizer.phase with
    | Open ->
      let completion = make_post_success_completion () in
      terminalizer.phase <- Commit_claimed completion;
      Commit_claim_acquired
    | Commit_claimed completion
    | Installed_pending_valid completion ->
      Commit_claim_in_progress completion.waiter
    | Committed _ -> Commit_claim_already_committed
    | Reject_claimed (_, completion) ->
      Commit_claim_in_progress completion.waiter
    | Rejected (terminal, result) ->
      Commit_claim_rejected (terminal, result))
;;

let claim_post_success_commit terminalizer =
  claim_post_success_commit_current terminalizer
;;

let with_post_success_commit terminalizer commit =
  match claim_post_success_commit_current terminalizer with
  | Commit_claim_acquired ->
    Post_success_commit_result (commit ())
  | Commit_claim_in_progress waiter ->
    Post_success_commit_in_progress waiter
  | Commit_claim_already_committed ->
    Post_success_commit_already_committed
  | Commit_claim_rejected (terminal, result) ->
    Post_success_commit_rejected (terminal, result)
;;

let mark_post_success_checkpoint_installed terminalizer =
  with_disposition terminalizer (fun () ->
    match terminalizer.phase with
    | Commit_claimed completion ->
      terminalizer.phase <- Installed_pending_valid completion;
      Ok ()
    | Open
    | Installed_pending_valid _
    | Committed _
    | Reject_claimed _
    | Rejected _ ->
      Error "post-success checkpoint installation has no commit claimant")
;;

let complete_post_success_commit terminalizer =
  let completion =
    with_disposition terminalizer (fun () ->
      match terminalizer.phase with
      | Installed_pending_valid completion ->
        terminalizer.domain_valid_attempts <-
          terminalizer.domain_valid_attempts + 1;
        terminalizer.phase <- Committed (Ok ());
        Ok (Some completion)
      | Committed result -> Result.map (fun () -> None) result
      | Open
      | Commit_claimed _
      | Reject_claimed _
      | Rejected _ ->
        Error
          "post-success completion has no installed commit claimant")
  in
  match completion with
  | Error _ as error -> error
  | Ok None -> Ok ()
  | Ok (Some completion) ->
    completion.resolve ();
    Ok ()
;;

let finish_post_success_commit_failure terminalizer detail =
  Eio.Cancel.protect
  @@ fun () ->
  let completion =
    with_disposition terminalizer (fun () ->
      match terminalizer.phase with
      | Installed_pending_valid completion ->
        terminalizer.domain_valid_attempts <-
          terminalizer.domain_valid_attempts + 1;
        terminalizer.phase <- Committed (Error detail);
        Ok (Some completion)
      | Committed result -> Result.map (fun () -> None) result
      | Open
      | Commit_claimed _
      | Reject_claimed _
      | Rejected _ ->
        Error
          "post-success failure has no installed commit claimant")
  in
  match completion with
  | Error _ as error -> error
  | Ok None -> Ok ()
  | Ok (Some completion) ->
    completion.resolve ();
    Error detail
;;

let claim_rejection terminalizer ~from_commit cause =
  with_disposition terminalizer (fun () ->
    match terminalizer.phase, from_commit with
    | Open, false ->
      let terminal = terminal_for terminalizer cause in
      let completion = make_post_success_completion () in
      terminalizer.domain_rejected_attempts <-
        terminalizer.domain_rejected_attempts + 1;
      terminalizer.phase <- Reject_claimed (terminal, completion);
      `Own (terminal, completion)
    | Commit_claimed completion, true ->
      let terminal = terminal_for terminalizer cause in
      terminalizer.domain_rejected_attempts <-
        terminalizer.domain_rejected_attempts + 1;
      terminalizer.phase <- Reject_claimed (terminal, completion);
      `Own (terminal, completion)
    | Reject_claimed (terminal, completion), _ ->
      `Await (terminal, completion)
    | Rejected (terminal, result), _ -> `Done (terminal, result)
    | Commit_claimed completion, false
    | Installed_pending_valid completion, _ ->
      `Commit_in_progress completion.waiter
    | Committed _, _ -> `Already_committed
    | Open, true ->
      `Invariant "commit claimant rejection observed an open disposition")
;;

let finish_claimed_rejection terminalizer role =
  match role with
  | `Own (terminal, completion) ->
    finish_rejection terminalizer terminal completion
  | `Await (terminal, completion) ->
    Eio.Promise.await completion.waiter;
    (match
       with_disposition terminalizer (fun () ->
         match terminalizer.phase with
         | Rejected (durable, result) when durable = terminal ->
           Some result
         | Open
         | Commit_claimed _
         | Installed_pending_valid _
         | Committed _
         | Reject_claimed _
         | Rejected _ ->
           None)
     with
     | Some result -> rejected_terminalization terminal result
     | None ->
       Terminalization_invariant_failed
         "post-success reject waiter completed without canonical rejection")
  | `Done (terminal, result) -> rejected_terminalization terminal result
  | `Commit_in_progress waiter -> Terminalization_commit_in_progress waiter
  | `Already_committed -> Terminalization_already_committed
  | `Invariant detail -> Terminalization_invariant_failed detail
;;

let terminalize_claimed_commit terminalizer cause =
  claim_rejection terminalizer ~from_commit:true cause
  |> finish_claimed_rejection terminalizer
;;

let terminalize_post_success (terminalizer : post_success_terminalizer) cause =
  claim_rejection terminalizer ~from_commit:false cause
  |> finish_claimed_rejection terminalizer
;;

let post_success_snapshot terminalizer =
  with_disposition terminalizer (fun () ->
    let phase =
      match terminalizer.phase with
      | Open -> Phase_open
      | Commit_claimed _ -> Phase_commit_claimed
      | Installed_pending_valid _ -> Phase_installed_pending_valid
      | Committed _ -> Phase_committed
      | Reject_claimed _ -> Phase_reject_claimed
      | Rejected _ -> Phase_rejected
    in
    { phase
    ; domain_valid_attempts = terminalizer.domain_valid_attempts
    ; domain_rejected_attempts = terminalizer.domain_rejected_attempts
    })
;;

let exact_execution_evidence (flow_success : Exact_output.flow_success) =
  let success = Exact_output.flow_success_output flow_success in
  let provenance = success.provenance in
  let identity = Exact_output.plan_provenance_target_identity provenance in
  let observation =
    flow_success
    |> Exact_output.flow_success_candidate
    |> observe_flow_attempt_receipt
  in
  { slot_id = observation.slot_id
  ; call_id = observation.call_id
  ; target_identity_fingerprint =
      Exact_output.target_identity_fingerprint identity
  ; catalog_generation_fingerprint =
      provenance
      |> Exact_output.plan_provenance_catalog_generation
      |> Exact_output.catalog_generation_fingerprint
  ; catalog_evidence_sha256 =
      provenance
      |> Exact_output.plan_provenance_catalog_evidence
      |> Exact_output.catalog_evidence_sha256
  ; plan_fingerprint = observation.receipt_plan_fingerprint
  ; receipt_request_body_sha256 =
      observation.receipt_request_body_sha256
  }
;;

let make_flow_candidates ~keeper_name selected_slots =
  let rec loop candidates = function
    | [] -> Ok (List.rev candidates)
    | (slot : Runtime_exact_output_registry.selected_slot) :: rest ->
      (match
         Exact_output.make_flow_candidate
           ~id:slot.slot_id
           ~admitted_target:slot.admitted_target
       with
       | Ok candidate -> loop (candidate :: candidates) rest
       | Error _ ->
         Log.Keeper.error
           ~keeper_name
           "compaction exact flow candidate rejected opaque slot identity slot=%s"
           slot.slot_id;
         Error Exact_admission_failed)
  in
  loop [] selected_slots
;;

let prepare_lane
      ~base_path:_
      ~keeper_name
      ~registry
      ~lane_id
      ~units
  =
  let* window =
    planning_window_for_units units |> Result.map_error (fun _ -> Invalid_plan)
  in
  let registry_generation = Runtime_exact_output_registry.generation registry in
  match Runtime_exact_output_registry.resolve_lane registry ~lane_id with
  | Error
        (Runtime_exact_output_registry.Exact_lane_unconfigured
           { lane_id = missing_lane_id }) ->
      Log.Keeper.warn
        ~keeper_name
        "compaction exact lane is unconfigured generation=%Ld lane_id=%s"
        registry_generation
        missing_lane_id;
      Error Exact_lane_unconfigured
  | Error
        (Runtime_exact_output_registry.No_admitted_lane_slots
           { lane_id = empty_lane_id }) ->
      Log.Keeper.warn
        ~keeper_name
        "compaction exact lane has no admitted opaque slots generation=%Ld lane_id=%s"
        registry_generation
        empty_lane_id;
      Error Exact_target_selection_failed
  | Ok { selected_slots } ->
    let messages = messages_for_plan ~window in
    let* candidates = make_flow_candidates ~keeper_name selected_slots in
    (match candidates with
     | [] -> Error Exact_target_selection_failed
     | first :: rest ->
       (match
          Exact_output.snapshot_flow
            ~first
            ~rest
            ~messages
            exact_output_requirement
        with
        | Error _ ->
          Log.Keeper.warn
            ~keeper_name
            "compaction exact flow admission rejected generation=%Ld lane_id=%s candidate_count=%d"
            registry_generation
            lane_id
            (List.length candidates);
          Error Exact_admission_failed
        | Ok flow_snapshot ->
          (match Exact_output.start_flow flow_snapshot with
           | Error _ ->
             Log.Keeper.error
               ~keeper_name
               "compaction exact flow identity allocation failed generation=%Ld lane_id=%s"
               registry_generation
               lane_id;
             Error Exact_attempt_start_failed
           | Ok flow_attempt ->
             Ok
               { window
               ; registry_generation
               ; ordered_slot_ids =
                   List.map
                     (fun (slot : Runtime_exact_output_registry.selected_slot) ->
                        slot.slot_id)
                     selected_slots
               ; flow_attempt
               })))
;;

type exact_flow_callback_failure =
  | Authority_absent
  | Authority_rejected
  | Bind_failed
  | Bind_sync_unconfirmed of Keeper_event_queue_state.exact_execution_terminal
  | Release_failed of Keeper_event_queue_state.exact_execution_terminal
  | Release_sync_unconfirmed of Keeper_event_queue_state.exact_execution_terminal

let bind_exact_execution
      ~keeper_name
      ~before_dispatch_authority
      ~exact_execution_guard
      observation
  =
  let authorize () =
    match before_dispatch_authority, exact_execution_guard with
    | None, None -> Error Authority_absent
    | None, Some _ -> Ok ()
    | Some authorize, _ ->
      (match authorize observation with
       | Ok () -> Ok ()
       | Error detail ->
         Log.Keeper.error
           ~keeper_name
           "compaction lifecycle authority rejected dispatch slot=%s call_id=%s: %s"
           observation.slot_id
           observation.call_id
           detail;
         Error Authority_rejected)
  in
  match authorize () with
  | Error _ as error -> error
  | Ok () ->
    (match exact_execution_guard with
     | None -> Ok ()
     | Some guard ->
    (match guard.before_dispatch observation with
     | Ok Fsync_completed -> Ok ()
     | Error detail ->
       Log.Keeper.error
         ~keeper_name
         "compaction exact durable bind failed slot=%s call_id=%s: %s"
         observation.slot_id
         observation.call_id
         detail;
       Error Bind_failed
     | Ok (Visible_sync_unconfirmed detail) ->
       Log.Keeper.error
         ~keeper_name
         "compaction exact durable bind is visible but sync is unconfirmed slot=%s call_id=%s: %s"
         observation.slot_id
         observation.call_id
         detail;
       Error
         (Bind_sync_unconfirmed
            (terminal_of_observation
               Keeper_event_queue_state.Terminal_persistence_failed
               observation))))
;;

let release_exact_execution
      ~keeper_name
      ~exact_execution_guard
      observation
  =
  let terminal () =
    terminal_of_observation
      Keeper_event_queue_state.Terminal_persistence_failed
      observation
  in
  match exact_execution_guard with
  | None -> Ok ()
  | Some guard ->
    (match guard.release_before_dispatch observation with
     | Ok Fsync_completed -> Ok ()
     | Error detail ->
       Log.Keeper.error
         ~keeper_name
         "compaction exact durable release failed slot=%s call_id=%s: %s"
         observation.slot_id
         observation.call_id
         detail;
       Error (Release_failed (terminal ()))
     | Ok (Visible_sync_unconfirmed detail) ->
       Log.Keeper.error
         ~keeper_name
         "compaction exact durable release is visible but sync is unconfirmed slot=%s call_id=%s: %s"
         observation.slot_id
         observation.call_id
         detail;
       Error (Release_sync_unconfirmed (terminal ())))
;;

let summarization_failure_of_callback = function
  | Authority_absent -> Exact_execution_authority_absent
  | Authority_rejected -> Exact_execution_authority_rejected
  | Bind_failed -> Exact_execution_bind_failed
  | Bind_sync_unconfirmed terminal
  | Release_failed terminal
  | Release_sync_unconfirmed terminal ->
    Exact_execution_terminal terminal
;;

let execute_prepared_lane_current
      ~keeper_name
      ~net
      ?clock
      ?before_dispatch_authority
      ?exact_execution_guard
      prepared_lane
  =
  let bound_observation = ref None in
  let before_dispatch candidate =
    let observation = observe_flow_attempt_receipt candidate in
    let* () =
      match !bound_observation with
      | None -> Ok ()
      | Some previous ->
        let* () =
          release_exact_execution
            ~keeper_name
            ~exact_execution_guard
            previous
        in
        bound_observation := None;
        Ok ()
    in
    let* () =
      bind_exact_execution
        ~keeper_name
        ~before_dispatch_authority
        ~exact_execution_guard
        observation
    in
    if
      Option.is_some exact_execution_guard
      || Option.is_some before_dispatch_authority
    then bound_observation := Some observation;
    Ok ()
  in
  let before_advance ~failed ~next:_ =
    match failed with
    | Exact_output.Flow_candidate_rejected _ -> Ok ()
    | Exact_output.Flow_candidate_execution_failed { candidate; cause = _ } ->
      let observation = observe_flow_attempt_receipt candidate in
      let* () =
        release_exact_execution
          ~keeper_name
          ~exact_execution_guard
          observation
      in
      bound_observation := None;
      Ok ()
  in
  let validate flow_success =
    let success = Exact_output.flow_success_output flow_success in
    match plan_of_json ~window:prepared_lane.window success.output with
    | Ok plan -> Exact_output.Accept plan
    | Error detail ->
      let observation =
        flow_success
        |> Exact_output.flow_success_candidate
        |> observe_flow_attempt_receipt
      in
      Log.Keeper.warn
        ~keeper_name
        "compaction exact output violated MASC domain plan slot=%s call_id=%s: %s"
        observation.slot_id
        observation.call_id
        detail;
      Exact_output.Reject_and_advance detail
  in
  let execution =
    try
      `Flow
        (Exact_output.execute_flow_once
           ~net
           ?clock
           ~before_measurement_dispatch:(fun _ -> Ok ())
           ~on_measurement_terminal:(fun _ -> Ok ())
           ~before_dispatch
           ~before_advance
           ~validate
           prepared_lane.flow_attempt)
    with
    | Eio.Cancel.Cancelled _ as cancellation ->
      let raw_bt = Printexc.get_raw_backtrace () in
      (* A durable bind is MASC's only ownership signal. MASC deliberately does
         not inspect OAS receipt phase/count after cancellation. If OAS had
         proved safe advancement it would first invoke [before_advance], whose
         fsynced release clears [bound_observation]. Therefore a still-bound
         identity is always source-terminal; a pre-bind cancellation is
         re-raised. *)
      (match !bound_observation with
       | None -> Printexc.raise_with_backtrace cancellation raw_bt
      | Some observation ->
        `Bound_cancellation observation)
  in
  let release_retained_semantic_binding fallback =
    match !bound_observation with
    | None -> fallback
    | Some observation ->
      (match
         release_exact_execution
           ~keeper_name
           ~exact_execution_guard
           observation
       with
       | Ok () ->
         bound_observation := None;
         fallback
       | Error cause ->
         Error (summarization_failure_of_callback cause))
  in
  let settle_execution () =
  match execution with
  | `Bound_cancellation observation ->
    Log.Keeper.warn
      ~keeper_name
      "compaction exact cancellation quarantines only the durably bound identity slot=%s call_id=%s"
      observation.slot_id
      observation.call_id;
    Error
      (Exact_execution_terminal
         (terminal_after_quarantine
            ~keeper_name
            ~exact_execution_guard
            ~cause:Keeper_event_queue_state.Exact_execution_cancelled
            observation))
  | `Flow
      (Error
        (Exact_output.Flow_execution_terminal
          { cause = Exact_output.Flow_attempt_already_started _; _ })) ->
    Error Exact_flow_already_started
  | `Flow
      (Error
        (Exact_output.Flow_execution_terminal
          { cause =
              ( Exact_output.Flow_attempt_start_failed _
              | Exact_output.Flow_measurement_start_failed _
              | Exact_output.Flow_candidates_exhausted _ )
          ; _
          })) ->
    release_retained_semantic_binding
      (Error Exact_attempt_start_failed)
  | `Flow
      (Error
        (Exact_output.Flow_execution_terminal
          { cause =
              ( Exact_output.Flow_before_measurement_dispatch_callback_failed
                  { cause; _ }
              | Exact_output.Flow_measurement_terminal_callback_failed
                  { cause; _ }
              | Exact_output.Flow_before_dispatch_callback_failed
                  { cause; _ } )
          ; _
          })) ->
    Error (summarization_failure_of_callback cause)
  | `Flow
      (Error
        (Exact_output.Flow_execution_terminal
          { cause =
              Exact_output.Flow_before_advance_callback_failed
                { cause; _ }
          ; _
          })) ->
    Error (summarization_failure_of_callback cause)
  | `Flow
      (Error
        (Exact_output.Flow_execution_terminal
          { cause =
              Exact_output.Flow_exact_execution_failed
                { candidate; _ }
          ; _
          })) ->
    let observation = observe_flow_attempt_receipt candidate in
    Error
      (Exact_execution_terminal
         (terminal_after_quarantine
            ~keeper_name
            ~exact_execution_guard
            ~cause:Keeper_event_queue_state.Exact_execution_failed
            observation))
  | `Flow
      (Error
        (Exact_output.Flow_semantic_candidates_exhausted
          { rejections; evidence = _ })) ->
    let rejection =
      List.fold_left
        (fun _ rejection -> rejection)
        rejections.first
        rejections.rest
    in
    let flow_success = rejection.transport_success in
    let observation =
      flow_success
      |> Exact_output.flow_success_candidate
      |> observe_flow_attempt_receipt
    in
    Log.Keeper.warn
      ~keeper_name
      "compaction exact semantic candidates exhausted slot=%s call_id=%s: %s"
      observation.slot_id
      observation.call_id
      rejection.rejection;
    Error
      (Exact_execution_terminal
         (terminal_after_quarantine
            ~keeper_name
            ~exact_execution_guard
            ~cause:Keeper_event_queue_state.Domain_invalid_output
            observation))
  | `Flow (Ok validated) ->
    let flow_success = validated.transport_success in
    let observation =
      flow_success
      |> Exact_output.flow_success_candidate
      |> observe_flow_attempt_receipt
    in
    Ok
      { plan = validated.accepted
      ; exact_execution_evidence = exact_execution_evidence flow_success
      ; post_success_terminalizer =
          { keeper_name
          ; exact_execution_guard
          ; attempt_observation = observation
          ; disposition_mutex = Eio.Mutex.create ()
          ; phase = Open
          ; domain_valid_attempts = 0
          ; domain_rejected_attempts = 0
          }
      }
  in
  match execution with
  | `Bound_cancellation _ -> Eio.Cancel.protect settle_execution
  | `Flow _ -> settle_execution ()
;;

let execute_prepared_lane
      ~keeper_name
      ~net
      ?clock
      ?before_dispatch_authority
      ?exact_execution_guard
      prepared_lane
  =
  execute_prepared_lane_current
    ~keeper_name
    ~net
    ?clock
    ?before_dispatch_authority
    ?exact_execution_guard
    prepared_lane
;;

let run_exact
      ?before_dispatch_authority
      ?exact_execution_guard
      ~base_path
      ~keeper_name
      ~sw:_
      ~net
      ~clock
      ~units
      ()
  =
  if not (has_eligible_units units)
  then Error Invalid_plan
  else
    match Runtime_exact_output_registry.current () with
    | Error _ -> Error Exact_target_selection_failed
    | Ok registry ->
      let* prepared_lane =
        prepare_lane
          ~base_path
          ~keeper_name
          ~registry
          ~lane_id:"compaction_exact"
          ~units
      in
      execute_prepared_lane
        ~keeper_name
        ~net
        ?clock
        ?before_dispatch_authority
        ?exact_execution_guard
        prepared_lane
;;

let make_resolved
      ?before_dispatch_authority
      ?exact_execution_guard
      ~base_path
      ~(keeper_name : string)
      ()
      : summarizer option
  =
  match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
  | Some sw, Some net ->
    let clock = Eio_context.get_clock_opt () in
    Some
      (fun ~units ->
         run_exact
           ?before_dispatch_authority
           ?exact_execution_guard
           ~base_path
           ~keeper_name
           ~sw
           ~net
           ~clock
           ~units
           ())
  | _ -> None
;;

let make
      ?before_dispatch_authority
      ?exact_execution_guard
      ~base_path
      ~keeper_name
      ()
  =
  make_resolved
    ?before_dispatch_authority
    ?exact_execution_guard
    ~base_path
    ~keeper_name
    ()
;;

let completed_plan completed = completed.plan
let completed_exact_execution_evidence completed = completed.exact_execution_evidence
let completed_post_success_terminalizer completed = completed.post_success_terminalizer

let completed_attempt_observation completed =
  completed.post_success_terminalizer.attempt_observation
;;

let exact_execution_evidence_slot_id (evidence : exact_execution_evidence) = evidence.slot_id
let exact_execution_evidence_call_id (evidence : exact_execution_evidence) = evidence.call_id

let exact_execution_evidence_target_identity_fingerprint
      (evidence : exact_execution_evidence) =
  evidence.target_identity_fingerprint
;;

let exact_execution_evidence_catalog_generation_fingerprint
      (evidence : exact_execution_evidence) =
  evidence.catalog_generation_fingerprint
;;

let exact_execution_evidence_catalog_evidence_sha256
      (evidence : exact_execution_evidence) =
  evidence.catalog_evidence_sha256
;;

let exact_execution_evidence_plan_fingerprint (evidence : exact_execution_evidence) =
  evidence.plan_fingerprint
;;

let exact_execution_evidence_receipt_request_body_sha256
      (evidence : exact_execution_evidence) =
  evidence.receipt_request_body_sha256
;;

module For_testing = struct
  let messages_for_plan = messages_for_plan
  let planning_window_for_units = planning_window_for_units
  let planning_window_source_indices window =
    List.map
      (fun source -> source.source_index)
      (planning_window_sources window)
  ;;

  let flow_slot_ids prepared_lane = prepared_lane.ordered_slot_ids
  let registry_generation prepared_lane = prepared_lane.registry_generation

  let attempt_observations prepared_lane =
    let evidence : Exact_output.flow_evidence =
      Exact_output.flow_attempt_evidence prepared_lane.flow_attempt
    in
    List.map
      (fun (candidate : Exact_output.flow_attempt_snapshot) ->
        let receipt = candidate.receipt in
        { slot_id = candidate.visit.identity.candidate_id
        ; call_id =
            receipt
            |> Exact_output.generation_receipt_snapshot_call_id
            |> call_id_to_string
        ; catalog_generation_fingerprint =
            candidate.visit.identity.catalog_generation
            |> Exact_output.catalog_generation_fingerprint
        ; receipt_plan_fingerprint =
            Exact_output.generation_receipt_snapshot_plan_fingerprint receipt
        ; receipt_request_body_sha256 =
            Exact_output.generation_receipt_snapshot_request_body_sha256 receipt
        })
      evidence.attempts
  ;;

  let candidate_snapshot_slot_ids prepared_lane =
    let evidence : Exact_output.flow_evidence =
      Exact_output.flow_attempt_evidence prepared_lane.flow_attempt
    in
    List.map
      (fun (candidate : Exact_output.flow_candidate_identity) ->
        candidate.candidate_id)
      evidence.declared_candidate_snapshot
  ;;

  let post_success_snapshot = post_success_snapshot
end
