type exact_lane =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Compaction

type proof_role =
  | Autonomous_keeper
  | Completion_authority
  | Verification
  | Cross_verifier
  | Exact_lane of exact_lane
  | Fusion_panel
  | Fusion_judge
  | Fusion_meta_judge

type capability_case =
  | Provider_probe
  | Autonomous_turn
  | Verification_run
  | Cross_verification
  | Librarian_run
  | Hitl_auto_judge_run
  | Board_attention_run
  | Compaction_run
  | Fusion_panel_run
  | Fusion_judge_run
  | Fusion_meta_judge_run
  | Queue_fifo
  | Scheduler_occurrence
  | Board_comment
  | Task_lifecycle
  | Goal_lifecycle
  | Tool_serial
  | Tool_parallel
  | Tool_batch
  | Async_lifecycle
  | Sandbox_containment
  | Broadcast_turn
  | Stream_replay
  | Restart_succession

type scenario =
  | Nominal
  | Invalid_input
  | Provider_rejected
  | Effect_denied
  | Effect_deferred
  | Cancelled
  | Restart_recovery
  | Outcome_unknown
  | Duplicate_delivery
  | Blocked_head

type protocol =
  | Agent_core_http
  | Official_client
  | Mcp
  | Dashboard_http
  | Sse
  | Websocket
  | Browser
  | Durable_store
  | Domain_api

type field =
  | Runtime_id
  | Model_id
  | Build_commit
  | Config_revision

type create_error = Blank_field of field

type case_id = string

type t =
  { runtime_id : string
  ; model_id : string option
  ; role : proof_role
  ; capability : capability_case
  ; scenario : scenario
  ; protocol : protocol
  ; build_commit : string option
  ; config_revision : string option
  ; case_id : case_id
  }

let exact_lane_to_string = function
  | Librarian -> "librarian"
  | Hitl_auto_judge -> "hitl_auto_judge"
  | Board_attention -> "board_attention"
  | Compaction -> "compaction"
;;

let proof_role_to_string = function
  | Autonomous_keeper -> "autonomous_keeper"
  | Completion_authority -> "completion_authority"
  | Verification -> "verification"
  | Cross_verifier -> "cross_verifier"
  | Exact_lane lane -> "exact_lane:" ^ exact_lane_to_string lane
  | Fusion_panel -> "fusion_panel"
  | Fusion_judge -> "fusion_judge"
  | Fusion_meta_judge -> "fusion_meta_judge"
;;

let capability_case_to_string = function
  | Provider_probe -> "provider_probe"
  | Autonomous_turn -> "autonomous_turn"
  | Verification_run -> "verification_run"
  | Cross_verification -> "cross_verification"
  | Librarian_run -> "librarian_run"
  | Hitl_auto_judge_run -> "hitl_auto_judge_run"
  | Board_attention_run -> "board_attention_run"
  | Compaction_run -> "compaction_run"
  | Fusion_panel_run -> "fusion_panel_run"
  | Fusion_judge_run -> "fusion_judge_run"
  | Fusion_meta_judge_run -> "fusion_meta_judge_run"
  | Queue_fifo -> "queue_fifo"
  | Scheduler_occurrence -> "scheduler_occurrence"
  | Board_comment -> "board_comment"
  | Task_lifecycle -> "task_lifecycle"
  | Goal_lifecycle -> "goal_lifecycle"
  | Tool_serial -> "tool_serial"
  | Tool_parallel -> "tool_parallel"
  | Tool_batch -> "tool_batch"
  | Async_lifecycle -> "async_lifecycle"
  | Sandbox_containment -> "sandbox_containment"
  | Broadcast_turn -> "broadcast_turn"
  | Stream_replay -> "stream_replay"
  | Restart_succession -> "restart_succession"
;;

let scenario_to_string = function
  | Nominal -> "nominal"
  | Invalid_input -> "invalid_input"
  | Provider_rejected -> "provider_rejected"
  | Effect_denied -> "effect_denied"
  | Effect_deferred -> "effect_deferred"
  | Cancelled -> "cancelled"
  | Restart_recovery -> "restart_recovery"
  | Outcome_unknown -> "outcome_unknown"
  | Duplicate_delivery -> "duplicate_delivery"
  | Blocked_head -> "blocked_head"
;;

let protocol_to_string = function
  | Agent_core_http -> "agent_core_http"
  | Official_client -> "official_client"
  | Mcp -> "mcp"
  | Dashboard_http -> "dashboard_http"
  | Sse -> "sse"
  | Websocket -> "websocket"
  | Browser -> "browser"
  | Durable_store -> "durable_store"
  | Domain_api -> "domain_api"
