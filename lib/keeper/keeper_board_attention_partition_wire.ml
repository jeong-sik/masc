(** Pure current-schema partition codec, separate from durable state effects. *)
open Keeper_board_attention_partition_types

let ( let* ) = Result.bind
let schema_version = 7

let state_to_string = function
  | Ready -> "ready"
  | Running _ -> "running"
  | Completed _ -> "completed"
  | Settled _ -> "settled"
  | Abandoned _ -> "abandoned"
  | Blocked _ -> "blocked"
;;

let exact_provenance_to_yojson (provenance : exact_provenance) =
  `Assoc
    [ "slot_id", `String provenance.slot_id
    ; "call_id", `String provenance.call_id
    ; "plan_fingerprint", `String provenance.plan_fingerprint
    ; "request_body_sha256", `String provenance.request_body_sha256
    ]
;;

let candidate_attempt_provenance_to_yojson
      (provenance : Candidate.attempt_provenance)
  =
  exact_provenance_to_yojson
    { slot_id = provenance.slot_id
    ; call_id = provenance.call_id
    ; plan_fingerprint = provenance.plan_fingerprint
    ; request_body_sha256 = provenance.request_body_sha256
    }
;;

let candidate_visit_to_yojson visit =
  `Assoc
    [ "flow_id", `String visit.flow_id
    ; "ordinal", `Int visit.ordinal
    ; "slot_id", `String visit.slot_id
    ; ( "catalog_generation_fingerprint"
      , `String visit.catalog_generation_fingerprint )
    ; "catalog_evidence_sha256", `String visit.catalog_evidence_sha256
    ; "target_identity_fingerprint", `String visit.target_identity_fingerprint
    ]
;;

let running_progress_to_yojson = function
  | Unbound -> `Assoc [ "kind", `String "unbound" ]
  | Bound provenance ->
    `Assoc
      [ "kind", `String "bound"
      ; "provenance", exact_provenance_to_yojson provenance
      ]
  | Advancing { execution_anchor; last_from; next } ->
    `Assoc
      [ "kind", `String "advancing"
      ; ( "execution_anchor"
        , match execution_anchor with
          | Some provenance -> exact_provenance_to_yojson provenance
          | None -> `Null )
      ; ( "last_from"
        , match last_from with
          | Some visit -> candidate_visit_to_yojson visit
          | None -> `Null )
      ; "next", candidate_visit_to_yojson next
      ]
;;

let optional_progress_to_yojson = function
  | Some progress -> running_progress_to_yojson progress
  | None -> `Null
;;

let classified_failure_to_yojson ~kind detail progress =
  `Assoc
    [ "kind", `String kind
    ; "detail", `String detail
    ; "progress", optional_progress_to_yojson progress
    ]
;;

