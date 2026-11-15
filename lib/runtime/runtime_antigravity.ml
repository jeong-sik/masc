(** Official Antigravity CLI single-turn execution.

    The [agy] process owns its OAuth session, model turn, and built-in agent
    tools. MASC owns argv construction, environment admission, process
    lifetime, strict stream-json decoding, and durable conversation identity. *)

module Protocol = Runtime_antigravity_protocol

type effort =
  | Low
  | Medium
  | High

type execution_mode =
  | Plan
  | Accept_edits

type config =
  { cli_path : string
  ; cwd : string
  ; add_dirs : string list
  ; model : string
  ; agent : string option
  ; effort : effort option
  ; execution_mode : execution_mode
  ; sandbox : bool
  ; disable_slash_commands : bool
  ; admission_timeout_s : float
  ; timeout_s : float option
  ; output_schema : Yojson.Safe.t option
  }

let default_timeout_s = 300.0

(* How long a CLI that already delivered its result event may take to
   exit before we reap it. A healthy CLI exits well under a second after
   the result; the #28912 shutdown hang ("Waiting for migrations to
   complete", a child language server holding stdout open) never exits at
   all, so anything past this window is the hang, not slow work — the
   turn itself is already complete and none of this wait is on the
   critical path of a healthy turn. *)
let result_exit_grace_s = 5.0

(* [None] installs no deadline. The vendor client owns when its own turn ends;
   a declared bound is the operator's optional liveness guard over a silent
   client, not a limit on how long legitimate work may take. *)
let stderr_chunk_bytes = 4096
let stderr_tail_bytes = 8192

(* The empty-success rejection carries what a bare sentence cannot: the model
   that answered blank, how far the trajectory got, and the CLI's own last
   words on stderr — the split between a model that ended a tool-only turn
   without a reply and a vendor that dressed a quota or auth refusal up as a
   successful empty result. The stderr byte budget bounds what reaches the
   session log and the dashboard. *)
let empty_success_detail_prefix = "successful result response has no deliverable content"

let empty_success_stderr_bytes = 200

(* Both process-exit and empty-success details pass through the same masking
   boundary before projection. The shared structural patterns preserve useful
   diagnostics while masking credentials, including standalone token values. *)
let redact_stderr_tail = Secret_patterns.redact_text

