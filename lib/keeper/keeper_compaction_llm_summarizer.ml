(** LLM-backed keeper context compaction over the OAS exact-output surface.
    See keeper_compaction_llm_summarizer.mli. MASC owns the domain plan while
    OAS owns frozen target admission, dispatch, and receipt provenance. *)

module Schema = Keeper_structured_output_schema
module Exact_output = Agent_sdk.Exact_output
module Int_set = Set.Make (Int)
module Int_map = Map.Make (Int)
module String_set = Set.Make (String)

type eligible_source =
  { source_index : int
  ; message : Agent_sdk.Types.message
  ; text_blocks : string list
  }

type action =
  | Keep
  | Drop
  | Summarize of string

type decision =
  { source : eligible_source
  ; action : action
  }

type compaction_plan =
  { decisions : decision list
  ; source_units : Keeper_compaction_unit.closed_unit list
  }

type exact_execution_evidence =
  { slot_id : string
  ; call_id : string
  ; target_identity_fingerprint : string
  ; catalog_generation_fingerprint : string
  ; catalog_evidence_sha256 : string
  ; plan_fingerprint : string
  ; receipt_plan_fingerprint : string
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
  { base_path : string
  ; keeper_name : string
  ; flow_scope : Keeper_exact_flow_scope.t
  ; flow_success : Exact_output.flow_success
  ; exact_execution_guard : exact_execution_guard
  ; attempt_observation : attempt_observation
  ; disposition_mutex : Eio.Mutex.t
  ; mutable phase : post_success_phase
  ; mutable domain_valid_attempts : int
  ; mutable domain_rejected_attempts : int
  }

type 'a post_success_boundary =
  | Post_success_current of 'a
  | Post_success_owner_unregistered_deferred

type post_success_terminalization =
  | Terminalized of Keeper_event_queue_state.exact_execution_terminal
  | Terminalization_persistence_failed of
      Keeper_event_queue_state.exact_execution_terminal * string
  | Terminalization_commit_in_progress of unit Eio.Promise.t
  | Terminalization_already_committed
  | Terminalization_invariant_failed of string
  | Terminalization_owner_unregistered_deferred

type post_success_commit_claim =
  | Commit_claim_acquired
  | Commit_claim_in_progress of unit Eio.Promise.t
  | Commit_claim_already_committed
  | Commit_claim_rejected of
      Keeper_event_queue_state.exact_execution_terminal
      * (unit, string) result
  | Commit_claim_owner_unregistered_deferred

type 'a post_success_commit_boundary =
  | Post_success_commit_owner_result of 'a
  | Post_success_commit_in_progress of unit Eio.Promise.t
  | Post_success_commit_already_committed
  | Post_success_commit_rejected of
      Keeper_event_queue_state.exact_execution_terminal
      * (unit, string) result
  | Post_success_commit_owner_unregistered_deferred

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
  | Exact_owner_unregistered_deferred
  | Exact_execution_context_unavailable
  | Exact_execution_guard_absent
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

let text_blocks blocks =
  List.fold_right
    (fun block texts ->
      match block, texts with
      | Agent_sdk.Types.Text text, Some texts -> Some (text :: texts)
      | ( Agent_sdk.Types.Thinking _
        | Agent_sdk.Types.ReasoningDetails _
        | Agent_sdk.Types.RedactedThinking _
        | Agent_sdk.Types.ToolUse _
        | Agent_sdk.Types.ToolResult _
        | Agent_sdk.Types.Image _
        | Agent_sdk.Types.Document _
        | Agent_sdk.Types.Audio _ )
        , _ ->
        None
      | _, None -> None)
    blocks
    (Some [])

let eligible_source source_index = function
  | Keeper_compaction_unit.Ordinary_message
      ({ role = Agent_sdk.Types.Assistant
       ; content
       ; name = None
       ; tool_call_id = None
       ; metadata = []
       } as message) ->
    (match text_blocks content with
     | Some (_ :: _ as text_blocks)
       when List.exists (fun text -> String.trim text <> "") text_blocks ->
       Some { source_index; message; text_blocks }
     | Some [] | Some (_ :: _) | None -> None)
  | Keeper_compaction_unit.Ordinary_message _
  | Keeper_compaction_unit.Closed_tool_cycle _ ->
    None

let eligible_sources units =
  units
  |> List.mapi eligible_source
  |> List.filter_map Fun.id

let has_eligible_units units = eligible_sources units <> []

let eligible_units_json sources =
  `List
    (List.map
       (fun source ->
         `Assoc
           [ Schema.compaction_plan_field_unit_index, `Int source.source_index
           ; "role", `String (Agent_sdk.Types.role_to_string source.message.role)
           ; "text_blocks", `List (List.map (fun text -> `String text) source.text_blocks)
           ])
       sources)

