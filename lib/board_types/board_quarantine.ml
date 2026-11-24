(** The Board attention quarantine inventory and exact operator recovery wire. *)

open Result.Syntax

let request_schema = "keeper.board_attention.quarantine.recovery.request.v1"
let result_schema = "keeper.board_attention.quarantine.recovery.result.v1"

type decision = Acknowledge_and_requeue

type request =
  { candidate_id : string
  ; expected_quarantine_id : string
  ; decision : decision
  }

type quarantine_failure_category =
  | Candidate_membership_conflict
  | Durable_partition_invariant
  | Exact_setup_unavailable
  | Exact_flow_replayed
  | Exact_lane_exhausted
  | Exact_flow_bookkeeping_failed
  | Exact_completion_failed
  | Domain_output_invalid
  | Execution_provenance_mismatch
  | Unexpected_worker_failure
  | Exact_execution_quarantined
  | Exact_execution_interrupted
[@@deriving enumerate]

type attempt_provenance =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

let quarantine_failure_category_to_string = function
  | Candidate_membership_conflict -> "candidate_membership_conflict"
  | Durable_partition_invariant -> "durable_partition_invariant"
  | Exact_setup_unavailable -> "exact_setup_unavailable"
  | Exact_flow_replayed -> "exact_flow_replayed"
  | Exact_lane_exhausted -> "exact_lane_exhausted"
  | Exact_flow_bookkeeping_failed -> "exact_flow_bookkeeping_failed"
  | Exact_completion_failed -> "exact_completion_failed"
  | Domain_output_invalid -> "domain_output_invalid"
  | Execution_provenance_mismatch -> "execution_provenance_mismatch"
  | Unexpected_worker_failure -> "unexpected_worker_failure"
  | Exact_execution_quarantined -> "exact_execution_quarantined"
  | Exact_execution_interrupted -> "exact_execution_interrupted"
;;

let quarantine_failure_category_of_string s = List.find_opt (fun v -> String.equal (quarantine_failure_category_to_string v) s) all_of_quarantine_failure_category
;;

type inventory_phase =
  | Inventory_quarantined
  | Inventory_requeue_requested
  | Inventory_requeue_unfinished
  | Inventory_requeued
  | Inventory_requeue_unreconciled
[@@deriving enumerate]

type inventory_item =
  { keeper_name : string
  ; partition_id : string
  ; candidate_id : string
  ; quarantine_id : string
  ; phase : inventory_phase
  ; failure_category : quarantine_failure_category
  ; attempt_provenance : attempt_provenance option
  ; quarantined_at : float
  ; requested_at : float option
  ; requeued_at : float option
  ; requested_by : string option
  }

type inventory_error_kind =
  | Inventory_candidate_ledger_unavailable
  | Inventory_partition_ledger_unavailable
[@@deriving enumerate]

type inventory_error =
  { keeper_name : string
  ; kind : inventory_error_kind
  }

type inventory =
  { items : inventory_item list
  ; errors : inventory_error list
  }

let inventory_phase_to_string = function
  | Inventory_quarantined -> "quarantined"
  | Inventory_requeue_requested -> "requeue_requested"
  | Inventory_requeue_unfinished -> "requeue_unfinished"
  | Inventory_requeued -> "requeued"
  | Inventory_requeue_unreconciled -> "requeue_unreconciled"
;;

let inventory_error_kind_to_string = function
  | Inventory_candidate_ledger_unavailable -> "candidate_ledger_unavailable"
  | Inventory_partition_ledger_unavailable -> "partition_ledger_unavailable"
;;


let attempt_provenance_to_json = function
  | None -> `Null
  | Some (attempt : attempt_provenance) ->
    `Assoc
      [ "slot_id", `String attempt.slot_id
      ; "call_id", `String attempt.call_id
      ; "plan_fingerprint", `String attempt.plan_fingerprint
      ; "request_body_sha256", `String attempt.request_body_sha256
      ]
;;

