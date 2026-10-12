open Keeper_event_queue_state_core

let ( let* ) = Result.bind
let schema = Keeper_event_queue_schema.state

let assoc_fields ~context = function
  | `Assoc fields -> Ok fields
  | _ -> Error (context ^ " must be a JSON object")
;;

let required_field ~context name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s missing required field %s" context name)
;;

let exact_fields ~context ~expected fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (name, _) :: rest ->
      if not (List.exists (String.equal name) expected)
      then Error (Printf.sprintf "%s contains unknown field %s" context name)
      else if List.exists (String.equal name) seen
      then Error (Printf.sprintf "%s contains duplicate field %s" context name)
      else loop (name :: seen) rest
  in
  loop [] fields
;;

let string_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "%s.%s must be a string" context name)
;;

let float_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error (Printf.sprintf "%s.%s must be a number" context name)
;;


let int64_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `Int value -> Ok (Int64.of_int value)
  | `Intlit value ->
    (match Int64.of_string_opt value with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "%s.%s must be an int64" context name))
  | _ -> Error (Printf.sprintf "%s.%s must be an int64" context name)
;;

let int_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Printf.sprintf "%s.%s must be an int" context name)
;;

let list_field ~context name parse fields =
  let* value = required_field ~context name fields in
  match value with
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        let* parsed = parse value in
        loop (parsed :: acc) rest
    in
    loop [] values
  | _ -> Error (Printf.sprintf "%s.%s must be a list" context name)
;;

let int64_json value = `Intlit (Int64.to_string value)

