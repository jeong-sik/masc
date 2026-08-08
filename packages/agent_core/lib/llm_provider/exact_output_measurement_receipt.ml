module Flow_admission = Exact_output_flow_admission

type measurement_dispatch_fact = Flow_admission.measurement_dispatch_fact =
  | No_measurement_dispatch
  | Measurement_dispatch_unknown
  | Measurement_dispatch_started

type measurement_outcome = Flow_admission.measurement_outcome =
  | Measurement_not_required
  | Measurement_succeeded
  | Measurement_unsupported
  | Measurement_local_invalid
  | Measurement_transport_failed
  | Measurement_invalid_response
  | Measurement_fence_rejected
  | Measurement_cancelled

type measurement_evidence = Flow_admission.measurement_evidence =
  { dispatch : measurement_dispatch_fact
  ; outcome : measurement_outcome
  }

type measurement_operation_id = Measurement_operation_id of string

type measurement_receipt_phase = Flow_admission.measurement_receipt_phase =
  | Measurement_fence_committed
  | Measurement_wire_started
  | Measurement_terminal

type flow_id = Flow_id of string
type flow_visit_ordinal = Flow_visit_ordinal of int

type measurement_receipt_snapshot =
  { operation_id : measurement_operation_id
  ; flow_id : flow_id
  ; visit_ordinal : flow_visit_ordinal
  ; candidate_id : string
  ; candidate_binding_sha256 : string
  ; catalog_generation_fingerprint : string
  ; catalog_evidence_sha256 : string
  ; request_body_sha256 : string
  ; phase : measurement_receipt_phase
  ; dispatch : measurement_dispatch_fact
  ; outcome : measurement_outcome option
  }

type measurement_receipt_snapshot_decode_error =
  | Measurement_receipt_snapshot_malformed_json of string
  | Measurement_receipt_snapshot_invalid_fields
  | Measurement_receipt_snapshot_unknown_format of string
  | Measurement_receipt_snapshot_unsupported_version of int
  | Measurement_receipt_snapshot_invalid_field of string
  | Measurement_receipt_snapshot_integrity_mismatch

type measurement_receipt_transition_conflict =
  | Measurement_operation_mismatch
  | Measurement_operation_binding_mismatch
  | Measurement_invalid_commit_phase of measurement_receipt_phase
  | Measurement_invalid_previous_boundary of
      { phase : measurement_receipt_phase
      ; dispatch : measurement_dispatch_fact
      ; outcome : measurement_outcome option
      }
  | Measurement_phase_regression of
      { previous_phase : measurement_receipt_phase
      ; incoming_phase : measurement_receipt_phase
      }
  | Measurement_evidence_conflict

type measurement_receipt_transition =
  | Measurement_dispatch_intent
  | Measurement_terminal_advance
  | Measurement_idempotent_replay
  | Measurement_transition_conflict of measurement_receipt_transition_conflict

let ( let* ) = Result.bind
let flow_id_to_string (Flow_id value) = value
let flow_visit_ordinal_to_int (Flow_visit_ordinal value) = value
let measurement_operation_id_to_string (Measurement_operation_id value) = value

let create_measurement_receipt_snapshot
      ~operation_id
      ~flow_id
      ~visit_ordinal
      ~candidate_id
      ~candidate_binding_sha256
      ~catalog_generation_fingerprint
      ~catalog_evidence_sha256
      ~request_body_sha256
      ~phase
      ~dispatch
      ~outcome
  =
  { operation_id = Measurement_operation_id operation_id
  ; flow_id
  ; visit_ordinal
  ; candidate_id
  ; candidate_binding_sha256
  ; catalog_generation_fingerprint
  ; catalog_evidence_sha256
  ; request_body_sha256
  ; phase
  ; dispatch
  ; outcome
  }
;;

let measurement_receipt_operation_id snapshot = snapshot.operation_id
let measurement_receipt_flow_id snapshot = snapshot.flow_id
let measurement_receipt_visit_ordinal snapshot = snapshot.visit_ordinal
let measurement_receipt_candidate_id snapshot = snapshot.candidate_id

let measurement_receipt_candidate_binding_sha256 snapshot =
  snapshot.candidate_binding_sha256
;;

let measurement_receipt_catalog_generation_fingerprint snapshot =
  snapshot.catalog_generation_fingerprint
;;

let measurement_receipt_catalog_evidence_sha256 snapshot =
  snapshot.catalog_evidence_sha256
;;

