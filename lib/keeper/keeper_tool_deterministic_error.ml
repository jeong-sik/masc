(** Keeper_tool_deterministic_error — see .mli for design notes. *)

type deterministic_reason =
  | Command_blocked
  | Command_shape_blocked
  | Task_state_probe_blocked
  | Destructive_operation_blocked
  | Path_outside_sandbox
  | Cwd_not_directory
  | Policy_blocked
  | Write_operation_gated
  | Completion_contract_violation
  | Structured_tool_payload
  | Workflow_rejection_blocked
  | Path_not_found

type classification_source =
  | Deterministic_retry_marker
  | Workflow_rejection_marker
  | Path_check_marker

type classification =
  { reason : deterministic_reason
  ; source : classification_source
  }

type raw_payload_parse_error = Raw_payload_malformed_json of string

let classification_source_to_string = function
  | Deterministic_retry_marker -> "deterministic_retry_marker"
  | Workflow_rejection_marker -> "workflow_rejection_marker"
  | Path_check_marker -> "path_check_marker"
;;

let raw_payload_parse_error_to_string = function
  | Raw_payload_malformed_json message -> "malformed_json: " ^ message
;;

let to_telemetry_key = function
  | Command_blocked -> "deterministic_error_command_blocked"
  | Command_shape_blocked -> "deterministic_error_command_shape_blocked"
  | Task_state_probe_blocked ->
    "deterministic_error_task_state_probe_blocked"
  | Destructive_operation_blocked ->
    "deterministic_error_destructive_operation_blocked"
  | Path_outside_sandbox -> "deterministic_error_path_outside_sandbox"
  | Cwd_not_directory -> "deterministic_error_cwd_not_directory"
  | Policy_blocked -> "deterministic_error_policy_blocked"
  | Write_operation_gated -> "deterministic_error_write_operation_gated"
  | Completion_contract_violation ->
    "deterministic_error_completion_contract_violation"
  | Structured_tool_payload -> "deterministic_error_structured_tool_payload"
  | Workflow_rejection_blocked -> "deterministic_error_workflow_rejection_blocked"
  | Path_not_found -> "deterministic_error_path_not_found"
;;

let to_string = function
  | Command_blocked ->
    "tool execute command blocked by policy; follow recovery_plan instead"
  | Command_shape_blocked ->
    "Execute command-shape blocked (pipes/redirects/chaining/substitution/scan)"
  | Task_state_probe_blocked ->
    "raw shell task-state probe blocked; use keeper task/context tools"
  | Destructive_operation_blocked ->
    "destructive operation blocked (force push / rm -rf / push to main)"
  | Path_outside_sandbox -> "path argument outside keeper-allowed sandbox roots"
  | Cwd_not_directory -> "cwd argument is not a directory"
  | Policy_blocked -> "governance / candidate policy rejected the call"
  | Write_operation_gated ->
    "write-capable Execute is required; retrying the same arguments cannot succeed"
  | Completion_contract_violation ->
    "keeper completion contract violated"
  | Structured_tool_payload ->
    "raw shell rejected; caller must use the visible structured tool from the recovery plan"
  | Workflow_rejection_blocked ->
    "workflow rejection explicitly marked deterministic and unrecoverable"
  | Path_not_found ->
    "a typed Execute path argument does not exist; probe the parent directory before retrying"
;;

(* ── JSON helpers ─────────────────────────────────────────────── *)

let detail_assoc_field_opt key json =
  match Json_util.assoc_member_opt key json with
  | Some _ as value -> value
  | None ->
    (match Json_util.assoc_member_opt "detail" json with
     | Some detail -> Json_util.assoc_member_opt key detail
     | None -> None)
;;

(* [error_or_detail key json] reads [key] at top level, falling back
   to a nested ["detail"] object. Mirrors the lookup pattern used in
   [keeper_tools_oas.workflow_rejection_info_of_raw]. *)
let error_or_detail_string key json =
  match Json_util.assoc_string_opt key json with
  | Some _ as v -> v
  | None ->
    (match Json_util.assoc_member_opt "detail" json with
     | Some detail -> Json_util.assoc_string_opt key detail
     | None -> None)
;;

let reason_to_wire = function
  | Command_blocked -> "command_blocked"
  | Command_shape_blocked -> "command_shape_blocked"
  | Task_state_probe_blocked -> "task_state_probe_blocked"
  | Destructive_operation_blocked -> "destructive_operation_blocked"
  | Path_outside_sandbox -> "path_outside_sandbox"
  | Cwd_not_directory -> "cwd_not_directory"
  | Policy_blocked -> "policy_blocked"
  | Write_operation_gated -> "write_operation_gated"
  | Completion_contract_violation -> "completion_contract_violation"
  | Structured_tool_payload -> "structured_tool_payload"
  | Workflow_rejection_blocked -> "workflow_rejection_blocked"
  | Path_not_found -> "path_not_found"
;;