;;

let field_to_string = function
  | Runtime_id -> "runtime_id"
  | Model_id -> "model_id"
  | Build_commit -> "build_commit"
  | Config_revision -> "config_revision"
;;

let create_error_to_string = function
  | Blank_field field -> "blank_field:" ^ field_to_string field
;;

let all_proof_roles =
  [ Autonomous_keeper
  ; Completion_authority
  ; Verification
  ; Cross_verifier
  ; Exact_lane Librarian
  ; Exact_lane Hitl_auto_judge
  ; Exact_lane Board_attention
  ; Exact_lane Compaction
  ; Fusion_panel
  ; Fusion_judge
  ; Fusion_meta_judge
  ]
;;

let all_capability_cases =
  [ Provider_probe
  ; Autonomous_turn
  ; Verification_run
  ; Cross_verification
  ; Librarian_run
  ; Hitl_auto_judge_run
  ; Board_attention_run
  ; Compaction_run
  ; Fusion_panel_run
  ; Fusion_judge_run
  ; Fusion_meta_judge_run
  ; Queue_fifo
  ; Scheduler_occurrence
  ; Board_comment
  ; Task_lifecycle
  ; Goal_lifecycle
  ; Tool_serial
  ; Tool_parallel
  ; Tool_batch
  ; Async_lifecycle
  ; Sandbox_containment
  ; Broadcast_turn
  ; Stream_replay
  ; Restart_succession
  ]
;;

let all_scenarios =
  [ Nominal
  ; Invalid_input
  ; Provider_rejected
  ; Effect_denied
  ; Effect_deferred
  ; Cancelled
  ; Restart_recovery
  ; Outcome_unknown
  ; Duplicate_delivery
  ; Blocked_head
  ]
;;

let all_protocols =
  [ Agent_core_http
  ; Official_client
  ; Mcp
  ; Dashboard_http
  ; Sse
  ; Websocket
  ; Browser
  ; Durable_store
  ; Domain_api
  ]
;;

let nonblank field value =
  if String.trim value = "" then Error (Blank_field field) else Ok value
;;

let optional_nonblank field = function
  | None -> Ok None
  | Some value -> Result.map (fun value -> Some value) (nonblank field value)
;;

let length_prefixed value = Printf.sprintf "%d:%s" (String.length value) value

let optional_material = function
  | None -> "n"
  | Some value -> "s" ^ length_prefixed value
;;

let canonical_material
      ~runtime_id
      ~model_id
      ~role
      ~capability
      ~scenario
      ~protocol
      ~build_commit
      ~config_revision
  =
  [ "masc-capability-proof-case-v1"
  ; length_prefixed runtime_id
  ; optional_material model_id
  ; length_prefixed (proof_role_to_string role)
  ; length_prefixed (capability_case_to_string capability)
  ; length_prefixed (scenario_to_string scenario)
  ; length_prefixed (protocol_to_string protocol)
  ; optional_material build_commit
  ; optional_material config_revision
  ]
  |> String.concat ""
;;

let ( let* ) = Result.bind

let create
      ~runtime_id
      ~model_id
      ~role
      ~capability
      ~scenario
      ~protocol
      ~build_commit
      ~config_revision
  =
  let* runtime_id = nonblank Runtime_id runtime_id in
  let* model_id = optional_nonblank Model_id model_id in
  let* build_commit = optional_nonblank Build_commit build_commit in
  let* config_revision = optional_nonblank Config_revision config_revision in
  let material =
    canonical_material
      ~runtime_id
      ~model_id
      ~role
      ~capability
      ~scenario
      ~protocol
      ~build_commit
      ~config_revision
  in
  let case_id = "cpc_" ^ Digestif.SHA256.(digest_string material |> to_hex) in
  Ok
    { runtime_id
    ; model_id
    ; role
    ; capability
    ; scenario
    ; protocol
    ; build_commit
    ; config_revision
    ; case_id
    }
;;

let case_id t = t.case_id
let case_id_to_string value = value
let runtime_id t = t.runtime_id
let model_id t = t.model_id
let role t = t.role
let capability t = t.capability
let scenario t = t.scenario
let protocol t = t.protocol
let build_commit t = t.build_commit
let config_revision t = t.config_revision

type proof_path =
  | Hermetic
  | Isolated
  | Fleet