let measurement_receipt_request_body_sha256 snapshot = snapshot.request_body_sha256
let measurement_receipt_phase snapshot = snapshot.phase
let measurement_receipt_dispatch_fact snapshot = snapshot.dispatch
let measurement_receipt_outcome snapshot = snapshot.outcome
let snapshot_format = "oas.exact-output.measurement-receipt"
let snapshot_version = 1
let sha256 value = Digestif.SHA256.(to_hex (digest_string value))

let phase_to_string = function
  | Measurement_fence_committed -> "fence_committed"
  | Measurement_wire_started -> "wire_started"
  | Measurement_terminal -> "terminal"
;;

let phase_of_string = function
  | "fence_committed" -> Some Measurement_fence_committed
  | "wire_started" -> Some Measurement_wire_started
  | "terminal" -> Some Measurement_terminal
  | _ -> None
;;

let dispatch_to_string = function
  | No_measurement_dispatch -> "no_dispatch"
  | Measurement_dispatch_unknown -> "dispatch_unknown"
  | Measurement_dispatch_started -> "dispatch_started"
;;

let dispatch_of_string = function
  | "no_dispatch" -> Some No_measurement_dispatch
  | "dispatch_unknown" -> Some Measurement_dispatch_unknown
  | "dispatch_started" -> Some Measurement_dispatch_started
  | _ -> None
;;

let outcome_to_string = function
  | Measurement_not_required -> "not_required"
  | Measurement_succeeded -> "succeeded"
  | Measurement_unsupported -> "unsupported"
  | Measurement_local_invalid -> "local_invalid"
  | Measurement_transport_failed -> "transport_failed"
  | Measurement_invalid_response -> "invalid_response"
  | Measurement_fence_rejected -> "fence_rejected"
  | Measurement_cancelled -> "cancelled"
;;

let outcome_of_string = function
  | "not_required" -> Some Measurement_not_required
  | "succeeded" -> Some Measurement_succeeded
  | "unsupported" -> Some Measurement_unsupported
  | "local_invalid" -> Some Measurement_local_invalid
  | "transport_failed" -> Some Measurement_transport_failed
  | "invalid_response" -> Some Measurement_invalid_response
  | "fence_rejected" -> Some Measurement_fence_rejected
  | "cancelled" -> Some Measurement_cancelled
  | _ -> None
;;

let payload_fields snapshot =
  [ "format", `String snapshot_format
  ; "version", `Int snapshot_version
  ; "operation_id", `String (measurement_operation_id_to_string snapshot.operation_id)
  ; "flow_id", `String (flow_id_to_string snapshot.flow_id)
  ; "visit_ordinal", `Int (flow_visit_ordinal_to_int snapshot.visit_ordinal)
  ; "candidate_id", `String snapshot.candidate_id
  ; "candidate_binding_sha256", `String snapshot.candidate_binding_sha256
  ; "catalog_generation_fingerprint", `String snapshot.catalog_generation_fingerprint
  ; "catalog_evidence_sha256", `String snapshot.catalog_evidence_sha256
  ; "request_body_sha256", `String snapshot.request_body_sha256
  ; "phase", `String (phase_to_string snapshot.phase)
  ; "dispatch", `String (dispatch_to_string snapshot.dispatch)
  ; ( "outcome"
    , match snapshot.outcome with
      | None -> `Null
      | Some outcome -> `String (outcome_to_string outcome) )
  ]
;;