let messages_for_plan ~units =
  let sources = eligible_sources units in
  let system =
    "You compact only the explicitly supplied eligible Assistant text units. \
     Return exactly one decision for every supplied unit_index and do not \
     invent indices. keep preserves the source verbatim. summarize replaces \
     that unit in place with its faithful summary. drop is valid only when the \
     unit contributes no state, decision, evidence, constraint, unresolved \
     work, or outcome. For keep and drop, summary must be null. For summarize, \
     summary must be a non-empty string. Do not infer recency policy, merge \
     units, relocate facts, invent facts, or include markdown fences. Respond \
     with a single JSON object and no other text."
  in
  let user =
    Printf.sprintf
      "eligible_units=%s\nReturn {\"%s\":[{\"%s\":integer,\"%s\":\
       \"%s|%s|%s\",\"%s\":string|null}]} with exactly one decision per \
       supplied unit_index."
      (eligible_units_json sources |> Yojson.Safe.to_string)
      Schema.compaction_plan_field_decisions
      Schema.compaction_plan_field_unit_index
      Schema.compaction_plan_field_action
      Schema.compaction_plan_action_keep
      Schema.compaction_plan_action_drop
      Schema.compaction_plan_action_summarize
      Schema.compaction_plan_field_summary
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

let summary_value ~field = function
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ -> Error (field ^ " must be a string or null")

let parse_action ~action_token ~summary =
  if String.equal action_token Schema.compaction_plan_action_keep
  then
    (match summary with
     | None -> Ok Keep
     | Some _ -> Error "keep decision summary must be null")
  else if String.equal action_token Schema.compaction_plan_action_drop
  then
    (match summary with
     | None -> Ok Drop
     | Some _ -> Error "drop decision summary must be null")
  else if String.equal action_token Schema.compaction_plan_action_summarize
  then
    (match summary with
     | Some summary when String.trim summary <> "" -> Ok (Summarize summary)
     | Some _ -> Error "summarize decision summary must be non-empty"
     | None -> Error "summarize decision summary must be a string")
  else Error ("unknown compaction action " ^ action_token)

let decision_of_json sources_by_index json =
  let expected_fields =
    [ Schema.compaction_plan_field_unit_index
    ; Schema.compaction_plan_field_action
    ; Schema.compaction_plan_field_summary
    ]
  in
  let* fields = object_fields ~context:"decision" ~expected:expected_fields json in
  let* index_json = required_field Schema.compaction_plan_field_unit_index fields in
  let* source_index =
    int_value ~field:Schema.compaction_plan_field_unit_index index_json
  in
  let* source =
    match Int_map.find_opt source_index sources_by_index with
    | Some source -> Ok source
    | None -> Error (Printf.sprintf "unit_index %d is not eligible" source_index)
  in
  let* action_json = required_field Schema.compaction_plan_field_action fields in
  let* action_token =
    string_value ~field:Schema.compaction_plan_field_action action_json
  in
  let* summary_json = required_field Schema.compaction_plan_field_summary fields in
  let* summary = summary_value ~field:Schema.compaction_plan_field_summary summary_json in
  let* action = parse_action ~action_token ~summary in
  Ok { source; action }