type evidence_kind =
  | Journal
  | Receipt
  | Durable_queue
  | Gate
  | Domain_store
  | Api
  | Sse_trace
  | Browser_screenshot
  | Config_snapshot
  | Deployment_identity

type evidence_ref =
  { path : proof_path
  ; kind : evidence_kind
  ; locator : string
  ; sha256 : string
  ; captured_at : string
  }

type evidence_error =
  | Blank_locator
  | Blank_captured_at
  | Invalid_sha256

let proof_path_to_string = function
  | Hermetic -> "hermetic"
  | Isolated -> "isolated"
  | Fleet -> "fleet"
;;

let evidence_kind_to_string = function
  | Journal -> "journal"
  | Receipt -> "receipt"
  | Durable_queue -> "durable_queue"
  | Gate -> "gate"
  | Domain_store -> "domain_store"
  | Api -> "api"
  | Sse_trace -> "sse_trace"
  | Browser_screenshot -> "browser_screenshot"
  | Config_snapshot -> "config_snapshot"
  | Deployment_identity -> "deployment_identity"
;;

let evidence_error_to_string = function
  | Blank_locator -> "blank_locator"
  | Blank_captured_at -> "blank_captured_at"
  | Invalid_sha256 -> "invalid_sha256"
;;

let all_proof_paths = [ Hermetic; Isolated; Fleet ]

let is_lower_hex = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false
;;

let valid_sha256 value = String.length value = 64 && String.for_all is_lower_hex value

let create_evidence_ref ~path ~kind ~locator ~sha256 ~captured_at =
  if String.trim locator = ""
  then Error Blank_locator
  else if not (valid_sha256 sha256)
  then Error Invalid_sha256
  else if String.trim captured_at = ""
  then Error Blank_captured_at
  else Ok { path; kind; locator; sha256; captured_at }
;;

type evidence_bundle = evidence_ref list

type bundle_error =
  | Missing_proof_paths of proof_path list
  | Duplicate_evidence_ref of string

let evidence_identity evidence =
  String.concat
    "\000"
    [ proof_path_to_string evidence.path
    ; evidence_kind_to_string evidence.kind
    ; evidence.locator
    ; evidence.sha256
    ; evidence.captured_at
    ]
;;

let rec first_duplicate seen = function
  | [] -> None
  | evidence :: rest ->
    let identity = evidence_identity evidence in
    if List.mem identity seen then Some evidence.locator else first_duplicate (identity :: seen) rest
;;

let create_evidence_bundle refs =
  match first_duplicate [] refs with
  | Some locator -> Error (Duplicate_evidence_ref locator)
  | None ->
    let missing =
      List.filter
        (fun path -> not (List.exists (fun evidence -> evidence.path = path) refs))
        all_proof_paths
    in
    if missing = [] then Ok refs else Error (Missing_proof_paths missing)
;;

let evidence_bundle_refs bundle = bundle

let bundle_error_to_string = function
  | Missing_proof_paths paths ->
    "missing_proof_paths:" ^ String.concat "," (List.map proof_path_to_string paths)
  | Duplicate_evidence_ref locator -> "duplicate_evidence_ref:" ^ locator
;;

type failure_kind =
  | Contract_violation
  | Provider_failure
  | Infrastructure_failure
  | Evidence_mismatch
  | Stream_replay_duplicate
  | Queue_order_violation
  | Sandbox_escape
  | Scheduler_settlement_failure
  | Gate_settlement_failure
  | Domain_receipt_failure

type unsupported_reason =
  | Protocol_not_supported of protocol
  | Capability_not_declared of capability_case

type blocker_ref = string

type proof_result =
  | Passed of evidence_bundle
  | Failed of failure_kind * evidence_ref list
  | Unsupported of unsupported_reason
  | Not_run
  | Blocked of blocker_ref

type result_error =
  | Invalid_evidence_bundle of bundle_error
  | Failure_without_evidence
  | Blank_blocker_ref

let failure_kind_to_string = function
  | Contract_violation -> "contract_violation"
  | Provider_failure -> "provider_failure"
  | Infrastructure_failure -> "infrastructure_failure"
  | Evidence_mismatch -> "evidence_mismatch"
  | Stream_replay_duplicate -> "stream_replay_duplicate"
  | Queue_order_violation -> "queue_order_violation"
  | Sandbox_escape -> "sandbox_escape"
  | Scheduler_settlement_failure -> "scheduler_settlement_failure"
  | Gate_settlement_failure -> "gate_settlement_failure"
  | Domain_receipt_failure -> "domain_receipt_failure"
