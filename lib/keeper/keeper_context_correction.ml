module Exact_output = Agent_sdk.Exact_output

let ( let* ) = Result.bind
let lane_id = "context_correction_exact"
let state_context_key = "keeper.context_correction.v1"
let state_version = 1
let max_closed_units = 16
let max_closed_bytes = 65_536

let sha256 value = Digestif.SHA256.(digest_string value |> to_hex)

type submission = Unavailable | Coalesced | Submitted

type queued_job = unit -> unit

type slot = { mutable latest : queued_job option }

type executor =
  { generation : int
  ; sw : Eio.Switch.t
  ; mutable accepting : bool
  ; slots : (string, slot) Hashtbl.t
  }

let executor : executor option ref = ref None
let executor_mu = Stdlib.Mutex.create ()
let executor_generation = Atomic.make 0

let init ~sw =
  let generation = Atomic.fetch_and_add executor_generation 1 + 1 in
  let installed =
    { generation; sw; accepting = true; slots = Hashtbl.create 16 }
  in
  Eio.Switch.on_release sw (fun () ->
    Stdlib.Mutex.protect executor_mu (fun () ->
      installed.accepting <- false;
      match !executor with
      | Some current when current == installed -> executor := None
      | _ -> ()));
  Stdlib.Mutex.protect executor_mu (fun () ->
    if installed.accepting then executor := Some installed)
;;

let executor_key ~base_path ~keeper_name =
  Keeper_registry_types.registry_key ~base_path keeper_name
;;

let release_slot installed key admitted_slot =
  Stdlib.Mutex.protect executor_mu (fun () ->
    match Hashtbl.find_opt installed.slots key with
    | Some current when current == admitted_slot ->
      Hashtbl.remove installed.slots key
    | _ -> ())
;;

let take_latest_or_release installed key admitted_slot =
  Stdlib.Mutex.protect executor_mu (fun () ->
    match Hashtbl.find_opt installed.slots key with
    | Some current when current == admitted_slot ->
      (match current.latest with
       | Some job ->
         current.latest <- None;
         Some job
       | None ->
         Hashtbl.remove installed.slots key;
         None)
    | _ -> None)
;;

let run_job ~keeper_name job =
  try job () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.warn
      ~keeper_name
      "context correction detached fiber failed: %s"
      (Printexc.to_string exn)
;;

let run_slot installed key admitted_slot ~keeper_name first_job =
  let rec loop job =
    run_job ~keeper_name job;
    match take_latest_or_release installed key admitted_slot with
    | Some next ->
      Eio.Fiber.yield ();
      loop next
    | None -> ()
  in
  Eio.Switch.run @@ fun worker_sw ->
  Eio.Switch.on_release worker_sw (fun () ->
    release_slot installed key admitted_slot);
  loop first_job
;;

let submit ~base_path ~keeper_name job =
  let key = executor_key ~base_path ~keeper_name in
  let decision =
    Stdlib.Mutex.protect executor_mu (fun () ->
      match !executor with
      | None -> `Unavailable
      | Some installed when not installed.accepting -> `Unavailable
      | Some installed ->
        (match Hashtbl.find_opt installed.slots key with
         | Some admitted_slot ->
           admitted_slot.latest <- Some job;
           `Coalesced
         | None ->
           let admitted_slot = { latest = None } in
           Hashtbl.add installed.slots key admitted_slot;
           `Admitted (installed, admitted_slot)))
  in
  match decision with
  | `Unavailable -> Unavailable
  | `Coalesced -> Coalesced
  | `Admitted (installed, admitted_slot) ->
    (try
       Eio.Fiber.fork ~sw:installed.sw (fun () ->
         (* [fork] may transfer directly to the child. Yield before observing
            the job so [submit] never executes caller work inline. *)
         Eio.Fiber.yield ();
         run_slot installed key admitted_slot ~keeper_name job);
       Submitted
     with
     | _ ->
       release_slot installed key admitted_slot;
       Unavailable)
;;

let canonical_messages messages =
  messages
  |> List.map Keeper_context_core.message_to_json
  |> fun values -> Yojson.Safe.to_string (`List values)
;;

type marker =
  { semantic_message_count : int; semantic_state_sha256 : string;
    accepted_closed_unit_count : int; accepted_closed_prefix_sha256 : string }

let genesis_marker =
  { semantic_message_count = 0
  ; semantic_state_sha256 = sha256 "[]"
  ; accepted_closed_unit_count = 0
  ; accepted_closed_prefix_sha256 = sha256 "context-correction:v1:root"
  }
;;

let marker_to_json marker =
  `Assoc
    [ "version", `Int state_version
    ; "semantic_message_count", `Int marker.semantic_message_count
    ; "semantic_state_sha256", `String marker.semantic_state_sha256
    ; "accepted_closed_unit_count", `Int marker.accepted_closed_unit_count
    ; ( "accepted_closed_prefix_sha256"
      , `String marker.accepted_closed_prefix_sha256 )
    ]
;;

type preserved_reason =
  | Control_checkpoint | Raw_save_superseded | Fresh_state_required
  | Marker_corrupt
  | No_closed_delta | Closed_unit_over_budget | Network_unavailable
  | Clock_unavailable | Exact_lane_unavailable | Exact_flow_failed
  | Semantic_output_invalid | Deadline_exceeded
  | Deadline_exceeded_before_cas | Cas_conflict | Cas_not_installed