let transition_to_yojson = function
  | Cancel_accepted cancellation ->
    `Assoc
      [ "kind", `String "cancel_accepted"
      ; "source", Keeper_event_queue.stimulus_to_yojson cancellation.source
      ; "source_incarnation", int64_json cancellation.source_incarnation
      ; "operator_operation_id", `String cancellation.operator_operation_id
      ; "reason", `String cancellation.reason
      ]
  | Transfer_accepted transfer ->
    `Assoc
      [ "kind", `String "transfer_accepted"
      ; "source", Keeper_event_queue.stimulus_to_yojson transfer.source
      ; "source_incarnation", int64_json transfer.source_incarnation
      ; "operator_operation_id", `String transfer.operator_operation_id
      ; "from_keeper", `String transfer.from_keeper
      ; "to_keeper", `String transfer.to_keeper
      ; "target_trace_id", `String (Keeper_id.Trace_id.to_string transfer.target_trace_id)
      ]
  | Ack_source_terminal source_terminal ->
    let fields =
      [ "kind", `String "ack_source_terminal"
      ; "source", Keeper_event_queue.stimulus_to_yojson source_terminal.source
      ; "source_incarnation", int64_json source_terminal.source_incarnation
      ; "operator_operation_id", `String source_terminal.operator_operation_id
      ]
    in
    let receipt_fields =
      match source_terminal.source_receipt with
      | Fusion_terminal _ ->
        [ "source_receipt_kind", `String "fusion_terminal" ]
      | Hitl_terminal _ ->
        [ "source_receipt_kind", `String "hitl_terminal" ]
      | Turn_completed ->
        [ "source_receipt_kind", `String "turn_completed" ]
      | Turn_attempt_terminal { detail } ->
        [ "source_receipt_kind", `String "turn_attempt_terminal"
        ; "detail", `String detail
        ]
    in
    `Assoc (fields @ receipt_fields)
;;

let transition_of_yojson json =
  let context = "event queue transition" in
  let* fields = assoc_fields ~context json in
  let* kind = string_field ~context "kind" fields in
  match kind with
  | "cancel_accepted" ->
    let* () =
      exact_fields
        ~context
        ~expected:
          [ "kind"
          ; "source"
          ; "source_incarnation"
          ; "operator_operation_id"
          ; "reason"
          ]
        fields
    in
    let* source_json = required_field ~context "source" fields in
    let* source = Keeper_event_queue.stimulus_of_yojson source_json in
    let* source_incarnation = int64_field ~context "source_incarnation" fields in
    let* operator_operation_id =
      string_field ~context "operator_operation_id" fields
    in
    let* reason = string_field ~context "reason" fields in
    let cancellation =
      { source; source_incarnation; operator_operation_id; reason }
    in
    let* () = validate_accepted_cancellation cancellation in
    Ok (Cancel_accepted cancellation)
  | "transfer_accepted" ->
    let* () =
      exact_fields
        ~context
        ~expected:
          [ "kind"
          ; "source"
          ; "source_incarnation"
          ; "operator_operation_id"
          ; "from_keeper"
          ; "to_keeper"
          ; "target_trace_id"
          ]
        fields
    in
    let* source_json = required_field ~context "source" fields in
    let* source = Keeper_event_queue.stimulus_of_yojson source_json in
    let* source_incarnation = int64_field ~context "source_incarnation" fields in
    let* operator_operation_id =
      string_field ~context "operator_operation_id" fields
    in
    let* from_keeper = string_field ~context "from_keeper" fields in
    let* to_keeper = string_field ~context "to_keeper" fields in
    let* target_trace_id_wire = string_field ~context "target_trace_id" fields in
    let* target_trace_id =
      Keeper_id.Trace_id.of_string target_trace_id_wire
      |> Result.map_error (fun detail ->
        Printf.sprintf "%s.target_trace_id is invalid: %s" context detail)
    in
    let transfer =
      { source
      ; source_incarnation
      ; operator_operation_id
      ; from_keeper
      ; to_keeper
      ; target_trace_id
      }
    in
    let* () = validate_accepted_transfer transfer in
    Ok (Transfer_accepted transfer)
  | "ack_source_terminal" ->
    let* source_json = required_field ~context "source" fields in
    let* source = Keeper_event_queue.stimulus_of_yojson source_json in
    let* source_incarnation = int64_field ~context "source_incarnation" fields in
    let* operator_operation_id =
      string_field ~context "operator_operation_id" fields
    in
    let* source_receipt_kind =
      string_field ~context "source_receipt_kind" fields
    in
    let common_fields =
      [ "kind"
      ; "source"
      ; "source_incarnation"
      ; "operator_operation_id"
      ; "source_receipt_kind"
      ]
    in
    let* source_receipt =
      match source_receipt_kind with
      | "turn_completed" ->
        let* () = exact_fields ~context ~expected:common_fields fields in
        Ok Turn_completed
      | "turn_attempt_terminal" ->
        let* () =
          exact_fields
            ~context
            ~expected:("detail" :: common_fields)
            fields
        in
        let* detail = string_field ~context "detail" fields in
        Ok (Turn_attempt_terminal { detail })
      | ("fusion_terminal" | "hitl_terminal") as expected_kind ->
        let* () = exact_fields ~context ~expected:common_fields fields in
        let* source_receipt = source_terminal_receipt_of_stimulus source in
        let* actual_kind =
          match source_receipt with
          | Fusion_terminal _ -> Ok "fusion_terminal"
          | Hitl_terminal _ -> Ok "hitl_terminal"
          | Turn_completed
          | Turn_attempt_terminal _ ->
            Error "source payload produced a non-intrinsic terminal receipt"
        in
        if String.equal expected_kind actual_kind
        then Ok source_receipt
        else Error "source-terminal receipt kind does not match source payload"
      | other ->
        Error (Printf.sprintf "unknown source-terminal receipt kind: %s" other)
    in
    let source_terminal =
      { source
      ; source_incarnation
      ; operator_operation_id
      ; source_receipt
      }
    in
    let* () = validate_accepted_source_terminal source_terminal in
    Ok (Ack_source_terminal source_terminal)
  | kind -> Error (Printf.sprintf "unknown event queue transition kind: %s" kind)
;;

let accepted_transfer_projection_to_yojson (transfer : accepted_transfer) =
  transition_to_yojson (Transfer_accepted transfer)
;;

let accepted_transfer_projection_of_yojson json =
  let* transition = transition_of_yojson json in
  match transition with
  | Transfer_accepted transfer -> Ok transfer
  | Cancel_accepted _
  | Ack_source_terminal _ ->
    Error "target transfer projection must contain transfer_accepted"
;;

let transition_receipt_to_yojson (receipt : transition_receipt) =
  `Assoc
    [ "transition_id", `String receipt.transition_id
    ; "event_id", `String receipt.event_id
    ; "applied_at_unix", `Float receipt.applied_at
    ; "transition", transition_to_yojson receipt.transition
    ]
