(** LLM-backed keeper context compaction over the AGENT_CORE exact-output surface.
    See keeper_compaction_llm_summarizer.mli. MASC owns the domain plan while
    AGENT_CORE owns frozen target admission, dispatch, and receipt provenance. *)

module Schema = Keeper_structured_output_schema
module Exact_output = Agent_core.Exact_output
module String_set = Set.Make (String)

type message_text_source =
  { role : Agent_core.Types.role
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

type prior_summary =
  { source_index : int
  ; text : string
  }

type planning_window =
  { prior_summary : prior_summary option
  ; first_source : eligible_source
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

type before_dispatch_authority =
  attempt_observation -> (unit, string) result

type completed_plan =
  { plan : compaction_plan
  ; exact_execution_evidence : exact_execution_evidence
  }

type summarization_failure =
  | Exact_lane_unconfigured
  | Exact_target_selection_failed
  | Exact_admission_failed
  | Exact_attempt_start_failed
  | Exact_execution_context_unavailable
  | Exact_execution_authority_absent
  | Exact_execution_authority_rejected
  | Exact_flow_already_started
  | Exact_execution_terminal of Keeper_compaction_outcome.exact_execution_terminal
  | No_reducible_boundary
  | Invalid_plan

type summarizer =
  units:Keeper_compaction_unit.closed_unit list ->
  (completed_plan, summarization_failure) result

let compaction_summary_metadata_key = "masc.compaction.bounded_summary"

let message role text : Agent_core.Types.message = Agent_core.Types.text_message role text

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
  | Agent_core.Types.Validation_error -> "validation_error"
  | Agent_core.Types.Recoverable_tool_error -> "recoverable_tool_error"
  | Agent_core.Types.Non_retryable_tool_error -> "non_retryable_tool_error"
  | Agent_core.Types.Reported_tool_error -> "reported_tool_error"
  | Agent_core.Types.Unattributed_tool_error -> "unattributed_tool_error"

let tool_error_class_string = function
  | Agent_core.Types.Transient -> "transient"
  | Agent_core.Types.Deterministic -> "deterministic"
  | Agent_core.Types.Unknown -> "unknown"

let tool_result_outcome_json = function
  | Agent_core.Types.Tool_succeeded -> `Assoc [ "kind", `String "succeeded" ]
  | Agent_core.Types.Tool_failed { failure_kind; error_class } ->
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
    | Agent_core.Types.Text text :: rest ->
      loop
        (`Assoc [ "type", `String "text"; "text", `String text ] :: projected_rev)
        rest
    | ( Agent_core.Types.Thinking _
      | Agent_core.Types.ReasoningDetails _
      | Agent_core.Types.RedactedThinking _ )
      :: rest ->
      loop projected_rev rest
    | Agent_core.Types.ToolUse { id; name; input } :: rest ->
      loop
        (`Assoc
           [ "type", `String "tool_use"
           ; "id", `String id
           ; "name", `String name
           ; "input", canonical_json input
           ]
         :: projected_rev)
        rest
    | Agent_core.Types.ToolResult
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
    | (Agent_core.Types.Image _ | Agent_core.Types.Document _ | Agent_core.Types.Audio _)
      :: _ ->
      Error Unsupported_media
  in
  loop [] blocks

and semantic_optional_content_blocks_json = function
  | None -> Ok `Null
  | Some blocks -> semantic_content_blocks_json blocks

let semantic_message_json (message : Agent_core.Types.message) =
  match semantic_content_blocks_json message.content with
  | Error _ as error -> error
  | Ok content_blocks ->
    Ok
      (`Assoc
         [ "role", `String (Agent_core.Types.role_to_string message.role)
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
    | Agent_core.Types.Text text :: rest ->
      loop (text :: text_blocks_rev) rest
    | ( Agent_core.Types.Thinking _
      | Agent_core.Types.ReasoningDetails _
      | Agent_core.Types.RedactedThinking _ )
      :: rest ->
      loop text_blocks_rev rest
    | ( Agent_core.Types.ToolUse _
      | Agent_core.Types.ToolResult _
      | Agent_core.Types.Image _
      | Agent_core.Types.Document _
      | Agent_core.Types.Audio _ )
      :: _ ->
      None
  in
  loop [] blocks

let cycle_has_tool_protocol messages =
  let has_tool_use =
    List.exists
      (fun (message : Agent_core.Types.message) ->
        List.exists
          (function Agent_core.Types.ToolUse _ -> true | _ -> false)
          message.content)
      messages
  in
  let has_tool_result =
    List.exists
      (fun (message : Agent_core.Types.message) ->
        List.exists
          (function Agent_core.Types.ToolResult _ -> true | _ -> false)
          message.content)
      messages
  in
  has_tool_use && has_tool_result

let eligible_source ~first_user_seen source_index = function
  | Keeper_compaction_unit.Ordinary_message
      ({ role = (Agent_core.Types.User | Agent_core.Types.Assistant)
       ; content
       ; name = None
       ; tool_call_id = None
       ; metadata = []
       } as message)
    when message.role <> Agent_core.Types.User || first_user_seen ->
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
  (* Keep the first User message outside the window because current-format
     summaries may already sit immediately behind it. Selecting that message
     would put an eligible source before the summary and make the checkpoint
     unplannable. Later plain User messages remain part of the typed
     conversation state: protecting every one would split a real Keeper history
     into one tiny window per turn and defeat boundary compaction. *)
  let rec loop source_index first_user_seen sources_rev = function
    | [] -> List.rev sources_rev
    | unit_ :: rest ->
      let source = eligible_source ~first_user_seen source_index unit_ in
      let first_user_seen =
        first_user_seen
        ||
        match unit_ with
        | Keeper_compaction_unit.Ordinary_message
            { role = Agent_core.Types.User; _ } -> true
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

let prior_summary source_index = function
  | Keeper_compaction_unit.Ordinary_message
      { role = Agent_core.Types.Assistant
      ; content = [ Agent_core.Types.Text text ]
      ; name = None
      ; tool_call_id = None
      ; metadata = [ key, `Bool true ]
      }
    when String.equal key compaction_summary_metadata_key
         && String.trim text <> "" ->
    Some { source_index; text }
  | Keeper_compaction_unit.Ordinary_message _
  | Keeper_compaction_unit.Closed_tool_cycle _ ->
    None

let prior_summaries units =
  units |> List.mapi prior_summary |> List.filter_map Fun.id

let oldest_contiguous_run (sources : eligible_source list) =
  match sources with
  | [] -> []
  | first :: rest ->
    let rec loop
          previous_index
          (sources_rev : eligible_source list)
          (remaining_sources : eligible_source list)
      =
      match remaining_sources with
      | source :: remaining when source.source_index = previous_index + 1 ->
        loop source.source_index (source :: sources_rev) remaining
      | _ -> List.rev sources_rev
    in
    loop first.source_index [ first ] rest

let planning_window_for_units source_units =
  let sources = eligible_sources source_units in
  let make prior_summary sources =
    match oldest_contiguous_run sources with
    | [] -> Error "source contains no eligible contiguous compaction window"
    | first_source :: remaining_sources ->
      Ok { prior_summary; first_source; remaining_sources; source_units }
  in
  match prior_summaries source_units with
  | [] -> make None sources
  | [ prior_summary ] ->
    if
      List.exists
        (fun (source : eligible_source) ->
           source.source_index < prior_summary.source_index)
        sources
    then Error "eligible source precedes the current-format compaction summary"
    else
      sources
      |> List.filter (fun (source : eligible_source) ->
        source.source_index > prior_summary.source_index)
      |> make (Some prior_summary)
  | _ :: _ :: _ ->
    Error "source contains multiple current-format compaction summaries"

let planning_window_sources (window : planning_window) =
  window.first_source :: window.remaining_sources

let planning_window_last_index (window : planning_window) =
  List.fold_left
    (fun _ (source : eligible_source) -> source.source_index)
    window.first_source.source_index
    window.remaining_sources

let planning_window_has_later_source (window : planning_window) =
  let last_index = planning_window_last_index window in
  eligible_sources window.source_units
  |> List.exists (fun (source : eligible_source) ->
    source.source_index > last_index)

let planning_window_max_keep_from window =
  let last_index = planning_window_last_index window in
  if planning_window_has_later_source window then last_index + 1 else last_index

let planning_window_has_valid_boundary window =
  window.first_source.source_index + 1 <= planning_window_max_keep_from window

let eligible_units_json (sources : eligible_source list) =
  `List
    (List.map
       (fun (source : eligible_source) ->
         match source.payload with
         | Message_text { role; text_blocks } ->
           `Assoc
             [ Schema.compaction_plan_field_unit_index, `Int source.source_index
             ; "kind", `String "message_text"
             ; ( "role"
               , `String
                   (Agent_core.Types.role_to_string role) )
             ; "text_blocks", `List (List.map (fun text -> `String text) text_blocks)
             ]
         | Closed_tool_cycle { semantic_json; _ } ->
           `Assoc
             [ Schema.compaction_plan_field_unit_index, `Int source.source_index
             ; "kind", `String "closed_tool_cycle"
             ; "messages", semantic_json
             ])
       sources)

let plan_prompts ~window =
  let sources = planning_window_sources window in
  let first_index = window.first_source.source_index in
  let last_index = planning_window_last_index window in
  let max_keep_from = planning_window_max_keep_from window in
  let prior_summary =
    match window.prior_summary with
    | None -> `Null
    | Some prior ->
      `Assoc
        [ Schema.compaction_plan_field_unit_index, `Int prior.source_index
        ; "text", `String prior.text
        ]
  in
  let system =
    "You hierarchically compact one optional prior Assistant memory plus the \
     supplied contiguous window of raw atomic eligible units. Choose one \
     keep_from_unit_index. Fold the prior memory, when present, and every raw \
     unit below that boundary into one faithful replacement Assistant memory. \
     The boundary and later raw units remain exact. Units outside the raw \
     window, including any exact units between the prior memory and the raw \
     window, remain exact by construction. Each closed_tool_cycle is one \
     indivisible unit. The replacement memory must preserve goals, constraints, \
     decisions, evidence, tool outcomes, unresolved work, corrections, and \
     state needed by future turns. Choose the latest boundary you can summarize \
     faithfully; keep exact only the minimal recent suffix whose details must \
     remain verbatim. Do not invent facts, reference unseen units, split tool \
     cycles, emit markdown fences, or enumerate per-unit decisions. Respond \
     with one JSON object and no other text."
  in
  let user =
    Printf.sprintf
      "prior_summary=%s\nwindow_first_unit_index=%d\nwindow_last_unit_index=%d\n\
       window_units=%s\n\
       Return {\"%s\":string,\"%s\":integer}. The summary must be non-empty. \
       keep_from_unit_index must be in [%d,%d], so at least the oldest unit is \
       summarized and one current or later raw unit remains available for the \
       next rolling fold."
      (Yojson.Safe.to_string prior_summary)
      first_index
      last_index
      (eligible_units_json sources |> Yojson.Safe.to_string)
      Schema.compaction_plan_field_summary
      Schema.compaction_plan_field_keep_from_unit_index
      (first_index + 1)
      max_keep_from
  in
  system, user

(* The cli one-shot path reuses the same two texts verbatim: one wording on
   both transports (RFC cli-runtimes-as-lane-slots). *)
let messages_for_plan ~window =
  let system, user = plan_prompts ~window in
  [ message Agent_core.Types.System system; message Agent_core.Types.User user ]

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
  let max_keep_from = planning_window_max_keep_from window in
  if keep_from_unit_index <= first_index || keep_from_unit_index > max_keep_from
  then
    Error
      (Printf.sprintf
         "keep_from_unit_index %d is outside [%d,%d]"
         keep_from_unit_index
         (first_index + 1)
         max_keep_from)
  else Ok { window; summary; keep_from_unit_index }

let summary_message summary =
  (* Current-format derived state, not a compatibility marker. The exact field
     identifies the one rolling summary consumed by [planning_window_for_units].
     Its blast radius is planning and in-place replacement only. *)
  { (message Agent_core.Types.Assistant summary) with
    metadata = [ compaction_summary_metadata_key, `Bool true ]
  }

let summarized_indices plan =
  planning_window_sources plan.window
  |> List.filter_map (fun (source : eligible_source) ->
    if source.source_index < plan.keep_from_unit_index
    then Some source.source_index
    else None)

let dropped_indices _ = []
let has_changes plan = summarized_indices plan <> []

let apply_units (plan : compaction_plan) =
  let first_index = plan.window.first_source.source_index in
  let summary_index =
    match plan.window.prior_summary with
    | Some prior -> prior.source_index
    | None -> first_index
  in
  plan.window.source_units
  |> List.mapi (fun index unit_ -> index, unit_)
  |> List.concat_map (fun (index, unit_) ->
    if index = summary_index
    then
      [ Keeper_compaction_unit.Ordinary_message
          (summary_message plan.summary)
      ]
    else if index >= first_index && index < plan.keep_from_unit_index
    then []
    else [ unit_ ])

let apply plan =
  apply_units plan |> List.concat_map messages_of_unit

let exact_output_requirement =
  Exact_output.make_output_requirement
    ~schema:Schema.compaction_plan_output_schema
    ~minimum_guarantee:Exact_output.Json_syntax
;;

let planning_window_with_sources window = function
  | [] -> None
  | first_source :: remaining_sources ->
    Some { window with first_source; remaining_sources }
;;

let next_progress_window plan =
  let* next_window =
    planning_window_for_units (apply_units plan)
  in
  planning_window_with_sources next_window [ next_window.first_source ]
  |> Option.to_result ~none:"compacted plan has no next rolling source"
;;

let window_prefix sources count =
  Array.sub sources 0 count |> Array.to_list
;;

let project_window_fits_all
      ~keeper_name
      (selected_slots : Runtime_exact_output_registry.selected_slot list)
      window
  =
  let messages = messages_for_plan ~window in
  let rec loop
        (slots : Runtime_exact_output_registry.selected_slot list)
    =
    match slots with
    | [] -> Ok true
    | slot :: rest ->
      (match
         Exact_output.project_request_body
           ~target:slot.admitted_target
           ~messages
           exact_output_requirement
       with
       | Error _ ->
         Log.Keeper.warn
           ~keeper_name
           "compaction request-body projection rejected opaque slot=%s"
           slot.slot_id;
         Error Exact_admission_failed
       | Ok projection ->
         if projection.within_limit
         then loop rest
         else Ok false)
  in
  loop selected_slots
;;

let largest_fitting_window ~keeper_name ~selected_slots window =
  let sources = planning_window_sources window |> Array.of_list in
  let candidate count =
    let* candidate =
      window_prefix sources count
      |> planning_window_with_sources window
      |> Option.to_result ~none:Invalid_plan
    in
    if planning_window_has_valid_boundary candidate
    then Ok candidate
    else Error Invalid_plan
  in
  (* Every candidate contains the same prior summary and an exact prefix of the
     same raw JSON window. Increasing [count] only appends source bytes to the
     messages handed to AGENT_CORE, so the exact serialized size is monotone. Binary
     search avoids repeatedly serializing every growing prefix. *)
  let rec search best low high =
    if low > high
    then
      match best with
      | Some window -> Ok window
      | None -> Error Exact_admission_failed
    else
      let midpoint = low + ((high - low) / 2) in
      let* window = candidate midpoint in
      let* fits =
        project_window_fits_all ~keeper_name selected_slots window
      in
      if fits
      then search (Some window) (midpoint + 1) high
      else search best low (midpoint - 1)
  in
  search None 1 (Array.length sources)
;;

let plan_preserves_exact_future_progress
      ~keeper_name
      selected_slots
      plan
  =
  match next_progress_window plan with
  | Error detail -> Error detail
  | Ok next_window ->
    (match
       project_window_fits_all
         ~keeper_name
         selected_slots
         next_window
     with
     | Ok true -> Ok ()
     | Ok false ->
       Error
         "replacement summary leaves no exact request-body capacity for the \
          next oldest source"
     | Error _ ->
       Error
         "replacement summary next-fold request projection was rejected")
;;

type prepared_lane =
  { window : planning_window
  ; ordered_slot_ids : string list
  ; selected_slots : Runtime_exact_output_registry.selected_slot list
  ; flow_attempt : Exact_output.flow_attempt
  ; cli_slots : string list
        (* Official-client runtime ids walked after every catalog slot is
           exhausted (RFC cli-runtimes-as-lane-slots), carried verbatim from
           the resolved lane. *)
  ; base_path : string
        (* Where a cli one-shot is spawned; prepare_lane already receives it
           and nothing else on this path retains it. *)
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

let terminal_of_observation ?detail cause (observation : attempt_observation) =
  Keeper_compaction_outcome.
    { cause
    ; slot_id = observation.slot_id
    ; call_id = observation.call_id
    ; plan_fingerprint = observation.receipt_plan_fingerprint
    ; request_body_sha256 = observation.receipt_request_body_sha256
    ; detail
    }
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
      ~base_path
      ~keeper_name
      ~registry
      ~lane_id
      ~units
  =
  let* window =
    planning_window_for_units units |> Result.map_error (fun _ -> Invalid_plan)
  in
  match Runtime_exact_output_registry.resolve_lane registry ~lane_id with
  | Error
        (Runtime_exact_output_registry.Exact_lane_unconfigured
           { lane_id = missing_lane_id }) ->
      Log.Keeper.warn
        ~keeper_name
        "compaction exact lane is unconfigured lane_id=%s"
        missing_lane_id;
      Error Exact_lane_unconfigured
  | Error
        (Runtime_exact_output_registry.No_admitted_lane_slots
           { lane_id = empty_lane_id }) ->
      Log.Keeper.warn
        ~keeper_name
        "compaction exact lane has no admitted opaque slots lane_id=%s"
        empty_lane_id;
      Error Exact_target_selection_failed
  | Ok resolved ->
    (* The other three registry lanes honor the operator's per-keeper slot
       pin here (librarian/hitl/board_attention all call
       [Keeper_exact_lane_preference.apply]); compaction was the one lane
       that resolved the lane and stopped, so a pin applied on three lanes
       and silently not on the fourth. *)
    let* { Runtime_exact_output_registry.selected_slots; cli_slots } =
      match
        Keeper_exact_lane_preference.apply
          ~base_path
          ~keeper_name
          ~lane_id
          resolved
      with
      | Ok resolved -> Ok resolved
      | Error detail ->
        Log.Keeper.warn
          ~keeper_name
          "compaction exact lane preference unavailable lane_id=%s: %s"
          lane_id
          detail;
        Error Exact_target_selection_failed
    in
    let* () =
      if planning_window_has_valid_boundary window
      then Ok ()
      else Error No_reducible_boundary
    in
    let* window =
      largest_fitting_window ~keeper_name ~selected_slots window
    in
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
            "compaction exact flow admission rejected lane_id=%s candidate_count=%d"
            lane_id
            (List.length candidates);
          Error Exact_admission_failed
        | Ok flow_snapshot ->
          (match Exact_output.start_flow flow_snapshot with
           | Error _ ->
             Log.Keeper.error
               ~keeper_name
               "compaction exact flow identity allocation failed lane_id=%s"
               lane_id;
             Error Exact_attempt_start_failed
           | Ok flow_attempt ->
             Ok
               { window
               ; ordered_slot_ids =
                   List.map
                     (fun (slot : Runtime_exact_output_registry.selected_slot) ->
                        slot.slot_id)
                     selected_slots
               ; selected_slots
               ; flow_attempt
               ; cli_slots
               ; base_path
               })))
;;

let prepared_ordered_slot_ids (prepared : prepared_lane) =
  prepared.ordered_slot_ids
;;

type exact_flow_callback_failure =
  | Authority_absent
  | Authority_rejected

let authorize_dispatch
      ~keeper_name
      ~before_dispatch_authority
      observation
  =
  match before_dispatch_authority with
  | None -> Error Authority_absent
  | Some authorize ->
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
;;

let summarization_failure_of_callback = function
  | Authority_absent -> Exact_execution_authority_absent
  | Authority_rejected -> Exact_execution_authority_rejected
;;

let summarization_failure_detail = function
  | Exact_lane_unconfigured -> "exact_lane_unconfigured"
  | Exact_target_selection_failed -> "exact_target_selection_failed"
  | Exact_admission_failed -> "exact_admission_failed"
  | Exact_attempt_start_failed -> "exact_attempt_start_failed"
  | Exact_execution_context_unavailable -> "exact_execution_context_unavailable"
  | Exact_execution_authority_absent -> "exact_execution_authority_absent"
  | Exact_execution_authority_rejected -> "exact_execution_authority_rejected"
  | Exact_flow_already_started -> "exact_flow_already_started"
  | Exact_execution_terminal terminal ->
    Keeper_compaction_outcome.exact_execution_terminal_to_string terminal
  | No_reducible_boundary -> "no_reducible_boundary"
  | Invalid_plan -> "invalid_plan"
;;

(* ── CLI lane-slot fallback (RFC cli-runtimes-as-lane-slots) ─────────
   Engaged only when the catalog walk reports provider exhaustion (every
   candidate rejected pre-dispatch, every output semantically rejected, or
   the last candidate failing post-dispatch with no successor). Compaction
   has no durable attempt queue — the exact-lane registry is an observation
   plane — so the walk is Keeper_lane_cli_oneshot.walk verbatim, followed by
   the same domain validation the HTTP path applies. A cli one-shot has no
   request body or catalog receipt; the evidence fields keep their meaning
   by naming the transport explicitly and fingerprinting the rendered
   prompt, which is that transport's whole input. *)

let cli_evidence ~runtime_id ~call_id ~prompt_sha256 =
  { slot_id = runtime_id
  ; call_id
  ; target_identity_fingerprint = "cli:" ^ runtime_id
  ; catalog_generation_fingerprint = "cli-oneshot"
  ; catalog_evidence_sha256 = "cli-oneshot"
  ; plan_fingerprint = "cli-oneshot:" ^ prompt_sha256
  ; receipt_request_body_sha256 = prompt_sha256
  }
;;

let try_cli_slots ~keeper_name ~cli_runner (prepared : prepared_lane) =
  match prepared.cli_slots with
  | [] -> None
  | cli_slots ->
    let system_prompt, user = plan_prompts ~window:prepared.window in
    let prompt_sha256 = Digestif.SHA256.(digest_string user |> to_hex) in
    (match
       Keeper_lane_cli_oneshot.walk
         ?runner:cli_runner
         ~base_dir:prepared.base_path
         ~cli_slots
         ~system_prompt
         ~requirement:exact_output_requirement
         ~prompt:user
         ()
     with
     | Error failures ->
       List.iter
         (fun failure ->
            Log.Keeper.warn
              ~keeper_name
              "compaction cli lane-slot failed: %s"
              (Keeper_lane_cli_oneshot.failure_to_string failure))
         failures;
       None
     | Ok (runtime_id, output) ->
       (match plan_of_json ~window:prepared.window output with
        | Error detail ->
          Log.Keeper.warn
            ~keeper_name
            "compaction cli output violated MASC domain plan slot=%s: %s"
            runtime_id
            detail;
          None
        | Ok plan ->
          (match
             plan_preserves_exact_future_progress
               ~keeper_name
               prepared.selected_slots
               plan
           with
           | Error detail ->
             Log.Keeper.warn
               ~keeper_name
               "compaction cli output blocked future rolling admission slot=%s: %s"
               runtime_id
               detail;
             None
           | Ok () ->
             let call_id = Random_id.prefixed ~prefix:"cli-compaction-" ~bytes:16 in
             Some
               ( runtime_id
               , { plan
                 ; exact_execution_evidence =
                     cli_evidence ~runtime_id ~call_id ~prompt_sha256
                 } ))))
;;

let execute_prepared_lane_current
      ~keeper_name
      ?cli_runner
      ~net
      ?clock
      ?before_dispatch_authority
      ?(observation_registry = Exact_lane_run_registry.global ())
      prepared_lane
  =
  let registry = observation_registry in
  let run_id = Random_id.prefixed ~prefix:"exact-compaction-" ~bytes:16 in
  let started_at = Time_compat.now () in
  let prior_summary =
    match prepared_lane.window.prior_summary with
    | None -> `Null
    | Some prior ->
      `Assoc
        [ Schema.compaction_plan_field_unit_index, `Int prior.source_index
        ; "text", `String prior.text
        ]
  in
  Exact_lane_run_registry.register_running
    registry
    ~run_id
    ~lane:Exact_lane_run_registry.Compaction
    ~actor:keeper_name
    ~started_at
    ~input:
      (Exact_lane_run_registry.Exact_input
         (`Assoc
         [ "slot_ids", `List (List.map (fun id -> `String id) prepared_lane.ordered_slot_ids)
         ; "prior_summary", prior_summary
         ; ( "window_units"
           , eligible_units_json (planning_window_sources prepared_lane.window) )
         ]));
  (* Derived observation only: this mirrors the candidate whose dispatch
     authority passed and never participates in lane selection or ownership. *)
  let authorized_observation = ref None in
  (* Set only when a cli slot produced the accepted plan: the observation ref
     above mirrors the last authorized HTTP dispatch, which is the wrong slot
     to attribute a cli success to. *)
  let cli_selected = ref None in
  let complete outcome output =
    let selected_slot =
      match !cli_selected with
      | Some runtime_id -> Some runtime_id
      | None ->
        Option.map
          (fun (observation : attempt_observation) -> observation.slot_id)
          !authorized_observation
    in
    match
      Exact_lane_run_registry.mark_completed
        registry
        ~run_id
        ~outcome
        ~elapsed_s:(Time_compat.now () -. started_at)
        ~selected_slot
        ~output
    with
    | Ok () -> ()
    | Error error ->
      (* The exact-lane registry is an observation plane, not compaction's
         lifecycle authority. Its durable completion must never replace a
         typed provider/domain terminal with an exception, otherwise the
         Keeper source remains eligible and can be dispatched again. *)
      Log.Keeper.error
        ~keeper_name
        "compaction exact-run observation completion failed run_id=%s: %s"
        run_id
        (Exact_lane_run_registry.completion_error_to_string error)
  in
  (* Process-local derived state only. It identifies the exact AGENT_CORE candidate
     whose dispatch callback passed, so cancellation can retain that source.
     It is not persisted and does not compete with AGENT_CORE execution ownership. *)
  let before_dispatch candidate =
    let observation = observe_flow_attempt_receipt candidate in
    let* () =
      authorize_dispatch
        ~keeper_name
        ~before_dispatch_authority
        observation
    in
    authorized_observation := Some observation;
    Ok ()
  in
  let before_advance ~failed ~next:_ =
    match failed with
    | Exact_output.Flow_candidate_rejected _ -> Ok ()
    | Exact_output.Flow_candidate_execution_failed _ ->
      authorized_observation := None;
      Ok ()
  in
  let validate flow_success =
    let success = Exact_output.flow_success_output flow_success in
    match plan_of_json ~window:prepared_lane.window success.output with
    | Ok plan ->
      (match
         plan_preserves_exact_future_progress
           ~keeper_name
           prepared_lane.selected_slots
           plan
       with
       | Ok () -> Exact_output.Accept plan
       | Error detail ->
         let observation =
           flow_success
           |> Exact_output.flow_success_candidate
           |> observe_flow_attempt_receipt
         in
         Log.Keeper.warn
           ~keeper_name
           "compaction exact output blocked future rolling admission slot=%s \
            call_id=%s: %s"
           observation.slot_id
           observation.call_id
           detail;
         Exact_output.Reject_and_advance detail)
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
      (* AGENT_CORE owns execution state; MASC retains only the source-authority
         observation. Cancellation is fiber teardown, not a compaction result:
         returning a typed terminal made the heartbeat record a schedule failure
         even though [Cycle.Cancelled] records none. Preserve the authorized
         source and continue the original cancellation. *)
      Option.iter
        (fun observation ->
           Log.Keeper.warn
             ~keeper_name
             "compaction exact cancellation retained the authorized source \
              slot=%s call_id=%s"
             observation.slot_id
             observation.call_id)
        !authorized_observation;
      complete Exact_lane_run_registry.Cancelled `Null;
      Printexc.raise_with_backtrace cancellation raw_bt
    | exn ->
      complete
        (Exact_lane_run_registry.Failed
           { code = "compaction_raised"; detail = Printexc.to_string exn })
        `Null;
      raise exn
  in
  let project_execution () =
  match execution with
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
              | Exact_output.Flow_measurement_start_failed _ )
          ; _
          })) ->
    Error Exact_attempt_start_failed
  | `Flow
      (Error
        (Exact_output.Flow_execution_terminal
          { cause = Exact_output.Flow_candidates_exhausted _; _ })) ->
    (* Provider exhaustion, split from the infrastructure start failures it
       used to share an arm with: only exhaustion may fall back to the cli
       walk (RFC cli-runtimes-as-lane-slots). *)
    (match try_cli_slots ~keeper_name ~cli_runner prepared_lane with
     | Some (runtime_id, completed) ->
       cli_selected := Some runtime_id;
       Ok completed
     | None -> Error Exact_attempt_start_failed)
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
                { candidate; cause; evidence }
          ; _
          })) ->
    let observation = observe_flow_attempt_receipt candidate in
    (* The sibling consumer of this same branch (hitl_summary_worker) already
       renders [cause] through Keeper_exact_flow_detail; compaction discarded
       it in the pattern, so its terminal named the call and never the reason.
       Measured on a live compaction that spent 470 s on glm-coding.glm-5-turbo
       — a slot completing 97% of its work elsewhere — and left four
       identifiers with no way to ask why. *)
    (* The last candidate died post-dispatch with no successor — the shape a
       single-slot lane actually produces on provider failure — so the cli
       walk gets its turn before the terminal stands. *)
    (match try_cli_slots ~keeper_name ~cli_runner prepared_lane with
     | Some (runtime_id, completed) ->
       cli_selected := Some runtime_id;
       Ok completed
     | None ->
       Error
         (Exact_execution_terminal
            (terminal_of_observation
               ~detail:
                 (Keeper_exact_flow_detail.execution_failure_detail
                    ~candidate ~cause ~evidence)
               Keeper_compaction_outcome.Exact_execution_failed
               observation)))
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
    (match try_cli_slots ~keeper_name ~cli_runner prepared_lane with
     | Some (runtime_id, completed) ->
       cli_selected := Some runtime_id;
       Ok completed
     | None ->
       Error
         (Exact_execution_terminal
            (terminal_of_observation
               Keeper_compaction_outcome.Domain_invalid_output
               observation)))
  | `Flow (Ok validated) ->
    let flow_success = validated.transport_success in
    Ok
      { plan = validated.accepted
      ; exact_execution_evidence = exact_execution_evidence flow_success
      }
  in
  let result = project_execution () in
  (match result with
   | Ok completed ->
     let evidence = completed.exact_execution_evidence in
     complete
       Exact_lane_run_registry.Succeeded
       (`Assoc
          [ ( "summary_excerpt"
            , `String
                (Observability_redact.redact_preview
                   ~max_len:512
                   completed.plan.summary) )
          ; "keep_from_unit_index", `Int completed.plan.keep_from_unit_index
          ; "slot_id", `String evidence.slot_id
          ; "call_id", `String evidence.call_id
          ; "target_identity_fingerprint", `String evidence.target_identity_fingerprint
          ; "catalog_generation_fingerprint", `String evidence.catalog_generation_fingerprint
          ; "catalog_evidence_sha256", `String evidence.catalog_evidence_sha256
          ; "plan_fingerprint", `String evidence.plan_fingerprint
          ; "request_body_sha256", `String evidence.receipt_request_body_sha256
          ])
   | Error failure ->
     let detail = summarization_failure_detail failure in
     complete
       (Exact_lane_run_registry.Failed { code = "compaction_failed"; detail })
       `Null);
  result
;;

let execute_prepared_lane
      ~keeper_name
      ?cli_runner
      ~net
      ?clock
      ?before_dispatch_authority
      ?observation_registry
      prepared_lane
  =
  execute_prepared_lane_current
    ~keeper_name
    ?cli_runner
    ~net
    ?clock
    ?before_dispatch_authority
    ?observation_registry
    prepared_lane
;;

let run_exact
      ?before_dispatch_authority
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
        prepared_lane
;;

let make_resolved
      ?before_dispatch_authority
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
      ~base_path
      ~keeper_name
      ()
  =
  make_resolved
    ?before_dispatch_authority
    ~base_path
    ~keeper_name
    ()
;;

let completed_plan completed = completed.plan
let completed_exact_execution_evidence completed = completed.exact_execution_evidence

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

let exact_execution_terminal ~cause (evidence : exact_execution_evidence) =
  Keeper_compaction_outcome.
    { cause
    ; slot_id = evidence.slot_id
    ; call_id = evidence.call_id
    ; plan_fingerprint = evidence.plan_fingerprint
    ; request_body_sha256 = evidence.receipt_request_body_sha256
    ; detail = None
    }
;;

module For_testing = struct
  let messages_for_plan = messages_for_plan
  let planning_window_for_units = planning_window_for_units
  let planning_window_source_indices window =
    List.map
      (fun (source : eligible_source) -> source.source_index)
      (planning_window_sources window)
  ;;

  let prepared_window_source_indices prepared_lane =
    planning_window_source_indices prepared_lane.window
  ;;

  let flow_slot_ids prepared_lane = prepared_lane.ordered_slot_ids

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
end
