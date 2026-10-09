type status =
  | Task_pending | Task_running | Task_completed | Task_failed | Task_killed | Task_paused

type terminal = Task_completed_notice | Task_failed_notice | Task_stopped_notice
type reason = Worker_restart
type boundary = Task_terminal_unobserved | Task_terminal_observed
type usage = { total_tokens : int; tool_uses : int; duration_ms : int }

type event =
  | Task_registered of
      { subagent_type : string option; is_backgrounded : bool option
      ; skip_transcript : bool option; ambient : bool option }
  | Task_patched of
      { status : status option; is_backgrounded : bool option
      ; end_time : int option; total_paused_ms : int option }
  | Task_progress_reported of { usage : usage; last_tool_name : string option }
  | Task_terminal_reported of
      { outcome : terminal; reason : reason option; usage : usage option
      ; skip_transcript : bool option; ambient : bool option }

type source =
  | Operation of { operation_id : string }
  | Autonomous_turn of { turn_ref : string }

type attempt =
  { routing_run_id : string; runtime_id : string; lane_attempt_index : int }
type invocation =
  { receiver_generation : string; session_id : string; client_uuid : string }
type native_call =
  { session_id : string; call_id : string; call_envelope_uuid : string; call_ordinal : int }
type origin =
  { keeper_name : string; source : source; attempt : attempt
  ; invocation : invocation; native_call : native_call
  ; task_id : string; run_id : string }
type t = { origin : origin; uuid : string; event : event; boundary : boundary }

let ( let* ) = Result.bind

