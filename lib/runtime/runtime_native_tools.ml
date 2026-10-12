type posture =
  | Native_none
  | Native_read
  | Native_full

type posture_source =
  | Declared_on_disk
  | Program_defined of posture

let posture_source_of_required = function
  | None -> Declared_on_disk
  | Some posture -> Program_defined posture
;;

type action_identity =
  | Call_id of string
  | Provider_step of
      { conversation_id : string
      ; step_index : int
      }

type origin =
  | Built_in
  | Mcp_wrapper

type observation =
  { identity : action_identity option
  ; tool_name : string option
  ; origin : origin
  }

type exact_action = action_identity * string

type completion_outcome =
  | End_observed
  | Completion_unrecorded
  | Completion_reported
  | Error_reported
  | Decline_reported
  | Result_received of { is_error : bool option }
  | Unrecognized_status of string

type completion = { outcome : completion_outcome; exit_code : int option }
type finished = { observation : observation; completion : completion }

type retry_agent = { agent_id : string; subagent_type : string }
type retry_note =
  { agent : retry_agent; attempt : int; max_retries : int; retry_delay_ms : int
  ; error_status : int option; error_category : string }
type retry_observation = Retry_reported of retry_note | Retry_cleared of retry_agent

type progress =
  | Output_observed of { byte_count : int }
  | Message_reported of { message : string }
  | Heartbeat_reported of { elapsed_seconds : int }
  | Retry_observed of retry_observation

let retry_agent_fields agent =
  ["agent_id", `String agent.agent_id; "subagent_type", `String agent.subagent_type]

let progress_to_json = function
  | Retry_observed (Retry_cleared agent) ->
      `Assoc (("kind", `String "retry_cleared") :: retry_agent_fields agent)
  | Retry_observed (Retry_reported note) ->
      `Assoc (["kind", `String "retry_reported"; "attempt", `Int note.attempt;
        "max_retries", `Int note.max_retries; "retry_delay_ms", `Int note.retry_delay_ms;
        "error_status", Option.fold ~none:`Null ~some:(fun value -> `Int value) note.error_status;
        "error_category", `String note.error_category] @ retry_agent_fields note.agent)
  | Heartbeat_reported {elapsed_seconds} -> `Assoc ["kind", `String "heartbeat_reported"; "elapsed_seconds", `Int elapsed_seconds]
  | Output_observed {byte_count} -> `Assoc ["kind", `String "output_observed"; "byte_count", `Int byte_count]
  | Message_reported {message} -> `Assoc ["kind", `String "message_reported"; "message", `String message]

let progress_of_json = function
  | `Assoc fields ->
      let keys = List.map fst fields in
      let sorted = List.sort String.compare keys in
      if List.length keys <> List.length (List.sort_uniq String.compare keys)
      then Error "duplicate native progress field"
      else
        let ( let* ) = Result.bind in
        let string key = match List.assoc_opt key fields with
          | Some (`String value) when String.trim value <> "" -> Ok value
          | Some _ | None -> Error ("native retry " ^ key ^ " must be a nonblank string") in
        let integer key = match List.assoc_opt key fields with
          | Some json -> Runtime_json_integer.of_json json
          | None -> Error ("native retry " ^ key ^ " is required") in
        let agent () = let* agent_id = string "agent_id" in
          let* subagent_type = string "subagent_type" in Ok {agent_id;subagent_type} in
        (match List.assoc_opt "kind" fields with
        | Some (`String "retry_cleared") when sorted = ["agent_id";"kind";"subagent_type"] ->
            let* agent = agent () in Ok (Retry_observed (Retry_cleared agent))
        | Some (`String "retry_reported") when sorted =
            ["agent_id";"attempt";"error_category";"error_status";"kind";"max_retries";"retry_delay_ms";"subagent_type"] ->
            let* agent = agent () in
            let* attempt = integer "attempt" in
            let* max_retries = integer "max_retries" in
            let* retry_delay_ms = integer "retry_delay_ms" in
            let* error_status = match List.assoc_opt "error_status" fields with
              | Some `Null -> Ok None
              | Some _ -> Result.map Option.some (integer "error_status")
              | None -> Error "native retry error_status is required" in
            let* error_category = string "error_category" in
            Ok (Retry_observed (Retry_reported {agent;attempt;max_retries;retry_delay_ms;error_status;error_category}))
        | Some (`String "output_observed") when sorted = ["byte_count"; "kind"] ->
            (match List.assoc_opt "byte_count" fields with
             | Some json ->
                 (match Runtime_json_integer.of_json json with
                  | Ok byte_count when byte_count > 0 -> Ok (Output_observed {byte_count})
                  | Ok _ | Error _ -> Error "native output byte_count must be a positive safe integer")
             | None -> Error "native output byte_count must be a positive safe integer")
        | Some (`String "heartbeat_reported") when sorted = ["elapsed_seconds"; "kind"] ->
            (match List.assoc_opt "elapsed_seconds" fields with
             | Some json ->
                 (match Runtime_json_integer.of_json json with
                  | Ok elapsed_seconds when elapsed_seconds >= 0 -> Ok (Heartbeat_reported {elapsed_seconds})
                  | Ok _ | Error _ -> Error "native heartbeat elapsed_seconds must be a nonnegative safe integer")
             | None -> Error "native heartbeat elapsed_seconds must be a nonnegative safe integer")
        | Some (`String "message_reported") when sorted = ["kind"; "message"] ->
            (match List.assoc_opt "message" fields with
             | Some (`String message) -> Ok (Message_reported {message})
             | _ -> Error "native progress message must be a string")
        | _ -> Error "native progress kind or fields are invalid")
  | _ -> Error "native progress must be an object"