let inventory_item_to_json (item : inventory_item) =
  `Assoc
    [ "keeper_name", `String item.keeper_name
    ; "partition_id", `String item.partition_id
    ; "candidate_id", `String item.candidate_id
    ; "quarantine_id", `String item.quarantine_id
    ; "phase", `String (inventory_phase_to_string item.phase)
    ; ( "failure_category"
      , `String
          (quarantine_failure_category_to_string item.failure_category) )
    ; "attempt_provenance", attempt_provenance_to_json item.attempt_provenance
    ; "quarantined_at", `Float item.quarantined_at
    ; "requested_at", Json_util.float_opt_to_json item.requested_at
    ; "requeued_at", Json_util.float_opt_to_json item.requeued_at
    ; "requested_by", Json_util.string_opt_to_json item.requested_by
    ]
;;

let inventory_to_json inventory =
  `Assoc
    [ "count", `Int (List.length inventory.items)
    ; "items", `List (List.map inventory_item_to_json inventory.items)
    ; ( "errors"
      , `List
          (List.map
             (fun (error : inventory_error) ->
               `Assoc
                 [ "keeper_name", `String error.keeper_name
                 ; "kind", `String (inventory_error_kind_to_string error.kind)
                 ])
             inventory.errors) )
    ]
;;

(* The body [parse_request] accepts, built from the same fields. A client that
   spelled the schema and the decision itself would be a second copy of them. *)
let decision_to_string = function Acknowledge_and_requeue -> "acknowledge_and_requeue"
let request_to_json (request : request) =
  `Assoc
    [ "schema", `String request_schema
    ; "candidate_id", `String request.candidate_id
    ; "expected_quarantine_id", `String request.expected_quarantine_id
    ; ( "decision"
      , `String
          (decision_to_string request.decision) )
    ]
;;

(* Readers of [inventory_item_to_json] and the error rows beside it. They sit
   next to the writers so the two cannot drift: a field renamed on one side is
   a failing round trip in this module's own suite. *)
let inventory_phase_of_string s = List.find_opt (fun v -> String.equal (inventory_phase_to_string v) s) all_of_inventory_phase
;;

let inventory_error_kind_of_string s = List.find_opt (fun v -> String.equal (inventory_error_kind_to_string v) s) all_of_inventory_error_kind
;;

let json_field fields name =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field " ^ name)
;;

let json_string fields name =
  let* value = json_field fields name in
  match value with
  | `String text -> Ok text
  | _ -> Error (name ^ " must be a string")
;;

let json_number = function
  | `Float value -> Some value
  | `Int value -> Some (Float.of_int value)
  | _ -> None
;;

let json_float fields name =
  let* value = json_field fields name in
  match json_number value with
  | Some number -> Ok number
  | None -> Error (name ^ " must be a number")
;;

let json_float_opt fields name =
  let* value = json_field fields name in
  match value with
  | `Null -> Ok None
  | other ->
    (match json_number other with
     | Some number -> Ok (Some number)
     | None -> Error (name ^ " must be a number or null"))
;;

let json_string_opt fields name =
  let* value = json_field fields name in
  match value with
  | `Null -> Ok None
  | `String text -> Ok (Some text)
  | _ -> Error (name ^ " must be a string or null")
;;

let attempt_provenance_of_json = function
  | `Null -> Ok None
  | `Assoc fields ->
    let* slot_id = json_string fields "slot_id" in
    let* call_id = json_string fields "call_id" in
    let* plan_fingerprint = json_string fields "plan_fingerprint" in
    let* request_body_sha256 = json_string fields "request_body_sha256" in
    Ok
      (Some
         ({ slot_id; call_id; plan_fingerprint; request_body_sha256 }
          : attempt_provenance))
  | _ -> Error "attempt_provenance must be an object or null"
;;

let inventory_item_of_json = function
  | `Assoc fields ->
    let* keeper_name = json_string fields "keeper_name" in
    let* partition_id = json_string fields "partition_id" in
    let* candidate_id = json_string fields "candidate_id" in
    let* quarantine_id = json_string fields "quarantine_id" in
    let* phase_raw = json_string fields "phase" in
    let* phase =
      match inventory_phase_of_string phase_raw with
      | Some phase -> Ok phase
      | None -> Error ("unknown phase " ^ phase_raw)
    in
    let* category_raw = json_string fields "failure_category" in
    let* failure_category =
      match quarantine_failure_category_of_string category_raw with
      | Some category -> Ok category
      | None -> Error ("unknown failure_category " ^ category_raw)
    in
    let* provenance_json = json_field fields "attempt_provenance" in
    let* attempt_provenance = attempt_provenance_of_json provenance_json in
    let* quarantined_at = json_float fields "quarantined_at" in
    let* requested_at = json_float_opt fields "requested_at" in
    let* requested_by = json_string_opt fields "requested_by" in
    let* requeued_at = json_float_opt fields "requeued_at" in
    Ok
      ({ keeper_name
       ; partition_id
       ; candidate_id
       ; quarantine_id
       ; phase
       ; failure_category
       ; attempt_provenance
       ; quarantined_at
       ; requested_at
       ; requested_by
       ; requeued_at
       }
       : inventory_item)
  | _ -> Error "inventory item must be an object"
;;

let inventory_error_of_json = function
  | `Assoc fields ->
    let* keeper_name = json_string fields "keeper_name" in
    let* kind_raw = json_string fields "kind" in
    (match inventory_error_kind_of_string kind_raw with
     | Some kind -> Ok ({ keeper_name; kind } : inventory_error)
     | None -> Error ("unknown inventory error kind " ^ kind_raw))
  | _ -> Error "inventory error must be an object"
;;

let same_candidate (a : inventory_item) (b : inventory_item) =
  String.equal a.keeper_name b.keeper_name
  && String.equal a.partition_id b.partition_id
  && String.equal a.candidate_id b.candidate_id
  && String.equal a.quarantine_id b.quarantine_id

let recoverable = function
  | Inventory_quarantined | Inventory_requeue_requested | Inventory_requeue_unfinished -> true
  | Inventory_requeued | Inventory_requeue_unreconciled -> false

let inventory_of_json ~keeper = function
  | `Assoc fields ->
      let rows field decode =
        match List.assoc_opt field fields with
        | Some (`List values) -> List.fold_left
              (fun acc value ->
                let* acc = acc in
                let* row = decode value in
                Ok (row :: acc))
              (Ok []) values |> Result.map List.rev
        | _ -> Error (field ^ " must be an array")
      in
      let* items = rows "items" inventory_item_of_json in
      let* errors = rows "errors" inventory_error_of_json in
      (match List.assoc_opt "count" fields with
       | Some (`Int n) when n = List.length items
                            && List.for_all (fun (r : inventory_item) -> String.equal keeper r.keeper_name) items
                            && List.for_all (fun (e : inventory_error) -> String.equal keeper e.keeper_name) errors ->
           Ok { items; errors }
       | _ -> Error "Board quarantine inventory scope or count mismatch")
  | _ -> Error "Board quarantine inventory must be an object"

type wake_delivery = Signaled | Coalesced | Not_registered
type audit_status = Recorded | Recording_failed
type recovery_receipt = { wake : wake_delivery; audit : audit_status }

let recovery_confirmed (item : inventory_item) = function
  | `Assoc fields ->
      let matches key wanted = List.assoc_opt key fields = Some (`String wanted) in
      let* () =
        if List.assoc_opt "ok" fields = Some (`Bool true)
           && matches "schema" result_schema
           && matches "keeper_name" item.keeper_name
           && matches "partition_id" item.partition_id
           && matches "candidate_id" item.candidate_id
           && matches "quarantine_id" item.quarantine_id
           && matches "failure_category" (quarantine_failure_category_to_string item.failure_category)
           && matches "decision" (decision_to_string Acknowledge_and_requeue)
        then Ok () else Error "Board recovery receipt does not match the selected quarantine"
      in
      let* wake =
        match List.assoc_opt "wake" fields with
        | Some (`String "signaled") -> Ok Signaled
        | Some (`String "coalesced") -> Ok Coalesced
        | Some (`String "not_registered") -> Ok Not_registered
        | _ -> Error "Board recovery receipt has no recognized wake outcome"
      in
      let* audit =
        match List.assoc_opt "audit" fields with
        | Some (`Assoc audit) ->
            (match List.assoc_opt "recorded" audit with
             | Some (`Bool true) -> Ok Recorded
             | Some (`Bool false) -> Ok Recording_failed
             | _ -> Error "Board recovery receipt has no audit outcome")
        | _ -> Error "Board recovery receipt has no audit outcome"
      in
      Ok { wake; audit }
  | _ -> Error "Board recovery receipt must be an object"
