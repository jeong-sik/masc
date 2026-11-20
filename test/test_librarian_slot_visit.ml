(* Every row of the slot-outcome table (RFC librarian-call-only-proposes §7.2)
   through Librarian_slot_visit.classify. The table is read from
   test/fixtures/librarian_slot_outcome: table.tsv gives one outcome per
   constructor of the types a visit carries, and not-constructors.tsv the
   visit's own cases. A sample
   names the rows its value passes, from a root type to the row that gives
   the outcome. The test fails when those rows are not a chain of the table,
   when classify disagrees with the last one, or when a row has no sample. *)

module Exact = Agent_core.Exact_output
module Http_client = Llm_provider.Http_client
module Stop = Llm_provider.Types
module Oneshot = Masc.Keeper_lane_cli_oneshot
module Client = Masc.Fusion_official_client
module Codex = Runtime_codex_app_server
module Info = Runtime_codex_app_server.Codex_error_info
module Claude = Runtime_claude_code
module Antigravity = Runtime_antigravity
module Muse = Runtime_muse_serve
module Visit = Masc.Librarian_slot_visit

let folder = "test/fixtures/librarian_slot_outcome"

type row =
  | Constructor of
      { file : string
      ; type_ : string
      ; constructor : string
      ; case : string
      }
  | Not_constructor of
      { source : string
      ; value : string
      }

let row_text = function
  | Constructor { file; type_; constructor; case } ->
    String.concat " " [ file; type_; constructor; case ]
  | Not_constructor { source; value } -> source ^ ": " ^ value

(* The cells of each line after the header. *)
let cells name =
  let path = Masc_test_deps.source_path (Filename.concat folder name) in
  match String.split_on_char '\n' (Masc_test_deps.read_file path) with
  | [] -> Alcotest.failf "%s is empty" name
  | _header :: lines ->
    List.filter_map
      (fun line -> if String.equal line "" then None else Some (String.split_on_char '\t' line))
      lines

(* Each row of both files with its outcome cell. *)
let table () =
  List.map
    (function
      | [ file; type_; constructor; case; outcome; _why ] ->
        Constructor { file; type_; constructor; case }, outcome
      | line -> Alcotest.failf "table.tsv: a line of %d cells" (List.length line))
    (cells "table.tsv")
  @ List.map
      (function
        | [ source; value; outcome; _why ] -> Not_constructor { source; value }, outcome
        | line -> Alcotest.failf "not-constructors.tsv: a line of %d cells" (List.length line))
      (cells "not-constructors.tsv")

(* An outcome as the table writes it. *)
let outcome_text : Masc.Librarian_slot_outcome.t -> string = function
  | Slot_answered -> "Slot_answered"
  | Refused (Sized Input_too_large) -> "Refused (Sized Input_too_large)"
  | Refused (Sized Output_over_reserve) -> "Refused (Sized Output_over_reserve)"
  | Refused (Sized Window_reached) -> "Refused (Sized Window_reached)"
  | Refused Unsized -> "Refused Unsized"
  | Silent Not_called -> "Silent Not_called"
  | Silent Unavailable -> "Silent Unavailable"
  | Silent Busy -> "Silent Busy"
  | Silent Lost -> "Silent Lost"
  | Silent (Unusable Not_json) -> "Silent (Unusable Not_json)"
  | Silent (Unusable (Schema_violation _)) -> "Silent (Unusable Schema_violation)"
  | Silent (Unusable Echo_mismatch) -> "Silent (Unusable Echo_mismatch)"
  | Silent (Unusable Empty_or_partial) -> "Silent (Unusable Empty_or_partial)"

(* A type of the table: the rows a value of it passes from a root type, and
   the visit that carries such a value. *)
type 'a under =
  { through : row list
  ; file : string
  ; type_ : string
  ; make : 'a -> Visit.t
  }

let root ~file ~type_ make = { through = []; file; type_; make }

(* The type that the [constructor] row of [parent] points at. [wrap] puts a
   value of it under that constructor. *)