(* Cut at a UTF-8 character boundary — String_util is the SSOT for that
   rule (#39090), so a Korean stderr line never breaks mid-character. *)
let diagnostic_stderr_tail stderr =
  String_util.utf8_suffix ~max_bytes:empty_success_stderr_bytes
    (redact_stderr_tail (String.trim stderr))
;;

let empty_success_detail ~model ~tool_steps stderr =
  let stderr_tail = diagnostic_stderr_tail stderr in
  if stderr_tail = "" then
    Printf.sprintf "%s (model=%s, tool_steps=%d, stderr=<empty>)"
      empty_success_detail_prefix model tool_steps
  else
    Printf.sprintf "%s (model=%s, tool_steps=%d, stderr tail: %s)"
      empty_success_detail_prefix model tool_steps stderr_tail

(* A refusal's stderr is read from its first words: agy's closing sentence
   opens by naming what was refused and why, and anything it printed about
   the refused call comes before that sentence. The empty-success suffix cut
   that opening off (#50291), so a refusal keeps both ends of the retained
   stderr and counts the bytes it leaves out of the middle. The tail budget
   holds the closing sentence whole; the one measured on 2026-11-09 is 298
   bytes. *)
let denied_stderr_head_bytes = 512
let denied_stderr_tail_bytes = 1024

let denied_stderr_excerpt stderr =
  let redacted = redact_stderr_tail (String.trim stderr) in
  (* The retained stderr is the end of a byte ring and may begin inside a
     character; [utf8_suffix] drops those leading continuation bytes. *)
  let text = String_util.utf8_suffix ~max_bytes:(String.length redacted) redacted in
  if String.length text <= denied_stderr_head_bytes + denied_stderr_tail_bytes
  then text
  else (
    let head = String_util.utf8_prefix ~max_bytes:denied_stderr_head_bytes text in
    let tail = String_util.utf8_suffix ~max_bytes:denied_stderr_tail_bytes text in
    Printf.sprintf "%s ... [%d bytes omitted] ... %s"
      head
      (String.length text - String.length head - String.length tail)
      tail)
;;

let max_wire_line_bytes = 8 * 1024 * 1024

(* [--print-timeout] is a wall-clock deadline owned by agy, not an idle
   deadline. It ended a live turn after 9.45s despite an agent response, a
   completed 4.25s tool, and a checkpoint inside a 10s window (agy 1.1.12,
   2026-08-11). MASC owns liveness below by timing each JSONL read, so the CLI
   deadline must be non-authoritative. This is Go's maximum time.Duration,
   accepted by the installed CLI; it is finite and therefore keeps argv strict
   without imposing a practical wall-clock ceiling. *)
let cli_non_authoritative_timeout = "2562047h47m16.854775807s"

let default_config ~cwd ~model =
  { cli_path = "agy"
  ; cwd
  ; add_dirs = []
  ; model
  ; agent = None
  ; effort = None
  ; execution_mode = Plan
  ; sandbox = false
  ; disable_slash_commands = true
  ; admission_timeout_s = default_timeout_s
  ; timeout_s = Some default_timeout_s
  ; output_schema = None
  }
;;

(* Which liveness bound the next read runs under, decided by what the CLI
   said last. agy narrates a trajectory one step at a time and writes nothing
   while a tool step runs: the step's output arrives in its DONE (or ERROR)
   update. Silence inside a tool step is the protocol, not a client that has
   gone away, so the model-turn bound ([timeout_s], 300s) must not cap it —
   but the phase still needs a backstop, or a wedged tool holds its CLI
   spawn slot forever (#43259): 2h of total event silence is past any
   plausible healthy tool, and the kill is a typed, visible Timeout rather
   than a hang. The owner retains cancellation authority throughout. *)
type read_phase = Protocol.read_phase =
  | Awaiting_admission
  | Model_turn
  | Tool_step_running

let tool_step_idle_timeout_s = 7200.0

let timeout_s_for_phase config = function
  | Awaiting_admission -> Some config.admission_timeout_s
  | Model_turn -> config.timeout_s
  | Tool_step_running -> Some tool_step_idle_timeout_s
;;

type conversation_mode = Protocol.conversation_mode =
  | Start
  | Resume of { conversation_id : string }

type usage = Protocol.usage =
  { input_tokens : int
  ; output_tokens : int
  ; thinking_tokens : int
  ; cache_read_tokens : int
  ; total_tokens : int
  }

(* Nothing in this tree branches on [permission_mode]: the only read of the
   field is its own parse site. It was closed, and the one member the CLI added
   ended a turn, parked the official-client session, and stopped a live Keeper
   after 110 turns in one hour (#28008). Adding that member leaves the
   next one to do it again, so an unseen mode is carried rather than rejected.
   [step_type] took the same route in #28027. *)
type permission_mode = Protocol.permission_mode =
  | Always_proceed
  | Request_review
  | Unrecognized_permission_mode of string

type turn_result =
  { conversation_id : string
  ; model : string
  ; text : string
  ; num_turns : int
  ; usage : usage
  ; permission_mode : permission_mode
  ; tool_steps : int
  ; tool_errors : int
  ; trajectory_error : string option
  ; resumed : bool
  ; wall_duration_s : float
  }

type response_ending = Protocol.response_ending = Response_done | Response_error

type noncompletion_status = Protocol.noncompletion_status =
  | Canceled
  | Interrupted
  | Invalid
  | Waiting
  | Running

let noncompletion_status_to_string = function
  | Canceled -> "CANCELED"
  | Interrupted -> "INTERRUPTED"
  | Invalid -> "INVALID"
  | Waiting -> "WAITING"
  | Running -> "RUNNING"
;;

type stream_event = Protocol.stream_event =
  | Turn_started of
      { conversation_id : string
      ; model : string
      }
  | Text_delta of
      { step_index : int option
      ; text : string
      }
  | Text_completed of { step_index : int; ending : response_ending }
  | Native_tool_started of Runtime_native_tools.observation
  | Native_tool_finished of Runtime_native_tools.finished
  | Usage_reported of
      { conversation_id : string
      ; model : string
      ; num_turns : int
      ; usage : usage
      }
  | Turn_finished of { text : string }

let emit_stream_event on_stream_event event =
  match on_stream_event with
  | None -> ()
  | Some emit ->
    (try emit event with
     | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Runtime_agent.warn
         "Antigravity stream callback raised (error=%s)"
         (Printexc.to_string exn))
;;

type denied_actions = Protocol.denied_actions =
  { first : string
  ; rest : string list
  }

let denied_action_names (denied : denied_actions) = denied.first :: denied.rest

type noncompletion_result = Protocol.noncompletion_result =
  { status : noncompletion_status
  ; conversation_id : string option
  ; response : string
  ; error : string option
  ; num_turns : int
  ; usage : usage
  ; denied : denied_actions option
  }

let noncompletion_result_to_json (result : noncompletion_result) =
  let optional_string = function None -> `Null | Some value -> `String value in
  `Assoc
    [ "kind", `String "result_not_completed"
    ; "completed", `Bool false
    ; "status", `String (noncompletion_status_to_string result.status)
    ; "conversation_id", optional_string result.conversation_id
    ; "partial_response", `String result.response
    ; "error", optional_string result.error
    ; "reported_num_turns", `Int result.num_turns
    ; "denied_actions",
      (match result.denied with
       | None -> `Null
       | Some denied ->
         `List (List.map (fun action -> `String action) (denied_action_names denied)))
    ; "reported_usage", `Assoc
        [ "input_tokens", `Int result.usage.input_tokens
        ; "output_tokens", `Int result.usage.output_tokens
        ; "thinking_tokens", `Int result.usage.thinking_tokens
        ; "cache_read_tokens", `Int result.usage.cache_read_tokens
        ; "total_tokens", `Int result.usage.total_tokens
        ]
    ]
;;

type denied_result = Protocol.denied_result =
  { conversation_id : string
  ; model : string
  ; denied : denied_actions
  ; response : string
  ; num_turns : int
  ; usage : usage
  ; tool_steps : int
  ; stderr_tail : string
  }

type error = Protocol.error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | State_callback_failed of string
  | Turn_failed of string
  | Result_not_completed of noncompletion_result
  | Actions_denied of denied_result
  | Process_exited of string
  | Unhandled_exception of string
  | Child_fd_ceiling_exceeded of
      { count : int option
      ; ceiling : int
      }
  | Timeout of float

exception Runtime_error of error

let error_to_string = function
  | Invalid_config detail -> "invalid Antigravity CLI config: " ^ detail
  | Spawn_failed detail -> "failed to start Antigravity CLI: " ^ detail
  | Protocol_error { stage; detail } ->
    Printf.sprintf "Antigravity stream-json protocol error during %s: %s" stage detail
  | State_callback_failed detail -> "Antigravity conversation state callback failed: " ^ detail
  | Turn_failed detail -> "Antigravity turn failed: " ^ detail
  | Result_not_completed { status; error; _ } ->
    Printf.sprintf "Antigravity result did not complete (status=%s)%s"
      (noncompletion_status_to_string status)
      (match error with None -> "" | Some detail -> ": " ^ detail)
  | Actions_denied { denied; response; model; tool_steps; stderr_tail; _ } ->
    Printf.sprintf
      "Antigravity print mode refused %s and ended the turn before it finished (model=%s, tool_steps=%d, partial response: %d bytes, %s)"
      (String.concat ", " (denied_action_names denied))
      model
      tool_steps
      (String.length response)
      (if stderr_tail = "" then "stderr=<empty>" else "stderr tail: " ^ stderr_tail)
  | Process_exited detail -> "Antigravity CLI exited before completion: " ^ detail
  | Unhandled_exception detail -> "Antigravity runtime raised: " ^ detail
  | Child_fd_ceiling_exceeded { count = Some count; ceiling } ->
    Printf.sprintf
      "Antigravity CLI held %d open files past the %d ceiling; the turn was failed to protect the system file table (#43259)"
      count
      ceiling
  | Child_fd_ceiling_exceeded { count = None; ceiling } ->
    Printf.sprintf
      "Antigravity CLI file usage was unobservable under system fd pressure; the turn was failed at the %d-file ceiling rather than risk ENFILE (#43259)"
      ceiling
  | Timeout seconds -> Printf.sprintf "Antigravity stream was idle for %.3fs" seconds
;;

let protocol_error stage detail = Error (Protocol_error { stage; detail })
let ( let* ) result f = Result.bind result f

(* The three official-client runtimes speak the same line-delimited JSON
   protocol and differ only in the error constructor they fail with. The shape
   checks live once in {!Runtime_official_client_json}; this instantiates them
   against this runtime's own [error]. *)
module Shared_json = Runtime_official_client_json.Make (struct
  type t = error

  let protocol ~stage ~detail = Protocol_error { stage; detail }
end)

open Shared_json

module Stderr = Runtime_official_client_json.Stderr

let required_string ?(nonempty = true) stage name fields =
  match List.assoc_opt name fields with
  | Some (`String value) when (not nonempty) || String.trim value <> "" -> Ok value
  | Some (`String _) ->
    protocol_error stage (Printf.sprintf "field %S must not be empty" name)
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a string" name)
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

(* The init event states the conversation's identity; step_update and result
   restate it. Present and non-blank is a restatement; missing, null, or
   blank is silence. [required_string] cannot express that difference -- it
   rejects a blank before anything decides whether the value was needed. *)
let restated_string stage name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) when String.trim value = "" -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a string" name)
;;

let required_nonnegative_int stage name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) when value >= 0 -> Ok value
  | Some (`Int _) ->
    protocol_error stage (Printf.sprintf "field %S must be non-negative" name)
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be an integer" name)
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

let parse_usage stage fields =
  let* usage_json = required_member stage "usage" fields in
  let* usage_fields = assoc_at stage usage_json in
  let* input_tokens = required_nonnegative_int stage "input_tokens" usage_fields in
  let* output_tokens = required_nonnegative_int stage "output_tokens" usage_fields in
  let* thinking_tokens = required_nonnegative_int stage "thinking_tokens" usage_fields in
  let* cache_read_tokens = required_nonnegative_int stage "cache_read_tokens" usage_fields in
  let* total_tokens = required_nonnegative_int stage "total_tokens" usage_fields in
  if total_tokens <> input_tokens + output_tokens
  then
    protocol_error
      stage
      "usage.total_tokens must equal input_tokens + output_tokens"
  else Ok { input_tokens; output_tokens; thinking_tokens; cache_read_tokens; total_tokens }
;;

type wire_event = Protocol.wire_event =
  | Init of
      { conversation_id : string
      ; model : string
      ; cwd : string
      ; permission_mode : permission_mode
      }
  | Step_update of
      { conversation_id : string option
      ; step_index : int option
      ; state : step_state
      ; step_type : step_type
      ; tool_name : string option
      ; (* The piece of the answer this frame carries. agy sends it on the
           [Agent_response] steps as the model writes, so the text reaches a
           reader while the turn runs rather than only in the result event
           (measured 2026-09-18, agy 1.2.6). *)
        text_delta : string option
      }
  | Result of
      { (* [None] two ways: the CLI refuses a bad invocation with a single
           result event and never opens a conversation, or a live result
           restates the identity as blank. Init is the one event that states
           it. *)
        conversation_id : string option
      ; status : result_status
      ; response : string
      ; error : string option
      ; num_turns : int
      ; usage : usage
      ; denied : denied_actions option
      }

and step_state = Protocol.step_state =
  | Active
  | Done
  | Step_error

and step_type = Protocol.step_type =
  | Agent_response
  | System_message
  | Tool
  | User_input
  | Internal
  | Checkpoint
  | Unrecognized of string

and result_status = Protocol.result_status =
  | Success
  | Result_error
  | Not_completed of noncompletion_status

let closed_string stage name parse value =
  match parse value with
  | Some value -> Ok value
  | None ->
    protocol_error stage (Printf.sprintf "unsupported field %S value %S" name value)
;;

let parse_permission_mode _stage value =
  Ok
    (match value with
     | "always-proceed" -> Always_proceed
     | "request-review" -> Request_review
     | other -> Unrecognized_permission_mode other)
;;

let parse_step_state stage value =
  closed_string
    stage
    "state"
    (function
      | "ACTIVE" -> Some Active
      | "DONE" -> Some Done
      | "ERROR" -> Some Step_error
      | _ -> None)
    value
;;

(* [step_type] decides tool counters and the idle window, and a known
   [Agent_response] now also supplies a content-end boundary. Other non-[Tool]
   values retain the open-vocabulary admission behavior: no tool count and an
   armed idle window. Unknown values never invent a response completion.
   Rejecting an unknown value instead ends the turn and parks the session,
   which blocks every later turn
   for that Keeper. Live 2026-08-10: Antigravity began emitting
   "system_message" and the affected Keeper stopped (#28027).

   #28029 opened this with [Unrecognized]; #28037 closed it again and named
   [System_message] instead. Naming the member that stalled a keeper leaves the
   next one to stall it again. Both are kept here:
   the known member keeps its name, and anything else is carried rather than
   rejected.

   [Unrecognized] carries the value rather than folding it into [Internal] so a
   later consumer cannot read an unseen step as a known one. It does not make
   the drift observable: [step_type] never reaches [turn_result], so nothing
   renders it today.

   [state] and [status] stay closed: each of those does decide something.
   [permission_mode] does not, and is open for the same reason as this one. *)
let parse_step_type _stage value =
  Ok
    (match value with
     | "agent_response" -> Agent_response
     | "system_message" -> System_message
     | "tool" -> Tool
     | "user_input" -> User_input
     | "unknown" -> Internal
     | "checkpoint" -> Checkpoint
     | other -> Unrecognized other)
;;

let parse_result_status stage value =
  closed_string
    stage
    "status"
    (function
      | "SUCCESS" -> Some Success
      | "ERROR" -> Some Result_error
      | "CANCELED" -> Some (Not_completed Canceled)
      | "INTERRUPTED" -> Some (Not_completed Interrupted)
      | "INVALID" -> Some (Not_completed Invalid)
      | "WAITING" -> Some (Not_completed Waiting)
      | "RUNNING" -> Some (Not_completed Running)
      | _ -> None)
    value
;;

let parse_init fields =
  let stage = "init event" in
  let* conversation_id = required_string stage "conversation_id" fields in
  let* init_json = required_member stage "init" fields in
  let* init_fields = assoc_at stage init_json in
  let* model = required_string stage "model" init_fields in
  let* cwd = required_string stage "cwd" init_fields in
  let* permission_mode_string = required_string stage "permission_mode" init_fields in
  let* permission_mode = parse_permission_mode stage permission_mode_string in
  Ok (Init { conversation_id; model; cwd; permission_mode })
;;

let parse_step_update fields =
  let stage = "step_update event" in
  let* step_json = required_member stage "step_update" fields in
  let* step_fields = assoc_at stage step_json in
  let* conversation_id = restated_string stage "conversation_id" step_fields in
  (* A usable ordinal identifies native or response content. Preserve the
     existing optional-index admission contract (#28010): absence or drift
     leaves content unassigned and cannot authorize an identified block end. *)
  let step_index =
    match List.assoc_opt "step_index" step_fields with
    | Some (`Int value) when value >= 0 -> Some value
    | Some (`Intlit value) ->
      (match int_of_string_opt value with
       | Some value when value >= 0 -> Some value
       | Some _ | None -> None)
    | Some _ | None -> None
  in
  let* state_string = required_string stage "state" step_fields in
  let* state = parse_step_state stage state_string in
  let* step_type_string = required_string stage "step_type" step_fields in
  let* step_type = parse_step_type stage step_type_string in
  let* tool_name = optional_string stage "tool_name" step_fields in
  let* text_delta = optional_string stage "text_delta" step_fields in
  Ok (Step_update { conversation_id; step_index; state; step_type; tool_name; text_delta })
;;

(* [denied_actions] is absent when agy refused nothing. An entry that is not
   an object naming its action is a protocol error, not a refusal to skip. *)
let parse_denied_actions stage fields =
  let rec parse_entries = function
    | [] -> Ok []
    | entry :: rest ->
      let* entry_fields = assoc_at stage entry in
      let* action = required_string stage "action" entry_fields in
      let* actions = parse_entries rest in
      Ok (action :: actions)
  in
  match List.assoc_opt "denied_actions" fields with
  | None | Some `Null -> Ok None
  | Some (`List entries) ->
    let* actions = parse_entries entries in
    (match actions with
     | [] -> Ok None
     | first :: rest -> Ok (Some ({ first; rest } : denied_actions)))
  | Some _ -> protocol_error stage "field \"denied_actions\" must be a list"
;;

let parse_result fields =
  let stage = "result event" in
  let* result_json = required_member stage "result" fields in
  let* result_fields = assoc_at stage result_json in
  let* conversation_id = restated_string stage "conversation_id" result_fields in
  let* status_string = required_string stage "status" result_fields in
  let* status = parse_result_status stage status_string in
  let* response = required_string ~nonempty:false stage "response" result_fields in
  (* Under --json-schema the CLI validates its answer and re-prompts, and only
     [structured_output] carries what passed. Measured 2026-08-30: [response]
     still held a fenced draft containing a key the schema forbids while
     [structured_output] held the clean object. So where the field is present
     it is the answer, and the prose beside it is narration. *)
  let response =
    match List.assoc_opt "structured_output" result_fields with
    | None | Some `Null -> response
    | Some value -> Yojson.Safe.to_string value
  in
  let* error = optional_string stage "error" result_fields in
  let* num_turns = required_nonnegative_int stage "num_turns" result_fields in
  let* usage = parse_usage stage result_fields in
  let* denied = parse_denied_actions stage result_fields in
  Ok (Result { conversation_id; status; response; error; num_turns; usage; denied })
;;

let parse_wire_line line =
  let stage = "stream-json message" in
  let json_result =
    try Ok (Yojson.Safe.from_string line) with
    | Yojson.Json_error detail -> protocol_error stage ("invalid JSON: " ^ detail)
  in
  let* json = json_result in
  let* () = validate_unique_object_keys ~stage ~path:"$" json in
  let* fields = assoc_at stage json in
  let* event = required_string stage "event" fields in
  match event with
  | "init" -> parse_init fields
  | "step_update" -> parse_step_update fields
  | "result" -> parse_result fields
  | other -> protocol_error stage (Printf.sprintf "unsupported event %S" other)
;;

let effort_to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
;;

(* Under [--json-schema] agy takes the answer as the arguments of a tool it
   calls [finish]. A value the model writes as text is not an answer to it:
   the CLI replies "You did not call any tools. ... If you have completed your
   task call the finish tool." and the model answers again with the whole
   prompt re-sent. Measured 2026-10-08 on agy 1.3.1, gemini-3.8-flash-low: of
   499 Librarian passes told to "return exactly one JSON value", 308 wrote
   text first and all 308 took a second model call. *)
let structured_output_tool = "finish"

let structured_output_instruction ~schema =
  Printf.sprintf
    "Deliver exactly one JSON value matching this JSON Schema by calling the `%s` tool \
     in your first response, with the value's members as the tool's arguments. Do not \
     write the value as text and do not call any other tool. JSON Schema: %s"
    structured_output_tool
    (Yojson.Safe.to_string schema)
;;

let execution_mode_to_string = function
  | Plan -> "plan"
  | Accept_edits -> "accept-edits"
;;

let validate_config config ~conversation_mode ~prompt =
  if String.trim config.cli_path = ""
  then Error (Invalid_config "cli_path must not be empty")
  else if String.trim config.cwd = "" || Filename.is_relative config.cwd
  then Error (Invalid_config "cwd must be an absolute path")
  else if String.trim config.model = ""
  then Error (Invalid_config "model must not be empty")
  else if
    not (Float.is_finite config.admission_timeout_s)
    || config.admission_timeout_s <= 0.0
  then Error (Invalid_config "admission_timeout_s must be positive and finite")
  else if
    (match config.timeout_s with
     | None -> false
     | Some seconds -> not (Float.is_finite seconds) || seconds <= 0.0)
  then Error (Invalid_config "a declared timeout_s must be positive and finite")
  else if String.trim prompt = ""
  then Error (Invalid_config "prompt must not be empty")
  else
    match config.agent, conversation_mode with
    | Some agent, _ when String.trim agent = "" ->
      Error (Invalid_config "agent must not be empty when present")
    | _, Resume { conversation_id } when String.trim conversation_id = "" ->
      Error (Invalid_config "resume conversation_id must not be empty")
    | (None | Some _), (Start | Resume _) -> Ok ()
;;

let validate_turn ?(conversation_mode = Start) config ~prompt =
  validate_config config ~conversation_mode ~prompt
;;

let env_key entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> entry
;;

let allowed_environment_key key =
  List.mem
    key
    [ "COLORTERM"
    ; "HOME"
    ; "LANG"
    ; "LC_ALL"
    ; "LC_CTYPE"
    ; "LOGNAME"
    ; "PATH"
    ; "SHELL"
    ; "SSL_CERT_DIR"
    ; "SSL_CERT_FILE"
    ; "TEMP"
    ; "TERM"
    ; "TMP"
    ; "TMPDIR"
    ; "TZ"
    ; "USER"
    ; "XDG_CACHE_HOME"
    ; "XDG_CONFIG_HOME"
    ; "XDG_DATA_HOME"
    ; "XDG_RUNTIME_DIR"
    ]
;;

(* agy starts a background self-update when it launches. A Keeper turn would
   then swap the binary under the next turn, and parallel turns would each
   start one (RFC-0490 §2.4). Only the value "true" stops it; "1" does not
   (RFC-0490 measurement 11). The key is not on the allowlist above, so the
   operator's own setting never reaches the child and this entry is the only one. *)
let auto_update_disabled = "AGY_CLI_DISABLE_AUTO_UPDATE=true"

let official_client_environment ?home_dir () =
  let overridden_keys =
    match home_dir with
    | None -> []
    | Some _ -> [ "HOME"; "XDG_CACHE_HOME"; "XDG_CONFIG_HOME"; "XDG_DATA_HOME" ]
  in
  let inherited =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun entry ->
      let key = env_key entry in
      allowed_environment_key key && not (List.mem key overridden_keys))
  in
  let environment = auto_update_disabled :: inherited in
  match home_dir with
  | None -> Array.of_list environment
  | Some home_dir -> Array.of_list (("HOME=" ^ home_dir) :: environment)
;;

let argv config ~conversation_mode =
  let base =
    [ config.cli_path
    ; "--output-format"
    ; "stream-json"
    ; "--model"
    ; config.model
    ; "--mode"
    ; execution_mode_to_string config.execution_mode
    ]
    (* The keeper base path is always the first workspace root; [add_dirs]
       extends it with the provider-declared extra roots, one [--add-dir]
       per directory. *)
    @ List.concat_map
        (fun dir -> [ "--add-dir"; dir ])
        (config.cwd :: config.add_dirs)
    @ [ "--print-timeout"; cli_non_authoritative_timeout ]
  in
  let with_optional flag value values =
    match value with
    | None -> values
    | Some value -> values @ [ flag; value ]
  in
  base
  |> with_optional
       "--json-schema"
       (* The flag takes an inline schema string or a path. With
          --output-format stream-json the CLI applies it to the terminal
          result event, which is the event this adapter reads, so the
          existing stream shape needs no change. *)
       (Option.map Yojson.Safe.to_string config.output_schema)
  |> with_optional "--agent" config.agent
  |> with_optional "--effort" (Option.map effort_to_string config.effort)
  |> (fun values -> if config.sandbox then values @ [ "--sandbox" ] else values)
  |> (fun values ->
    if config.disable_slash_commands then values @ [ "--disable-slash-commands" ] else values)
  |> (fun values ->
    match conversation_mode with
    | Start -> values @ [ "--new-project" ]
    | Resume { conversation_id } -> values @ [ "--conversation"; conversation_id ])
;;

let drain_stderr flow tail =
  let chunk = Cstruct.create stderr_chunk_bytes in
  try
    while true do
      let count = Eio.Flow.single_read flow chunk in
      Stderr.append tail (Cstruct.to_string (Cstruct.sub chunk 0 count))
    done
  with
  | End_of_file -> ()
  | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Runtime_agent.debug
      "Antigravity CLI stderr drain failed: %s"
      (Printexc.to_string exn)
;;

let signal_spawned_process proc stdin_w =
  Eio.Cancel.protect (fun () ->
    (try Eio.Flow.close stdin_w with
     | _ -> ()); (* cancel-guard-ok: the whole process-termination body runs under Eio.Cancel.protect, so the ambient cancellation cannot fire inside it even where Eio.Process.await suspends. *)
    (try Eio.Process.signal proc Sys.sigterm with
     | _ -> ())) (* cancel-guard-ok: the whole process-termination body runs under Eio.Cancel.protect, so the ambient cancellation cannot fire inside it even where Eio.Process.await suspends. *)
;;

(* The CLI is asked to stop and given the shared grace to exit before it is
   killed. A cancelled owner calls [signal_spawned_process] instead: the
   switch's release hook kills and reaps the CLI, and [Eio.Process.await]
   cannot finish once the switch that owns the CLI is cancelled.

   This function does not look at the owner's cancellation, unlike its
   siblings in the other host runtimes, because no cancelled owner reaches it:
   this module has no [Fun.protect ~finally] around the turn, and cancellation
   is received only by the [Eio.Cancel.Cancelled] and operator-interrupt arms
   of [run_spawned] and by the [Eio.Switch.on_release] handler, which only
   signal. A finalizer that calls this function must check the cancellation
   first. *)
let terminate_spawned_process ~sw ~clock proc stdin_w =
  Eio.Cancel.protect (fun () ->
    (try Eio.Flow.close stdin_w with
     | _ -> ()); (* cancel-guard-ok: the whole process-termination body runs under Eio.Cancel.protect, so the ambient cancellation cannot fire inside it even where Eio.Process.await suspends. *)
    Eio_process_capture.reap_proc_with_clock
      ~sw
      (clock :> float Eio.Time.clock_ty Eio.Resource.t)
      proc)
;;

(* Protocol proposals contain no callbacks. Apply the ordered obligations
   under the driver's existing callback deadline, then publish the candidate.
   Readiness, terminal and stream callbacks retain their distinct failure
   policies; a candidate itself is no evidence that an obligation happened. *)
let apply_event (config : config) ~conversation_mode ~on_conversation_ready
    ~on_stream_event ~on_terminal_received state event =
  let* transition = Protocol.advance
      ~expected_model:config.model ~expected_cwd:config.cwd
      ~conversation_mode state event in
  let rec interpret = function
    | [] -> Ok ()
    | Protocol.Admit_conversation { conversation_id } :: rest ->
        let callback_result =
          try on_conversation_ready ~conversation_id with
          | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | Eio.Time.Timeout as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        (match callback_result with
         | Error detail -> Error (State_callback_failed detail)
         | Ok () -> interpret rest)
    | Protocol.Terminal_received :: rest ->
        on_terminal_received ();
        interpret rest
    | Protocol.Stream event :: rest ->
        emit_stream_event on_stream_event event;
        interpret rest
  in
  let* () = interpret (Protocol.obligations transition) in
  Ok (Protocol.next_state transition)
;;

let status_to_string = function
  | `Exited code -> Printf.sprintf "exit code %d" code
  | `Signaled signal -> Printf.sprintf "signal %d" signal
;;

let context_submission_to_json write =
  `Assoc
    [ "schema", `String "masc.antigravity-context-submission.v1"
    ; "phase", `String "stdin_write_completed"
    ; "frame", `String "stdin_prompt"
    ; "write", Runtime_official_client_write.to_json write
    ; "client_acceptance", `String "not_observed_by_this_event"
    ]
;;

let child_fd_sampler_key : (unit -> Runtime_cli_spawn_gate.child_fds) Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let run_spawned ?home_dir ?before_spawn ?on_spawned ?on_prompt_sent ?on_context_submission ~mgr ~clock ~cwd config ~conversation_mode
    ~prompt ~on_conversation_ready ~on_stream_event ~on_terminal_received =
  Eio.Switch.run (fun sw ->
    let stdin_r, stdin_w = Eio.Process.pipe ~sw mgr in
    let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
    let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
    let stderr_tail = Stderr.create ~limit:stderr_tail_bytes in
    let proc =
      try
        Option.iter (fun callback -> callback ()) before_spawn;
        Eio.Process.spawn
          ~sw
          mgr
          ~cwd
          ~env:(official_client_environment ?home_dir ())
          ~stdin:stdin_r
          ~stdout:stdout_w
          ~stderr:stderr_w
          (argv config ~conversation_mode)
      with
      | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> raise (Runtime_error (Spawn_failed (Printexc.to_string exn)))
    in
    Option.iter (fun callback -> callback ~pid:(Eio.Process.pid proc)) on_spawned;
    Eio.Flow.close stdin_r;
    Eio.Flow.close stdout_w;
    Eio.Flow.close stderr_w;
    (* A prompt longer than the pipe buffer stops until the CLI reads it, and
       a CLI that answers without draining stdin never does. [Switch.run]
       joins an ordinary fiber on the way out of a body that returned a
       value, so an unwindowed write there turns a served turn into a wait
       with nothing left to end it. The window is the one the first read
       uses. *)
    Eio.Fiber.fork ~sw (fun () ->
      with_optional_idle_timeout
        clock
        (timeout_s_for_phase config Awaiting_admission)
        (fun () -> Eio.Flow.copy_string prompt stdin_w);
      (* A successful prompt write must deliver EOF to the CLI. If the copy
         raises, the failed fiber cancels [sw] and the pipe's switch-owned
         release handler closes [stdin_w]. *)
      Eio.Flow.close stdin_w;
      (* The receipt is of the bytes just written; hashing a long prompt runs
         off the scheduler domain. *)
      Option.iter (fun observer ->
        Runtime_official_client_write.report ~label:"Antigravity stdin prompt" observer
          (Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
             Runtime_official_client_write.raw prompt)))
        on_context_submission;
      Option.iter (fun callback -> callback ()) on_prompt_sent);
    (* Diagnostics only, so a daemon: the switch cancels it once the body
       returns. A grandchild the CLI leaves behind (an MCP server orphaned
       when the CLI is reaped) inherits this pipe's write end, so EOF may
       never come, and a joined fiber would hold the switch open after the
       turn was served. *)
    Eio.Fiber.fork_daemon ~sw (fun () ->
      drain_stderr stderr_r stderr_tail;
      `Stop_daemon);
    let reader = Eio.Buf_read.of_flow ~max_size:max_wire_line_bytes stdout_r in
    let process_settled = ref false in
    let settle_failed_process () =
      if not !process_settled
      then (
        Eio.Cancel.protect (fun () -> terminate_spawned_process ~sw ~clock proc stdin_w);
        process_settled := true)
    in
    let abort_with_runtime_error error =
      settle_failed_process ();
      raise (Runtime_error error)
    in
    (* The CLI opens most of its files at startup — workspace scans plus
       project preload — before its first protocol event (~7.5k healthy,
       26k+ sick, #43259), but a mid-turn tool step can grow the count
       further. Sample at the first event and at the result event; any
       sample past the ceiling fails the turn, even a completed one — a
       hot turn is the workspace-sick signal, not a result to keep. *)
    let sampled_at_first_event = ref false in
    let enforce_child_fd_ceiling () =
      let pid = Eio.Process.pid proc in
      let ceiling = Runtime_cli_spawn_gate.child_fd_ceiling in
      let sample =
        match
          Eio.Time.with_timeout
            clock
            Runtime_cli_spawn_gate.child_fd_probe_timeout_s
            (fun () ->
              Ok (match Eio.Fiber.get child_fd_sampler_key with
                | Some sample -> sample ()
                | None -> Runtime_cli_spawn_gate.sample_child_fds ~mgr ~cwd ~pid))
        with
        | Ok sample -> sample
        | Error `Timeout ->
          Log.Runtime_agent.debug
            "Antigravity child fd probe timed out after %.1fs; allowing the turn (#43259)"
            Runtime_cli_spawn_gate.child_fd_probe_timeout_s;
          Runtime_cli_spawn_gate.Fds_unobservable
      in
      (match sample with
       | Runtime_cli_spawn_gate.Fd_count count ->
         Log.Runtime_agent.debug
           "Antigravity child %d holds %d open files (ceiling %d)"
           pid
           count
           ceiling;
         if count > ceiling
         then
           abort_with_runtime_error
             (Child_fd_ceiling_exceeded { count = Some count; ceiling })
       | Runtime_cli_spawn_gate.Fds_unobservable -> ()
       | Runtime_cli_spawn_gate.Fds_pressured ->
         if Runtime_cli_spawn_gate.child_is_alive ~pid
         then
           abort_with_runtime_error
             (Child_fd_ceiling_exceeded { count = None; ceiling }))
    in
    let enforce_child_fd_ceiling_once () =
      if not !sampled_at_first_event
      then (
        sampled_at_first_event := true;
        enforce_child_fd_ceiling ())
    in
    (* This handler runs before Eio's process release handler (LIFO). It must
       only signal: awaiting here would race the release handler's reap and
       deadlock timeout cancellation. Typed non-cancellation failures reap in
       [settle_failed_process] before leaving the switch. *)
    Eio.Switch.on_release sw (fun () ->
      if not !process_settled then signal_spawned_process proc stdin_w);
    let state = ref Protocol.initial in
    (try
       (* The result event completes the protocol — nothing after it is
          attribution or content (apply_event rejects post-result events).
          EOF cannot be the completion contract: the CLI's own shutdown can
          hang while a child process keeps stdout open (#28912), which
          turned already-served turns into idle timeouts. *)
       while Option.is_none (Protocol.terminal !state) do
         let phase = Protocol.read_phase !state in
         let read_timeout_s =
           timeout_s_for_phase config phase
         in
         (* Applying an event runs MASC's own callbacks (admission, stream
            observers). The tool-step exemption is about the CLI's silence,
            not about them, so they keep the model-turn bound. *)
         let callback_timeout_s =
           timeout_s_for_phase
             config
             (match phase with
              | Awaiting_admission -> Awaiting_admission
              | Model_turn | Tool_step_running -> Model_turn)
         in
         let line =
           with_optional_idle_timeout clock read_timeout_s (fun () ->
             Eio.Buf_read.line reader)
         in
         match parse_wire_line line with
         | Error error -> abort_with_runtime_error error
         | Ok event ->
           (* Sample before the callbacks: a killed turn must not mutate
              session state first. *)
           enforce_child_fd_ceiling_once ();
           (match
              with_optional_idle_timeout clock callback_timeout_s (fun () ->
                apply_event
                  config
                  ~conversation_mode
                  ~on_conversation_ready
                  ~on_stream_event
                  ~on_terminal_received
                  !state
                  event)
            with
            | Error error -> abort_with_runtime_error error
            | Ok next -> state := next)
       done;
       (* The result event is in: catch growth the first sample missed.
          An already-exited child samples unobservable and passes. *)
       enforce_child_fd_ceiling ()
     with
     | End_of_file -> ()
     | exn when Keeper_operator_interrupt.is_operator_interrupt exn ->
       signal_spawned_process proc stdin_w;
       process_settled := true;
       raise exn
     | Eio.Cancel.Cancelled _ as exn ->
       signal_spawned_process proc stdin_w;
       process_settled := true;
       raise exn
     | Idle_timeout seconds ->
       abort_with_runtime_error (Timeout seconds)
     | Eio.Time.Timeout as exn -> raise exn
     | Runtime_error _ as exn -> raise exn
     | exn ->
       abort_with_runtime_error
         (Protocol_error
            { stage = "stdout read"; detail = Printexc.to_string exn }));
    let status =
      (* Bounded: after a completed protocol (or EOF) a healthy CLI exits
         almost immediately; a CLI stuck in its shutdown gets reaped. The
         repeated await after terminate is safe — Eio.Process.await is
         idempotent over the cached exit status. *)
      try
        Eio.Time.with_timeout_exn clock result_exit_grace_s (fun () ->
          Eio.Process.await proc)
      with
      | Eio.Time.Timeout ->
        Eio.Cancel.protect (fun () -> terminate_spawned_process ~sw ~clock proc stdin_w);
        Eio.Process.await proc
    in
    process_settled := true;
    status, !state, String.trim (Stderr.contents stderr_tail))
;;

let run_turn ?(conversation_mode = Start) ?home_dir ?before_spawn ?on_spawned ?on_prompt_sent ?on_context_submission
    ?(on_terminal_received = fun () -> ()) ~host:(_ : Runtime_account_access.host_account)
    ~mgr ~clock ~cwd
    ?(on_conversation_ready = fun ~conversation_id:_ -> Ok ()) ?on_stream_event
    config ~prompt =
  let* () =
    match home_dir with
    | None -> Ok ()
    | Some path when String.trim path = "" || Filename.is_relative path ->
      Error (Invalid_config "home_dir must be an absolute non-empty path")
    | Some _ -> Ok ()
  in
  let* () = validate_config config ~conversation_mode ~prompt in
  let started_at = Eio.Time.now clock in
  let run_result =
    try
      Ok
        (Runtime_cli_spawn_gate.with_cli_spawn_slot ~clock (fun () ->
           run_spawned
             ?home_dir
             ?before_spawn
             ?on_spawned
             ?on_prompt_sent
             ?on_context_submission
             ~mgr
             ~clock
             ~cwd
             config
             ~conversation_mode
             ~prompt
             ~on_conversation_ready
             ~on_stream_event ~on_terminal_received))
    with
    | Idle_timeout seconds -> Error (Timeout seconds)
    | Runtime_cli_spawn_gate.Slot_timeout { waited_s; limit_s } ->
      (* Retryable pressure, not a broken turn: the gate was full for the
         whole budget. Spawn_failed keeps its Transient keeper mapping,
         which is exactly right for "try again shortly". *)
      Error
        (Spawn_failed
           (Printf.sprintf
              "CLI capacity busy: no Antigravity spawn slot within %.1fs (limit %.1fs, %d active, %d waiting); retry shortly"
              waited_s
              limit_s
              (Runtime_cli_spawn_gate.active_cli_spawns ())
              (Runtime_cli_spawn_gate.waiting_cli_spawns ())))
    | Eio.Time.Timeout as exn -> raise exn
    | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Runtime_error error -> Error error
    | exn ->
      (* Read before anything else runs: the backtrace belongs to this raise.
         Nothing else records where the exception came from. *)
      let backtrace = Printexc.get_backtrace () in
      Llm_provider.Reserved_exn.reraise_if_reserved exn;
      Log.Runtime_agent.error
        "Antigravity runtime raised outside the protocol: %s\nBacktrace: %s"
        (Printexc.to_string exn)
        backtrace;
      Error (Unhandled_exception (Printexc.to_string exn))
  in
  let* status, state, stderr = run_result in
  let wall_duration_s = max 0.0 (Eio.Time.now clock -. started_at) in
  let complete (terminal : Protocol.terminal) ~trajectory_error =
    emit_stream_event on_stream_event (Turn_finished { text = terminal.response });
    Ok
      { conversation_id = terminal.conversation_id
      ; model = terminal.model
      ; text = terminal.response
      ; num_turns = terminal.num_turns
      ; usage = terminal.usage
      ; permission_mode = terminal.permission_mode
      ; tool_steps = terminal.tool_steps
      ; tool_errors = terminal.tool_errors
      ; trajectory_error
      ; resumed =
          (match conversation_mode with
           | Start -> false
           | Resume _ -> true)
      ; wall_duration_s
      }
  in
  match status, Protocol.terminal state with
  | _, Some terminal ->
    (* The parsed result ends the protocol regardless of how the CLI
       shut down. The core guarantees its original admitted identity exists.
       Final interpretation and Turn_finished remain after process drain. *)
    let deliverable =
      Agent_core.Response_shape.has_deliverable_content
        (Agent_core.Response_shape.summarize_blocks
           [ Llm_provider.Types.Text terminal.response ]) in
    (match terminal.status, terminal.denied with
     (* A refusal ended the run: the text so far, if any, is not the answer,
        whether the CLI called the run a success or an error. *)
     | (Success | Result_error), Some denied ->
         Error (Actions_denied
           { conversation_id = terminal.conversation_id; model = terminal.model
           ; denied; response = terminal.response; num_turns = terminal.num_turns
           ; usage = terminal.usage; tool_steps = terminal.tool_steps
           ; stderr_tail = denied_stderr_excerpt stderr })
     | Success, None ->
         if deliverable then complete terminal ~trajectory_error:None
         else Error (Turn_failed
           (empty_success_detail ~model:terminal.model
              ~tool_steps:terminal.tool_steps stderr))
     | Result_error, None ->
         let detail = match terminal.error with
           | Some detail -> detail
           | None -> "status=ERROR" in
         (* A corrected trajectory can report ERROR with a real reply.
            Prior streamed text cannot rescue an empty terminal response. *)
         if deliverable then complete terminal ~trajectory_error:(Some detail)
         else Error (Turn_failed detail)
     (* The CLI's own noncompletion keeps its stricter recovery fence; the
        refusals ride along as evidence. *)
     | Not_completed status, (None | Some _) ->
         Error
           (Result_not_completed
              { status; conversation_id = Some terminal.conversation_id
              ; response = terminal.response; error = terminal.error
              ; num_turns = terminal.num_turns; usage = terminal.usage
              ; denied = terminal.denied }))
  | `Exited 0, None ->
    Error (Protocol_error { stage = "process completion"; detail = "missing result event" })
  | (`Exited _ | `Signaled _), None ->
    let exit = status_to_string status in
    let stderr = redact_stderr_tail stderr in
    Error (Process_exited (if stderr = "" then exit else exit ^ ": " ^ stderr))
;;

module For_testing = struct
  let tool_step_timeout_s config = timeout_s_for_phase config Tool_step_running
  let with_child_fd_sampler sample f = Eio.Fiber.with_binding child_fd_sampler_key sample f
end
