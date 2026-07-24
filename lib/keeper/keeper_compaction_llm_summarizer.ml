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

type post_success_terminalizer =
  { keeper_name : string
  ; exact_execution_guard : exact_execution_guard
  ; attempt_observation : attempt_observation
  ; terminalization_mutex : Eio.Mutex.t
  ; mutable canonical_terminal :
      (Keeper_event_queue_state.exact_execution_terminal * unit Eio.Promise.t) option
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
  | Exact_execution_guard_failed
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
  { units : Keeper_compaction_unit.closed_unit list
  ; registry_generation : int64
  ; ordered_slot_ids : string list
  ; flow_attempt : Exact_output.flow_attempt
  }

let call_id_to_string call_id = Exact_output.call_id_to_string call_id

let observe_flow_attempt_receipt
      (candidate : Exact_output.flow_attempt_receipt)
  =
  let receipt = candidate.receipt in
  { slot_id = candidate.identity.candidate_id
  ; call_id = receipt |> Exact_output.receipt_call_id |> call_id_to_string
  ; catalog_generation_fingerprint =
      candidate.identity.catalog_generation
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
      terminalizer
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

let terminalize_post_success terminalizer cause =
  let role =
    Eio.Cancel.protect
    @@ fun () ->
    let role =
      Eio.Mutex.use_rw ~protect:true terminalizer.terminalization_mutex
      @@ fun () ->
      match terminalizer.canonical_terminal with
      | Some (terminal, completion) -> `Await (terminal, completion)
      | None ->
        let terminal =
          Keeper_event_queue_state.
            { cause
            ; slot_id = terminalizer.attempt_observation.slot_id
            ; call_id = terminalizer.attempt_observation.call_id
            ; plan_fingerprint =
                terminalizer.attempt_observation.receipt_plan_fingerprint
            ; request_body_sha256 =
                terminalizer.attempt_observation.receipt_request_body_sha256
            }
        in
        let completion, resolve_completion = Eio.Promise.create () in
        terminalizer.canonical_terminal <- Some (terminal, completion);
        `Own (terminal, resolve_completion)
    in
    match role with
    | `Await _ as role -> role
    | `Own (terminal, resolve_completion) ->
      let failure =
        try
          match
            quarantine_exact_execution
              ~keeper_name:terminalizer.keeper_name
              ~exact_execution_guard:(Some terminalizer.exact_execution_guard)
              ~cause:terminal.cause
              terminalizer.attempt_observation
          with
          | Ok Fsync_completed -> None
          | Ok (Visible_sync_unconfirmed detail) ->
            Log.Keeper.warn
              ~keeper_name:terminalizer.keeper_name
              "post-success exact-execution quarantine is visible but sync is unconfirmed slot_id=%s call_id=%s: %s"
              terminal.slot_id
              terminal.call_id
              detail;
            None
          | Error detail -> Some detail
        with
        | exn -> Some ("raised " ^ Printexc.to_string exn)
      in
      Option.iter (log_terminal_quarantine_failure terminalizer terminal) failure;
      Eio.Promise.resolve resolve_completion ();
      `Done terminal
  in
  match role with
  | `Done terminal -> terminal
  | `Await (terminal, completion) ->
    Eio.Promise.await completion;
    terminal
;;

let exact_execution_evidence (flow_success : Exact_output.flow_success) =
  let success = flow_success.success in
  let provenance = success.provenance in
  let identity = provenance.target_identity in
  let observation = observe_flow_attempt_receipt flow_success.candidate in
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
      (match Exact_output.make_flow_candidate ~id:slot.slot_id ~target:slot.target with
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

let prepare_lane ~keeper_name ~registry ~lane_id ~units =
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
        (Runtime_exact_output_registry.No_usable_lane_slots
           { unavailable_slots; _ }) ->
      Log.Keeper.warn
        ~keeper_name
        "compaction exact lane has no usable opaque slots generation=%Ld lane_id=%s unavailable_count=%d"
        registry_generation
        lane_id
        (List.length unavailable_slots);
      Error Exact_target_selection_failed
    | Ok { selected_slots; unavailable_slots } ->
      List.iter
        (fun (unavailable : Runtime_exact_output_registry.unavailable_slot) ->
           Log.Keeper.warn
             ~keeper_name
             "compaction exact opaque slot unavailable generation=%Ld lane_id=%s position=%d slot=%s"
             registry_generation
             lane_id
             unavailable.position
             unavailable.slot_id)
        unavailable_slots;
      let messages = messages_for_plan ~units in
      let* candidates = make_flow_candidates ~keeper_name selected_slots in
      (match candidates with
       | [] -> Error Exact_target_selection_failed
       | first :: rest ->
         (match
            Exact_output.admit_flow
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
          | Ok ready_flow ->
            (match Exact_output.start_flow ready_flow with
             | Error _ ->
               Log.Keeper.error
                 ~keeper_name
                 "compaction exact flow identity allocation failed generation=%Ld lane_id=%s"
                 registry_generation
                 lane_id;
               Error Exact_attempt_start_failed
             | Ok flow_attempt ->
               Ok
                 { units
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
    Error Bind_failed
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
  | Bind_failed -> Exact_execution_guard_failed
  | Bind_sync_unconfirmed terminal
  | Release_failed terminal
  | Release_sync_unconfirmed terminal ->
    Exact_execution_terminal terminal
;;

let execute_prepared_lane ~keeper_name ~net ?clock ?exact_execution_guard prepared_lane =
  let bound_observation = ref None in
  let before_dispatch candidate =
    let observation = observe_flow_attempt_receipt candidate in
    match bind_exact_execution ~keeper_name ~exact_execution_guard observation with
    | Error _ as error -> error
    | Ok () ->
      bound_observation := Some observation;
      Ok ()
  in
  let before_advance ~failed ~failure:_ ~next:_ =
    let observation = observe_flow_attempt_receipt failed in
    match release_exact_execution ~keeper_name ~exact_execution_guard observation with
    | Error _ as error -> error
    | Ok () ->
      bound_observation := None;
      Ok ()
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
      Eio.Cancel.protect
      @@ fun () ->
      (* A durable bind is MASC's only ownership signal. MASC deliberately does
         not inspect OAS receipt phase/count after cancellation. If OAS had
         proved safe advancement it would first invoke [before_advance], whose
         fsynced release clears [bound_observation]. Therefore a still-bound
         identity is always source-terminal; a pre-bind cancellation is
         re-raised. *)
      (match !bound_observation with
       | None -> raise cancellation
       | Some observation ->
         Log.Keeper.warn
           ~keeper_name
           "compaction exact cancellation quarantines only the durably bound identity slot=%s call_id=%s"
           observation.slot_id
           observation.call_id;
         `Failure
           (Exact_execution_terminal
              (terminal_after_quarantine
                 ~keeper_name
                 ~exact_execution_guard
                 ~cause:Keeper_event_queue_state.Exact_execution_cancelled
                 observation)))
  in
  match execution with
  | `Failure failure -> Error failure
  | `Flow (Error (Exact_output.Flow_attempt_already_started _)) ->
    Error Exact_flow_already_started
  | `Flow
      (Error
        (Exact_output.Flow_before_dispatch_callback_failed
          { cause; _ })) ->
    Error (summarization_failure_of_callback cause)
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
    let observation = observe_flow_attempt_receipt flow_success.candidate in
    (match plan_of_json ~units:prepared_lane.units flow_success.success.output with
     | Error detail ->
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
        | None -> Error Exact_execution_guard_failed
        | Some exact_execution_guard ->
          Ok
            { plan
            ; exact_execution_evidence = exact_execution_evidence flow_success
            ; post_success_terminalizer =
                { keeper_name
                ; exact_execution_guard
                ; attempt_observation = observation
                ; terminalization_mutex = Eio.Mutex.create ()
                ; canonical_terminal = None
                }
            }))
;;

let run_exact ?exact_execution_guard ~keeper_name ~sw:_ ~net ~clock ~units () =
  if not (has_eligible_units units)
  then Error Invalid_plan
  else
    match Runtime_exact_output_registry.current () with
    | Error _ -> Error Exact_target_selection_failed
    | Ok registry ->
      let* prepared_lane =
        prepare_lane
          ~keeper_name
          ~registry
          ~lane_id:"compaction_exact"
          ~units
      in
      execute_prepared_lane ~keeper_name ~net ?clock ?exact_execution_guard prepared_lane
;;

let make_resolved ?exact_execution_guard ~(keeper_name : string) () : summarizer option =
  match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
  | Some sw, Some net ->
    let clock = Eio_context.get_clock_opt () in
    Some
      (fun ~units ->
         run_exact ?exact_execution_guard ~keeper_name ~sw ~net ~clock ~units ())
  | _ -> None
;;

let make ?exact_execution_guard ~keeper_name () =
  make_resolved ?exact_execution_guard ~keeper_name ()
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
    List.map observe_flow_attempt_receipt evidence.attempts
  ;;
end