let below ?(case = "-") parent constructor ~file ~type_ wrap =
  { through =
      parent.through @ [ Constructor { file = parent.file; type_ = parent.type_; constructor; case } ]
  ; file
  ; type_
  ; make = (fun value -> parent.make (wrap value))
  }

type sample =
  { rows : row list
  ; visit : Visit.t
  }

let at ?(case = "-") under constructor value =
  { rows = under.through @ [ Constructor { file = under.file; type_ = under.type_; constructor; case } ]
  ; visit = under.make value
  }

let plain source value visit = { rows = [ Not_constructor { source; value } ]; visit }

let exact = "exact_output.mli"
let http = "http_client.mli"
let rejection = root ~file:exact ~type_:"candidate_rejection_disposition" (fun d -> Visit.Http (Rejected_before_dispatch d))

(* Exact_output declares Input_capacity twice. The constraint names this one. *)
let input_capacity =
  below rejection "Input_capacity" ~file:exact ~type_:"input_capacity_disposition" (fun d ->
    (Exact.Input_capacity d : Exact.candidate_rejection_disposition))

let token_capacity =
  below input_capacity "Token_capacity_rejected" ~file:exact ~type_:"token_capacity_rejection"
    (fun r -> Exact.Token_capacity_rejected r)

let cause = root ~file:exact ~type_:"execution_error_cause" (fun c -> Visit.Http (Execution_failed c))

(* classify reads the refusal, not the status. *)
let refusal =
  below cause "Provider_response_refused" ~file:exact ~type_:"provider_refusal" (fun refusal ->
    Exact.Provider_response_refused { http_status = 0; refusal; retry_after_s = None })

let incomplete =
  below cause "Incomplete_output" ~file:"exact_output_plan.mli" ~type_:"incomplete_stop" (fun stop ->
    Exact.Incomplete_output { stop })

let http_error =
  below cause "Completion_failed" ~file:http ~type_:"http_error" (fun error ->
    Exact.Completion_failed { error; dispatch = Exact.No_generation_dispatch })

let terminal =
  below http_error "ProviderTerminal" ~file:http ~type_:"provider_terminal_kind" (fun kind ->
    Http_client.ProviderTerminal { kind; message = "" })

let failure_kind =
  below http_error "ProviderFailure" ~file:http ~type_:"provider_failure_kind" (fun kind ->
    Http_client.ProviderFailure { kind; message = "" })

let stop_reason =
  below failure_kind "Empty_completion" ~file:"types.mli" ~type_:"stop_reason" (fun stop_reason ->
    Http_client.Empty_completion { stop_reason })

let cli = root ~file:"keeper_lane_cli_oneshot.mli" ~type_:"failure" (fun f -> Visit.Cli (Cli_failed f))

let client =
  below cli "Execution_failed" ~file:"fusion_official_client.mli" ~type_:"failure" (fun cause ->
    Oneshot.Execution_failed { runtime_id = ""; cause })

let codex_file = "runtime_codex_app_server.mli"
let claude_file = "runtime_claude_code.mli"
let codex = below client "Codex_failure" ~file:codex_file ~type_:"error" (fun e -> Client.Codex_failure e)

let codex_info =
  below codex "Turn_failed" ~case:"codex_error_info = Some info" ~file:codex_file
    ~type_:"Codex_error_info.t" (fun info -> Codex.Turn_failed { detail = ""; codex_error_info = Some info })

let claude = below client "Claude_failure" ~file:claude_file ~type_:"error" (fun e -> Client.Claude_failure e)

let claude_admission =
  below client "Claude_admission_failure" ~file:claude_file ~type_:"error" (fun e ->
    Client.Claude_admission_failure e)

let antigravity =
  below client "Antigravity_failure" ~file:"runtime_antigravity.mli" ~type_:"error" (fun e ->
    Client.Antigravity_failure e)

let muse = below client "Muse_failure" ~file:"runtime_muse_serve.mli" ~type_:"error" (fun e -> Client.Muse_failure e)
let host_stop = Codex.Terminal_tool_boundary { tool_name = ""; outcome = Terminal_completed }