;;

let unsupported_reason_to_string = function
  | Protocol_not_supported protocol -> "protocol_not_supported:" ^ protocol_to_string protocol
  | Capability_not_declared capability ->
    "capability_not_declared:" ^ capability_case_to_string capability
;;

let passed refs =
  match create_evidence_bundle refs with
  | Ok bundle -> Ok (Passed bundle)
  | Error error -> Error (Invalid_evidence_bundle error)
;;

let failed kind = function
  | [] -> Error Failure_without_evidence
  | refs -> Ok (Failed (kind, refs))
;;

let unsupported reason = Unsupported reason
let not_run = Not_run

let blocked blocker =
  if String.trim blocker = "" then Error Blank_blocker_ref else Ok (Blocked blocker)
;;

let proof_result_to_string = function
  | Passed _ -> "passed"
  | Failed (kind, _) -> "failed:" ^ failure_kind_to_string kind
  | Unsupported reason -> "unsupported:" ^ unsupported_reason_to_string reason
  | Not_run -> "not_run"
  | Blocked blocker -> "blocked:" ^ blocker
;;

let result_error_to_string = function
  | Invalid_evidence_bundle error -> "invalid_evidence_bundle:" ^ bundle_error_to_string error
  | Failure_without_evidence -> "failure_without_evidence"
  | Blank_blocker_ref -> "blank_blocker_ref"
;;

type case_json_error =
  | Expected_object
  | Unknown_field of string
  | Missing_field of string
  | Duplicate_field of string
  | Expected_string of string
  | Expected_nullable_string of string
  | Unknown_variant of string * string
  | Invalid_case_field of create_error
  | Case_id_mismatch of
      { encoded : string
      ; derived : string
      }

let case_wire_fields =
  [ "case_id"
  ; "runtime_id"
  ; "model_id"
  ; "role"
  ; "capability"
  ; "scenario"
  ; "protocol"
  ; "build_commit"
  ; "config_revision"
  ]
;;

let option_to_json = function
  | None -> `Null
  | Some value -> `String value
;;

let case_to_json case =
  `Assoc
    [ "case_id", `String (case_id case |> case_id_to_string)
    ; "runtime_id", `String (runtime_id case)
    ; "model_id", option_to_json (model_id case)
    ; "role", `String (proof_role_to_string (role case))
    ; "capability", `String (capability_case_to_string (capability case))
    ; "scenario", `String (scenario_to_string (scenario case))
    ; "protocol", `String (protocol_to_string (protocol case))
    ; "build_commit", option_to_json (build_commit case)
    ; "config_revision", option_to_json (config_revision case)
    ]
;;

let exact_lane_of_string = function
  | "librarian" -> Some Librarian
  | "hitl_auto_judge" -> Some Hitl_auto_judge
  | "board_attention" -> Some Board_attention
  | "compaction" -> Some Compaction
  | _ -> None
;;

let proof_role_of_string = function
  | "autonomous_keeper" -> Some Autonomous_keeper
  | "completion_authority" -> Some Completion_authority
  | "verification" -> Some Verification
  | "cross_verifier" -> Some Cross_verifier
  | "fusion_panel" -> Some Fusion_panel
  | "fusion_judge" -> Some Fusion_judge
  | "fusion_meta_judge" -> Some Fusion_meta_judge
  | value ->
    let prefix = "exact_lane:" in
    let prefix_length = String.length prefix in
    if String.length value > prefix_length
       && String.sub value 0 prefix_length = prefix
    then
      String.sub value prefix_length (String.length value - prefix_length)
      |> exact_lane_of_string
      |> Option.map (fun lane -> Exact_lane lane)
    else None
;;

let capability_case_of_string = function
  | "provider_probe" -> Some Provider_probe
  | "autonomous_turn" -> Some Autonomous_turn
  | "verification_run" -> Some Verification_run
  | "cross_verification" -> Some Cross_verification
  | "librarian_run" -> Some Librarian_run
  | "hitl_auto_judge_run" -> Some Hitl_auto_judge_run
  | "board_attention_run" -> Some Board_attention_run
  | "compaction_run" -> Some Compaction_run
  | "fusion_panel_run" -> Some Fusion_panel_run
  | "fusion_judge_run" -> Some Fusion_judge_run
  | "fusion_meta_judge_run" -> Some Fusion_meta_judge_run
  | "queue_fifo" -> Some Queue_fifo
  | "scheduler_occurrence" -> Some Scheduler_occurrence
  | "board_comment" -> Some Board_comment
  | "task_lifecycle" -> Some Task_lifecycle
  | "goal_lifecycle" -> Some Goal_lifecycle
  | "tool_serial" -> Some Tool_serial
  | "tool_parallel" -> Some Tool_parallel
  | "tool_batch" -> Some Tool_batch
  | "async_lifecycle" -> Some Async_lifecycle
  | "sandbox_containment" -> Some Sandbox_containment
  | "broadcast_turn" -> Some Broadcast_turn
  | "stream_replay" -> Some Stream_replay
  | "restart_succession" -> Some Restart_succession
  | _ -> None
;;

let scenario_of_string = function
  | "nominal" -> Some Nominal
  | "invalid_input" -> Some Invalid_input
  | "provider_rejected" -> Some Provider_rejected
  | "effect_denied" -> Some Effect_denied
  | "effect_deferred" -> Some Effect_deferred
  | "cancelled" -> Some Cancelled
  | "restart_recovery" -> Some Restart_recovery
  | "outcome_unknown" -> Some Outcome_unknown
  | "duplicate_delivery" -> Some Duplicate_delivery
  | "blocked_head" -> Some Blocked_head
  | _ -> None
;;

let protocol_of_string = function
  | "agent_core_http" -> Some Agent_core_http
  | "official_client" -> Some Official_client
  | "mcp" -> Some Mcp
  | "dashboard_http" -> Some Dashboard_http
  | "sse" -> Some Sse
  | "websocket" -> Some Websocket
  | "browser" -> Some Browser
  | "durable_store" -> Some Durable_store
  | "domain_api" -> Some Domain_api
  | _ -> None
;;

let decode_unique fields name =
  match List.filter (fun (field, _) -> String.equal field name) fields with
  | [] -> Error (Missing_field name)
  | [ (_, value) ] -> Ok value
  | _ -> Error (Duplicate_field name)
;;

let decode_string fields name =
  let* value = decode_unique fields name in
  match value with
  | `String value -> Ok value
  | _ -> Error (Expected_string name)