let decisions_value json =
  let expected = [ Schema.compaction_plan_field_decisions ] in
  let* fields = object_fields ~context:"plan" ~expected json in
  let* decisions = required_field Schema.compaction_plan_field_decisions fields in
  match decisions with
  | `List decisions -> Ok decisions
  | _ -> Error (Schema.compaction_plan_field_decisions ^ " must be an array")

let parse_decisions ~sources decisions_json =
  let sources_by_index =
    List.fold_left
      (fun sources source -> Int_map.add source.source_index source sources)
      Int_map.empty
      sources
  in
  let rec parse seen decisions = function
    | [] -> Ok (List.rev decisions, seen)
    | json :: rest ->
      let* decision = decision_of_json sources_by_index json in
      let source_index = decision.source.source_index in
      if Int_set.mem source_index seen
      then Error (Printf.sprintf "unit_index %d appears more than once" source_index)
      else parse (Int_set.add source_index seen) (decision :: decisions) rest
  in
  parse Int_set.empty [] decisions_json

let plan_of_json ~units json =
  let sources = eligible_sources units in
  if sources = []
  then Error "source contains no eligible compaction units"
  else
  let expected_indices =
    List.fold_left
      (fun indices source -> Int_set.add source.source_index indices)
      Int_set.empty
      sources
  in
  let* decisions_json = decisions_value json in
  let* decisions, seen = parse_decisions ~sources decisions_json in
  let missing = Int_set.diff expected_indices seen |> Int_set.elements in
  let* () =
    if missing = []
    then Ok ()
    else
      Error
        (Printf.sprintf
           "eligible unit indices not covered: %s"
           (String.concat "," (List.map string_of_int missing)))
  in
  let* () =
    if List.exists
         (fun decision ->
           match decision.action with
           | Drop | Summarize _ -> true
           | Keep -> false)
         decisions
    then Ok ()
    else Error "plan keeps every eligible unit without changing any"
  in
  let* () =
    if List.exists
         (fun decision ->
           match decision.action with
           | Keep | Summarize _ -> true
           | Drop -> false)
         decisions
    then Ok ()
    else Error "plan would remove every eligible unit"
  in
  let decisions =
    List.sort
      (fun left right -> Int.compare left.source.source_index right.source.source_index)
      decisions
  in
  Ok { decisions; source_units = units }

let apply (plan : compaction_plan) =
  let decisions =
    List.fold_left
      (fun decisions decision ->
        Int_map.add decision.source.source_index decision decisions)
      Int_map.empty
      plan.decisions
  in
  plan.source_units
  |> List.mapi (fun idx unit_ -> idx, unit_)
  |> List.concat_map (fun (idx, unit_) ->
    match Int_map.find_opt idx decisions with
    | None | Some { action = Keep; _ } -> messages_of_unit unit_
    | Some { action = Drop; _ } -> []
    | Some { source; action = Summarize summary } ->
      [ { source.message with
          content = [ Agent_sdk.Types.Text summary ]
        }
      ])

let indices_for_action predicate plan =
  plan.decisions
  |> List.filter_map (fun decision ->
    if predicate decision.action then Some decision.source.source_index else None)

let summarized_indices = indices_for_action (function Summarize _ -> true | Keep | Drop -> false)
let dropped_indices = indices_for_action (function Drop -> true | Keep | Summarize _ -> false)
let has_changes plan = summarized_indices plan <> [] || dropped_indices plan <> []

let exact_output_requirement =
  Exact_output.make_output_requirement
    ~schema:Schema.compaction_plan_output_schema
    ~minimum_guarantee:Exact_output.Json_syntax
;;

type prepared_lane =
  { base_path : string
  ; keeper_name : string
  ; flow_scope : Keeper_exact_flow_scope.t
  ; units : Keeper_compaction_unit.closed_unit list
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

let observe_flow_attempt_snapshot
      (candidate : Exact_output.flow_attempt_snapshot)
  =
  let receipt = candidate.receipt in
  let identity = candidate.visit.identity in
  { slot_id = identity.candidate_id
  ; call_id =
      receipt
      |> Exact_output.generation_receipt_snapshot_call_id
      |> call_id_to_string
  ; catalog_generation_fingerprint =
      identity.catalog_generation
      |> Exact_output.catalog_generation_fingerprint
  ; receipt_plan_fingerprint =
      Exact_output.generation_receipt_snapshot_plan_fingerprint receipt
  ; receipt_request_body_sha256 =
      Exact_output.generation_receipt_snapshot_request_body_sha256 receipt
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

let with_current_post_success
      (terminalizer : post_success_terminalizer)
      callback
  =
  match
    Keeper_exact_flow_scope.with_settlement
      terminalizer.flow_scope
      ~registered_lane_id:
        (fun () ->
           match
             Keeper_registry.get
               ~base_path:terminalizer.base_path
               terminalizer.keeper_name
           with
           | Some entry -> Some (Keeper_lane.id entry.lane)
           | None -> None)
      callback
  with
  | Keeper_exact_flow_scope.Current value -> Post_success_current value
  | Keeper_exact_flow_scope.Owner_unregistered_deferred ->
    Post_success_owner_unregistered_deferred
;;

let domain_settlement_error_to_string = function
  | Exact_output.Domain_already_settled ->
    "OAS exact flow domain disposition was already settled"
  | Exact_output.Domain_preference_scope_released ->
    "OAS exact flow preference scope was released before domain settlement"
;;

let settle_exact_flow_domain flow_success disposition =
  Exact_output.settle_flow_domain flow_success disposition
  |> Result.map (fun _ -> ())
  |> Result.map_error domain_settlement_error_to_string
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
    match
      settle_exact_flow_domain
        terminalizer.flow_success
        Exact_output.Domain_rejected
    with
    | Error detail ->
      Error
        ("post-success reject claimant could not settle OAS domain: " ^ detail)
    | Ok () ->
      let quarantine_result =
        try
          match
            quarantine_exact_execution
              ~keeper_name:terminalizer.keeper_name
              ~exact_execution_guard:(Some terminalizer.exact_execution_guard)
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
             ^ Printexc.to_string exn)
      in
      (match quarantine_result with
       | Ok () -> ()
       | Error detail ->
         log_terminal_quarantine_failure terminalizer terminal detail);
      quarantine_result
  in
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
  match
    with_current_post_success terminalizer (fun () ->
      claim_post_success_commit_current terminalizer)
  with
  | Post_success_current claim -> claim
  | Post_success_owner_unregistered_deferred ->
    Commit_claim_owner_unregistered_deferred
;;

let with_post_success_commit terminalizer commit =
  match
    with_current_post_success terminalizer (fun () ->
      match claim_post_success_commit_current terminalizer with
      | Commit_claim_acquired ->
        Post_success_commit_owner_result (commit ())
      | Commit_claim_in_progress waiter ->
        Post_success_commit_in_progress waiter
      | Commit_claim_already_committed ->
        Post_success_commit_already_committed
      | Commit_claim_rejected (terminal, result) ->
        Post_success_commit_rejected (terminal, result)
      | Commit_claim_owner_unregistered_deferred ->
        Post_success_commit_owner_unregistered_deferred)
  with
  | Post_success_current result -> result
  | Post_success_owner_unregistered_deferred ->
    Post_success_commit_owner_unregistered_deferred
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

let finalize_installed_commit terminalizer completion result =
  with_disposition terminalizer (fun () ->
    match terminalizer.phase with
    | Installed_pending_valid current when current == completion ->
      terminalizer.phase <- Committed result
    | Open
    | Commit_claimed _
    | Installed_pending_valid _
    | Committed _
    | Reject_claimed _
    | Rejected _ ->
      ());
  completion.resolve ();
  result
;;

let settle_post_success_domain_valid_with_failure
      ?(settle_domain = settle_exact_flow_domain)
      ?(on_await = fun () -> ())
      terminalizer
      ~failure_detail
  =
  let role =
    with_disposition terminalizer (fun () ->
      match terminalizer.phase with
      | Installed_pending_valid completion
        when terminalizer.domain_valid_attempts = 0 ->
        terminalizer.domain_valid_attempts <-
          terminalizer.domain_valid_attempts + 1;
        `Own completion
      | Installed_pending_valid completion ->
        `Await completion
      | Committed result -> `Done result
      | Open
      | Commit_claimed _
      | Reject_claimed _
      | Rejected _ ->
        `Done
          (Error
             "post-success Domain_valid settlement has no installed commit claimant"))
  in
  match role with
  | `Done result -> result
  | `Await completion ->
    on_await ();
    Eio.Promise.await completion.waiter;
    with_disposition terminalizer (fun () ->
      match terminalizer.phase with
      | Committed result -> result
      | Open
      | Commit_claimed _
      | Installed_pending_valid _
      | Reject_claimed _
      | Rejected _ ->
        Error
          "post-success Domain_valid waiter completed without canonical commit")
  | `Own completion ->
    let result =
      try
        settle_domain terminalizer.flow_success Exact_output.Domain_valid
        |> Result.map_error (fun detail ->
          "post-success commit claimant could not settle OAS domain: " ^ detail)
      with
      | exn ->
        Error
          (failure_detail ^ ": " ^ Printexc.to_string exn)
    in
    finalize_installed_commit terminalizer completion result