let antigravity_usage : Antigravity.usage =
  { input_tokens = 0; output_tokens = 0; thinking_tokens = 0; cache_read_tokens = 0; total_tokens = 0 }

let muse_turn_error quota : Runtime_muse_msp.turn_error =
  { kind = Model_error; message = ""; retryable = false; quota }

let claude_overflow ~tool_effect_attempted ~response_emitted =
  Claude.Context_window_exceeded { message = ""; tool_effect_attempted; response_emitted }

let claude_observation api_error_cause =
  Claude.Turn_failed_with_observation
    { detail = ""
    ; api_error_status = None
    ; api_error_cause
    ; tool_effect_attempted = false
    ; response_emitted = false
    }

let schema_violation =
  Masc.Librarian_answer.Schema_violation { Masc.Keeper_memory_os_types.path = []; reason = Expected_object }

let answer_check = "the Librarian's answer check"

let samples =
  [ at rejection "Runtime_slot_unavailable" Exact.Runtime_slot_unavailable
  ; at rejection "Runtime_contract_rejected" Exact.Runtime_contract_rejected
  ; at rejection "Input_contract_rejected" Exact.Input_contract_rejected
  ; at rejection "Output_requirement_rejected" Exact.Output_requirement_rejected
  ; at rejection "Request_preparation_failed" Exact.Request_preparation_failed
  ; at rejection "Seats_full" Exact.Seats_full
  ; at input_capacity "Token_measurement_required"
      (Exact.Token_measurement_required { accepted_through_tokens = 0; rejected_from_tokens = None })
  ; at input_capacity "Context_window_exceeded"
      (Exact.Context_window_exceeded { input_tokens = 0; reserved_output_tokens = 0; max_context_tokens = 0 })
  ; at token_capacity "Capacity_evidence_not_yet_valid"
      (Exact.Capacity_evidence_not_yet_valid { now_unix_s = 0; checked_at_unix_s = 0 })
  ; at token_capacity "Capacity_evidence_expired"
      (Exact.Capacity_evidence_expired { now_unix_s = 0; expires_at_unix_s = 0 })
  ; at token_capacity "Capacity_boundary_unknown"
      (Exact.Capacity_boundary_unknown
         { input_tokens = 0; accepted_through_tokens = 0; rejected_from_tokens = None })
  ; at token_capacity "Capacity_input_rejected"
      (Exact.Capacity_input_rejected { input_tokens = 0; accepted_through_tokens = 0; rejected_from_tokens = 0 })
  ; at cause "Response_body_deadline_exceeded" Exact.Response_body_deadline_exceeded
  ; at cause "Provider_context_overflow"
      (Exact.Provider_context_overflow
         { error = Http_client.ProviderFailure { kind = Context_overflow { limit = None }; message = "" }
         ; http_status = None
         ; dispatch = Exact.Generation_dispatch_started
         })
  ; at cause "Output_limit_reached" Exact.Output_limit_reached
  ; at cause "Window_reached" (Exact.Window_reached { output = Exact.No_output })
  ; at cause "Window_reached" (Exact.Window_reached { output = Exact.Partial_output })
  ; at cause "Missing_output" Exact.Missing_output
  ; at cause "Ambiguous_output" (Exact.Ambiguous_output 2)
  ; at cause "Unexpected_output_content" Exact.Unexpected_output_content
  ; at cause "Invalid_json_output" Exact.Invalid_json_output
  ; at refusal "Request_body_refused" Exact.Request_body_refused
  ; at refusal "Refusal_body_not_received" Exact.Refusal_body_not_received
  ; at refusal "Rate_limited" Exact.Rate_limited
  ; at refusal "Overloaded" Exact.Overloaded
  ; at refusal "Server_error" Exact.Server_error
  ; at refusal "Auth_failed" Exact.Auth_failed
  ; at refusal "Authorization_refused" Exact.Authorization_refused
  ; at refusal "Payment_required" Exact.Payment_required
  ; at refusal "Invalid_request" Exact.Invalid_request
  ; at refusal "Unclassified_status" Exact.Unclassified_status
  ; at refusal "Not_found" Exact.Not_found
  ; at refusal "Context_overflow" Exact.Context_overflow
  ; at refusal "Input_capacity" Exact.Input_capacity
  ; at refusal "Network_error" Exact.Network_error
  ; at refusal "Connect_failed" Exact.Connect_failed
  ; at refusal "Timeout" Exact.Timeout
  ; at incomplete "End_turn" Exact.End_turn
  ; at incomplete "Tool_use" Exact.Tool_use
  ; at incomplete "Stop_sequence" Exact.Stop_sequence
  ; at incomplete "Refusal" Exact.Refusal
  ; at incomplete "Content_filter" Exact.Content_filter
  ; at incomplete "Repetition_truncation" Exact.Repetition_truncation
  ; at incomplete "Pause_turn" Exact.Pause_turn
  ; at incomplete "Compaction" Exact.Compaction
  ; at incomplete "Unmatched_tool_calls" Exact.Unmatched_tool_calls
  ; at incomplete "Unknown_stop" (Exact.Unknown_stop "")
  ; at http_error "HttpError"
      (Http_client.HttpError { code = 0; body = Http_client.Received ""; retry_after_header = None })
  ; at http_error "NetworkError" (Http_client.NetworkError { message = ""; kind = Connection_refused })
  ; at http_error "Connect_failed" (Http_client.Connect_failed { message = ""; kind = Dns_failure })
  ; at http_error "TimeoutError" (Http_client.TimeoutError { message = ""; phase = Wall_clock })
  ; at http_error "AcceptRejected" (Http_client.AcceptRejected { reason = "" })
  ; at terminal "Session_conflict" Http_client.Session_conflict
  ; at terminal "Other" (Http_client.Other "")
  ; at failure_kind "Capacity_exhausted"
      (Http_client.Capacity_exhausted { scope = Failure_scope_unknown; retry_after = None; model = None })
  ; at failure_kind "Hard_quota" (Http_client.Hard_quota { retry_after = None })
  ; at failure_kind "Capability_mismatch" (Http_client.Capability_mismatch { capability = None })
  ; at failure_kind "Cli_policy_invalid" (Http_client.Cli_policy_invalid { tool_name = None; rule = None })
  ; at failure_kind "Cli_startup_failed"
      (Http_client.Cli_startup_failed { reason = Unknown_cli_startup_failure })
  ; at failure_kind "Provider_parse_error" (Http_client.Provider_parse_error { parser = None })
  ; at failure_kind "Provider_wire_error"
      (Http_client.Provider_wire_error { format = Sse; kind = Malformed_payload })
  ; at failure_kind "Provider_reported_error" (Http_client.Provider_reported_error { error_type = None })
  ; at failure_kind "Provider_interrupted" Http_client.Provider_interrupted
  ; at failure_kind "Response_body_too_large" (Http_client.Response_body_too_large { limit_bytes = 0 })
  ; at failure_kind "Context_overflow" (Http_client.Context_overflow { limit = None })
  ; at failure_kind "Unknown_provider_failure" (Http_client.Unknown_provider_failure { reason = None })
  ; at stop_reason "EndTurn" Stop.EndTurn
  ; at stop_reason "StopToolUse" Stop.StopToolUse
  ; at stop_reason "MaxTokens" Stop.MaxTokens
  ; at stop_reason "StopSequence" Stop.StopSequence
  ; at stop_reason "Refusal" Stop.Refusal
  ; at stop_reason "ContentFilter" Stop.ContentFilter
  ; at stop_reason "RepetitionTruncation" Stop.RepetitionTruncation
  ; at stop_reason "PauseTurn" Stop.PauseTurn
  ; at stop_reason "Compaction" Stop.Compaction
  ; at stop_reason "ContextWindowExceeded" Stop.ContextWindowExceeded
  ; at stop_reason "UnmatchedToolCalls" Stop.UnmatchedToolCalls
  ; at stop_reason "Unknown" (Stop.Unknown "")
  ; at cli "Unknown_runtime" (Oneshot.Unknown_runtime { runtime_id = "" })
  ; at cli "Not_an_official_client" (Oneshot.Not_an_official_client { runtime_id = "" })
  ; at cli "Invalid_json_output" (Oneshot.Invalid_json_output { runtime_id = ""; detail = "" })
  ; at cli "Invalid_domain_output" (Oneshot.Invalid_domain_output { runtime_id = ""; detail = "" })
  ; at cli "Held" (Oneshot.Held { runtime_id = ""; until = 0. })
  ; at client "Missing_reply" Client.Missing_reply
  ; at client "Setup_failure" (Client.Setup_failure "")
  ; at client "Vibe_failure" (Client.Vibe_failure (Vibe_run_failed (Runtime_vibe_cli.Invalid_config "")))
  ; at codex "Invalid_config" (Codex.Invalid_config "")
  ; at codex "Spawn_refused" (Codex.Spawn_refused Process_eio.Empty_argv)
  ; at codex "Reasoning_effort_admission_failed"
      (Codex.Reasoning_effort_admission_failed { model = ""; detail = "" })
  ; at codex "Turn_input_write_failed" (Codex.Turn_input_write_failed "")
  ; at codex "Protocol_error" (Codex.Protocol_error { stage = ""; detail = "" })
  ; at codex "Rpc_error" (Codex.Rpc_error { method_ = ""; code = None; message = ""; data = None })
  ; at codex "Account_read_failed" (Codex.Account_read_failed { code = None; message = ""; data = None })
  ; at codex "Subscription_required" (Codex.Subscription_required "")
  ; at codex "Unsupported_server_request" (Codex.Unsupported_server_request "")
  ; at codex "Context_window_exceeded" ~case:"tool_effect_attempted = false"
      (Codex.Context_window_exceeded { message = ""; tool_effect_attempted = false })
  ; at codex "Context_window_exceeded" ~case:"tool_effect_attempted = true"
      (Codex.Context_window_exceeded { message = ""; tool_effect_attempted = true })
  ; at codex "Turn_failed" ~case:"codex_error_info = None"
      (Codex.Turn_failed { detail = ""; codex_error_info = None })
  ; at codex "Stopped_by_host" (Codex.Stopped_by_host host_stop)
  ; at codex "Turn_interrupted" Codex.Turn_interrupted
  ; at codex "Runtime_shutting_down" Codex.Runtime_shutting_down
  ; at codex "Process_exited" (Codex.Process_exited { detail = ""; turn_accepted = false })
  ; at codex "Timeout" (Codex.Timeout { seconds = 0.; turn_accepted = false })
  ; at codex_info "Session_budget_exceeded" Info.Session_budget_exceeded
  ; at codex_info "Usage_limit_exceeded" Info.Usage_limit_exceeded
  ; at codex_info "Rate_limit_exceeded" Info.Rate_limit_exceeded
  ; at codex_info "Server_overloaded" Info.Server_overloaded
  ; at codex_info "Cyber_policy" Info.Cyber_policy
  ; at codex_info "Misalignment_policy_violation" Info.Misalignment_policy_violation
  ; at codex_info "Internal_server_error" Info.Internal_server_error
  ; at codex_info "Unauthorized" Info.Unauthorized
  ; at codex_info "Bad_request" Info.Bad_request
  ; at codex_info "Thread_rollback_failed" Info.Thread_rollback_failed
  ; at codex_info "Sandbox_error" Info.Sandbox_error
  ; at codex_info "Other" Info.Other
  ; at codex_info "Http_connection_failed" (Info.Http_connection_failed { http_status_code = None })
  ; at codex_info "Response_stream_connection_failed"
      (Info.Response_stream_connection_failed { http_status_code = None })
  ; at codex_info "Response_stream_disconnected" (Info.Response_stream_disconnected { http_status_code = None })
  ; at codex_info "Response_too_many_failed_attempts"
      (Info.Response_too_many_failed_attempts { http_status_code = None })
  ; at codex_info "Active_turn_not_steerable" (Info.Active_turn_not_steerable { turn_kind = Review })
  ; at codex_info "Unrecognized" (Info.Unrecognized `Null)
  ; at claude "Invalid_config" (Claude.Invalid_config "")
  ; at claude "Spawn_refused" (Claude.Spawn_refused Process_eio.Empty_argv)
  ; at claude "Protocol_error" (Claude.Protocol_error { stage = ""; detail = "" })
  ; at claude_admission "Subscription_required" (Claude.Subscription_required "")
  ; at claude "Unsupported_control_request" (Claude.Unsupported_control_request "")
  ; at claude "Turn_transport_interrupted"
      (Claude.Turn_transport_interrupted { stage = ""; tool_effect_attempted = false; detail = "" })
  ; at claude "Context_window_exceeded" ~case:"tool_effect_attempted = false and response_emitted = false"
      (claude_overflow ~tool_effect_attempted:false ~response_emitted:false)
  ; at claude "Context_window_exceeded" ~case:"tool_effect_attempted = true or response_emitted = true"
      (claude_overflow ~tool_effect_attempted:true ~response_emitted:false)
  ; at claude "Context_window_exceeded" ~case:"tool_effect_attempted = true or response_emitted = true"
      (claude_overflow ~tool_effect_attempted:false ~response_emitted:true)
  ; at claude "Turn_failed" (Claude.Turn_failed "")
  ; at claude "Turn_failed_with_observation" ~case:"api_error_cause = Some Authentication_failed"
      (claude_observation (Some Authentication_failed))
  ; at claude "Turn_failed_with_observation" ~case:"api_error_cause = None or Some Other_api_error_cause"
      (claude_observation None)
  ; at claude "Turn_failed_with_observation" ~case:"api_error_cause = None or Some Other_api_error_cause"
      (claude_observation (Some Other_api_error_cause))
  ; at claude "Stopped_by_host" (Claude.Stopped_by_host { stop = host_stop; latest_request_input = None })
  ; at claude "Quota_blocked"
      (Claude.Quota_blocked
         { api_error_status = None; block = Rate_throttled; tool_effect_attempted = false; response_emitted = false })
  ; at claude "Process_exited" (Claude.Process_exited { detail = ""; turn_admitted = false })
  ; at claude "Unhandled_exception" (Claude.Unhandled_exception "")
  ; at claude "Timeout" (Claude.Timeout 0.)
  ; at antigravity "Invalid_config" (Antigravity.Invalid_config "")
  ; at antigravity "Spawn_refused" (Antigravity.Spawn_refused Process_eio.Empty_argv)
  ; at antigravity "Spawn_capacity_busy" (Antigravity.Spawn_capacity_busy { waited_s = 0.; limit_s = 0. })
  ; at antigravity "Protocol_error" (Antigravity.Protocol_error { stage = ""; detail = "" })
  ; at antigravity "State_callback_failed" (Antigravity.State_callback_failed "")
  ; at antigravity "Turn_failed" (Antigravity.Turn_failed "")
  ; at antigravity "Result_not_completed"
      (Antigravity.Result_not_completed
         { status = Canceled
         ; conversation_id = None
         ; response = ""
         ; error = None
         ; num_turns = 0
         ; usage = antigravity_usage
         ; denied = None
         })
  ; at antigravity "Actions_denied"
      (Antigravity.Actions_denied
         { conversation_id = ""
         ; model = ""
         ; denied = { first = ""; rest = [] }
         ; response = ""
         ; num_turns = 0
         ; usage = antigravity_usage
         ; tool_steps = 0
         ; stderr_tail = ""
         })
  ; at antigravity "Process_exited" (Antigravity.Process_exited "")
  ; at antigravity "Unhandled_exception" (Antigravity.Unhandled_exception "")
  ; at antigravity "Child_fd_ceiling_exceeded" (Antigravity.Child_fd_ceiling_exceeded { count = None; ceiling = 0 })
  ; at antigravity "Timeout" (Antigravity.Timeout 0.)
  ; at muse "Invalid_config" (Muse.Invalid_config "")
  ; at muse "Spawn_refused" (Muse.Spawn_refused Process_eio.Empty_argv)
  ; at muse "Turn_input_write_failed" (Muse.Turn_input_write_failed "")
  ; at muse "Protocol_error" (Muse.Protocol_error { stage = ""; detail = "" })
  ; at muse "Rpc_error" (Muse.Rpc_error { method_ = ""; code = 0; message = "" })
  ; at muse "Capability_not_granted" (Muse.Capability_not_granted Session_mcp)
  ; at muse "Session_not_durable" Muse.Session_not_durable
  ; at muse "Session_model_mismatch" (Muse.Session_model_mismatch { requested = ""; resumed = None })
  ; at muse "Session_workspace_mismatch" (Muse.Session_workspace_mismatch { requested = ""; reported = None })
  ; at muse "Session_approval_mode_mismatch"
      (Muse.Session_approval_mode_mismatch { requested = Allow_all; reported = None })
  ; at muse "Auth_required" (Muse.Auth_required "")
  ; at muse "Turn_failed" ~case:"quota = Some _"
      (Muse.Turn_failed (muse_turn_error (Some { limit_kind = ""; resets_at_ms = 0 })))
  ; at muse "Turn_failed" ~case:"quota = None" (Muse.Turn_failed (muse_turn_error None))
  ; at muse "Turn_cancelled" Muse.Turn_cancelled
  ; at muse "Unsupported_server_request" (Muse.Unsupported_server_request "")
  ; at muse "Runtime_shutting_down" Muse.Runtime_shutting_down
  ; at muse "Process_exited" (Muse.Process_exited { status = None; detail = ""; turn_accepted = false })
  ; at muse "Timeout" (Muse.Timeout { seconds = 0.; turn_accepted = false })
  ; plain "the ask's own fold" "a declared slot with no visit" Visit.Not_visited
  ; plain "Runtime_exact_lane_backpressure.order" "a slot in held_http" (Visit.Http Held)
  ; plain answer_check "Not_json" (Visit.Http (Answer_rejected Not_json))
  ; plain answer_check "Not_json" (Visit.Cli (Cli_answer_rejected Not_json))
  ; plain answer_check "Schema_violation" (Visit.Http (Answer_rejected schema_violation))
  ; plain answer_check "Schema_violation" (Visit.Cli (Cli_answer_rejected schema_violation))
  ; plain answer_check "Echo_mismatch" (Visit.Http (Answer_rejected Echo_mismatch))
  ; plain answer_check "Echo_mismatch" (Visit.Cli (Cli_answer_rejected Echo_mismatch))
  ; plain answer_check "Empty_or_partial" (Visit.Http (Answer_rejected Empty_or_partial))
  ; plain answer_check "Empty_or_partial" (Visit.Cli (Cli_answer_rejected Empty_or_partial))
  ; plain answer_check "accepted" (Visit.Http Answer_accepted)
  ; plain answer_check "accepted" (Visit.Cli Cli_answer_accepted)
  ]

let every_row_gives_its_outcome () =
  let table = table () in
  let outcome row =
    match List.assoc_opt row table with
    | Some outcome -> outcome
    | None -> Alcotest.failf "no row: %s" (row_text row)
  in
  let rec follow visit = function
    | [] -> Alcotest.fail "a sample names no row"
    | [ last ] -> Alcotest.(check string) (row_text last) (outcome last) (outcome_text (Visit.classify visit))
    | row :: (next :: _ as rest) ->
      (match next with
       | Constructor { file; type_; _ } ->
         Alcotest.(check string) (row_text row) ("> " ^ file ^ " " ^ type_) (outcome row)
       | Not_constructor _ -> Alcotest.failf "%s is followed by a visit" (row_text row));
      follow visit rest
  in
  List.iter (fun { rows; visit } -> follow visit rows) samples;
  let passed = List.concat_map (fun { rows; _ } -> rows) samples in
  List.iter
    (fun (row, _) ->
      if not (List.mem row passed) then Alcotest.failf "no sample passes %s" (row_text row))
    table

let () =
  Alcotest.run "librarian_slot_visit"
    [ "table", [ Alcotest.test_case "every row gives its outcome" `Quick every_row_gives_its_outcome ] ]