let blocked_reason_to_yojson = function
  | Candidate_membership_conflict detail ->
    `Assoc [ "kind", `String "candidate_membership_conflict"; "detail", `String detail ]
  | Durable_partition_invariant detail ->
    `Assoc [ "kind", `String "durable_partition_invariant"; "detail", `String detail ]
  | Exact_setup_unavailable detail ->
    `Assoc [ "kind", `String "exact_setup_unavailable"; "detail", `String detail ]
  | Exact_flow_replayed progress ->
    `Assoc
      [ "kind", `String "exact_flow_replayed"
      ; "progress", optional_progress_to_yojson progress
      ]
  | Exact_lane_exhausted { detail; progress } ->
    classified_failure_to_yojson ~kind:"exact_lane_exhausted" detail progress
  | Exact_flow_bookkeeping_failed { detail; progress } ->
    classified_failure_to_yojson ~kind:"exact_flow_bookkeeping_failed" detail progress
  | Exact_completion_failed { detail; progress } ->
    classified_failure_to_yojson ~kind:"exact_completion_failed" detail progress
  | Domain_output_invalid { detail; progress } ->
    classified_failure_to_yojson ~kind:"domain_output_invalid" detail progress
  | Execution_provenance_mismatch { detail; progress } ->
    classified_failure_to_yojson ~kind:"execution_provenance_mismatch" detail progress
  | Unexpected_worker_failure { detail; progress } ->
    classified_failure_to_yojson ~kind:"unexpected_worker_failure" detail progress
  | Exact_execution_quarantined progress ->
    `Assoc
      [ "kind", `String "exact_execution_quarantined"
      ; "progress", running_progress_to_yojson progress
      ]
  | Exact_execution_interrupted progress ->
    `Assoc
      [ "kind", `String "exact_execution_interrupted"
      ; "progress", running_progress_to_yojson progress
      ]
  | Restored_candidate_quarantine { failure_category; attempt_provenance } ->
    `Assoc
      [ "kind", `String "restored_candidate_quarantine"
      ; ( "failure_category"
        , `String (Candidate.quarantine_failure_category_to_string failure_category) )
      ; ( "attempt_provenance"
        , match attempt_provenance with
          | Some provenance -> candidate_attempt_provenance_to_yojson provenance
          | None -> `Null )
      ]
;;

let completed_item_to_yojson (item : completed_item) =
  `Assoc
    [ "candidate_id", `String item.candidate_id
    ; "judgment", Candidate.judgment_to_yojson item.judgment
    ]
;;

let state_to_yojson = function
  | Ready -> `Assoc [ "kind", `String "ready" ]
  | Running { worker_epoch; started_at; progress } ->
    `Assoc
      [ "kind", `String "running"
      ; "worker_epoch", `String (Worker_epoch.to_string worker_epoch)
      ; "started_at", `Float started_at
      ; "progress", running_progress_to_yojson progress
      ]
  | Completed { item; completed_at } ->
    `Assoc
      [ "kind", `String "completed"
      ; "item", completed_item_to_yojson item
      ; "completed_at", `Float completed_at
      ]
  | Settled { settled_at } ->
    `Assoc [ "kind", `String "settled"; "settled_at", `Float settled_at ]
  | Abandoned { abandoned_at } ->
    `Assoc [ "kind", `String "abandoned"; "abandoned_at", `Float abandoned_at ]
  | Blocked { reason; blocked_at } ->
    `Assoc
      [ "kind", `String "blocked"
      ; "reason", blocked_reason_to_yojson reason
      ; "blocked_at", `Float blocked_at
      ]
;;

let partition_fields partition =
  [ "schema_version", `Int schema_version
    ; "partition_id", `String partition.partition_id
    ; "keeper_name", `String partition.keeper_name
    ; "context_key", Candidate.Context_key.to_yojson partition.context_key
    ; "candidate_id", `String partition.candidate_id
    ; "created_at", `Float partition.created_at
    ; "generation", Generation.to_yojson partition.generation
    ; "state", state_to_yojson partition.state
  ]
;;

let to_yojson partition = `Assoc (partition_fields partition)
;;

type ready_confirmation =
  { partition_id : string
  ; generation : Generation.t
  ; confirmed_at : float
  ; runtime_instance_id : string
  }

let ready_confirmation_to_yojson confirmation =
  `Assoc
    [ "kind", `String "ready_confirmation"
    ; "schema_version", `Int 1
    ; "partition_id", `String confirmation.partition_id
    ; "generation", Generation.to_yojson confirmation.generation
    ; "confirmed_at", `Float confirmation.confirmed_at
    ; "runtime_instance_id", `String confirmation.runtime_instance_id
    ]
;;

let confirmed_ready_to_yojson partition confirmation =
  `Assoc
    (partition_fields partition
     @ [ "ready_confirmation", ready_confirmation_to_yojson confirmation ])
;;

(* Structural decode helpers live in Candidate, which decodes the same
   candidate JSON; these aliases keep the call sites in this module short. *)
let assoc = Candidate.assoc
let exact_fields = Candidate.exact_fields
let field = Candidate.field

let string_json ~context = function
  | `String value when not (String.equal value "") -> Ok value
  | `String _ -> Error (context ^ " must not be empty")
  | _ -> Error (context ^ " must be a string")
;;

let float_json ~context = function
  | `Float value when Float.is_finite value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | `Float _ -> Error (context ^ " must be finite")
  | _ -> Error (context ^ " must be a number")
;;

let nonnegative_int_json ~context = function
  | `Int value when value >= 0 -> Ok value
  | `Int _ -> Error (context ^ " must be nonnegative")
  | _ -> Error (context ^ " must be an integer")
;;

let ready_confirmation_of_yojson json =
  let context = "Board attention Ready confirmation" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "kind"
      ; "schema_version"
      ; "partition_id"
      ; "generation"
      ; "confirmed_at"
      ; "runtime_instance_id"
      ]
      fields
  in
  let* kind_json = field ~context "kind" fields in
  let* () =
    match kind_json with
    | `String "ready_confirmation" -> Ok ()
    | _ -> Error (context ^ ".kind must be ready_confirmation")
  in
  let* version_json = field ~context "schema_version" fields in
  let* () =
    match version_json with
    | `Int 1 -> Ok ()
    | _ -> Error (context ^ ".schema_version must be 1")
  in
  let* partition_json = field ~context "partition_id" fields in
  let* partition_id = string_json ~context:(context ^ ".partition_id") partition_json in
  let* generation_json = field ~context "generation" fields in
  let* generation = Generation.of_yojson generation_json in
  let* confirmed_json = field ~context "confirmed_at" fields in
  let* confirmed_at = float_json ~context:(context ^ ".confirmed_at") confirmed_json in
  let* runtime_json = field ~context "runtime_instance_id" fields in
  let* runtime_instance_id =
    string_json ~context:(context ^ ".runtime_instance_id") runtime_json
  in
  Ok { partition_id; generation; confirmed_at; runtime_instance_id }
;;

let exact_provenance_of_yojson json =
  let context = "Board attention exact provenance" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "slot_id"; "call_id"; "plan_fingerprint"; "request_body_sha256" ]
      fields
  in
  let* slot_json = field ~context "slot_id" fields in
  let* slot_id = string_json ~context:(context ^ ".slot_id") slot_json in
  let* call_json = field ~context "call_id" fields in
  let* call_id = string_json ~context:(context ^ ".call_id") call_json in
  let* fingerprint_json = field ~context "plan_fingerprint" fields in
  let* plan_fingerprint =
    string_json ~context:(context ^ ".plan_fingerprint") fingerprint_json
  in
  let* body_json = field ~context "request_body_sha256" fields in
  let* request_body_sha256 =
    string_json ~context:(context ^ ".request_body_sha256") body_json
  in
  Ok { slot_id; call_id; plan_fingerprint; request_body_sha256 }
;;

let candidate_attempt_provenance_of_yojson json =
  let* (provenance : exact_provenance) = exact_provenance_of_yojson json in
  Ok
    ({ Candidate.slot_id = provenance.slot_id
     ; call_id = provenance.call_id
     ; plan_fingerprint = provenance.plan_fingerprint
     ; request_body_sha256 = provenance.request_body_sha256
     } : Candidate.attempt_provenance)
;;

let candidate_visit_of_yojson json =
  let context = "Board attention exact candidate visit" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "flow_id"
      ; "ordinal"
      ; "slot_id"
      ; "catalog_generation_fingerprint"
      ; "catalog_evidence_sha256"
      ; "target_identity_fingerprint"
      ]
      fields
  in
  let* flow_id_json = field ~context "flow_id" fields in
  let* flow_id = string_json ~context:(context ^ ".flow_id") flow_id_json in
  let* ordinal_json = field ~context "ordinal" fields in
  let* ordinal =
    nonnegative_int_json ~context:(context ^ ".ordinal") ordinal_json
  in
  let* slot_json = field ~context "slot_id" fields in
  let* slot_id = string_json ~context:(context ^ ".slot_id") slot_json in
  let* generation_json =
    field ~context "catalog_generation_fingerprint" fields
  in
  let* catalog_generation_fingerprint =
    string_json
      ~context:(context ^ ".catalog_generation_fingerprint")
      generation_json
  in
  let* evidence_json = field ~context "catalog_evidence_sha256" fields in
  let* catalog_evidence_sha256 =
    string_json
      ~context:(context ^ ".catalog_evidence_sha256")
      evidence_json
  in
  let* target_json = field ~context "target_identity_fingerprint" fields in
  let* target_identity_fingerprint =
    string_json
      ~context:(context ^ ".target_identity_fingerprint")
      target_json
  in
  Ok
    { flow_id
    ; ordinal
    ; slot_id
    ; catalog_generation_fingerprint
    ; catalog_evidence_sha256
    ; target_identity_fingerprint
    }
;;

let running_progress_of_yojson json =
  let context = "Board attention exact progress" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "unbound" ->
    let* () = exact_fields ~context [ "kind" ] fields in
    Ok Unbound
  | "bound" ->
    let* () = exact_fields ~context [ "kind"; "provenance" ] fields in
    let* provenance_json = field ~context "provenance" fields in
    let* provenance = exact_provenance_of_yojson provenance_json in
    Ok (Bound provenance)
  | "advancing" ->
    let* () =
      exact_fields
        ~context
        [ "kind"; "execution_anchor"; "last_from"; "next" ]
        fields
    in
    let* execution_anchor_json = field ~context "execution_anchor" fields in
    let* execution_anchor =
      match execution_anchor_json with
      | `Null -> Ok None
      | json -> exact_provenance_of_yojson json |> Result.map Option.some
    in
    let* last_from_json = field ~context "last_from" fields in
    let* last_from =
      match last_from_json with
      | `Null -> Ok None
      | json -> candidate_visit_of_yojson json |> Result.map Option.some
    in
    let* next_json = field ~context "next" fields in
    let* next = candidate_visit_of_yojson next_json in
    (match execution_anchor, last_from with
     | None, None ->
       Error "advancing progress requires an execution anchor or rejected visit"
     | _ -> Ok (Advancing { execution_anchor; last_from; next }))
  | value -> Error (Printf.sprintf "unknown Board attention exact progress %S" value)
;;

(* A classified failure never retains [Unbound]: an execution that bound no
   provider call has no progress worth keeping, so it is written as [None]. *)
let optional_progress_field ~context fields =
  let* progress_json = field ~context "progress" fields in
  match progress_json with
  | `Null -> Ok None
  | json ->
    let* progress = running_progress_of_yojson json in
    (match progress with
     | Unbound -> Error "classified execution failure cannot retain unbound progress"
     | Bound _ | Advancing _ -> Ok (Some progress))
;;

let classified_failure_fields ~context fields =
  let* () = exact_fields ~context [ "kind"; "detail"; "progress" ] fields in
  let* detail_json = field ~context "detail" fields in
  let* detail = string_json ~context:(context ^ ".detail") detail_json in
  let* progress = optional_progress_field ~context fields in
  Ok (detail, progress)
;;

let blocked_reason_of_yojson json =
  let context = "Board attention blocked reason" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "candidate_membership_conflict" ->
    let* () = exact_fields ~context [ "kind"; "detail" ] fields in
    let* detail_json = field ~context "detail" fields in
    let* detail = string_json ~context:(context ^ ".detail") detail_json in
    Ok (Candidate_membership_conflict detail)
  | "durable_partition_invariant" ->
    let* () = exact_fields ~context [ "kind"; "detail" ] fields in
    let* detail_json = field ~context "detail" fields in
    let* detail = string_json ~context:(context ^ ".detail") detail_json in
    Ok (Durable_partition_invariant detail)
  | "exact_setup_unavailable" ->
    let* () = exact_fields ~context [ "kind"; "detail" ] fields in
    let* detail_json = field ~context "detail" fields in
    let* detail = string_json ~context:(context ^ ".detail") detail_json in
    Ok (Exact_setup_unavailable detail)
  | "exact_flow_replayed" ->
    let* () = exact_fields ~context [ "kind"; "progress" ] fields in
    let* progress = optional_progress_field ~context fields in
    Ok (Exact_flow_replayed progress)
  | "exact_lane_exhausted" ->
    let* detail, progress = classified_failure_fields ~context fields in
    Ok (Exact_lane_exhausted { detail; progress })
  | "exact_flow_bookkeeping_failed" ->
    let* detail, progress = classified_failure_fields ~context fields in
    Ok (Exact_flow_bookkeeping_failed { detail; progress })
  | "exact_completion_failed" ->
    let* detail, progress = classified_failure_fields ~context fields in
    Ok (Exact_completion_failed { detail; progress })
  | "domain_output_invalid" ->
    let* detail, progress = classified_failure_fields ~context fields in
    Ok (Domain_output_invalid { detail; progress })
  | "execution_provenance_mismatch" ->
    let* detail, progress = classified_failure_fields ~context fields in
    Ok (Execution_provenance_mismatch { detail; progress })
  | "unexpected_worker_failure" ->
    let* detail, progress = classified_failure_fields ~context fields in
    Ok (Unexpected_worker_failure { detail; progress })
  | "exact_execution_quarantined" ->
    let* () = exact_fields ~context [ "kind"; "progress" ] fields in
    let* progress_json = field ~context "progress" fields in
    let* progress = running_progress_of_yojson progress_json in
    (match progress with
     | Bound _ | Advancing _ -> Ok (Exact_execution_quarantined progress)
     | Unbound -> Error "unbound execution cannot be quarantined")
  | "exact_execution_interrupted" ->
    let* () = exact_fields ~context [ "kind"; "progress" ] fields in
    let* progress_json = field ~context "progress" fields in
    let* progress = running_progress_of_yojson progress_json in
    (match progress with
     | Bound _ | Advancing _ -> Ok (Exact_execution_interrupted progress)
     | Unbound -> Error "unbound execution cannot be interrupted")
  | "restored_candidate_quarantine" ->
    let* () =
      exact_fields
        ~context
        [ "kind"; "failure_category"; "attempt_provenance" ]
        fields
    in
    let* category_json = field ~context "failure_category" fields in
    let* category =
      match category_json with
      | `String raw ->
        (match Candidate.quarantine_failure_category_of_string raw with
         | Some category -> Ok category
         | None -> Error ("unknown Board attention failure category " ^ raw))
      | _ -> Error "Board attention failure category must be a string"
    in
    let* provenance_json = field ~context "attempt_provenance" fields in
    let* attempt_provenance =
      match provenance_json with
      | `Null -> Ok None
      | json ->
        candidate_attempt_provenance_of_yojson json |> Result.map Option.some
    in
    Ok
      (Restored_candidate_quarantine
         { failure_category = category; attempt_provenance })
  | value -> Error (Printf.sprintf "unknown Board attention blocked reason %S" value)
;;

let completed_item_of_yojson json =
  let context = "Board attention completed item" in
  let* fields = assoc ~context json in
  let* () = exact_fields ~context [ "candidate_id"; "judgment" ] fields in
  let* candidate_id_json = field ~context "candidate_id" fields in
  let* candidate_id = string_json ~context:(context ^ ".candidate_id") candidate_id_json in
  let* judgment_json = field ~context "judgment" fields in
  let* judgment = Candidate.judgment_of_yojson judgment_json in
  Ok { candidate_id; judgment }
;;

let state_of_yojson json =
  let context = "Board attention partition state" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "ready" ->
    let* () = exact_fields ~context [ "kind" ] fields in
    Ok Ready
  | "running" ->
    let* () =
      exact_fields ~context [ "kind"; "worker_epoch"; "started_at"; "progress" ] fields
    in
    let* epoch_json = field ~context "worker_epoch" fields in
    let* epoch_raw = string_json ~context:(context ^ ".worker_epoch") epoch_json in
    let* worker_epoch = Worker_epoch.of_string epoch_raw in
    let* started_json = field ~context "started_at" fields in
    let* started_at = float_json ~context:(context ^ ".started_at") started_json in
    let* progress_json = field ~context "progress" fields in
    let* progress = running_progress_of_yojson progress_json in
    Ok (Running { worker_epoch; started_at; progress })
  | "completed" ->
    let* () = exact_fields ~context [ "kind"; "item"; "completed_at" ] fields in
    let* item_json = field ~context "item" fields in
    let* item = completed_item_of_yojson item_json in
    let* completed_json = field ~context "completed_at" fields in
    let* completed_at = float_json ~context:(context ^ ".completed_at") completed_json in
    Ok (Completed { item; completed_at })
  | "settled" ->
    let* () = exact_fields ~context [ "kind"; "settled_at" ] fields in
    let* settled_json = field ~context "settled_at" fields in
    let* settled_at = float_json ~context:(context ^ ".settled_at") settled_json in
    Ok (Settled { settled_at })
  | "abandoned" ->
    let* () = exact_fields ~context [ "kind"; "abandoned_at" ] fields in
    let* abandoned_json = field ~context "abandoned_at" fields in
    let* abandoned_at =
      float_json ~context:(context ^ ".abandoned_at") abandoned_json
    in
    Ok (Abandoned { abandoned_at })
  | "blocked" ->
    let* () = exact_fields ~context [ "kind"; "reason"; "blocked_at" ] fields in
    let* reason_json = field ~context "reason" fields in
    let* reason = blocked_reason_of_yojson reason_json in
    let* blocked_json = field ~context "blocked_at" fields in
    let* blocked_at = float_json ~context:(context ^ ".blocked_at") blocked_json in
    Ok (Blocked { reason; blocked_at })
  | value -> Error (Printf.sprintf "unknown Board attention partition state %S" value)
;;

let of_yojson json =
  let context = "Board attention partition" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "schema_version"
      ; "partition_id"
      ; "keeper_name"
      ; "context_key"
      ; "candidate_id"
      ; "created_at"
      ; "generation"
      ; "state"
      ]
      fields
  in
  let* version_json = field ~context "schema_version" fields in
  let* () =
    match version_json with
    | `Int version when Int.equal version schema_version -> Ok ()
    | `Int version ->
      Error
        (Printf.sprintf
           "unsupported Board attention partition schema version %d"
           version)
    | _ -> Error (context ^ ".schema_version must be an integer")
  in
  let* partition_json = field ~context "partition_id" fields in
  let* partition_id = string_json ~context:(context ^ ".partition_id") partition_json in
  let* keeper_json = field ~context "keeper_name" fields in
  let* keeper_name = string_json ~context:(context ^ ".keeper_name") keeper_json in
  let* context_json = field ~context "context_key" fields in
  let* context_key = Candidate.Context_key.of_yojson context_json in
  let* candidate_json = field ~context "candidate_id" fields in
  let* candidate_id = string_json ~context:(context ^ ".candidate_id") candidate_json in
  let* created_json = field ~context "created_at" fields in
  let* created_at = float_json ~context:(context ^ ".created_at") created_json in
  let* generation_json = field ~context "generation" fields in
  let* generation = Generation.of_yojson generation_json in
  let* state_json = field ~context "state" fields in
  let* state = state_of_yojson state_json in
  let* () =
    match state with
    | Completed { item; _ } when String.equal item.candidate_id candidate_id -> Ok ()
    | Completed _ -> Error "completed item identity differs from partition candidate"
    | Ready | Running _ | Settled _ | Abandoned _ | Blocked _ -> Ok ()
  in
  Ok
    { partition_id
    ; keeper_name
    ; context_key
    ; candidate_id
    ; created_at
    ; generation
    ; state
    }
;;

let parse content =
  String.split_on_char '\n' content
  |> List.fold_left
       (fun result line ->
          let* rows, confirmations = result in
          let line = String.trim line in
          if String.equal line ""
          then Ok (rows, confirmations)
          else
            match Yojson.Safe.from_string line with
            | json ->
              let* fields = assoc ~context:"Board attention ledger row" json in
              (match List.assoc_opt "kind" fields with
               | None ->
                 let partition_fields, confirmation_fields =
                   List.partition
                     (fun (name, _) ->
                        not (String.equal name "ready_confirmation"))
                     fields
                 in
                 (match confirmation_fields with
                  | [] ->
                    let* row = of_yojson json in
                    Ok (row :: rows, confirmations)
                  | [ (_, confirmation_json) ] ->
                    let* row = of_yojson (`Assoc partition_fields) in
                    let* confirmation =
                      ready_confirmation_of_yojson confirmation_json
                    in
                    let* () =
                      if String.equal row.partition_id confirmation.partition_id
                         && Generation.equal row.generation confirmation.generation
                      then
                        match row.state with
                        | Ready -> Ok ()
                        | Running _ | Completed _ | Settled _ | Abandoned _
                        | Blocked _ ->
                          Error "Ready confirmation belongs to a non-Ready row"
                      else Error "Ready confirmation identity differs from its row"
                    in
                    Ok (row :: rows, confirmation :: confirmations)
                  | _ -> Error "Ready confirmation field occurs more than once")
               | Some _ ->
                 let* confirmation = ready_confirmation_of_yojson json in
                 Ok (rows, confirmation :: confirmations))
            | exception Yojson.Json_error detail -> Error ("invalid partition JSON: " ^ detail))
       (Ok ([], []))
  |> Result.map (fun (rows, confirmations) -> List.rev rows, List.rev confirmations)
;;

let serialize rows =
  rows
  |> List.map (fun row -> Yojson.Safe.to_string (to_yojson row) ^ "\n")
  |> String.concat ""
;;

let serialize_confirmations confirmations =
  confirmations
  |> List.map (fun confirmation ->
    Yojson.Safe.to_string (ready_confirmation_to_yojson confirmation) ^ "\n")
  |> String.concat ""
;;