let preserved_reason_to_string = function
  | Control_checkpoint -> "control_checkpoint"
  | Raw_save_superseded -> "raw_save_superseded"
  | Fresh_state_required -> "fresh_state_required"
  | Marker_corrupt -> "marker_corrupt"
  | No_closed_delta -> "no_closed_delta"
  | Closed_unit_over_budget -> "closed_unit_over_budget"
  | Network_unavailable -> "network_unavailable"
  | Clock_unavailable -> "clock_unavailable"
  | Exact_lane_unavailable -> "exact_lane_unavailable"
  | Exact_flow_failed -> "exact_flow_failed"
  | Semantic_output_invalid -> "semantic_output_invalid"
  | Deadline_exceeded -> "deadline_exceeded"
  | Deadline_exceeded_before_cas -> "deadline_exceeded_before_cas"
  | Cas_conflict -> "cas_conflict"
  | Cas_not_installed -> "cas_not_installed"
;;

let marker_of_json = function
  | `Assoc fields ->
    let expected = [ "accepted_closed_prefix_sha256"; "accepted_closed_unit_count";
      "semantic_message_count"; "semantic_state_sha256"; "version" ] in
    let keys = List.map fst fields |> List.sort String.compare in
    let int_field name = match List.assoc_opt name fields with
      | Some (`Int value) -> Some value | _ -> None in
    let string_field name = match List.assoc_opt name fields with
      | Some (`String value) -> Some value | _ -> None in
    (match
       ( keys = expected
       , int_field "version"
       , int_field "semantic_message_count"
       , string_field "semantic_state_sha256"
       , int_field "accepted_closed_unit_count"
       , string_field "accepted_closed_prefix_sha256" )
     with
     | ( true
       , Some version
       , Some semantic_message_count
       , Some semantic_state_sha256
       , Some accepted_closed_unit_count
       , Some accepted_closed_prefix_sha256 )
       when version = state_version && semantic_message_count >= 0
            && semantic_message_count <= 1 && accepted_closed_unit_count >= 0
            && String.length semantic_state_sha256 = 64
            && String.length accepted_closed_prefix_sha256 = 64 ->
       Ok
         { semantic_message_count
         ; semantic_state_sha256
         ; accepted_closed_unit_count
         ; accepted_closed_prefix_sha256
         }
     | _ -> Error Marker_corrupt)
  | _ -> Error Marker_corrupt
;;

let marker_of_context context =
  match
    Agent_sdk.Context.get_scoped
      context
      Agent_sdk.Context.Session
      state_context_key
  with
  | None -> Error Fresh_state_required
  | Some json -> marker_of_json json
;;

let set_marker context marker =
  Agent_sdk.Context.set_scoped
    context
    Agent_sdk.Context.Session
    state_context_key
    (marker_to_json marker)
;;

let marker_from_resume = function
  | None -> Ok genesis_marker
  | Some (checkpoint : Agent_sdk.Checkpoint.t) ->
    marker_of_context checkpoint.context
;;

let bind_marker_from_resume ~resume_checkpoint context =
  match marker_from_resume resume_checkpoint with
  | Ok marker -> set_marker context marker
  | Error _ -> ()
;;

let prepare_raw_checkpoint
      ~resume_checkpoint
      (checkpoint : Agent_sdk.Checkpoint.t)
  =
  match marker_from_resume resume_checkpoint with
  | Error _ -> checkpoint
  | Ok marker ->
    let context = Agent_sdk.Context.copy checkpoint.context in
    set_marker context marker;
    { checkpoint with Agent_sdk.Checkpoint.context }
;;

let rec split_at count acc values =
  if count = 0
  then Ok (List.rev acc, values)
  else
    match values with
    | [] -> Error Marker_corrupt
    | value :: rest -> split_at (count - 1) (value :: acc) rest
;;

let messages_of_closed_unit = function
  | Keeper_compaction_unit.Ordinary_message message -> [ message ]
  | Keeper_compaction_unit.Closed_tool_cycle messages -> messages
;;

let select_closed_units units =
  let rec loop count bytes selected = function
    | [] -> Ok (List.rev selected, [])
    | unit :: rest ->
      let unit_bytes =
        unit |> messages_of_closed_unit |> canonical_messages |> String.length
      in
      if count = 0 && unit_bytes > max_closed_bytes
      then Error Closed_unit_over_budget
      else if count >= max_closed_units || bytes + unit_bytes > max_closed_bytes
      then Ok (List.rev selected, unit :: rest)
      else loop (count + 1) (bytes + unit_bytes) (unit :: selected) rest
  in
  loop 0 0 [] units
;;

let advance_anchor marker units =
  List.fold_left
    (fun (count, digest) unit ->
       let canonical = unit |> messages_of_closed_unit |> canonical_messages in
       count + 1, sha256 (digest ^ "\000" ^ canonical))
    ( marker.accepted_closed_unit_count
    , marker.accepted_closed_prefix_sha256 )
    units
;;

let prepare_candidate
      ~marker
      ~(raw_checkpoint : Agent_sdk.Checkpoint.t)
      ~semantic_context
  =
  let semantic_context = String.trim semantic_context in
  if semantic_context = ""
  then Error Semantic_output_invalid
  else
    let* semantic_messages, backlog =
      split_at marker.semantic_message_count [] raw_checkpoint.messages
    in
    if not (String.equal marker.semantic_state_sha256 (sha256 (canonical_messages semantic_messages)))
    then Error Marker_corrupt
    else
      let* partition =
        Keeper_compaction_unit.partition backlog
        |> Result.map_error (fun _ -> Marker_corrupt)
      in
      let* selected, remaining =
        select_closed_units partition.closed_prefix
      in
      if selected = []
      then Error No_closed_delta
      else
        let semantic_message = Agent_sdk.Types.system_msg semantic_context in
        let remaining_messages =
          List.concat_map messages_of_closed_unit remaining
          @ partition.protected_suffix
        in
        let count, digest = advance_anchor marker selected in
        let marker =
          { semantic_message_count = 1
          ; semantic_state_sha256 = sha256 (canonical_messages [ semantic_message ])
          ; accepted_closed_unit_count = count
          ; accepted_closed_prefix_sha256 = digest
          }
        in
        let context = Agent_sdk.Context.copy raw_checkpoint.context in
        set_marker context marker;
        Ok
          ( { raw_checkpoint with
              Agent_sdk.Checkpoint.messages =
                semantic_message :: remaining_messages
            ; context
            ; working_context = None
            }
          , marker )
;;

type provenance =
  { slot_id : string; call_id : string; plan_fingerprint : string;
    request_body_sha256 : string; response_body_sha256 : string;
    http_status : int option; provider_trace_fingerprint : string option;
    catalog_generation_fingerprint : string; catalog_evidence_sha256 : string;
    target_identity_fingerprint : string }

type outcome =
  | Applied of
      { checkpoint : Agent_sdk.Checkpoint.t; raw_ref : Keeper_checkpoint_ref.t;
        installed_ref : Keeper_checkpoint_ref.t; provenance : provenance }
  | Preserved of
      { checkpoint : Agent_sdk.Checkpoint.t; raw_ref : Keeper_checkpoint_ref.t;
        reason : preserved_reason; detail : Yojson.Safe.t option }
  | Skipped of { reason : preserved_reason; detail : Yojson.Safe.t option }

let preserved ?detail checkpoint raw_ref reason =
  Preserved { checkpoint; raw_ref; reason; detail }
;;

let checkpoint_of_outcome = function
  | Applied { checkpoint; _ } | Preserved { checkpoint; _ } -> Some checkpoint
  | Skipped _ -> None
;;

let require_equal left right =
  if String.equal left right then Ok () else Error Semantic_output_invalid
;;

let effect_phase_to_string = function
  | Exact_output.Not_started -> "not_started"
  | Exact_output.Before_dispatch -> "before_dispatch"
  | Exact_output.Dispatch_started -> "dispatch_started"
  | Exact_output.Response_received -> "response_received"
  | Exact_output.Terminal -> "terminal"
;;

let option_to_json convert = function
  | Some value -> convert value
  | None -> `Null
;;

let receipt_to_json receipt =
  let provider_trace_fingerprint =
    receipt
    |> Exact_output.receipt_provider_trace
    |> Option.map Exact_output.provider_trace_fingerprint
  in
  `Assoc
    [ "call_id",
      `String
        (receipt
         |> Exact_output.receipt_call_id
         |> Exact_output.call_id_to_string)
    ; "phase",
      `String
        (receipt
         |> Exact_output.receipt_phase
         |> effect_phase_to_string)
    ; "dispatch_count", `Int (Exact_output.receipt_dispatch_count receipt)
    ; "http_status",
      option_to_json (fun value -> `Int value)
        (Exact_output.receipt_http_status receipt)
    ; "provider_trace_fingerprint",
      option_to_json (fun value -> `String value) provider_trace_fingerprint
    ; "plan_fingerprint",
      `String (Exact_output.receipt_plan_fingerprint receipt)
    ; "request_body_sha256",
      `String (Exact_output.receipt_request_body_sha256 receipt)
    ; "catalog_generation_fingerprint",
      `String
        (receipt
         |> Exact_output.receipt_catalog_generation
         |> Exact_output.catalog_generation_fingerprint)
    ; "catalog_evidence_sha256",
      `String
        (receipt
         |> Exact_output.receipt_catalog_evidence
         |> Exact_output.catalog_evidence_sha256)
    ; "target_identity_fingerprint",
      `String
        (receipt
         |> Exact_output.receipt_target_identity
         |> Exact_output.target_identity_fingerprint)
    ]
;;

let execution_error_cause_to_json = function
  | Exact_output.Attempt_already_started ->
    `Assoc [ "kind", `String "attempt_already_started" ]
  | Exact_output.Clock_required_for_timeout ->
    `Assoc [ "kind", `String "clock_required_for_timeout" ]
  | Exact_output.Frozen_request_mismatch ->
    `Assoc [ "kind", `String "frozen_request_mismatch" ]
  | Exact_output.Completion_failed ->
    `Assoc [ "kind", `String "completion_failed" ]
  | Exact_output.Input_capacity_refused refusal ->
    (match refusal with
     | Exact_output.Context_window_refused { limit_tokens } ->
       `Assoc
         [ "kind", `String "context_window_refused"
         ; "limit_tokens",
           option_to_json (fun value -> `Int value) limit_tokens
         ]
     | Exact_output.Serialized_request_refused { http_status } ->
       `Assoc
         [ "kind", `String "serialized_request_refused"
         ; "http_status", `Int http_status
         ])
  | Exact_output.Incomplete_output ->
    `Assoc [ "kind", `String "incomplete_output" ]
  | Exact_output.Missing_output ->
    `Assoc [ "kind", `String "missing_output" ]
  | Exact_output.Ambiguous_output count ->
    `Assoc
      [ "kind", `String "ambiguous_output"; "output_count", `Int count ]
  | Exact_output.Unexpected_output_content ->
    `Assoc [ "kind", `String "unexpected_output_content" ]
  | Exact_output.Invalid_json_output ->
    `Assoc [ "kind", `String "invalid_json_output" ]
  | Exact_output.Internal_non_json_output ->
    `Assoc [ "kind", `String "internal_non_json_output" ]
;;

let execution_error_to_json (error : Exact_output.execution_error) =
  `Assoc
    [ "receipt", receipt_to_json error.receipt
    ; "cause", execution_error_cause_to_json error.cause
    ; "response_body_sha256",
      option_to_json
        (fun (response : Exact_output.raw_response) ->
           `String response.body_sha256)
        error.raw_response
    ]
;;

let candidate_identity_to_json
      (identity : Exact_output.flow_candidate_identity)
  =
  `Assoc
    [ "candidate_id", `String identity.candidate_id
    ; "catalog_generation_fingerprint",
      `String
        (Exact_output.catalog_generation_fingerprint
           identity.catalog_generation)
    ; "catalog_evidence_sha256",
      `String
        (Exact_output.catalog_evidence_sha256 identity.catalog_evidence)
    ; "target_identity_fingerprint",
      `String
        (Exact_output.target_identity_fingerprint identity.target_identity)
    ]
;;

let capacity_disposition_to_json = function
  | Exact_output.Token_measurement_required
      { accepted_through_tokens; rejected_from_tokens } ->
    `Assoc
      [ "kind", `String "token_measurement_required"
      ; "accepted_through_tokens", `Int accepted_through_tokens
      ; "rejected_from_tokens",
        option_to_json (fun value -> `Int value) rejected_from_tokens
      ]
  | Exact_output.Context_window_exceeded
      { input_tokens; reserved_output_tokens; max_context_tokens } ->
    `Assoc
      [ "kind", `String "context_window_exceeded"
      ; "input_tokens", `Int input_tokens
      ; "reserved_output_tokens", `Int reserved_output_tokens
      ; "max_context_tokens", `Int max_context_tokens
      ]
  | Exact_output.Token_capacity_rejected rejection ->
    (match rejection with
     | Exact_output.Capacity_evidence_not_yet_valid
         { now_unix_s; checked_at_unix_s } ->
       `Assoc
         [ "kind", `String "capacity_evidence_not_yet_valid"
         ; "now_unix_s", `Int now_unix_s
         ; "checked_at_unix_s", `Int checked_at_unix_s
         ]
     | Exact_output.Capacity_evidence_expired
         { now_unix_s; expires_at_unix_s } ->
       `Assoc
         [ "kind", `String "capacity_evidence_expired"
         ; "now_unix_s", `Int now_unix_s
         ; "expires_at_unix_s", `Int expires_at_unix_s
         ]
     | Exact_output.Capacity_boundary_unknown
         { input_tokens; accepted_through_tokens; rejected_from_tokens } ->
       `Assoc
         [ "kind", `String "capacity_boundary_unknown"
         ; "input_tokens", `Int input_tokens
         ; "accepted_through_tokens", `Int accepted_through_tokens
         ; "rejected_from_tokens",
           option_to_json (fun value -> `Int value) rejected_from_tokens
         ]
     | Exact_output.Capacity_input_rejected
         { input_tokens; accepted_through_tokens; rejected_from_tokens } ->
       `Assoc
         [ "kind", `String "capacity_input_rejected"
         ; "input_tokens", `Int input_tokens
         ; "accepted_through_tokens", `Int accepted_through_tokens
         ; "rejected_from_tokens", `Int rejected_from_tokens
         ])
  | Exact_output.Serialized_request_body_too_large
      { actual_bytes; limit_bytes } ->
    `Assoc
      [ "kind", `String "serialized_request_body_too_large"
      ; "actual_bytes", `Int actual_bytes
      ; "limit_bytes", `Int limit_bytes
      ]
;;

let candidate_disposition_to_json = function
  | Exact_output.Runtime_slot_unavailable ->
    `Assoc [ "kind", `String "runtime_slot_unavailable" ]
  | Exact_output.Runtime_contract_rejected ->
    `Assoc [ "kind", `String "runtime_contract_rejected" ]
  | Exact_output.Input_contract_rejected ->
    `Assoc [ "kind", `String "input_contract_rejected" ]
  | Exact_output.Output_requirement_rejected ->
    `Assoc [ "kind", `String "output_requirement_rejected" ]
  | Exact_output.Input_capacity capacity ->
    `Assoc
      [ "kind", `String "input_capacity"
      ; "capacity", capacity_disposition_to_json capacity
      ]
  | Exact_output.Request_preparation_failed ->
    `Assoc [ "kind", `String "request_preparation_failed" ]