;;

let transition_receipt_of_yojson json =
  let context = "event queue transition receipt" in
  let* fields = assoc_fields ~context json in
  let* () =
    exact_fields
      ~context
      ~expected:
        [ "transition_id"
        ; "event_id"
        ; "applied_at_unix"
        ; "transition"
        ]
      fields
  in
  let* receipt_transition_id = string_field ~context "transition_id" fields in
  let* event_id = string_field ~context "event_id" fields in
  let* applied_at = float_field ~context "applied_at_unix" fields in
  let* transition_json = required_field ~context "transition" fields in
  let* transition = transition_of_yojson transition_json in
  if not (Float.is_finite applied_at)
  then Error "event queue receipt application time must be finite"
  else if
    not
      (String.equal
         receipt_transition_id
         (pending_transition_id transition))
  then Error (Printf.sprintf "event queue receipt transition id mismatch: %s" receipt_transition_id)
  else if not (String.equal event_id (event_id_of_transition receipt_transition_id))
  then Error (Printf.sprintf "event queue receipt event id mismatch: %s" event_id)
  else
    Ok
      { transition_id = receipt_transition_id
      ; event_id
      ; applied_at
      ; transition
      }
;;

let is_sha256 value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value
;;

let projected_source_kind_to_string = function
  | Source_board_signal -> "board_signal"
  | Source_board_attention -> "board_attention"
  | Source_bootstrap -> "bootstrap"
  | Source_fusion_completed -> "fusion_completed"
  | Source_schedule_due -> "schedule_due"
  | Source_connector_attention -> "connector_attention"
  | Source_hitl_resolved -> "hitl_resolved"
  | Source_ask_answered -> "ask_answered"
  | Source_completion_authority_rejected -> "completion_authority_rejected"
  | Source_task_outcome -> "task_outcome"
  | Source_task_cancelled -> "task_cancelled"
  | Source_workspace_message -> "workspace_message"
  | Source_delegate_completed -> "keeper_delegate_completed"
  | Source_composition_completed -> "keeper_composition_completed"
;;

let source_kind_of_string = function
  | "board_signal" -> Ok Source_board_signal
  | "board_attention" -> Ok Source_board_attention
  | "bootstrap" -> Ok Source_bootstrap
  | "fusion_completed" -> Ok Source_fusion_completed
  | "schedule_due" -> Ok Source_schedule_due
  | "connector_attention" -> Ok Source_connector_attention
  | "hitl_resolved" -> Ok Source_hitl_resolved
  | "ask_answered" -> Ok Source_ask_answered
  | "completion_authority_rejected" -> Ok Source_completion_authority_rejected
  | "task_outcome" -> Ok Source_task_outcome
  | "task_cancelled" -> Ok Source_task_cancelled
  | "workspace_message" -> Ok Source_workspace_message
  | "keeper_delegate_completed" -> Ok Source_delegate_completed
  | "keeper_composition_completed" -> Ok Source_composition_completed
  | other -> Error (Printf.sprintf "unknown projected source kind: %s" other)
;;