;;

let decode_nullable_string fields name =
  let* value = decode_unique fields name in
  match value with
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ -> Error (Expected_nullable_string name)
;;

let decode_variant fields name decode =
  let* encoded = decode_string fields name in
  match decode encoded with
  | Some value -> Ok value
  | None -> Error (Unknown_variant (name, encoded))
;;

let case_of_json = function
  | `Assoc fields ->
    (match
       List.find_opt
         (fun (name, _) -> not (List.mem name case_wire_fields))
         fields
     with
     | Some (name, _) -> Error (Unknown_field name)
     | None ->
       let* encoded_case_id = decode_string fields "case_id" in
       let* runtime_id = decode_string fields "runtime_id" in
       let* model_id = decode_nullable_string fields "model_id" in
       let* role = decode_variant fields "role" proof_role_of_string in
       let* capability =
         decode_variant fields "capability" capability_case_of_string
       in
       let* scenario = decode_variant fields "scenario" scenario_of_string in
       let* protocol = decode_variant fields "protocol" protocol_of_string in
       let* build_commit = decode_nullable_string fields "build_commit" in
       let* config_revision = decode_nullable_string fields "config_revision" in
       (match
          create
            ~runtime_id
            ~model_id
            ~role
            ~capability
            ~scenario
            ~protocol
            ~build_commit
            ~config_revision
        with
        | Error error -> Error (Invalid_case_field error)
        | Ok case ->
          let derived_case_id = case_id case |> case_id_to_string in
          if String.equal encoded_case_id derived_case_id
          then Ok case
          else
            Error
              (Case_id_mismatch
                 { encoded = encoded_case_id; derived = derived_case_id })))
  | _ -> Error Expected_object
;;

let case_json_error_to_string = function
  | Expected_object -> "expected_object"
  | Unknown_field name -> "unknown_field:" ^ name
  | Missing_field name -> "missing_field:" ^ name
  | Duplicate_field name -> "duplicate_field:" ^ name
  | Expected_string name -> "expected_string:" ^ name
  | Expected_nullable_string name -> "expected_nullable_string:" ^ name
  | Unknown_variant (name, value) -> "unknown_variant:" ^ name ^ ":" ^ value
  | Invalid_case_field error -> "invalid_case_field:" ^ create_error_to_string error
  | Case_id_mismatch { encoded; derived } ->
    Printf.sprintf "case_id_mismatch:encoded=%s:derived=%s" encoded derived
;;