let reason_of_wire = function
  | "command_blocked" -> Some Command_blocked
  | "command_shape_blocked" -> Some Command_shape_blocked
  | "task_state_probe_blocked" -> Some Task_state_probe_blocked
  | "destructive_operation_blocked" -> Some Destructive_operation_blocked
  | "path_outside_sandbox" -> Some Path_outside_sandbox
  | "cwd_not_directory" -> Some Cwd_not_directory
  | "policy_blocked" -> Some Policy_blocked
  | "write_operation_gated" -> Some Write_operation_gated
  | "completion_contract_violation" -> Some Completion_contract_violation
  | "structured_tool_payload" -> Some Structured_tool_payload
  | "workflow_rejection_blocked" -> Some Workflow_rejection_blocked
  | "path_not_found" -> Some Path_not_found
  | _ -> None
;;

let deterministic_retry_fields reason =
  [ ( "deterministic_retry"
    , `Assoc
        [ "reason", `String (reason_to_wire reason)
        ; "retry_same_args", `Bool false
        ] )
  ]
;;

(* Path-prefixed marker string (no substring search): path checks
   compare the *full* value of the [error] field — or, when the
   payload nests the reason in [detail.path_check.reason], that field
   — but never accept a partial match. *)
let path_check_reason_of_explicit = function
  | "path_outside_sandbox" -> Some Path_outside_sandbox
  | "path_not_in_allowed_paths" -> Some Path_outside_sandbox
  | "cwd_not_directory" -> Some Cwd_not_directory
  | _ -> None
;;

(* ── Classifier ───────────────────────────────────────────────── *)

let classify_deterministic_retry json =
  match detail_assoc_field_opt "deterministic_retry" json with
  | Some (`Assoc _ as retry) ->
    (match Json_util.assoc_bool_opt "retry_same_args" retry, Json_util.assoc_string_opt "reason" retry with
     | Some false, Some reason -> reason_of_wire reason
     | (Some true | None), _
     | _, None ->
       None)
  | Some _
  | None ->
    None
;;

type workflow_rejection_classification =
  | Workflow_rejection_absent
  | Workflow_rejection_observed
  | Workflow_rejection_deterministic of deterministic_reason

let classify_workflow_rejection json =
  match Keeper_tools_oas_workflow.workflow_rejection_payload_of_json json with
  | Some payload
    when Keeper_tools_oas_workflow.workflow_rejection_should_skip_retry payload
    -> Workflow_rejection_deterministic Workflow_rejection_blocked
  | Some _ -> Workflow_rejection_observed
  | None -> Workflow_rejection_absent
;;

let classify_path_check json =
  (* Some path-check failures surface as a discriminated [error] code
     directly; others nest the typed reason under
     [detail.path_check.reason]. Both are checked against a closed
     allow-list (no substring scanning). *)
  let from_path_check_field =
    match Json_util.assoc_member_opt "path_check" json with
    | Some pc ->
      (match Json_util.assoc_string_opt "reason" pc with
       | Some v -> path_check_reason_of_explicit v
       | None -> None)
    | None -> None
  in
  match from_path_check_field with
  | Some _ as v -> v
  | None ->
    (match error_or_detail_string "error" json with
     | Some v -> path_check_reason_of_explicit v
     | None -> None)
;;

let classify_with_source (json : Yojson.Safe.t) : classification option =
  (* Precedence: explicit deterministic_retry > workflow_rejection >
     path_check.
     Workflow rejection is the most specific (already routed to a
     dedicated counter in [Keeper_tools_oas]). Once observed, it must
     not fall through to [error] string fallbacks; only explicit
     deterministic workflow markers may short-circuit retry. Path
     checks have their own typed surface. Generic [error] codes,
     retryability-only fields, and git process failures are
     observational metadata, not a deterministic reason. *)
  match classify_deterministic_retry json with
  | Some reason -> Some { reason; source = Deterministic_retry_marker }
  | None ->
    (match classify_workflow_rejection json with
     | Workflow_rejection_deterministic reason ->
       Some { reason; source = Workflow_rejection_marker }
     | Workflow_rejection_observed -> None
     | Workflow_rejection_absent ->
       (match classify_path_check json with
        | Some reason -> Some { reason; source = Path_check_marker }
        | None -> None))
;;

let classify (json : Yojson.Safe.t) : deterministic_reason option =
  match classify_with_source json with
  | Some classification -> Some classification.reason
  | None -> None
;;

let classify_raw_result (raw : string) :
    (deterministic_reason option, raw_payload_parse_error) result =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error message ->
    Error (Raw_payload_malformed_json message)
  | json -> Ok (classify json)
;;

let classify_raw_with_source_result (raw : string) :
    (classification option, raw_payload_parse_error) result =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error message ->
    Error (Raw_payload_malformed_json message)
  | json -> Ok (classify_with_source json)
;;

let classify_raw (raw : string) : deterministic_reason option =
  match classify_raw_result raw with
  | Ok classification -> classification
  | Error (Raw_payload_malformed_json _) -> None
;;

let classify_raw_with_source (raw : string) : classification option =
  match classify_raw_with_source_result raw with
  | Ok classification -> classification
  | Error (Raw_payload_malformed_json _) -> None
;;