;;

let settle_post_success_domain_valid terminalizer =
  settle_post_success_domain_valid_with_failure
    terminalizer
    ~failure_detail:"post-success Domain_valid settlement raised"
;;

let finish_post_success_commit_failure terminalizer detail =
  Eio.Cancel.protect (fun () ->
    settle_post_success_domain_valid_with_failure
      terminalizer
      ~failure_detail:detail)
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
  match
    with_current_post_success terminalizer (fun () ->
      claim_rejection terminalizer ~from_commit:false cause
      |> finish_claimed_rejection terminalizer)
  with
  | Post_success_current terminalization -> terminalization
  | Post_success_owner_unregistered_deferred ->
    Terminalization_owner_unregistered_deferred
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
  let identity = provenance.target_identity in
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
      Exact_output.catalog_generation_fingerprint provenance.catalog_generation
  ; catalog_evidence_sha256 =
      Exact_output.catalog_evidence_sha256 provenance.catalog_evidence
  ; plan_fingerprint = observation.receipt_plan_fingerprint
  ; receipt_plan_fingerprint = observation.receipt_plan_fingerprint
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

let registered_lane_id ~base_path ~keeper_name () =
  match Keeper_registry.get ~base_path keeper_name with
  | Some entry -> Some (Keeper_lane.id entry.lane)
  | None -> None