let validate_integer ~field value =
  Runtime_json_integer.of_json (`Int value)
  |> Result.map (fun _ -> ())
  |> Result.map_error (fun detail -> field ^ ": " ^ detail)

let validate_index ~field value =
  let* () = validate_integer ~field value in
  if value < 0 then Error (field ^ " must be nonnegative") else Ok ()

let validate_optional validate = function
  | None -> Ok ()
  | Some value -> validate value

let validate_usage usage =
  let* () = validate_integer ~field:"usage.total_tokens" usage.total_tokens in
  let* () = validate_integer ~field:"usage.tool_uses" usage.tool_uses in
  validate_integer ~field:"usage.duration_ms" usage.duration_ms

let validate_event event boundary =
  let boundary_is expected =
    if boundary = expected then Ok ()
    else Error "native task event contradicts its terminal boundary" in
  match event with
  | Task_registered _ -> boundary_is Task_terminal_unobserved
  | Task_progress_reported {usage; _} ->
      let* () = validate_usage usage in
      boundary_is Task_terminal_unobserved
  | Task_patched {status; end_time; total_paused_ms; _} ->
      let* () = validate_optional (validate_integer ~field:"end_time") end_time in
      let* () = validate_optional (validate_integer ~field:"total_paused_ms") total_paused_ms in
      (match status with
       | None -> Ok ()
       | Some (Task_pending | Task_running | Task_paused) -> boundary_is Task_terminal_unobserved
       | Some (Task_completed | Task_failed | Task_killed) -> boundary_is Task_terminal_observed)
  | Task_terminal_reported {outcome; reason; usage; _} ->
      let* () = validate_optional validate_usage usage in
      let* () = match reason, outcome with
        | Some Worker_restart, (Task_completed_notice | Task_failed_notice) ->
            Error "worker_restart requires a stopped task notification"
        | None, (Task_completed_notice | Task_failed_notice | Task_stopped_notice)
        | Some Worker_restart, Task_stopped_notice -> Ok () in
      boundary_is Task_terminal_observed

let make ~origin ~uuid ~event ~boundary =
  let* () = validate_index ~field:"attempt.lane_attempt_index" origin.attempt.lane_attempt_index in
  let* () = validate_index ~field:"native_call.call_ordinal" origin.native_call.call_ordinal in
  let* () = if origin.invocation.session_id = origin.native_call.session_id then Ok ()
    else Error "native task invocation and original native call sessions differ" in
  let* () = validate_event event boundary in
  Ok {origin; uuid; event; boundary}

let status_to_string = function
  | Task_pending -> "pending" | Task_running -> "running"
  | Task_completed -> "completed" | Task_failed -> "failed"
  | Task_killed -> "killed" | Task_paused -> "paused"

let terminal_to_string = function
  | Task_completed_notice -> "completed" | Task_failed_notice -> "failed"
  | Task_stopped_notice -> "stopped"

let boundary_to_string = function
  | Task_terminal_unobserved -> "terminal_unobserved"
  | Task_terminal_observed -> "terminal_observed"

let optional key encode = function None -> [] | Some value -> [key, encode value]
let string value = `String value
let integer value = `Int value
let boolean value = `Bool value

let usage_to_json usage =
  `Assoc ["total_tokens", integer usage.total_tokens; "tool_uses", integer usage.tool_uses;
    "duration_ms", integer usage.duration_ms]

let event_to_json = function
  | Task_registered value ->
      `Assoc (["kind", string "registered"]
        @ optional "subagent_type" string value.subagent_type
        @ optional "is_backgrounded" boolean value.is_backgrounded
        @ optional "skip_transcript" boolean value.skip_transcript
        @ optional "ambient" boolean value.ambient)
  | Task_patched value ->
      `Assoc (["kind", string "patched"]
        @ optional "status" (fun status -> string (status_to_string status)) value.status
        @ optional "is_backgrounded" boolean value.is_backgrounded
        @ optional "end_time" integer value.end_time
        @ optional "total_paused_ms" integer value.total_paused_ms)
  | Task_progress_reported value ->
      `Assoc (["kind", string "progress_reported"; "usage", usage_to_json value.usage]
        @ optional "last_tool_name" string value.last_tool_name)
  | Task_terminal_reported value ->
      `Assoc (["kind", string "terminal_reported"; "outcome", string (terminal_to_string value.outcome)]
        @ optional "reason" (function Worker_restart -> string "worker_restart") value.reason
        @ optional "usage" usage_to_json value.usage
        @ optional "skip_transcript" boolean value.skip_transcript
        @ optional "ambient" boolean value.ambient)

let source_to_json = function
  | Operation {operation_id} -> `Assoc ["kind", string "operation"; "operation_id", string operation_id]
  | Autonomous_turn {turn_ref} -> `Assoc ["kind", string "autonomous_turn"; "turn_ref", string turn_ref]

let schema = "masc.native_task_observation.v1"

let to_json value =
  let origin = value.origin in
  `Assoc
    [ "schema", string schema
    ; "origin", `Assoc
        [ "keeper_name", string origin.keeper_name
        ; "source", source_to_json origin.source
        ; "attempt", `Assoc ["routing_run_id", string origin.attempt.routing_run_id;
            "runtime_id", string origin.attempt.runtime_id;
            "lane_attempt_index", integer origin.attempt.lane_attempt_index]
        ; "invocation", `Assoc ["receiver_generation", string origin.invocation.receiver_generation;
            "session_id", string origin.invocation.session_id; "client_uuid", string origin.invocation.client_uuid]
        ; "native_call", `Assoc ["session_id", string origin.native_call.session_id;
            "call_id", string origin.native_call.call_id;
            "call_envelope_uuid", string origin.native_call.call_envelope_uuid;
            "call_ordinal", integer origin.native_call.call_ordinal]
        ; "task_id", string origin.task_id; "run_id", string origin.run_id ]
    ; "uuid", string value.uuid
    ; "event", event_to_json value.event
    ; "boundary", string (boundary_to_string value.boundary) ]

