(** Keeper_tool_deterministic_error — see .mli for design notes. *)

type deterministic_reason =
  | Command_blocked
  | Command_shape_blocked
  | Task_state_probe_blocked
  | Destructive_operation_blocked
  | Path_syntax_blocked
  | Path_outside_sandbox
  | Cwd_not_directory
  | Policy_blocked
  | Completion_contract_violation
  | Keeper_shell_op_required
  | Workflow_rejection_blocked
  | Git_ref_precondition_failed
  | Git_command_usage_error

let to_telemetry_key = function
  | Command_blocked -> "deterministic_error_command_blocked"
  | Command_shape_blocked -> "deterministic_error_command_shape_blocked"
  | Task_state_probe_blocked ->
    "deterministic_error_task_state_probe_blocked"
  | Destructive_operation_blocked ->
    "deterministic_error_destructive_operation_blocked"
  | Path_syntax_blocked -> "deterministic_error_path_syntax_blocked"
  | Path_outside_sandbox -> "deterministic_error_path_outside_sandbox"
  | Cwd_not_directory -> "deterministic_error_cwd_not_directory"
  | Policy_blocked -> "deterministic_error_policy_blocked"
  | Completion_contract_violation ->
    "deterministic_error_completion_contract_violation"
  | Keeper_shell_op_required -> "deterministic_error_keeper_shell_op_required"
  | Workflow_rejection_blocked -> "deterministic_error_workflow_rejection_blocked"
  | Git_ref_precondition_failed ->
    "deterministic_error_git_ref_precondition_failed"
  | Git_command_usage_error -> "deterministic_error_git_command_usage_error"
;;

let to_string = function
  | Command_blocked ->
    "keeper shell command blocked by policy; follow recovery_plan instead"
  | Command_shape_blocked ->
    "keeper_bash command-shape blocked (pipes/redirects/chaining/substitution/scan)"
  | Task_state_probe_blocked ->
    "raw shell task-state probe blocked; use keeper task/context tools"
  | Destructive_operation_blocked ->
    "destructive operation blocked (force push / rm -rf / push to main)"
  | Path_syntax_blocked -> "path argument failed syntax check before execution"
  | Path_outside_sandbox -> "path argument outside keeper-allowed sandbox roots"
  | Cwd_not_directory -> "cwd argument is not a directory"
  | Policy_blocked -> "governance / preset policy rejected the call"
  | Completion_contract_violation ->
    "keeper completion contract violated (e.g. require_tool_use)"
  | Keeper_shell_op_required ->
    "raw keeper_bash rejected; caller must use keeper_shell op=<verb>"
  | Workflow_rejection_blocked ->
    "typed workflow_rejection failure_class returned by the tool"
  | Git_ref_precondition_failed ->
    "git ref/precondition failure (missing ref, unknown revision, or no merge base)"
  | Git_command_usage_error ->
    "git command usage error; change flags or command shape before retrying"
;;

(* ── JSON helpers ─────────────────────────────────────────────── *)

let assoc_field_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let assoc_string_opt key json =
  match assoc_field_opt key json with
  | Some (`String value) -> Some value
  | _ -> None
;;

let assoc_int_opt key json =
  match assoc_field_opt key json with
  | Some (`Int value) -> Some value
  | _ -> None
;;

let starts_with ~prefix text =
  let prefix_len = String.length prefix in
  String.length text >= prefix_len && String.sub text 0 prefix_len = prefix
;;

(* [error_or_detail key json] reads [key] at top level, falling back
   to a nested ["detail"] object. Mirrors the lookup pattern used in
   [keeper_tools_oas.workflow_rejection_info_of_raw]. *)
let error_or_detail_string key json =
  match assoc_string_opt key json with
  | Some _ as v -> v
  | None ->
    (match assoc_field_opt "detail" json with
     | Some detail -> assoc_string_opt key detail
     | None -> None)
;;

(* Closed mapping: [error] field value -> [deterministic_reason].
   New error codes added in [Exec_core.blocked_result_json] callers
   must be wired here explicitly; an unmapped value returns [None]
   so transient/runtime errors stay outside the short-circuit. *)