;;

let prepare_lane_with_scope
      ~base_path
      ~flow_scope
      ~keeper_name
      ~registry
      ~lane_id
     ~units
  =
  if not (has_eligible_units units)
  then Error Invalid_plan
  else
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
      let messages = messages_for_plan ~units in
      let* candidates = make_flow_candidates ~keeper_name selected_slots in
      (match candidates with
       | [] -> Error Exact_target_selection_failed
       | first :: rest ->
         (match
            Exact_output.snapshot_flow
              ~preferences:
                (Keeper_exact_flow_scope.preference_store flow_scope)
              ~scope:(Keeper_exact_flow_scope.scope flow_scope)
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
                 { base_path
                 ; keeper_name
                 ; flow_scope
                 ; units
                 ; registry_generation
                 ; ordered_slot_ids =
                     List.map
                       (fun (slot : Runtime_exact_output_registry.selected_slot) ->
                          slot.slot_id)
                       selected_slots
                 ; flow_attempt
                 })))
;;

let prepare_lane ~base_path ~keeper_name ~registry ~lane_id ~units =
  let* flow_scope =
    Keeper_exact_flow_scope.for_registered
      ~registered_lane_id:(registered_lane_id ~base_path ~keeper_name)
      ~base_path
      ~keeper_name
      ~surface:Keeper_exact_flow_scope.Compaction
    |> Result.map_error (fun _ -> Exact_execution_context_unavailable)
  in
  match
    Keeper_exact_flow_scope.with_current
      flow_scope
      ~registered_lane_id:(registered_lane_id ~base_path ~keeper_name)
      (fun () ->
         prepare_lane_with_scope
           ~base_path
           ~flow_scope
           ~keeper_name
           ~registry
           ~lane_id
           ~units)
  with
  | Keeper_exact_flow_scope.Current result -> result
  | Keeper_exact_flow_scope.Owner_unregistered_deferred ->
    Error Exact_execution_context_unavailable
;;

type exact_flow_callback_failure =
  | Owner_unregistered_deferred
  | Guard_absent
  | Bind_failed
  | Bind_sync_unconfirmed of Keeper_event_queue_state.exact_execution_terminal
  | Release_failed of Keeper_event_queue_state.exact_execution_terminal
  | Release_sync_unconfirmed of Keeper_event_queue_state.exact_execution_terminal