let redact_progress redact = function
  | (Output_observed _ | Heartbeat_reported _) as progress -> progress
  | Message_reported {message} -> Message_reported {message=redact message}
  | Retry_observed retry ->
      let agent value = {value with subagent_type=redact value.subagent_type} in
      Retry_observed (match retry with
        | Retry_cleared value -> Retry_cleared (agent value)
        | Retry_reported note -> Retry_reported
            {note with agent=agent note.agent; error_category=redact note.error_category})

let end_observed = {outcome=End_observed; exit_code=None}
let completion_unrecorded = {outcome=Completion_unrecorded; exit_code=None}

let completion_to_json {outcome; exit_code} =
  let kind, fields = match outcome with
    | End_observed -> "end_observed", []
    | Completion_unrecorded -> "completion_unrecorded", []
    | Completion_reported -> "completion_reported", []
    | Error_reported -> "error_reported", []
    | Decline_reported -> "decline_reported", []
    | Result_received {is_error} -> "result_received",
        ["is_error", Option.fold ~none:`Null ~some:(fun value -> `Bool value) is_error]
    | Unrecognized_status value -> "unrecognized_status", ["status", `String value]
  in
  `Assoc (["kind", `String kind;
    "exit_code", Option.fold ~none:`Null ~some:(fun value -> `Int value) exit_code] @ fields)

let completion_of_json = function
  | `Assoc fields ->
      let ( let* ) = Result.bind in
      let rec unique seen = function
        | [] -> Ok ()
        | (key, _) :: rest ->
            if List.mem key seen then Error ("duplicate native completion field: " ^ key)
            else unique (key :: seen) rest
      in
      let* () = unique [] fields in
      let* outcome = match List.assoc_opt "kind" fields with
        | Some (`String "end_observed") -> Ok End_observed
        | Some (`String "completion_unrecorded") -> Ok Completion_unrecorded
        | Some (`String "completion_reported") -> Ok Completion_reported
        | Some (`String "error_reported") -> Ok Error_reported
        | Some (`String "decline_reported") -> Ok Decline_reported
        | Some (`String "result_received") ->
            (match List.assoc_opt "is_error" fields with
             | Some `Null -> Ok (Result_received {is_error=None})
             | Some (`Bool value) -> Ok (Result_received {is_error=Some value})
             | Some _ | None -> Error "native result is_error must be a boolean or null")
        | Some (`String "unrecognized_status") ->
            (match List.assoc_opt "status" fields with
             | Some (`String value) -> Ok (Unrecognized_status value)
             | Some _ | None -> Error "unrecognized native status must retain its string")
        | Some _ | None -> Error "native completion kind is missing or unknown"
      in
      let allowed = ["kind"; "exit_code"] @ (match outcome with
        | Result_received _ -> ["is_error"]
        | Unrecognized_status _ -> ["status"]
        | End_observed | Completion_unrecorded | Completion_reported | Error_reported
        | Decline_reported -> []) in
      let* () = match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
        | None -> Ok ()
        | Some (key, _) -> Error ("unsupported native completion field: " ^ key)
      in
      (match outcome, List.assoc_opt "exit_code" fields with
       | _, Some `Null -> Ok {outcome; exit_code=None}
       | Completion_unrecorded, Some _ -> Error "an unrecorded native completion has no exit_code"
       | ( End_observed | Completion_reported | Error_reported | Decline_reported
         | Result_received _ | Unrecognized_status _ ), Some json ->
           (match Runtime_json_integer.of_json json with
            | Ok value -> Ok {outcome; exit_code=Some value}
            | Error _ -> Error "native exit_code must be a safe integer or null")
       | _, None -> Error "native exit_code must be a safe integer or null")
  | _ -> Error "native completion must be an object"

let redact_completion redact completion =
  match completion.outcome with
  | Unrecognized_status status -> {completion with outcome=Unrecognized_status (redact status)}
  | End_observed | Completion_unrecorded | Completion_reported | Error_reported | Decline_reported
  | Result_received _ -> completion

let valid_identity = function
  | Call_id call_id -> String.trim call_id <> ""
  | Provider_step { conversation_id; step_index } ->
    String.trim conversation_id <> "" && step_index >= 0
;;

let exact_action (observation : observation) =
  match observation with
  | { identity = Some identity; tool_name = Some tool_name; origin = Built_in }
    when valid_identity identity && String.trim tool_name <> "" ->
    Some (identity, tool_name)
  | { origin = Mcp_wrapper; _ }
  | { identity = None; _ }
  | { tool_name = None; _ }
  | { identity = Some _; tool_name = Some _ } -> None
;;

let observe_exact_action ~official_turn ~observe observation =
  Option.iter
    (fun (identity, tool_name) -> observe ~official_turn ~identity ~tool_name)
    (exact_action observation)
;;

let call_id observation =
  match observation.identity with
  | Some (Call_id call_id) -> Some call_id
  | Some (Provider_step _) | None -> None
;;

let stream_content_type = "native_tool_use"

let to_string = function
  | Native_none -> "none"
  | Native_read -> "read"
  | Native_full -> "full"
;;

let of_string = function
  | "none" -> Some Native_none
  | "read" -> Some Native_read
  | "full" -> Some Native_full
  | _ -> None
;;

let valid_posture_strings = [ "none"; "read"; "full" ]
let claude_code_default = Native_none
let codex_default = Native_read
let antigravity_default = Native_read
let muse_default = Native_read
let muse_none_supported = false

(* WebFetch/WebSearch observe no local state but do reach the network, so
   they stay out of the read set until the RFC widens it deliberately. *)
let claude_code_read_tool_names = [ "Read"; "Glob"; "Grep" ]

(* RFC-0390 admission review: a declared posture that admission cannot
   honor resolves to the posture the client actually runs, instead of
   failing the whole runtime call. [full] under a non-yolo approval mode
   becomes [read] (effects stay behind the gate) — a true downgrade,
   reported per turn because the approval mode is turn state. [none] on
   a client without a disable switch becomes [read] (the client's own
   floor: its built-ins keep running no matter what we pass) — this is
   NOT a downgrade but a static contradiction (profile says [none],
   runtime.toml assigned a runtime that cannot honor it), so the event
   is reported once per process, not per turn (#30408 review). *)
let degrade_on_admission ~posture ~none_supported () =
  match (posture, none_supported) with
  | Native_full, _ -> Native_read
  | Native_none, false -> Native_read
  | posture, _ -> posture
;;

(* Claude Code's own schema lookup, and the reason every posture names it.
   [--tools] narrows the CLI's built-in set to exactly the names it lists, and
   [ToolSearch] is one of those built-ins. A list without it therefore also
   turns off the CLI's deferred loading of MCP tools — [isToolSearchEnabled]
   refuses when the tool is absent — so every masc tool schema is sent inline
   on every request instead of by name.

   It carries no posture cost: it observes no local state, reaches no network,
   and returns only the schemas of tools masc itself declared and already
   named in [--allowedTools]. So [none] keeps its meaning (no built-in touches
   the machine) while the CLI can still defer.

   Measured 2026-09-16 in the fleet's own argv shape (empty [--tools],
   [--strict-mcp-config], [--permission-mode dontAsk]) against a probe MCP
   server carrying 203 tools: 176,928 input tokens for the first request
   without this name, 8,926 with it. *)
let claude_code_schema_lookup_tool_name = "ToolSearch"

let claude_code_tools_arg = function
  | Native_none -> claude_code_schema_lookup_tool_name
  | Native_read ->
    String.concat
      ","
      (claude_code_read_tool_names @ [ claude_code_schema_lookup_tool_name ])
  (* [default] is the whole built-in set, which already carries the lookup. *)
  | Native_full -> "default"
;;

let claude_setting_sources_arg = "--setting-sources="