let projected_kind_to_yojson = function
  | Projected_cancel { reason_ref } ->
    `Assoc [ "kind", `String "cancel"; "reason_ref", `String reason_ref ]
  | Projected_transfer { from_keeper; to_keeper; target_trace_id } ->
    `Assoc
      [ "kind", `String "transfer"
      ; "from_keeper", `String from_keeper
      ; "to_keeper", `String to_keeper
      ; "target_trace_id", `String (Keeper_id.Trace_id.to_string target_trace_id)
      ]
  | Projected_fusion_terminal ->
    `Assoc [ "kind", `String "fusion_terminal" ]
  | Projected_hitl_terminal ->
    `Assoc [ "kind", `String "hitl_terminal" ]
  | Projected_turn_completed ->
    `Assoc [ "kind", `String "turn_completed" ]
  | Projected_turn_attempt_terminal ->
    `Assoc [ "kind", `String "turn_attempt_terminal" ]
;;

let projected_kind_of_yojson json =
  let context = "event queue projected disposition kind" in
  let* fields = assoc_fields ~context json in
  let* kind = string_field ~context "kind" fields in
  match kind with
  | "cancel" ->
    let* () = exact_fields ~context ~expected:[ "kind"; "reason_ref" ] fields in
    let* reason_ref = string_field ~context "reason_ref" fields in
    if not (is_sha256 reason_ref)
    then Error "projected cancellation reason_ref must be lowercase sha256"
    else Ok (Projected_cancel { reason_ref })
  | "transfer" ->
    let* () =
      exact_fields
        ~context
        ~expected:[ "kind"; "from_keeper"; "to_keeper"; "target_trace_id" ]
        fields
    in
    let* from_keeper = string_field ~context "from_keeper" fields in
    let* to_keeper = string_field ~context "to_keeper" fields in
    let* target_trace_id_wire = string_field ~context "target_trace_id" fields in
    let* target_trace_id =
      Keeper_id.Trace_id.of_string target_trace_id_wire
      |> Result.map_error (fun detail ->
        "projected transfer target_trace_id is invalid: " ^ detail)
    in
    if String.trim from_keeper = "" || String.trim to_keeper = ""
    then Error "projected transfer endpoints must not be empty"
    else if String.equal from_keeper to_keeper
    then Error "projected transfer endpoints must differ"
    else Ok (Projected_transfer { from_keeper; to_keeper; target_trace_id })
  | "fusion_terminal" | "hitl_terminal" | "turn_completed"
  | "turn_attempt_terminal" ->
    let* () = exact_fields ~context ~expected:[ "kind" ] fields in
    Ok
      (match kind with
       | "fusion_terminal" -> Projected_fusion_terminal
       | "hitl_terminal" -> Projected_hitl_terminal
       | "turn_completed" -> Projected_turn_completed
       | "turn_attempt_terminal" -> Projected_turn_attempt_terminal
       | _ -> assert false)
  | other -> Error (Printf.sprintf "unknown projected disposition kind: %s" other)
;;

