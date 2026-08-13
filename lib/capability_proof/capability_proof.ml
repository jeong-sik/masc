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
  | Runtime_role_not_declared of proof_role
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
  | Runtime_role_not_declared role ->
    "runtime_role_not_declared:" ^ proof_role_to_string role
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
