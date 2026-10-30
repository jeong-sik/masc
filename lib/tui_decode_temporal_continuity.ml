open Tui_decode_fields
let ( let* ) = Result.bind

type provenance = Live_keeper | Assessment
type capture_status = Recording | Recorded | Incomplete
type step_kind = Message | Restart | Await_summary
type step_status = Started | Collecting | Captured | Restart_observed | Summary_ready_observed
type scope = Reply | Working_state | Tool_calls
type judgment_result = Unavailable | Pending | Measured of { probability : float; model : string }
type judgment = { criterion_id : string; scope : scope; result : judgment_result }
type request_range = { capture_id : string; body_sha256 : string; first_atom : int; summary_end_atom : int option }
type omission_detail = { target_end_atom : int; requests : request_range list }
type omission = Not_requested | Omission_unavailable of string | Not_observed of string * omission_detail | Observed of omission_detail
type step = {
  id : string; kind : step_kind; status : step_status;
  operation_state : string option; turn_ref : string option;
  working_state_messages : int option; working_state : Yojson.Safe.t list option; reply : string list;
  omission : omission; target_end_atom : int option; judgments : judgment list;
}
type t = {
  keeper : string; provenance : provenance; status : capture_status;
  started_at : string; finished_at : string option; error : string option;
  report_path : string; report_sha256 : string; harness_source_sha256 : string;
  source_capture_sha256 : string option; binary_commit : string option;
  executable_sha256 : string option; timeline : step list;
}

let schema = "masc.keeper-temporal-continuity-view.v1"

let choice json field choices =
  let* value = required_string_field json field in
  match List.assoc_opt value choices with
  | Some value -> Ok value
  | None -> Error (field ^ ": unsupported value " ^ value)

let sha256 value =
  match Tool_blob_store.validate_sha256 value with
  | Ok () -> Ok value
  | Error error -> Error (Tool_blob_store.invalid_sha256_to_string error)

let required_sha256 json field =
  let* value = required_string_field json field in sha256 value

let nullable_sha256 json field =
  let* value = required_nullable_string_field json field in
  match value with None -> Ok None | Some value -> Result.map Option.some (sha256 value)

let nullable_natural json field =
  let* value = required_nullable_int_field json field in
  match value with
  | Some value when value < 0 -> Error (field ^ ": expected a nonnegative integer")
  | value -> Ok value

let target_boundary = function
  | `Null -> Ok None
  | json -> Result.map Option.some (required_nonnegative_int_field json "end_atom")

let request_range json =
  let* capture_id = required_nonempty_string_field json "capture_id" in
  let* body_sha256 = required_sha256 json "body_sha256" in
  let* first_atom = required_nonnegative_int_field json "first_atom" in
  let* summary_end_atom = nullable_natural json "summary_end_atom" in
  Ok { capture_id; body_sha256; first_atom; summary_end_atom }

let omission_detail json =
  let* boundary = required_object_field json "target_boundary" in
  let* target_end_atom = required_nonnegative_int_field boundary "end_atom" in
  let* rows = required_list_field json "requests" in
  let* requests = decode_list "requests" request_range rows in
  Ok { target_end_atom; requests }

let omission = function
  | `Null -> Ok Not_requested
  | json ->
    let* status = required_string_field json "status" in
    match status with
    | "unavailable" ->
      let* reason = required_string_field json "reason" in Ok (Omission_unavailable reason)
    | "not_observed" ->
      let* reason = required_string_field json "reason" in
      let* detail = omission_detail json in Ok (Not_observed (reason, detail))
    | "observed" ->
      let* detail = omission_detail json in
      if detail.requests = [] || List.exists (fun request ->
          request.first_atom < detail.target_end_atom ||
          match request.summary_end_atom with
          | None -> true | Some end_atom -> end_atom < detail.target_end_atom) detail.requests
      then Error "observed omission requires covering W and every request beyond the target"
      else Ok (Observed detail)
    | _ -> Error ("prefix_omission: unsupported status " ^ status)

