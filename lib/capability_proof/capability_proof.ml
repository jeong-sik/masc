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