let bind_exact_execution
      ~keeper_name
      ~exact_execution_guard
      observation
  =
  match exact_execution_guard with
  | None ->
    Log.Keeper.error
      ~keeper_name
      "compaction exact durable execution guard is unavailable slot=%s call_id=%s"
      observation.slot_id
      observation.call_id;
    Error Guard_absent
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
               observation)))
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
  | None ->
    Log.Keeper.error
      ~keeper_name
      "compaction exact durable release guard is unavailable slot=%s call_id=%s"
      observation.slot_id
      observation.call_id;
    Error (Release_failed (terminal ()))
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
  | Owner_unregistered_deferred -> Exact_owner_unregistered_deferred
  | Guard_absent -> Exact_execution_guard_absent
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
      ?exact_execution_guard
      prepared_lane
  =
  let with_current callback =
    Keeper_exact_flow_scope.with_current
      prepared_lane.flow_scope
      ~registered_lane_id:
        (registered_lane_id
           ~base_path:prepared_lane.base_path
           ~keeper_name:prepared_lane.keeper_name)
      callback
  in
  let with_settlement callback =
    Keeper_exact_flow_scope.with_settlement
      prepared_lane.flow_scope
      ~registered_lane_id:
        (registered_lane_id
           ~base_path:prepared_lane.base_path
           ~keeper_name:prepared_lane.keeper_name)
      callback
  in
  let bound_observation = ref None in
  let before_dispatch candidate =
    let observation = observe_flow_attempt_receipt candidate in
    match
      with_current (fun () ->
        match bind_exact_execution ~keeper_name ~exact_execution_guard observation with
        | Error _ as error -> error
        | Ok () ->
          bound_observation := Some observation;
          Ok ())
    with
    | Keeper_exact_flow_scope.Owner_unregistered_deferred ->
      Error Owner_unregistered_deferred
    | Keeper_exact_flow_scope.Current result -> result
  in
  let before_advance ~failed ~next:_ =
    match
      with_current (fun () ->
        match failed with
        | Exact_output.Flow_candidate_rejected _ -> Ok ()
        | Exact_output.Flow_candidate_execution_failed { candidate; cause = _ } ->
          let observation = observe_flow_attempt_receipt candidate in
          (match
             release_exact_execution
               ~keeper_name
               ~exact_execution_guard
               observation
           with
           | Error _ as error -> error
           | Ok () ->
             bound_observation := None;
             Ok ()))
    with
    | Keeper_exact_flow_scope.Owner_unregistered_deferred ->
      Error Owner_unregistered_deferred
    | Keeper_exact_flow_scope.Current result -> result
  in
  let execution =
    try
      `Flow
        (Exact_output.execute_flow_once
           ~net
           ?clock
           ~before_dispatch
           ~before_advance
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
  | `Flow (Error (Exact_output.Flow_attempt_already_started _)) ->
    Error Exact_flow_already_started
  | `Flow (Error (Exact_output.Flow_success_ordinal_exhausted _))
  | `Flow (Error (Exact_output.Flow_attempt_start_failed _))
  | `Flow (Error (Exact_output.Flow_candidates_exhausted _)) ->
    Error Exact_attempt_start_failed
  | `Flow
      (Error
        (Exact_output.Flow_before_dispatch_callback_failed
          { cause = Owner_unregistered_deferred; _ })) ->
    Error Exact_owner_unregistered_deferred
  | `Flow
      (Error
        (Exact_output.Flow_before_dispatch_callback_failed
          { cause; _ })) ->
    Error (summarization_failure_of_callback cause)
  | `Flow
      (Error
        (Exact_output.Flow_before_advance_callback_failed
          { cause = Owner_unregistered_deferred; _ })) ->
    Error Exact_owner_unregistered_deferred
  | `Flow
      (Error
        (Exact_output.Flow_before_advance_callback_failed
          { cause; _ })) ->
    Error (summarization_failure_of_callback cause)
  | `Flow
      (Error
        (Exact_output.Flow_exact_execution_failed
          { candidate; _ })) ->
    let observation = observe_flow_attempt_receipt candidate in
    Error
      (Exact_execution_terminal
         (terminal_after_quarantine
            ~keeper_name
            ~exact_execution_guard
            ~cause:Keeper_event_queue_state.Exact_execution_failed
            observation))
  | `Flow (Ok (flow_success : Exact_output.flow_success)) ->
    let observation =
      flow_success
      |> Exact_output.flow_success_candidate
      |> observe_flow_attempt_receipt
    in
    let success = Exact_output.flow_success_output flow_success in
    (match plan_of_json ~units:prepared_lane.units success.output with
     | Error detail ->
       (match
          settle_exact_flow_domain
            flow_success
            Exact_output.Domain_rejected
        with
        | Ok () -> ()
        | Error detail ->
          Log.Keeper.error
            ~keeper_name
            "compaction exact domain rejection settlement failed slot=%s call_id=%s: %s"
            observation.slot_id
            observation.call_id
            detail);
       Log.Keeper.warn
         ~keeper_name
         "compaction exact output violated MASC domain plan slot=%s call_id=%s: %s"
         observation.slot_id
         observation.call_id
         detail;
       Error
         (Exact_execution_terminal
            (terminal_after_quarantine
               ~keeper_name
               ~exact_execution_guard
               ~cause:Keeper_event_queue_state.Domain_invalid_output
               observation))
     | Ok plan ->
       (match exact_execution_guard with
        | None -> Error Exact_execution_guard_absent
        | Some exact_execution_guard ->
          Ok
            { plan
            ; exact_execution_evidence = exact_execution_evidence flow_success
            ; post_success_terminalizer =
                { base_path = prepared_lane.base_path
                ; keeper_name
                ; flow_scope = prepared_lane.flow_scope
                ; flow_success
                ; exact_execution_guard
                ; attempt_observation = observation
                ; disposition_mutex = Eio.Mutex.create ()
                ; phase = Open
                ; domain_valid_attempts = 0
                ; domain_rejected_attempts = 0
                }
            }))
  in
  let settle () =
    match with_settlement settle_execution with
    | Keeper_exact_flow_scope.Owner_unregistered_deferred ->
      Error Exact_owner_unregistered_deferred
    | Keeper_exact_flow_scope.Current result -> result
  in
  match execution with
  | `Bound_cancellation _ -> Eio.Cancel.protect settle
  | `Flow _ -> settle ()
;;

let execute_prepared_lane ~keeper_name ~net ?clock ?exact_execution_guard prepared_lane =
  match
    Keeper_exact_flow_scope.with_current
      prepared_lane.flow_scope
      ~registered_lane_id:
        (registered_lane_id
           ~base_path:prepared_lane.base_path
           ~keeper_name:prepared_lane.keeper_name)
      (fun () ->
         execute_prepared_lane_current
           ~keeper_name
           ~net
           ?clock
           ?exact_execution_guard
           prepared_lane)
  with
  | Keeper_exact_flow_scope.Owner_unregistered_deferred ->
    Error Exact_owner_unregistered_deferred
  | Keeper_exact_flow_scope.Current result -> result
;;

let run_exact
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
      execute_prepared_lane ~keeper_name ~net ?clock ?exact_execution_guard prepared_lane
;;

let make_resolved
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

let make ?exact_execution_guard ~base_path ~keeper_name () =
  make_resolved ?exact_execution_guard ~base_path ~keeper_name ()
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

let exact_execution_evidence_receipt_plan_fingerprint
      (evidence : exact_execution_evidence) =
  evidence.receipt_plan_fingerprint
;;

let exact_execution_evidence_receipt_request_body_sha256
      (evidence : exact_execution_evidence) =
  evidence.receipt_request_body_sha256
;;

module For_testing = struct
  let messages_for_plan = messages_for_plan

  let flow_slot_ids prepared_lane = prepared_lane.ordered_slot_ids
  let registry_generation prepared_lane = prepared_lane.registry_generation

  let attempt_observations prepared_lane =
    let evidence : Exact_output.flow_evidence =
      Exact_output.flow_attempt_evidence prepared_lane.flow_attempt
    in
    List.map observe_flow_attempt_snapshot evidence.attempts
  ;;

  let candidate_snapshot_slot_ids prepared_lane =
    let evidence : Exact_output.flow_evidence =
      Exact_output.flow_attempt_evidence prepared_lane.flow_attempt
    in
    List.map
      (fun candidate -> candidate.Exact_output.candidate_id)
      evidence.declared_candidate_snapshot
  ;;

  let post_success_snapshot = post_success_snapshot

  let settle_post_success_domain_valid_with_error terminalizer detail =
    settle_post_success_domain_valid_with_failure
      ~settle_domain:(fun _ _ -> Error detail)
      terminalizer
      ~failure_detail:detail
  ;;

  let settle_post_success_domain_valid_with_exception terminalizer exn =
    settle_post_success_domain_valid_with_failure
      ~settle_domain:(fun _ _ -> raise exn)
      terminalizer
      ~failure_detail:"injected Domain_valid settlement exception"
  ;;

  let settle_post_success_domain_valid_with ~settle terminalizer =
    settle_post_success_domain_valid_with_failure
      ~settle_domain:(fun _ _ -> settle ())
      terminalizer
      ~failure_detail:"injected Domain_valid settlement failed"
  ;;

  let settle_post_success_domain_valid_with_wait_hook ~on_wait terminalizer =
    settle_post_success_domain_valid_with_failure
      ~on_await:on_wait
      terminalizer
      ~failure_detail:"concurrent Domain_valid settlement failed"
  ;;
end