let measurement_receipt_snapshot_to_string snapshot =
  let fields = payload_fields snapshot in
  let integrity_sha256 = `Assoc fields |> Yojson.Safe.to_string |> sha256 in
  `Assoc (fields @ [ "integrity_sha256", `String integrity_sha256 ])
  |> Yojson.Safe.to_string
;;

let expected_fields =
  [ "format"
  ; "version"
  ; "operation_id"
  ; "flow_id"
  ; "visit_ordinal"
  ; "candidate_id"
  ; "candidate_binding_sha256"
  ; "catalog_generation_fingerprint"
  ; "catalog_evidence_sha256"
  ; "request_body_sha256"
  ; "phase"
  ; "dispatch"
  ; "outcome"
  ; "integrity_sha256"
  ]
;;

let is_sha256 value =
  String.length value = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       value
;;

let shape_is_valid snapshot =
  match snapshot.phase, snapshot.dispatch, snapshot.outcome with
  | Measurement_fence_committed, Measurement_dispatch_unknown, None
  | Measurement_fence_committed, No_measurement_dispatch, None
  | Measurement_wire_started, Measurement_dispatch_started, None -> true
  | Measurement_terminal, _, Some Measurement_not_required -> false
  | Measurement_terminal, _, Some _ -> true
  | Measurement_fence_committed, _, _
  | Measurement_wire_started, _, _
  | Measurement_terminal, _, None -> false
;;

let measurement_receipt_snapshot_of_string encoded =
  let invalid field = Error (Measurement_receipt_snapshot_invalid_field field) in
  let find fields name =
    match List.assoc_opt name fields with
    | Some value -> Ok value
    | None -> invalid name
  in
  let string_field fields name =
    let* value = find fields name in
    match value with
    | `String value -> Ok value
    | _ -> invalid name
  in
  let enum_field fields name decode =
    let* encoded = string_field fields name in
    match decode encoded with
    | Some value -> Ok value
    | None -> invalid name
  in
  try
    match Yojson.Safe.from_string encoded with
    | `Assoc fields ->
      let actual = List.map fst fields |> List.sort String.compare in
      if actual <> List.sort String.compare expected_fields
      then Error Measurement_receipt_snapshot_invalid_fields
      else
        let* format = string_field fields "format" in
        let* () =
          if String.equal format snapshot_format
          then Ok ()
          else Error (Measurement_receipt_snapshot_unknown_format format)
        in
        let* version = find fields "version" in
        let* () =
          match version with
          | `Int version when version = snapshot_version -> Ok ()
          | `Int version ->
            Error (Measurement_receipt_snapshot_unsupported_version version)
          | _ -> invalid "version"
        in
        let* operation_id = string_field fields "operation_id" in
        let* flow_id = string_field fields "flow_id" in
        let* visit_ordinal_json = find fields "visit_ordinal" in
        let* visit_ordinal =
          match visit_ordinal_json with
          | `Int ordinal when ordinal > 0 -> Ok ordinal
          | `Int _ | _ -> invalid "visit_ordinal"
        in
        let* candidate_id = string_field fields "candidate_id" in
        let* candidate_binding_sha256 = string_field fields "candidate_binding_sha256" in
        let* catalog_generation_fingerprint =
          string_field fields "catalog_generation_fingerprint"
        in
        let* catalog_evidence_sha256 = string_field fields "catalog_evidence_sha256" in
        let* request_body_sha256 = string_field fields "request_body_sha256" in
        let* phase = enum_field fields "phase" phase_of_string in
        let* dispatch = enum_field fields "dispatch" dispatch_of_string in
        let* outcome_json = find fields "outcome" in
        let* outcome =
          match outcome_json with
          | `Null -> Ok None
          | `String encoded ->
            (match outcome_of_string encoded with
             | Some outcome -> Ok (Some outcome)
             | None -> invalid "outcome")
          | _ -> invalid "outcome"
        in
        let* integrity_sha256 = string_field fields "integrity_sha256" in
        let canonical_nonempty value =
          (not (String.equal value "")) && String.equal value (String.trim value)
        in
        let* () =
          if canonical_nonempty operation_id then Ok () else invalid "operation_id"
        in
        let* () = if canonical_nonempty flow_id then Ok () else invalid "flow_id" in
        let* () =
          if canonical_nonempty candidate_id then Ok () else invalid "candidate_id"
        in
        let* () =
          if
            is_sha256 candidate_binding_sha256
            && is_sha256 catalog_generation_fingerprint
            && is_sha256 catalog_evidence_sha256
            && is_sha256 request_body_sha256
            && is_sha256 integrity_sha256
          then Ok ()
          else invalid "sha256"
        in
        let snapshot =
          create_measurement_receipt_snapshot
            ~operation_id
            ~flow_id:(Flow_id flow_id)
            ~visit_ordinal:(Flow_visit_ordinal visit_ordinal)
            ~candidate_id
            ~candidate_binding_sha256
            ~catalog_generation_fingerprint
            ~catalog_evidence_sha256
            ~request_body_sha256
            ~phase
            ~dispatch
            ~outcome
        in
        let* () = if shape_is_valid snapshot then Ok () else invalid "receipt_state" in
        let expected_integrity =
          `Assoc (payload_fields snapshot) |> Yojson.Safe.to_string |> sha256
        in
        if String.equal expected_integrity integrity_sha256
        then Ok snapshot
        else Error Measurement_receipt_snapshot_integrity_mismatch
    | _ -> Error Measurement_receipt_snapshot_invalid_fields
  with
  | Yojson.Json_error detail -> Error (Measurement_receipt_snapshot_malformed_json detail)
;;

let measurement_receipt_snapshot_decode_error_to_string = function
  | Measurement_receipt_snapshot_malformed_json detail ->
    "measurement receipt malformed JSON: " ^ detail
  | Measurement_receipt_snapshot_invalid_fields ->
    "measurement receipt fields do not match the current schema"
  | Measurement_receipt_snapshot_unknown_format format ->
    "measurement receipt has unknown format: " ^ format
  | Measurement_receipt_snapshot_unsupported_version version ->
    Printf.sprintf "measurement receipt has unsupported version: %d" version
  | Measurement_receipt_snapshot_invalid_field field ->
    "measurement receipt has invalid field: " ^ field
  | Measurement_receipt_snapshot_integrity_mismatch ->
    "measurement receipt integrity mismatch"
;;

let same_snapshot left right =
  String.equal
    (measurement_operation_id_to_string left.operation_id)
    (measurement_operation_id_to_string right.operation_id)
  && String.equal (flow_id_to_string left.flow_id) (flow_id_to_string right.flow_id)
  && flow_visit_ordinal_to_int left.visit_ordinal
     = flow_visit_ordinal_to_int right.visit_ordinal
  && String.equal left.candidate_id right.candidate_id
  && String.equal left.candidate_binding_sha256 right.candidate_binding_sha256
  && String.equal left.catalog_generation_fingerprint right.catalog_generation_fingerprint
  && String.equal left.catalog_evidence_sha256 right.catalog_evidence_sha256
  && String.equal left.request_body_sha256 right.request_body_sha256
  && left.phase = right.phase
  && left.dispatch = right.dispatch
  && left.outcome = right.outcome
;;

let measurement_receipt_same_operation left right =
  String.equal
    (measurement_operation_id_to_string left.operation_id)
    (measurement_operation_id_to_string right.operation_id)
;;

let same_binding left right =
  String.equal (flow_id_to_string left.flow_id) (flow_id_to_string right.flow_id)
  && flow_visit_ordinal_to_int left.visit_ordinal
     = flow_visit_ordinal_to_int right.visit_ordinal
  && String.equal left.candidate_id right.candidate_id
  && String.equal left.candidate_binding_sha256 right.candidate_binding_sha256
  && String.equal left.catalog_generation_fingerprint right.catalog_generation_fingerprint
  && String.equal left.catalog_evidence_sha256 right.catalog_evidence_sha256
  && String.equal left.request_body_sha256 right.request_body_sha256
;;

let is_dispatch_intent snapshot =
  snapshot.phase = Measurement_fence_committed
  && snapshot.dispatch = Measurement_dispatch_unknown
  && Option.is_none snapshot.outcome
;;

let phase_rank = function
  | Measurement_fence_committed -> 0
  | Measurement_wire_started -> 1
  | Measurement_terminal -> 2
;;

let is_terminal_boundary snapshot =
  snapshot.phase = Measurement_terminal && Option.is_some snapshot.outcome
;;

let is_durable_boundary snapshot =
  is_dispatch_intent snapshot || is_terminal_boundary snapshot
;;

let classify_measurement_receipt_transition ~previous ~incoming =
  match previous with
  | None ->
    if is_dispatch_intent incoming
    then Measurement_dispatch_intent
    else if incoming.phase <> Measurement_fence_committed
    then Measurement_transition_conflict (Measurement_invalid_commit_phase incoming.phase)
    else Measurement_transition_conflict Measurement_evidence_conflict
  | Some previous ->
    if not (is_durable_boundary previous)
    then
      Measurement_transition_conflict
        (Measurement_invalid_previous_boundary
           { phase = previous.phase
           ; dispatch = previous.dispatch
           ; outcome = previous.outcome
           })
    else if not (measurement_receipt_same_operation previous incoming)
    then Measurement_transition_conflict Measurement_operation_mismatch
    else if not (same_binding previous incoming)
    then Measurement_transition_conflict Measurement_operation_binding_mismatch
    else if same_snapshot previous incoming
    then Measurement_idempotent_replay
    else if phase_rank incoming.phase < phase_rank previous.phase
    then
      Measurement_transition_conflict
        (Measurement_phase_regression
           { previous_phase = previous.phase; incoming_phase = incoming.phase })
    else if
      is_dispatch_intent previous
      && incoming.phase = Measurement_terminal
      && Option.is_some incoming.outcome
    then Measurement_terminal_advance
    else if incoming.phase = Measurement_wire_started
    then Measurement_transition_conflict (Measurement_invalid_commit_phase incoming.phase)
    else Measurement_transition_conflict Measurement_evidence_conflict
;;
