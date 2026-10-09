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
  | Completion_reported
  | Error_reported
  | Decline_reported
  | Result_received of { is_error : bool option }
  | Unrecognized_status of string

type completion = { outcome : completion_outcome; exit_code : int option }
type finished = { observation : observation; completion : completion }

type progress =
  | Output_observed of { byte_count : int }
  | Message_reported of { message : string }

let progress_to_json = function
  | Output_observed {byte_count} -> `Assoc ["kind", `String "output_observed"; "byte_count", `Int byte_count]
  | Message_reported {message} -> `Assoc ["kind", `String "message_reported"; "message", `String message]

let progress_of_json = function
  | `Assoc fields ->
      let keys = List.map fst fields in
      let sorted = List.sort String.compare keys in
      if List.length keys <> List.length (List.sort_uniq String.compare keys)
      then Error "duplicate native progress field"
      else (match List.assoc_opt "kind" fields with
        | Some (`String "output_observed") when sorted = ["byte_count"; "kind"] ->
            (match List.assoc_opt "byte_count" fields with
             | Some (`Int byte_count) when byte_count > 0 -> Ok (Output_observed {byte_count})
             | _ -> Error "native output byte_count must be a positive integer")
        | Some (`String "message_reported") when sorted = ["kind"; "message"] ->
            (match List.assoc_opt "message" fields with
             | Some (`String message) -> Ok (Message_reported {message})
             | _ -> Error "native progress message must be a string")
        | _ -> Error "native progress kind or fields are invalid")
  | _ -> Error "native progress must be an object"

let redact_progress redact = function
  | Output_observed _ as progress -> progress
  | Message_reported {message} -> Message_reported {message=redact message}

let end_observed = {outcome=End_observed; exit_code=None}

let completion_to_json {outcome; exit_code} =
  let kind, fields = match outcome with
    | End_observed -> "end_observed", []
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
        | End_observed | Completion_reported | Error_reported | Decline_reported -> []) in
      let* () = match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
        | None -> Ok ()
        | Some (key, _) -> Error ("unsupported native completion field: " ^ key)
      in
      (match List.assoc_opt "exit_code" fields with
       | Some `Null -> Ok {outcome; exit_code=None}
       | Some (`Int value) -> Ok {outcome; exit_code=Some value}
       | Some _ | None -> Error "native exit_code must be an integer or null")
  | _ -> Error "native completion must be an object"

let redact_completion redact completion =
  match completion.outcome with
  | Unrecognized_status status -> {completion with outcome=Unrecognized_status (redact status)}
  | End_observed | Completion_reported | Error_reported | Decline_reported | Result_received _ -> completion

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