let unique_fields ~surface (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
      let rec check seen = function
        | [] -> Ok fields
        | (key, _) :: rest ->
            if List.mem key seen then Error (surface ^ ": duplicate field " ^ key)
            else check (key :: seen) rest in
      check [] fields
  | _ -> Error (surface ^ " must be an object")

let object_fields ~surface ~allowed json =
  let* fields = unique_fields ~surface json in
  match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
  | None -> Ok fields
  | Some (key, _) -> Error (surface ^ ": unknown field " ^ key)

let required parse ~field fields =
  match List.assoc_opt field fields with
  | None -> Error (field ^ " is required")
  | Some json -> parse json |> Result.map_error (fun detail -> field ^ ": " ^ detail)

let optional_field parse ~field fields =
  match List.assoc_opt field fields with
  | None -> Ok None
  | Some json -> parse json |> Result.map Option.some
      |> Result.map_error (fun detail -> field ^ ": " ^ detail)

let parse_string = function
  | `String value -> Ok value
  | _ -> Error "expected a string"

let parse_bool = function
  | `Bool value -> Ok value
  | _ -> Error "expected a boolean"

let parse_status = function
  | `String "pending" -> Ok Task_pending | `String "running" -> Ok Task_running
  | `String "completed" -> Ok Task_completed | `String "failed" -> Ok Task_failed
  | `String "killed" -> Ok Task_killed | `String "paused" -> Ok Task_paused
  | _ -> Error "unknown task status"

let parse_terminal = function
  | `String "completed" -> Ok Task_completed_notice | `String "failed" -> Ok Task_failed_notice
  | `String "stopped" -> Ok Task_stopped_notice
  | _ -> Error "unknown task terminal outcome"

let parse_reason = function
  | `String "worker_restart" -> Ok Worker_restart
  | _ -> Error "unknown task reason"

let parse_boundary = function
  | `String "terminal_unobserved" -> Ok Task_terminal_unobserved
  | `String "terminal_observed" -> Ok Task_terminal_observed
  | _ -> Error "unknown task terminal boundary"

let usage_of_json json =
  let* fields = object_fields ~surface:"usage" ~allowed:["total_tokens";"tool_uses";"duration_ms"] json in
  let* total_tokens = required Runtime_json_integer.of_json ~field:"total_tokens" fields in
  let* tool_uses = required Runtime_json_integer.of_json ~field:"tool_uses" fields in
  let* duration_ms = required Runtime_json_integer.of_json ~field:"duration_ms" fields in
  Ok {total_tokens;tool_uses;duration_ms}

let event_of_json json =
  (* Read the discriminant only after checking duplicate keys. Variant-specific
     exact fields are checked below before any record is constructed. *)
  let* fields = unique_fields ~surface:"event" json in
  let* kind = required parse_string ~field:"kind" fields in
  let exact allowed = object_fields ~surface:"event" ~allowed:("kind" :: allowed) json in
  match kind with
  | "registered" ->
      let* fields = exact ["subagent_type";"is_backgrounded";"skip_transcript";"ambient"] in
      let* subagent_type = optional_field parse_string ~field:"subagent_type" fields in
      let* is_backgrounded = optional_field parse_bool ~field:"is_backgrounded" fields in
      let* skip_transcript = optional_field parse_bool ~field:"skip_transcript" fields in
      let* ambient = optional_field parse_bool ~field:"ambient" fields in
      Ok (Task_registered {subagent_type;is_backgrounded;skip_transcript;ambient})
  | "patched" ->
      let* fields = exact ["status";"is_backgrounded";"end_time";"total_paused_ms"] in
      let* status = optional_field parse_status ~field:"status" fields in
      let* is_backgrounded = optional_field parse_bool ~field:"is_backgrounded" fields in
      let* end_time = optional_field Runtime_json_integer.of_json ~field:"end_time" fields in
      let* total_paused_ms = optional_field Runtime_json_integer.of_json ~field:"total_paused_ms" fields in
      Ok (Task_patched {status;is_backgrounded;end_time;total_paused_ms})
  | "progress_reported" ->
      let* fields = exact ["usage";"last_tool_name"] in
      let* usage = required usage_of_json ~field:"usage" fields in
      let* last_tool_name = optional_field parse_string ~field:"last_tool_name" fields in
      Ok (Task_progress_reported {usage;last_tool_name})
  | "terminal_reported" ->
      let* fields = exact ["outcome";"reason";"usage";"skip_transcript";"ambient"] in
      let* outcome = required parse_terminal ~field:"outcome" fields in
      let* reason = optional_field parse_reason ~field:"reason" fields in
      let* usage = optional_field usage_of_json ~field:"usage" fields in
      let* skip_transcript = optional_field parse_bool ~field:"skip_transcript" fields in
      let* ambient = optional_field parse_bool ~field:"ambient" fields in
      Ok (Task_terminal_reported {outcome;reason;usage;skip_transcript;ambient})
  | _ -> Error "unknown native task event kind"

let source_of_json json =
  let* fields = unique_fields ~surface:"source" json in
  let* kind = required parse_string ~field:"kind" fields in
  match kind with
  | "operation" ->
      let* fields = object_fields ~surface:"source" ~allowed:["kind";"operation_id"] json in
      let* operation_id = required parse_string ~field:"operation_id" fields in
      Ok (Operation {operation_id})
  | "autonomous_turn" ->
      let* fields = object_fields ~surface:"source" ~allowed:["kind";"turn_ref"] json in
      let* turn_ref = required parse_string ~field:"turn_ref" fields in
      Ok (Autonomous_turn {turn_ref})
  | _ -> Error "unknown native task source kind"

let attempt_of_json json =
  let* fields = object_fields ~surface:"attempt" ~allowed:["routing_run_id";"runtime_id";"lane_attempt_index"] json in
  let* routing_run_id = required parse_string ~field:"routing_run_id" fields in
  let* runtime_id = required parse_string ~field:"runtime_id" fields in
  let* lane_attempt_index = required Runtime_json_integer.of_json ~field:"lane_attempt_index" fields in
  Ok {routing_run_id;runtime_id;lane_attempt_index}

let invocation_of_json json =
  let* fields = object_fields ~surface:"invocation" ~allowed:["receiver_generation";"session_id";"client_uuid"] json in
  let* receiver_generation = required parse_string ~field:"receiver_generation" fields in
  let* session_id = required parse_string ~field:"session_id" fields in
  let* client_uuid = required parse_string ~field:"client_uuid" fields in
  Ok {receiver_generation;session_id;client_uuid}

let native_call_of_json json =
  let* fields = object_fields ~surface:"native_call" ~allowed:["session_id";"call_id";"call_envelope_uuid";"call_ordinal"] json in
  let* session_id = required parse_string ~field:"session_id" fields in
  let* call_id = required parse_string ~field:"call_id" fields in
  let* call_envelope_uuid = required parse_string ~field:"call_envelope_uuid" fields in
  let* call_ordinal = required Runtime_json_integer.of_json ~field:"call_ordinal" fields in
  Ok {session_id;call_id;call_envelope_uuid;call_ordinal}

let origin_of_json json =
  let* fields = object_fields ~surface:"origin" ~allowed:["keeper_name";"source";"attempt";
    "invocation";"native_call";"task_id";"run_id"] json in
  let* keeper_name = required parse_string ~field:"keeper_name" fields in
  let* source = required source_of_json ~field:"source" fields in
  let* attempt = required attempt_of_json ~field:"attempt" fields in
  let* invocation = required invocation_of_json ~field:"invocation" fields in
  let* native_call = required native_call_of_json ~field:"native_call" fields in
  let* task_id = required parse_string ~field:"task_id" fields in
  let* run_id = required parse_string ~field:"run_id" fields in
  Ok {keeper_name;source;attempt;invocation;native_call;task_id;run_id}

let of_json json =
  let* fields = object_fields ~surface:"native task observation"
    ~allowed:["schema";"origin";"uuid";"event";"boundary"] json in
  let* received_schema = required parse_string ~field:"schema" fields in
  let* () = if received_schema = schema then Ok ()
    else Error "unsupported native task observation schema" in
  let* origin = required origin_of_json ~field:"origin" fields in
  let* uuid = required parse_string ~field:"uuid" fields in
  let* event = required event_of_json ~field:"event" fields in
  let* boundary = required parse_boundary ~field:"boundary" fields in
  make ~origin ~uuid ~event ~boundary

let redact redact_text value =
  let event = match value.event with
    | Task_registered event ->
        Task_registered {event with subagent_type=Option.map redact_text event.subagent_type}
    | Task_progress_reported event ->
        Task_progress_reported {event with last_tool_name=Option.map redact_text event.last_tool_name}
    | (Task_patched _ | Task_terminal_reported _) as event -> event in
  {value with event}