let judgment json =
  let* criterion_id = required_nonempty_string_field json "criterion_id" in
  let* scope = choice json "scope" ["reply", Reply; "working_state", Working_state; "tool_calls", Tool_calls] in
  let* status = required_string_field json "status" in
  let* result = match status with
    | "unavailable" -> Ok Unavailable
    | "started" -> Ok Pending
    | "measured" ->
      let* probability = required_nullable_float_field json "probability" in
      let* model = required_nonempty_string_field json "response_model" in
      (match probability with
       | Some probability when Float.is_finite probability && probability >= 0. && probability <= 1. ->
         Ok (Measured { probability; model })
       | _ -> Error "measured judgment requires a finite probability in [0,1]")
    | _ -> Error ("judgment: unsupported status " ^ status) in
  Ok { criterion_id; scope; result }

let step json =
  let* id = required_nonempty_string_field json "step_id" in
  let* kind = choice json "kind" ["message", Message; "restart", Restart; "await_summary", Await_summary] in
  let* status = choice json "status"
      ["started", Started; "collecting", Collecting; "captured", Captured;
       "restart_observed", Restart_observed; "summary_ready_observed", Summary_ready_observed] in
  let* operation_state = required_nullable_string_field json "operation_state" in
  let* () = match operation_state with
    | None | Some ("Queued" | "Running" | "Succeeded" | "Failed" | "Cancelled") -> Ok ()
    | Some value -> Error ("unsupported operation state " ^ value) in
  let* turn_ref = required_nullable_string_field json "turn_ref" in
  let* working_state_messages = nullable_natural json "working_state_messages" in
  let* raw_state = required_member json "working_state" in
  let* working_state = match raw_state, working_state_messages with
    | `Null, None -> Ok None
    | `List rows, Some count when List.length rows = count -> Ok (Some rows)
    | _ -> Error "working state messages and their observed count differ" in
  let* reply = require_string_list json "reply" in
  let* omitted = required_member json "prefix_omission" in
  let* omission = omission omitted in
  let* boundary = required_member json "target_boundary" in
  let* target_end_atom = target_boundary boundary in
  let* rows = required_list_field json "judgments" in
  let* judgments = decode_list "judgments" judgment rows in
  Ok { id; kind; status; operation_state; turn_ref; working_state_messages; working_state; reply;
       omission; target_end_atom; judgments }

let of_yojson json =
  let* _ = choice json "schema" [schema, ()] in
  let* keeper = required_nonempty_string_field json "keeper" in
  let* provenance = choice json "provenance"
      ["live_keeper", Live_keeper; "assessment_of_captured_keeper_evidence", Assessment] in
  let* status = choice json "measurement_status"
      ["recording", Recording; "recorded", Recorded; "incomplete", Incomplete] in
  let* started_at = required_string_field json "started_at" in
  let* finished_at = required_nullable_string_field json "finished_at" in
  let* error = required_nullable_string_field json "error" in
  let* report_path = required_nonempty_string_field json "report_path" in
  let* report_sha256 = required_sha256 json "report_sha256" in
  let* harness_source_sha256 = required_sha256 json "harness_source_sha256" in
  let* source_capture_sha256 = nullable_sha256 json "source_capture_sha256" in
  let* binary_commit = required_nullable_string_field json "binary_commit" in
  let* executable_sha256 = nullable_sha256 json "executable_sha256" in
  let* () = require_null_field json "continuity_pass" in
  let* _ = choice json "body_response_binding" ["not_established", ()] in
  let* _ = choice json "librarian_causal_attribution" ["not_established", ()] in
  let* rows = required_list_field json "timeline" in
  let* timeline = decode_list "timeline" step rows in
  Ok { keeper; provenance; status; started_at; finished_at; error; report_path;
       report_sha256; harness_source_sha256; source_capture_sha256; binary_commit;
       executable_sha256; timeline }