let witness_to_yojson witness =
  `Assoc
    [ "transition_id", `String witness.transition_id
    ; "event_id", `String witness.event_id
    ; "applied_at_unix", `Float witness.applied_at
    ; "operator_operation_id", `String witness.operator_operation_id
    ; "transition_ref", `String witness.transition_ref
    ; "source_ref", `String witness.source_ref
    ; "post_id", `String witness.post_id
    ; "urgency", `String (Keeper_event_queue.urgency_to_string witness.urgency)
    ; "source_arrived_at", `Float witness.source_arrived_at
    ; ( "source_kind"
      , `String (projected_source_kind_to_string witness.source_kind) )
    ; "source_incarnation", int64_json witness.source_incarnation
    ; "disposition", projected_kind_to_yojson witness.kind
    ]
;;

let witness_of_yojson json =
  let context = "event queue projected disposition witness" in
  let* fields = assoc_fields ~context json in
  let* () =
    exact_fields
      ~context
      ~expected:
        [ "transition_id"
        ; "event_id"
        ; "applied_at_unix"
        ; "operator_operation_id"
        ; "transition_ref"
        ; "source_ref"
        ; "post_id"
        ; "urgency"
        ; "source_arrived_at"
        ; "source_kind"
        ; "source_incarnation"
        ; "disposition"
        ]
      fields
  in
  let* transition_id = string_field ~context "transition_id" fields in
  let* event_id = string_field ~context "event_id" fields in
  let* applied_at = float_field ~context "applied_at_unix" fields in
  let* operator_operation_id =
    string_field ~context "operator_operation_id" fields
  in
  let* transition_ref = string_field ~context "transition_ref" fields in
  let* source_ref = string_field ~context "source_ref" fields in
  let* post_id = string_field ~context "post_id" fields in
  let* urgency_raw = string_field ~context "urgency" fields in
  let* urgency = Keeper_event_queue.urgency_of_string urgency_raw in
  let* source_arrived_at = float_field ~context "source_arrived_at" fields in
  let* source_kind_raw = string_field ~context "source_kind" fields in
  let* source_kind = source_kind_of_string source_kind_raw in
  let* source_incarnation = int64_field ~context "source_incarnation" fields in
  let* disposition_json = required_field ~context "disposition" fields in
  let* kind = projected_kind_of_yojson disposition_json in
  let expected_transition_id =
    match kind with
    | Projected_cancel _ -> "pending-cancel:" ^ operator_operation_id
    | Projected_transfer _ -> "pending-transfer:" ^ operator_operation_id
    | Projected_fusion_terminal
    | Projected_hitl_terminal
    | Projected_turn_completed
    | Projected_turn_attempt_terminal ->
      "pending-source-terminal-ack:" ^ operator_operation_id
  in
  if not (Float.is_finite applied_at)
  then Error "projected disposition application time must be finite"
  else if not (Float.is_finite source_arrived_at)
  then Error "projected disposition source arrival time must be finite"
  else if Int64.compare source_incarnation 0L < 0
  then Error "projected disposition source incarnation must not be negative"
  else if String.trim operator_operation_id = ""
  then Error "projected disposition operation id must not be empty"
  else if String.trim post_id = ""
  then Error "projected disposition post id must not be empty"
  else if not (is_sha256 transition_ref && is_sha256 source_ref)
  then Error "projected disposition references must be lowercase sha256"
  else if not (String.equal transition_id expected_transition_id)
  then Error "projected disposition transition id mismatch"
  else if not (String.equal event_id (event_id_of_transition transition_id))
  then Error "projected disposition event id mismatch"
  else if
    match kind, source_kind with
    | Projected_fusion_terminal, Source_fusion_completed
    | Projected_hitl_terminal, Source_hitl_resolved -> false
    | Projected_fusion_terminal, _
    | Projected_hitl_terminal, _ -> true
    | Projected_cancel _, _
    | Projected_transfer _, _
    | Projected_turn_completed, _
    | Projected_turn_attempt_terminal, _ -> false
  then Error "projected intrinsic terminal kind conflicts with source kind"
  else
    Ok
      { transition_id
      ; event_id
      ; applied_at
      ; operator_operation_id
      ; transition_ref
      ; source_ref
      ; post_id
      ; urgency
      ; source_arrived_at
      ; source_kind
      ; source_incarnation
      ; kind
      }
;;

let durable_disposition_to_yojson = function
  | Current_receipt receipt ->
    `Assoc
      [ "storage", `String "full_receipt"
      ; "receipt", transition_receipt_to_yojson receipt
      ]
  | Projected_witness witness ->
    `Assoc
      [ "storage", `String "compact_witness"
      ; "witness", witness_to_yojson witness
      ]
;;

let durable_disposition_of_yojson json =
  let context = "event queue projected disposition" in
  let* fields = assoc_fields ~context json in
  let* storage = string_field ~context "storage" fields in
  match storage with
  | "full_receipt" ->
    Error "projected history must use a compact witness"
  | "compact_witness" ->
    let* () = exact_fields ~context ~expected:[ "storage"; "witness" ] fields in
    let* witness_json = required_field ~context "witness" fields in
    witness_of_yojson witness_json |> Result.map (fun w -> Projected_witness w)
  | other -> Error (Printf.sprintf "unknown projected disposition storage: %s" other)
;;

let outbox_entry_to_yojson entry =
  `Assoc
    [ "receipt", transition_receipt_to_yojson entry.receipt
    ; "stimuli", `List (List.map Keeper_event_queue.stimulus_to_yojson entry.stimuli)
    ]
;;

let outbox_entry_of_yojson json =
  let context = "event queue outbox entry" in
  let* fields = assoc_fields ~context json in
  let* receipt_json = required_field ~context "receipt" fields in
  let* receipt = transition_receipt_of_yojson receipt_json in
  let* stimuli =
    list_field ~context "stimuli" Keeper_event_queue.stimulus_of_yojson fields
  in
  (* Re-enforce the commit-time receipt-vs-stimuli invariant at the decode
     boundary; malformed typed terminal receipts are rejected as [Error]. *)
  let* () = validate_transition_for_stimuli receipt.transition stimuli in
  Ok { receipt; stimuli }
;;

let pending_entry_to_yojson entry =
  `Assoc
    ([ "source", Keeper_event_queue.stimulus_to_yojson entry.source
     ; "admitted_revision", int64_json entry.admitted_revision
     ; "checkpoint_retentions", `Int entry.checkpoint_retentions
     ] @ match entry.repetition_scope with
       | None -> []
       | Some scope -> [ "repetition_scope", Keeper_execution_scope_id.to_json scope ])
;;

let pending_entry_of_yojson json =
  let context = "event queue pending entry" in
  let* fields = assoc_fields ~context json in
  let* () =
    exact_fields
      ~context
      ~expected:([ "source"; "admitted_revision"; "checkpoint_retentions" ]
        @ if List.mem_assoc "repetition_scope" fields then [ "repetition_scope" ] else [])
      fields
  in
  let* source_json = required_field ~context "source" fields in
  let* source = Keeper_event_queue.stimulus_of_yojson source_json in
  let* admitted_revision =
    int64_field ~context "admitted_revision" fields
  in
  let* checkpoint_retentions =
    int_field ~context "checkpoint_retentions" fields
  in
  if Int64.compare admitted_revision 0L < 0
  then Error "event queue pending admission revision must not be negative"
  else if checkpoint_retentions < 0 then
    Error "event queue pending checkpoint retentions must not be negative"
  else
    let* repetition_scope = match List.assoc_opt "repetition_scope" fields with
      | None -> Ok None
      | Some json -> Keeper_execution_scope_id.of_json json |> Result.map Option.some in
    Ok { source; admitted_revision; checkpoint_retentions; repetition_scope }
;;

let to_yojson state =
  `Assoc
    [ "schema", `String schema
    ; "revision", int64_json state.revision
    ; ( "pending"
      , `List (List.map pending_entry_to_yojson state.pending_entries) )
    ; ( "last_transition"
      , match state.last_transition with
        | None -> `Null
        | Some receipt -> transition_receipt_to_yojson receipt )
    ; ( "projected_dispositions"
      , `List
          (List.map
             durable_disposition_to_yojson
             state.projected_dispositions) )
    ; ( "transition_outbox"
      , `List (List.map outbox_entry_to_yojson state.transition_outbox) )
    ; ( "accepted_transfer_projections"
      , `List
          (List.map
             accepted_transfer_projection_to_yojson
             state.accepted_transfer_projections) )
    ]
;;

module String_set = Set.Make (String)

let duplicate_by key values =
  let rec loop seen = function
    | [] -> None
    | value :: rest ->
      let key = key value in
      if String_set.mem key seen
      then Some key
      else loop (String_set.add key seen) rest
  in
  loop String_set.empty values
;;

let pending_identity_is_duplicated (entries : pending_selection list) =
  let rec loop seen = function
    | [] -> false
    | entry :: rest ->
      if
        List.exists
          (fun prior ->
             Keeper_event_queue.stimulus_identity_equal
               prior.source
               entry.source)
          seen
      then true
      else loop (entry :: seen) rest
  in
  loop [] entries
;;

let validate_state state =
  if Int64.compare state.revision 0L < 0
  then Error "event queue revision must not be negative"
  else if
    List.exists
      (fun entry ->
         Int64.compare entry.admitted_revision 0L < 0
         || Int64.compare entry.admitted_revision state.revision > 0)
      state.pending_entries
  then Error "event queue pending admission revision is outside the durable state"
  else if pending_identity_is_duplicated state.pending_entries
  then Error "event queue pending source identity is duplicated"
  else if List.length state.transition_outbox > 1
  then Error "event queue state must contain at most one unprojected transition"
  else if
    match state.transition_outbox with
    | [ entry ] ->
      List.exists
        (fun disposition ->
           String.equal
             (durable_transition_id disposition)
             entry.receipt.transition_id)
        (projected_dispositions state)
    | [] | _ :: _ :: _ -> false
  then Error "event queue projected ledger duplicates the unprojected transition"
  else
    let* () =
      match
        duplicate_by
          (fun entry -> entry.receipt.transition_id)
          state.transition_outbox
      with
      | Some transition_id ->
        Error (Printf.sprintf "duplicate event queue transition id: %s" transition_id)
      | None -> Ok ()
    in
    let* () =
      match
        duplicate_by
          durable_transition_id
          (projected_dispositions state)
      with
      | Some transition_id ->
        Error
          (Printf.sprintf
             "duplicate projected event queue transition id: %s"
             transition_id)
      | None -> Ok ()
    in
    let disposition_operation_ids =
      List.map
        durable_operation_id
        (projected_dispositions state)
      @ List.map
          (fun entry ->
             disposition_operation_id entry.receipt.transition)
          state.transition_outbox
    in
    let* () =
      match duplicate_by Fun.id disposition_operation_ids with
      | Some operation_id ->
        Error
          (Printf.sprintf
             "duplicate durable disposition operation id: %s"
             operation_id)
      | None -> Ok ()
    in
    let* () =
      match
        duplicate_by
          (fun (transfer : accepted_transfer) ->
             transfer.operator_operation_id)
          state.accepted_transfer_projections
      with
      | Some operation_id ->
        Error
          (Printf.sprintf
             "duplicate target transfer projection operation id: %s"
             operation_id)
      | None -> Ok ()
    in
    Ok state
;;

let of_yojson json =
  let context = "keeper event queue state" in
  let* fields = assoc_fields ~context json in
  let* schema_value = string_field ~context "schema" fields in
  let* () =
    if String.equal schema_value schema
    then Ok ()
    else
      Error
        (Printf.sprintf "unsupported keeper event queue state schema: %s" schema_value)
  in
  let* () =
    exact_fields
      ~context
      ~expected:
        [ "schema"
        ; "revision"
        ; "pending"
        ; "last_transition"
        ; "projected_dispositions"
        ; "transition_outbox"
        ; "accepted_transfer_projections"
        ]
      fields
  in
  let* revision = int64_field ~context "revision" fields in
  let* pending_entries =
    list_field ~context "pending" pending_entry_of_yojson fields
  in
  let* transition_outbox =
    list_field ~context "transition_outbox" outbox_entry_of_yojson fields
  in
  let* last_transition =
    match List.assoc_opt "last_transition" fields with
    | Some `Null -> Ok None
    | Some json -> transition_receipt_of_yojson json |> Result.map Option.some
    | None -> Error "keeper event queue state missing required field last_transition"
  in
  let* projected_dispositions =
    list_field
      ~context
      "projected_dispositions"
      durable_disposition_of_yojson
      fields
  in
  let* accepted_transfer_projections =
    list_field
      ~context
      "accepted_transfer_projections"
      accepted_transfer_projection_of_yojson
      fields
  in
  validate_state
    { revision
    ; pending_entries
    ; last_transition
    ; projected_dispositions
    ; transition_outbox
    ; accepted_transfer_projections
    }
;;