let reason_of_error_code = function
  | "command_blocked" -> Some Command_blocked
  | "keeper_bash_command_shape_blocked" -> Some Command_shape_blocked
  | "task_state_file_probe_blocked" | "task_state_http_probe_blocked" ->
    Some Task_state_probe_blocked
  | "destructive_operation_blocked" -> Some Destructive_operation_blocked
  | "policy_blocked" -> Some Policy_blocked
  | "policy_not_loaded" -> Some Policy_blocked
  | "gh_command_blocked" -> Some Policy_blocked
  | "gh_irreversible_blocked" -> Some Policy_blocked
  | "completion_contract_violation" -> Some Completion_contract_violation
  | "keeper_shell_bash_deprecated" -> Some Keeper_shell_op_required
  | "keeper_pr_create_requires_git_cwd" -> Some Keeper_shell_op_required
  | _ -> None
;;

(* Path-prefixed sentinel string (no substring search): the keeper
   path checker emits exactly these three prefixes via
   [Keeper_path_check_error.error_prefix]. We compare the *full*
   value of the [error] field — or, when the payload nests the
   syntax in [detail.path_check.reason], that field — but we never
   accept a partial match. *)
let path_check_reason_of_explicit = function
  | "path_syntax_blocked" -> Some Path_syntax_blocked
  | "path_outside_sandbox" -> Some Path_outside_sandbox
  | "path_not_in_allowed_paths" -> Some Path_outside_sandbox
  | "cwd_not_directory" -> Some Cwd_not_directory
  | _ -> None
;;

(* ── Classifier ───────────────────────────────────────────────── *)

let classify_workflow_rejection json =
  match error_or_detail_string "failure_class" json with
  | Some "workflow_rejection" -> Some Workflow_rejection_blocked
  | Some _ | None -> None
;;

let classify_error_code json =
  match error_or_detail_string "error" json with
  | Some code -> reason_of_error_code code
  | None -> None
;;

let classify_git_exit_128 json =
  match assoc_int_opt "exit_code" json with
  | Some 128 ->
    let command =
      assoc_string_opt "command" json
      |> Option.map String.trim
      |> Option.value ~default:""
    in
    let output =
      assoc_string_opt "output" json
      |> Option.map String.lowercase_ascii
      |> Option.value ~default:""
    in
    if starts_with ~prefix:"git " command
       && String_util.contains_substring output "no merge base"
    then Some Git_ref_precondition_failed
    else if starts_with ~prefix:"git " command
            && String_util.contains_substring output "ambiguous argument"
            && String_util.contains_substring output "unknown revision"
    then Some Git_ref_precondition_failed
    else if starts_with ~prefix:"git " command
            && String_util.contains_substring output "unknown revision or path"
    then Some Git_ref_precondition_failed
    else if starts_with ~prefix:"git " command
            && String_util.contains_substring output "fatal: unrecognized argument:"
    then Some Git_command_usage_error
    else None
  | Some _
  | None -> None
;;

let classify_path_check json =
  (* Some path-check failures surface as a discriminated [error] code
     directly; others nest the typed reason under
     [detail.path_check.reason]. Both are checked against a closed
     allow-list (no substring scanning). *)
  let from_path_check_field =
    match assoc_field_opt "path_check" json with
    | Some pc ->
      (match assoc_string_opt "reason" pc with
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

let classify (json : Yojson.Safe.t) : deterministic_reason option =
  (* Precedence: workflow_rejection > path_check > error_code.
     Workflow rejection is the most specific (already routed to a
     dedicated counter in [Keeper_tools_oas]). Path checks have their
     own typed surface. Generic [error] codes are the catch-up layer. *)
  match classify_workflow_rejection json with
  | Some _ as v -> v
  | None ->
    (match classify_path_check json with
     | Some _ as v -> v
     | None ->
       (match classify_error_code json with
        | Some _ as v -> v
        | None -> classify_git_exit_128 json))
;;

let classify_raw (raw : string) : deterministic_reason option =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error _ -> None
  | json -> classify json
;;