;;

let candidate_rejection_to_json rejection =
  `Assoc
    [ "candidate",
      candidate_identity_to_json
        (Exact_output.candidate_rejection_identity rejection)
    ; "disposition",
      candidate_disposition_to_json
        (Exact_output.candidate_rejection_disposition rejection)
    ]
;;

let candidate_failure_to_json = function
  | Exact_output.Flow_candidate_rejected rejection ->
    `Assoc
      [ "kind", `String "candidate_rejected"
      ; "rejection", candidate_rejection_to_json rejection
      ]
  | Exact_output.Flow_candidate_execution_failed { candidate; cause } ->
    `Assoc
      [ "kind", `String "candidate_execution_failed"
      ; "candidate", candidate_identity_to_json candidate.visit.identity
      ; "execution", execution_error_to_json cause
      ]
;;

let start_attempt_error_to_json = function
  | Exact_output.Call_id_generation_failed detail ->
    `Assoc
      [ "kind", `String "call_id_generation_failed"
      ; "detail", `String detail
      ]
;;

let measurement_start_error_to_json = function
  | Exact_output.Measurement_operation_id_generation_failed detail ->
    `Assoc
      [ "kind", `String "measurement_operation_id_generation_failed"
      ; "detail", `String detail
      ]
  | Exact_output.Measurement_clock_required_for_timeout ->
    `Assoc
      [ "kind", `String "measurement_clock_required_for_timeout" ]
;;

let flow_execution_error_to_json = function
  | Exact_output.Flow_attempt_already_started _ ->
    `Assoc [ "kind", `String "flow_attempt_already_started" ]
  | Exact_output.Flow_attempt_start_failed { candidate; cause; _ } ->
    `Assoc
      [ "kind", `String "flow_attempt_start_failed"
      ; "candidate", candidate_identity_to_json candidate.identity
      ; "cause", start_attempt_error_to_json cause
      ]
  | Exact_output.Flow_measurement_start_failed { candidate; cause; _ } ->
    `Assoc
      [ "kind", `String "flow_measurement_start_failed"
      ; "candidate", candidate_identity_to_json candidate.identity
      ; "cause", measurement_start_error_to_json cause
      ]
  | Exact_output.Flow_before_measurement_dispatch_callback_failed
      { measurement; _ } ->
    let snapshot =
      Exact_output.flow_measurement_receipt_snapshot measurement
    in
    `Assoc
      [ "kind",
        `String "flow_before_measurement_dispatch_callback_failed"
      ; "candidate_id",
        `String
          (Exact_output.measurement_receipt_candidate_id snapshot)
      ]
  | Exact_output.Flow_measurement_terminal_callback_failed
      { measurement; _ } ->
    let snapshot =
      Exact_output.flow_measurement_receipt_snapshot measurement
    in
    `Assoc
      [ "kind", `String "flow_measurement_terminal_callback_failed"
      ; "candidate_id",
        `String
          (Exact_output.measurement_receipt_candidate_id snapshot)
      ]
  | Exact_output.Flow_before_dispatch_callback_failed { candidate; _ } ->
    `Assoc
      [ "kind", `String "flow_before_dispatch_callback_failed"
      ; "candidate", candidate_identity_to_json candidate.visit.identity
      ; "receipt", receipt_to_json candidate.receipt
      ]
  | Exact_output.Flow_before_advance_callback_failed
      { failed; next; _ } ->
    `Assoc
      [ "kind", `String "flow_before_advance_callback_failed"
      ; "failed", candidate_failure_to_json failed
      ; "next", candidate_identity_to_json next.identity
      ]
  | Exact_output.Flow_candidates_exhausted { rejection; _ } ->
    `Assoc
      [ "kind", `String "flow_candidates_exhausted"
      ; "rejection", candidate_rejection_to_json rejection
      ]
  | Exact_output.Flow_exact_execution_failed { candidate; cause; _ } ->
    `Assoc
      [ "kind", `String "flow_exact_execution_failed"
      ; "candidate", candidate_identity_to_json candidate.visit.identity
      ; "execution", execution_error_to_json cause
      ]
;;

let semantic_of_success flow_success =
  let selected = Exact_output.flow_success_candidate flow_success in
  let success = Exact_output.flow_success_output flow_success in
  let call_id = Exact_output.call_id_to_string success.call_id in
  let selected_call_id =
    selected.receipt
    |> Exact_output.receipt_call_id
    |> Exact_output.call_id_to_string
  in
  let success_call_id =
    success.receipt
    |> Exact_output.receipt_call_id
    |> Exact_output.call_id_to_string
  in
  let plan_fingerprint =
    Exact_output.receipt_plan_fingerprint selected.receipt
  in
  let request_body_sha256 =
    Exact_output.receipt_request_body_sha256 selected.receipt
  in
  let response_body_sha256 = success.raw_response.body_sha256 in
  let http_status = Exact_output.receipt_http_status selected.receipt in
  let provider_trace_fingerprint =
    selected.receipt
    |> Exact_output.receipt_provider_trace
    |> Option.map Exact_output.provider_trace_fingerprint
  in
  let catalog_generation_fingerprint =
    selected.receipt
    |> Exact_output.receipt_catalog_generation
    |> Exact_output.catalog_generation_fingerprint
  in
  let catalog_evidence_sha256 =
    selected.receipt
    |> Exact_output.receipt_catalog_evidence
    |> Exact_output.catalog_evidence_sha256
  in
  let target_identity_fingerprint =
    selected.receipt
    |> Exact_output.receipt_target_identity
    |> Exact_output.target_identity_fingerprint
  in
  let* () = require_equal call_id selected_call_id in
  let* () = require_equal call_id success_call_id in
  let* () =
    require_equal
      plan_fingerprint
      (Exact_output.receipt_plan_fingerprint success.receipt)
  in
  let* () =
    require_equal
      request_body_sha256
      (Exact_output.receipt_request_body_sha256 success.receipt)
  in
  match success.output with
  | `Assoc [ "semantic_context", `String semantic_context ]
    when String.trim semantic_context <> "" ->
    Ok
      ( semantic_context
      , { slot_id = selected.visit.identity.candidate_id
        ; call_id
        ; plan_fingerprint
        ; request_body_sha256
        ; response_body_sha256
        ; http_status
        ; provider_trace_fingerprint
        ; catalog_generation_fingerprint
        ; catalog_evidence_sha256
        ; target_identity_fingerprint
        } )
  | _ -> Error Semantic_output_invalid
;;

let flow_candidates selected_slots =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (slot : Runtime_exact_output_registry.selected_slot) :: rest ->
      (match
         Exact_output.make_flow_candidate
           ~id:slot.slot_id
           ~admitted_target:slot.admitted_target
       with
       | Ok candidate -> loop (candidate :: acc) rest
       | Error _ -> Error Exact_lane_unavailable)
  in
  loop [] selected_slots
;;

let exact_schema =
  `Assoc
    [ "type", `String "object"
    ; "additionalProperties", `Bool false
    ; ( "properties"
      , `Assoc
          [ "semantic_context"
          , `Assoc [ "type", `String "string" ]
          ] )
    ; "required", `List [ `String "semantic_context" ]
    ]
;;

let correction_messages marker semantic_messages selected =
  let request =
    `Assoc
      [ "accepted_closed_unit_count", `Int marker.accepted_closed_unit_count
      ; "prior_semantic_messages",
        `List (List.map Keeper_context_core.message_to_json semantic_messages)
      ; ( "new_closed_units"
        , `List
            (List.map
               (fun unit ->
                  `List
                    (List.map
                       Keeper_context_core.message_to_json
                       (messages_of_closed_unit unit)))
               selected) )
      ]
  in
  [ Agent_sdk.Types.system_msg
      "Update the Keeper's semantic context from the prior semantic state and \
       the new closed turn units. Preserve decisions, constraints, goals, \
       unresolved work, durable facts, and causal context. Return only the \
       requested JSON object. Do not reproduce protocol shells."
  ; Agent_sdk.Types.user_msg (Yojson.Safe.to_string request)
  ]
;;

let execute_exact ~net ~clock ~marker ~semantic_messages ~selected =
  let* registry =
    Runtime_exact_output_registry.current ()
    |> Result.map_error (fun _ ->
      ( Exact_lane_unavailable
      , `Assoc [ "kind", `String "runtime_registry_unavailable" ] ))
  in
  let* lane =
    Runtime_exact_output_registry.resolve_lane registry ~lane_id
    |> Result.map_error (fun _ ->
      ( Exact_lane_unavailable
      , `Assoc
          [ "kind", `String "runtime_lane_unavailable"
          ; "lane_id", `String lane_id
          ] ))
  in
  let* candidates =
    flow_candidates lane.selected_slots
    |> Result.map_error (fun reason ->
      (reason, `Assoc [ "kind", `String "flow_candidate_invalid" ]))
  in
  match candidates with
  | [] ->
    Error
      ( Exact_lane_unavailable
      , `Assoc [ "kind", `String "runtime_lane_empty" ] )
  | first :: rest ->
    let requirement =
      Exact_output.make_output_requirement
        ~schema:exact_schema
        ~minimum_guarantee:Exact_output.Json_syntax
    in
    let* snapshot =
      Exact_output.snapshot_flow
        ~first
        ~rest
        ~messages:(correction_messages marker semantic_messages selected)
        requirement
      |> Result.map_error (fun _ ->
        ( Exact_flow_failed
        , `Assoc [ "kind", `String "flow_snapshot_invalid" ] ))
    in
    let* attempt =
      Exact_output.start_flow snapshot
      |> Result.map_error (fun (Exact_output.Flow_id_generation_failed detail) ->
        ( Exact_flow_failed
        , `Assoc
            [ "kind", `String "flow_id_generation_failed"
            ; "detail", `String detail
            ] ))
    in
    let validate success =
      match semantic_of_success success with
      | Ok value -> Exact_output.Accept value
      | Error reason -> Exact_output.Reject_and_advance reason
    in
    (match
       Exact_output.execute_flow_once
         ~net
         ~clock
         ~before_measurement_dispatch:(fun _ -> Ok ())
         ~on_measurement_terminal:(fun _ -> Ok ())
         ~before_dispatch:(fun _ -> Ok ())
         ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
         ~validate
         attempt
     with
     | Ok success -> Ok success.accepted
     | Error
         (Exact_output.Flow_semantic_candidates_exhausted
            { rejections; _ }) ->
       Error
         ( Semantic_output_invalid
         , `Assoc
             [ "kind", `String "semantic_candidates_exhausted"
             ; "rejection_count",
               `Int (1 + List.length rejections.rest)
             ] )
     | Error
         (Exact_output.Flow_execution_terminal
            { cause; prior_rejections }) ->
       Error
         ( Exact_flow_failed
         , `Assoc
             [ "kind", `String "execution_terminal"
             ; "cause", flow_execution_error_to_json cause
             ; "prior_semantic_rejections",
               `List
                 (List.map
                    (fun rejection ->
                       `String
                         (preserved_reason_to_string
                            rejection.Exact_output.rejection))
                    prior_rejections)
             ] ))
;;

let classify_installation ~raw_checkpoint ~raw_ref ~candidate ~provenance = function
  | Keeper_checkpoint_store.Installed { installed_ref; _ } ->
    Applied { checkpoint = candidate; raw_ref; installed_ref; provenance }
  | Keeper_checkpoint_store.Not_installed
      { cause = Keeper_checkpoint_store.Source_changed _; _ } ->
    preserved raw_checkpoint raw_ref Cas_conflict
  | Keeper_checkpoint_store.Not_installed { cause; _ } ->
    preserved
      ~detail:
        (`Assoc
           [ "kind", `String "checkpoint_not_installed"
           ; "cause",
             `String
               (match cause with
                | Keeper_checkpoint_store.Source_unavailable _ ->
                  "source_unavailable"
                | Keeper_checkpoint_store.Source_changed _ ->
                  "source_changed"
                | Keeper_checkpoint_store.Candidate_identity_invalid _ ->
                  "candidate_identity_invalid"
                | Keeper_checkpoint_store.Candidate_session_mismatch _ ->
                  "candidate_session_mismatch"
                | Keeper_checkpoint_store.Candidate_generation_mismatch _ ->
                  "candidate_generation_mismatch"
                | Keeper_checkpoint_store.Candidate_turn_regressed _ ->
                  "candidate_turn_regressed"
                | Keeper_checkpoint_store.Commit_not_installed _ ->
                  "commit_not_installed")
           ])
      raw_checkpoint
      raw_ref
      Cas_not_installed
;;

let run
      ~timeout_s
      ~keeper_name
      ~session_dir
      ~raw_checkpoint
      ~raw_ref
  =
  let preserve ?detail reason =
    preserved ?detail raw_checkpoint raw_ref reason
  in
  let raw_checkpoint_result =
    match
      Keeper_checkpoint_store.load_oas_exact_snapshot
        ~session_dir
        ~session_id:raw_checkpoint.session_id
    with
    | Error error ->
      Error
        ( Cas_not_installed
        , `Assoc
            [ "kind", `String "checkpoint_exact_read_failed"
            ; "cause",
              `String
                (match error with
                 | Keeper_checkpoint_store.Ref_not_found -> "ref_not_found"
                 | Keeper_checkpoint_store.Ref_read_failed _ ->
                   "ref_read_failed"
                 | Keeper_checkpoint_store.Ref_identity_invalid _ ->
                   "ref_identity_invalid"
                 | Keeper_checkpoint_store.Ref_session_mismatch _ ->
                   "ref_session_mismatch"
                 | Keeper_checkpoint_store.Ref_lock_failed _ ->
                   "ref_lock_failed")
            ] )
    | Ok snapshot ->
      let current_ref =
        Keeper_checkpoint_store.exact_snapshot_reference snapshot
      in
      if Keeper_checkpoint_ref.equal current_ref raw_ref
      then
        Ok (Keeper_checkpoint_store.exact_snapshot_checkpoint snapshot)
      else
        Error
          ( Cas_conflict
          , `Assoc
              [ "kind", `String "checkpoint_source_changed"
              ; "expected_sha256", `String raw_ref.sha256
              ; "actual_sha256", `String current_ref.sha256
              ] )
  in
  match raw_checkpoint_result with
  | Error (reason, detail) -> preserve ~detail reason
  | Ok raw_checkpoint ->
  let preserve ?detail reason =
    preserved ?detail raw_checkpoint raw_ref reason
  in
  let prepared =
    let* marker = marker_of_context raw_checkpoint.context in
    let* semantic_messages, backlog =
      split_at marker.semantic_message_count [] raw_checkpoint.messages
    in
    let* () =
      if String.equal marker.semantic_state_sha256 (sha256 (canonical_messages semantic_messages))
      then Ok ()
      else Error Marker_corrupt
    in
    let* partition =
      Keeper_compaction_unit.partition backlog
      |> Result.map_error (fun _ -> Marker_corrupt)
    in
    let* selected, _remaining = select_closed_units partition.closed_prefix in
    if selected = []
    then Error No_closed_delta
    else Ok (marker, semantic_messages, selected)
  in
  match prepared with
  | Error reason -> preserve reason
  | Ok (marker, semantic_messages, selected) ->
    (match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
     | None, _ -> preserve Network_unavailable
     | _, None -> preserve Clock_unavailable
     | Some net, Some clock ->
       let deadline = Eio.Time.now clock +. timeout_s in
       let exact_result =
         try
           Eio.Time.with_timeout_exn clock timeout_s (fun () ->
             execute_exact ~net ~clock ~marker ~semantic_messages ~selected)
         with
         | Eio.Time.Timeout ->
           Error
             ( Deadline_exceeded
             , `Assoc [ "kind", `String "deadline_exceeded" ] )
       in
       (match exact_result with
        | Error (reason, detail) ->
          Log.Keeper.warn
            ~keeper_name
            "context correction preserved raw checkpoint reason=%s"
            (preserved_reason_to_string reason);
          preserve ~detail reason
        | Ok (semantic_context, provenance) ->
          (match prepare_candidate ~marker ~raw_checkpoint ~semantic_context with
           | Error reason -> preserve reason
           | Ok (candidate, _marker) ->
             if Eio.Time.now clock >= deadline
             then preserve Deadline_exceeded_before_cas
             else
               Keeper_checkpoint_store.save_oas_if_source
                 ~session_dir
                 ~expected_source_ref:raw_ref
                 candidate
               |> classify_installation
                    ~raw_checkpoint
                    ~raw_ref
                    ~candidate
                    ~provenance)))
;;

let provenance_to_json provenance =
  `Assoc
    [ "slot_id", `String provenance.slot_id
    ; "call_id", `String provenance.call_id
    ; "plan_fingerprint", `String provenance.plan_fingerprint
    ; "request_body_sha256", `String provenance.request_body_sha256
    ; "response_body_sha256", `String provenance.response_body_sha256
    ; "http_status",
      option_to_json (fun value -> `Int value) provenance.http_status
    ; "provider_trace_fingerprint",
      option_to_json
        (fun value -> `String value)
        provenance.provider_trace_fingerprint
    ; "catalog_generation_fingerprint",
      `String provenance.catalog_generation_fingerprint
    ; "catalog_evidence_sha256",
      `String provenance.catalog_evidence_sha256
    ; "target_identity_fingerprint",
      `String provenance.target_identity_fingerprint
    ]
;;

let add_detail detail fields =
  match detail with
  | None -> fields
  | Some value -> fields @ [ "detail", value ]
;;

let outcome_to_json = function
  | Applied { raw_ref; installed_ref; provenance; _ } ->
    `Assoc
      [ "operation", `String "context_correction"
      ; "status", `String "applied"
      ; "raw_checkpoint_sha256", `String raw_ref.sha256
      ; "installed_checkpoint_sha256", `String installed_ref.sha256
      ; "receipt", provenance_to_json provenance
      ]
  | Preserved { raw_ref; reason; detail; _ } ->
    `Assoc
      (add_detail
         detail
         [ "operation", `String "context_correction"
         ; "status", `String "preserved"
         ; "raw_checkpoint_sha256", `String raw_ref.sha256
         ; "reason", `String (preserved_reason_to_string reason)
         ])
  | Skipped { reason; detail } ->
    `Assoc
      (add_detail
         detail
         [ "operation", `String "context_correction"
         ; "status", `String "skipped"
         ; "reason", `String (preserved_reason_to_string reason)
         ])
;;

let submission_to_json (submission : submission) =
  match submission with
  | Unavailable ->
    `Assoc
      [ "operation", `String "context_correction"
      ; "status", `String "unavailable"
      ]
  | Coalesced ->
    `Assoc
      [ "operation", `String "context_correction"
      ; "status", `String "coalesced"
      ]
  | Submitted ->
    `Assoc
      [ "operation", `String "context_correction"
      ; "status", `String "submitted"
      ]
;;

module For_testing = struct
  type nonrec marker = marker

  let genesis_marker = genesis_marker
  let marker_to_json = marker_to_json
  let marker_of_json = marker_of_json
  let prepare_candidate = prepare_candidate
  let classify_installation = classify_installation

  let reset_executor () =
    Stdlib.Mutex.protect executor_mu (fun () ->
      Option.iter
        (fun installed ->
           installed.accepting <- false;
           Hashtbl.reset installed.slots)
        !executor;
      executor := None)
  ;;

  let in_flight ~base_path ~keeper_name =
    let key = executor_key ~base_path ~keeper_name in
    Stdlib.Mutex.protect executor_mu (fun () ->
      match !executor with
      | Some installed -> Hashtbl.mem installed.slots key
      | None -> false)
  ;;

  let pending ~base_path ~keeper_name =
    let key = executor_key ~base_path ~keeper_name in
    Stdlib.Mutex.protect executor_mu (fun () ->
      match !executor with
      | Some installed ->
        (match Hashtbl.find_opt installed.slots key with
         | Some slot -> Option.is_some slot.latest
         | None -> false)
      | None -> false)
  ;;

  let executor_generation () =
    Stdlib.Mutex.protect executor_mu (fun () ->
      Option.map (fun installed -> installed.generation) !executor)
  ;;
end
