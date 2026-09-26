type error =
  { stage : string
  ; detail : string
  }

let error_to_string { stage; detail } = Printf.sprintf "MSP %s: %s" stage detail
let ( let* ) = Result.bind
let fail stage detail = Error { stage; detail }

module Json = Runtime_official_client_json.Make (struct
  type t = error

  let protocol ~stage ~detail = { stage; detail }
end)

open Json

(* Present and a string; empty is allowed. For text MASC carries through
   rather than keys on: a reply, a delta, a tool's output. *)
let required_text stage name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ -> fail stage (Printf.sprintf "field %S must be a string" name)
  | None -> fail stage (Printf.sprintf "missing field %S" name)
;;

let optional_text stage name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> fail stage (Printf.sprintf "field %S must be a string" name)
;;

let required_int stage name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some _ -> fail stage (Printf.sprintf "field %S must be an integer" name)
  | None -> fail stage (Printf.sprintf "missing field %S" name)
;;

let required_count stage name fields =
  let* value = required_int stage name fields in
  if value < 0
  then fail stage (Printf.sprintf "field %S must not be negative" name)
  else Ok value
;;

let optional_assoc stage name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some json ->
    let* assoc = assoc_at stage json in
    Ok (Some assoc)
;;

let rec map_result f = function
  | [] -> Ok []
  | x :: rest ->
    let* y = f x in
    let* ys = map_result f rest in
    Ok (y :: ys)
;;

(* ── Frames ─────────────────────────────────────────────────────────── *)

type request_id =
  | Int_id of int
  | String_id of string

let request_id_to_json = function
  | Int_id id -> `Int id
  | String_id id -> `String id
;;

type wire_message =
  | Response of
      { id : request_id
      ; result : Yojson.Safe.t
      }
  | Response_error of
      { id : request_id option
      ; code : int
      ; message : string
      ; data : Yojson.Safe.t option
      }
  | Notification of
      { method_ : string
      ; params : Yojson.Safe.t
      }
  | Server_request of
      { id : request_id
      ; method_ : string
      ; params : Yojson.Safe.t
      }

let request_id_of_json stage = function
  | `Int id -> Ok (Int_id id)
  | `String id -> Ok (String_id id)
  | _ -> fail stage "id must be an integer or a string"
;;

let parse_rpc_error id fields =
  let stage = "JSON-RPC error" in
  let* error_json = required_member stage "error" fields in
  let* error_fields = assoc_at stage error_json in
  let* message = required_text stage "message" error_fields in
  let* code = required_int stage "code" error_fields in
  let data =
    match List.assoc_opt "data" error_fields with
    | None | Some `Null -> None
    | Some data -> Some data
  in
  Ok (Response_error { id; code; message; data })
;;

let params_of fields =
  match List.assoc_opt "params" fields with
  | None -> `Assoc []
  | Some params -> params
;;

let parse_wire_line line =
  let stage = "JSON-RPC message" in
  let* json =
    match Yojson.Safe.from_string line with
    | json -> Ok json
    | exception Yojson.Json_error detail -> fail stage ("invalid JSON: " ^ detail)
  in
  let* () = validate_unique_object_keys ~stage ~path:"$" json in
  let* fields = assoc_at stage json in
  match List.assoc_opt "id" fields, List.assoc_opt "method" fields with
  | Some id, Some (`String method_) ->
    let* id = request_id_of_json stage id in
    Ok (Server_request { id; method_; params = params_of fields })
  | Some `Null, None ->
    (match List.assoc_opt "error" fields with
     | Some _ -> parse_rpc_error None fields
     | None -> fail stage "only an error response may carry a null id")
  | Some id, None ->
    let* id = request_id_of_json stage id in
    (match List.assoc_opt "error" fields with
     | Some _ -> parse_rpc_error (Some id) fields
     | None ->
       let* result = required_member stage "result" fields in
       Ok (Response { id; result }))
  | None, Some (`String method_) ->
    Ok (Notification { method_; params = params_of fields })
  | _, Some _ -> fail stage "method must be a string"
  | None, None -> fail stage "message has neither id nor method"
;;

let request ~id ~method_ params =
  `Assoc
    [ "jsonrpc", `String "2.0"
    ; "id", `Int id
    ; "method", `String method_
    ; "params", `Assoc params
    ]
;;

(* ── Client to server ───────────────────────────────────────────────── *)

type client_info =
  { name : string
  ; version : string
  }

type capability =
  | Session_mcp
  | User_shell
  | Session_list_stream
  | Unrecognized_capability of string

let capability_to_string = function
  | Session_mcp -> "sessionMcp"
  | User_shell -> "userShell"
  | Session_list_stream -> "sessionListStream"
  | Unrecognized_capability name -> name
;;

let capability_of_string = function
  | "sessionMcp" -> Session_mcp
  | "userShell" -> User_shell
  | "sessionListStream" -> Session_list_stream
  | name -> Unrecognized_capability name
;;

let initialize_request ~id { name; version } ~requested_capabilities ~user_input_dialogs =
  request
    ~id
    ~method_:"initialize"
    [ "clientInfo", `Assoc [ "name", `String name; "version", `String version ]
    ; ( "capabilities"
      , `Assoc
          (( "requestedCapabilities"
           , `List
               (List.map
                  (fun capability -> `String (capability_to_string capability))
                  requested_capabilities) )
           :: (if user_input_dialogs then [] else [ "userInputDialogs", `Bool false ])) )
    ]
;;

let initialized_notification =
  `Assoc [ "jsonrpc", `String "2.0"; "method", `String "initialized" ]
;;

type approval_mode =
  | Allow_all
  | Prompt_unmatched
  | On_request
  | Deny_unmatched

let approval_mode_to_string = function
  | Allow_all -> "allowAll"
  | Prompt_unmatched -> "promptUnmatched"
  | On_request -> "onRequest"
  | Deny_unmatched -> "denyUnmatched"
;;

type reasoning_effort =
  | Effort_none
  | Effort_minimal
  | Effort_low
  | Effort_medium
  | Effort_high
  | Effort_xhigh
  | Effort_max
  | Effort_ultra

let reasoning_effort_to_string = function
  | Effort_none -> "none"
  | Effort_minimal -> "minimal"
  | Effort_low -> "low"
  | Effort_medium -> "medium"
  | Effort_high -> "high"
  | Effort_xhigh -> "xhigh"
  | Effort_max -> "max"
  | Effort_ultra -> "ultra"
;;

let reasoning_effort_of_string = function
  | "none" -> Some Effort_none
  | "minimal" -> Some Effort_minimal
  | "low" -> Some Effort_low
  | "medium" -> Some Effort_medium
  | "high" -> Some Effort_high
  | "xhigh" -> Some Effort_xhigh
  | "max" -> Some Effort_max
  | "ultra" -> Some Effort_ultra
  | _ -> None
;;

type mcp_server =
  | Streamable_http of
      { url : string
      ; headers : (string * string) list
      ; required : bool
      }

type session_config = { mcp_servers : (string * mcp_server) list }

let mcp_server_json = function
  | Streamable_http { url; headers; required } ->
    `Assoc
      [ "transport", `String "streamableHttp"
      ; "url", `String url
      ; "headers", `Assoc (List.map (fun (k, v) -> k, `String v) headers)
      ; "mode", `String (if required then "required" else "optional")
      ]
;;

(* An empty server map is left off rather than sent as [{}], so a session
   with no MASC tools asks the host for nothing. *)
let config_fields { mcp_servers } =
  match mcp_servers with
  | [] -> []
  | servers ->
    [ ( "config"
      , `Assoc
          [ ( "mcpServers"
            , `Assoc (List.map (fun (name, server) -> name, mcp_server_json server) servers)
            )
          ] )
    ]
;;

let session_start_request ~id ~command_id ~workspace_root ~model_id ~approval_mode ~config
  =
  let optional name to_json = function
    | None -> []
    | Some value -> [ name, to_json value ]
  in
  request
    ~id
    ~method_:"session/start"
    ([ "commandId", `String command_id; "workspaceRoot", `String workspace_root ]
     @ optional "modelId" (fun m -> `String m) model_id
     @ optional
         "approvalMode"
         (fun mode -> `String (approval_mode_to_string mode))
         approval_mode
     @ config_fields config)
;;

let session_resume_request ~id ~command_id ~session_id ~config =
  request
    ~id
    ~method_:"session/resume"
    ([ "commandId", `String command_id
     ; "sessionId", `String session_id
     ; "excludeItems", `Bool true
     ]
     @ config_fields config)
;;

type input_part =
  | Text of string
  | Image of
      { media_type : string
      ; base64_data : string
      }

let input_part_json = function
  | Text text -> `Assoc [ "type", `String "text"; "text", `String text ]
  | Image { media_type; base64_data } ->
    `Assoc
      [ "type", `String "image"
      ; "base64Data", `String base64_data
      ; "mediaType", `String media_type
      ]
;;

let session_set_approval_mode_request ~id ~command_id ~session_id mode =
  request
    ~id
    ~method_:"session/setApprovalMode"
    [ "commandId", `String command_id
    ; "sessionId", `String session_id
    ; "mode", `String (approval_mode_to_string mode)
    ]
;;

let turn_start_request ~id ~session_id ~command_id ~input ~reasoning_effort =
  request
    ~id
    ~method_:"turn/start"
    ([ "sessionId", `String session_id
     ; "commandId", `String command_id
     ; "input", `List (List.map input_part_json input)
     ]
     @ (match reasoning_effort with
        | None -> []
        | Some effort -> [ "reasoningEffort", `String (reasoning_effort_to_string effort) ]))
;;

let turn_interrupt_request ~id ~session_id ~command_id ~turn_id =
  request
    ~id
    ~method_:"turn/interrupt"
    [ "sessionId", `String session_id
    ; "commandId", `String command_id
    ; "turnId", `String turn_id
    ]
;;

let usage_read_request ~id = request ~id ~method_:"usage/read" []

let method_not_found = -32601

let server_request_error id ~code ~message =
  `Assoc
    [ "jsonrpc", `String "2.0"
    ; "id", request_id_to_json id
    ; "error", `Assoc [ "code", `Int code; "message", `String message ]
    ]
;;

let server_request_ack id =
  `Assoc
    [ "jsonrpc", `String "2.0"; "id", request_id_to_json id; "result", `Assoc [] ]
;;

(* ── Server to client ───────────────────────────────────────────────── *)

type initialize_result =
  { server_version : string
  ; user_agent : string
  ; muse_home : string
  ; schema_fingerprint : string
  ; granted_capabilities : capability list
  }

let parse_initialize_result json =
  let stage = "initialize" in
  let* fields = assoc_at stage json in
  let* server_info = required_member stage "serverInfo" fields in
  let* server_info = assoc_at stage server_info in
  let* server_version = required_string stage "version" server_info in
  let* user_agent = required_string stage "userAgent" fields in
  let* muse_home = required_string stage "museHome" fields in
  let* schema = required_member stage "schema" fields in
  let* schema = assoc_at stage schema in
  let* schema_version = required_int stage "version" schema in
  let* () =
    if schema_version = 1
    then Ok ()
    else fail stage (Printf.sprintf "MSP schema version %d is not v1" schema_version)
  in
  let* schema_fingerprint = required_string stage "fingerprint" schema in
  let* granted_capabilities =
    match List.assoc_opt "grantedCapabilities" fields with
    | Some (`List names) ->
      map_result
        (function
          | `String name -> Ok (capability_of_string name)
          | _ -> fail stage "grantedCapabilities must hold strings")
        names
    | Some _ -> fail stage "field \"grantedCapabilities\" must be an array"
    | None -> fail stage "missing field \"grantedCapabilities\""
  in
  Ok { server_version; user_agent; muse_home; schema_fingerprint; granted_capabilities }
;;

let corpus_schema_fingerprint =
  "sha256:c8d1a2a1866814e220fd396d382a9a75861412feee884b5021b2ee359bd3dc59"
;;

type session =
  { session_id : string
  ; model_id : string option
  ; workspace_root : string option
  }

let parse_session_result ~stage json =
  let* fields = assoc_at stage json in
  let* session = required_member stage "session" fields in
  let* session = assoc_at stage session in
  let* session_id = required_string stage "sessionId" session in
  let* model_id = optional_string stage "modelId" session in
  let* workspace_root = optional_string stage "workspaceRoot" session in
  Ok ({ session_id; model_id; workspace_root } : session)
;;

type turn_disposition =
  | Started
  | Queued
  | Steered
  | Unrecognized_disposition of string

type turn_start_ack =
  { turn_id : string
  ; disposition : turn_disposition
  }

let turn_disposition_of_string = function
  | "started" -> Started
  | "queued" -> Queued
  | "steered" -> Steered
  | other -> Unrecognized_disposition other
;;

let parse_turn_start_result json =
  let stage = "turn/start" in
  let* fields = assoc_at stage json in
  let* turn_id = required_string stage "turnId" fields in
  let* disposition = required_string stage "disposition" fields in
  Ok ({ turn_id; disposition = turn_disposition_of_string disposition } : turn_start_ack)
;;

type token_usage =
  { input_tokens : int
  ; output_tokens : int
  ; cached_tokens : int
  ; reasoning_tokens : int
  }

let parse_token_usage stage fields =
  let* input_tokens = required_count stage "inputTokens" fields in
  let* output_tokens = required_count stage "outputTokens" fields in
  let* cached_tokens = required_count stage "cachedTokens" fields in
  let* reasoning_tokens = required_count stage "reasoningTokens" fields in
  Ok { input_tokens; output_tokens; cached_tokens; reasoning_tokens }
;;

type turn_error_kind =
  | Step_limit
  | Config_error
  | Projection_error
  | Log_error
  | Workflow_launch_error
  | Environment_error
  | Model_error
  | Launch_error
  | Auth_required
  | Unrecognized_error_kind of string

type turn_error =
  { kind : turn_error_kind
  ; message : string
  ; retryable : bool
  }

type terminal =
  | Terminal_completed
  | Terminal_failed of turn_error
  | Terminal_cancelled
  | Unrecognized_terminal of string

let turn_error_kind_of_string = function
  | "stepLimit" -> Step_limit
  | "configError" -> Config_error
  | "projectionError" -> Projection_error
  | "logError" -> Log_error
  | "workflowLaunchError" -> Workflow_launch_error
  | "environmentError" -> Environment_error
  | "modelError" -> Model_error
  | "launchError" -> Launch_error
  | "authRequired" -> Auth_required
  | other -> Unrecognized_error_kind other
;;

let turn_error_kind_to_string = function
  | Step_limit -> "stepLimit"
  | Config_error -> "configError"
  | Projection_error -> "projectionError"
  | Log_error -> "logError"
  | Workflow_launch_error -> "workflowLaunchError"
  | Environment_error -> "environmentError"
  | Model_error -> "modelError"
  | Launch_error -> "launchError"
  | Auth_required -> "authRequired"
  | Unrecognized_error_kind other -> other
;;

let parse_turn_error stage fields =
  let* kind = required_string stage "kind" fields in
  let* message = required_text stage "message" fields in
  let* retryable = required_bool stage "retryable" fields in
  Ok ({ kind = turn_error_kind_of_string kind; message; retryable } : turn_error)
;;

(* A "failed" terminal must carry [error] (tdd SS4.5.1); one without it is a
   host that broke its own contract, so it is refused rather than filled
   in. The schema keeps [error] optional on the other terminals, so an
   [error] beside "completed" or "cancelled" is not read: the terminal
   decides the outcome. *)
let parse_terminal stage fields =
  let* terminal = required_string stage "terminal" fields in
  let* error = optional_assoc stage "error" fields in
  match terminal, error with
  | "completed", _ -> Ok Terminal_completed
  | "cancelled", _ -> Ok Terminal_cancelled
  | "failed", Some error ->
    let* error = parse_turn_error stage error in
    Ok (Terminal_failed error)
  | "failed", None -> fail stage "failed terminal carries no error"
  | other, _ -> Ok (Unrecognized_terminal other)
;;

type item_kind =
  | User_message
  | Agent_message
  | Reasoning
  | Tool_call
  | User_shell
  | Subagent
  | Workflow
  | Reminder_child
  | Compaction
  | Unrecognized_item_kind of string

let item_kind_of_string = function
  | "userMessage" -> User_message
  | "agentMessage" -> Agent_message
  | "reasoning" -> Reasoning
  | "toolCall" -> Tool_call
  | "userShell" -> User_shell
  | "subagent" -> Subagent
  | "workflow" -> Workflow
  | "reminderChild" -> Reminder_child
  | "compaction" -> Compaction
  | other -> Unrecognized_item_kind other
;;

type item_status =
  | In_progress
  | Item_completed_status
  | Item_failed
  | Item_cancelled
  | Item_rejected
  | Item_timed_out
  | Unrecognized_item_status of string

let item_status_of_string = function
  | "inProgress" -> In_progress
  | "completed" -> Item_completed_status
  | "failed" -> Item_failed
  | "cancelled" -> Item_cancelled
  | "rejected" -> Item_rejected
  | "timedOut" -> Item_timed_out
  | other -> Unrecognized_item_status other
;;

type item =
  { item_id : string
  ; kind : item_kind
  ; status : item_status
  ; revision : int
  ; turn_id : string option
  ; text : string option
  ; tool : string option
  ; call_id : string option
  ; args : string option
  ; visible_output : string option
  }

let parse_item stage json =
  let* fields = assoc_at stage json in
  let* item_id = required_string stage "itemId" fields in
  let* kind = required_string stage "kind" fields in
  let* status = required_string stage "status" fields in
  let* revision = required_int stage "revision" fields in
  let* turn_id = optional_string stage "turnId" fields in
  let* text = optional_text stage "text" fields in
  let* tool = optional_string stage "tool" fields in
  let* call_id = optional_string stage "callId" fields in
  let* args = optional_text stage "args" fields in
  let* visible_output = optional_text stage "visibleOutput" fields in
  Ok
    ({ item_id
    ; kind = item_kind_of_string kind
    ; status = item_status_of_string status
    ; revision
    ; turn_id
    ; text
    ; tool
    ; call_id
    ; args
    ; visible_output
    }
      : item)
;;

type delta_field =
  | Delta_text
  | Delta_output
  | Delta_summary of int
  | Unrecognized_delta_field of string

(* "summary.n" addresses part n of a reasoning summary; the index is the only
   part of a field path that carries a value. *)
let delta_field_of_string = function
  | "text" -> Delta_text
  | "output" -> Delta_output
  | path ->
    (match String.split_on_char '.' path with
     | [ "summary"; index ] ->
       (match int_of_string_opt index with
        | Some n when n >= 0 -> Delta_summary n
        | Some _ | None -> Unrecognized_delta_field path)
     | _ -> Unrecognized_delta_field path)
;;

type usage_window =
  { used_percent : int
  ; resets_at_ms : int
  ; window_duration_mins : int
  }

type usage_weekly =
  { weekly_used_percent : int
  ; weekly_resets_at_ms : int
  }

type subscription_usage =
  { observed_at_ms : int
  ; tier : string
  ; window : usage_window
  ; weekly : usage_weekly
  }

let parse_subscription_usage stage fields =
  let* observed_at_ms = required_count stage "observedAtMs" fields in
  let* tier = required_string stage "tier" fields in
  let* window = required_member stage "window" fields in
  let* window = assoc_at stage window in
  let* used_percent = required_count stage "usedPercent" window in
  let* resets_at_ms = required_count stage "resetsAtMs" window in
  let* window_duration_mins = required_count stage "windowDurationMins" window in
  let* () =
    if window_duration_mins > 0
    then Ok ()
    else fail stage "field \"windowDurationMins\" must be positive"
  in
  let* weekly = required_member stage "weekly" fields in
  let* weekly = assoc_at stage weekly in
  let* weekly_used_percent = required_count stage "usedPercent" weekly in
  let* weekly_resets_at_ms = required_count stage "resetsAtMs" weekly in
  Ok
    { observed_at_ms
    ; tier
    ; window = { used_percent; resets_at_ms; window_duration_mins }
    ; weekly = { weekly_used_percent; weekly_resets_at_ms }
    }
;;

type notification =
  | Turn_started of
      { session_id : string
      ; turn_id : string
      }
  | Turn_completed of
      { session_id : string
      ; turn_id : string
      ; terminal : terminal
      ; usage : token_usage option
      ; reason : string option
      }
  | Item_started of
      { session_id : string
      ; item : item
      }
  | Item_updated of
      { session_id : string
      ; item : item
      }
  | Item_completed of
      { session_id : string
      ; item : item
      }
  | Item_delta of
      { session_id : string
      ; item_id : string
      ; field : delta_field
      ; delta : string
      }
  | Usage_changed of subscription_usage
  | Unhandled_notification of { method_ : string }

let item_notification ~stage fields =
  let* session_id = required_string stage "sessionId" fields in
  let* item = required_member stage "item" fields in
  let* item = parse_item stage item in
  Ok (session_id, item)
;;

let parse_notification ~method_ params =
  let stage = method_ in
  let* fields = assoc_at stage params in
  match method_ with
  | "turn/started" ->
    let* session_id = required_string stage "sessionId" fields in
    let* turn_id = required_string stage "turnId" fields in
    Ok (Turn_started { session_id; turn_id })
  | "turn/completed" ->
    let* session_id = required_string stage "sessionId" fields in
    let* turn_id = required_string stage "turnId" fields in
    let* terminal = parse_terminal stage fields in
    let* usage = optional_assoc stage "usage" fields in
    let* usage =
      match usage with
      | None -> Ok None
      | Some usage ->
        let* usage = parse_token_usage stage usage in
        Ok (Some usage)
    in
    let* reason = optional_text stage "reason" fields in
    Ok (Turn_completed { session_id; turn_id; terminal; usage; reason })
  | "item/started" ->
    let* session_id, item = item_notification ~stage fields in
    Ok (Item_started { session_id; item })
  | "item/updated" ->
    let* session_id, item = item_notification ~stage fields in
    Ok (Item_updated { session_id; item })
  | "item/completed" ->
    let* session_id, item = item_notification ~stage fields in
    Ok (Item_completed { session_id; item })
  | "item/delta" ->
    let* session_id = required_string stage "sessionId" fields in
    let* item_id = required_string stage "itemId" fields in
    let* field = optional_string stage "field" fields in
    let* delta = required_text stage "delta" fields in
    let field =
      match field with
      | None -> Delta_text
      | Some path -> delta_field_of_string path
    in
    Ok (Item_delta { session_id; item_id; field; delta })
  | "usage/changed" ->
    let* usage = parse_subscription_usage stage fields in
    Ok (Usage_changed usage)
  | _ -> Ok (Unhandled_notification { method_ })
;;

type approval_decision =
  | Approved
  | Approved_for_session
  | Approved_policy_amendment
  | Denied
  | Denied_policy_amendment
  | Timed_out
  | Abort
  | Unrecognized_decision of string

let approval_decision_of_string = function
  | "approved" -> Approved
  | "approvedForSession" -> Approved_for_session
  | "approvedPolicyAmendment" -> Approved_policy_amendment
  | "denied" -> Denied
  | "deniedPolicyAmendment" -> Denied_policy_amendment
  | "timedOut" -> Timed_out
  | "abort" -> Abort
  | other -> Unrecognized_decision other
;;

type approval_subject_kind =
  | Subject_shell
  | Subject_file_access
  | Subject_network
  | Subject_unix_socket
  | Subject_process
  | Subject_tool
  | Unrecognized_subject of string

let approval_subject_kind_of_string = function
  | "shell" -> Subject_shell
  | "fileAccess" -> Subject_file_access
  | "network" -> Subject_network
  | "unixSocket" -> Subject_unix_socket
  | "process" -> Subject_process
  | "tool" -> Subject_tool
  | other -> Unrecognized_subject other
;;

type approval_choice =
  { choice_id : string
  ; decision : approval_decision
  }

type approval_requirement =
  { requirement_approval_id : string
  ; source_index : int
  }

type approval_request =
  { session_id : string
  ; approval_id : string
  ; requirement : approval_requirement
  ; turn_id : string
  ; tool_name : string
  ; subject_kind : approval_subject_kind
  ; choices : approval_choice list
  }

type server_request =
  | Approval_request of approval_request
  | User_input_request of
      { session_id : string
      ; user_input_id : string
      ; turn_id : string
      }
  | Unhandled_server_request of { method_ : string }

let parse_approval_choice stage json =
  let* fields = assoc_at stage json in
  let* choice_id = required_string stage "choiceId" fields in
  let* decision = required_string stage "decision" fields in
  Ok ({ choice_id; decision = approval_decision_of_string decision } : approval_choice)
;;

let parse_approval_request stage fields =
  let* session_id = required_string stage "sessionId" fields in
  let* approval_id = required_string stage "approvalId" fields in
  let* requirement = required_member stage "currentRequirementId" fields in
  let* requirement = assoc_at stage requirement in
  let* requirement_approval_id = required_string stage "approvalId" requirement in
  let* source_index = required_count stage "sourceIndex" requirement in
  let* turn_id = required_string stage "turnId" fields in
  let* tool_name = required_string stage "toolName" fields in
  let* subject = required_member stage "subject" fields in
  let* subject = assoc_at stage subject in
  let* subject_kind = required_string stage "kind" subject in
  let* choices =
    match List.assoc_opt "availableChoices" fields with
    | Some (`List choices) -> map_result (parse_approval_choice stage) choices
    | Some _ -> fail stage "field \"availableChoices\" must be an array"
    | None -> fail stage "missing field \"availableChoices\""
  in
  Ok
    ({ session_id
    ; approval_id
    ; requirement = { requirement_approval_id; source_index }
    ; turn_id
    ; tool_name
    ; subject_kind = approval_subject_kind_of_string subject_kind
    ; choices
    }
      : approval_request)
;;

let parse_server_request ~method_ params =
  let stage = method_ in
  let* fields = assoc_at stage params in
  match method_ with
  | "approval/request" ->
    let* request = parse_approval_request stage fields in
    Ok (Approval_request request)
  | "userInput/request" ->
    let* session_id = required_string stage "sessionId" fields in
    let* user_input_id = required_string stage "userInputId" fields in
    let* turn_id = required_string stage "turnId" fields in
    Ok (User_input_request { session_id; user_input_id; turn_id })
  | _ -> Ok (Unhandled_server_request { method_ })
;;

let approval_decide_request
      ~id
      ~command_id
      (approval : approval_request)
      (choice : approval_choice)
  =
  request
    ~id
    ~method_:"approval/decide"
    [ "sessionId", `String approval.session_id
    ; "commandId", `String command_id
    ; "approvalId", `String approval.approval_id
    ; ( "requirementId"
      , `Assoc
          [ "approvalId", `String approval.requirement.requirement_approval_id
          ; "sourceIndex", `Int approval.requirement.source_index
          ] )
    ; "choiceId", `String choice.choice_id
    ]
;;

type approval_resolver =
  | Resolved_by_user
  | Resolved_by_policy
  | Resolved_by_llm_judge
  | Unrecognized_resolver of string

let approval_resolver_of_string = function
  | "user" -> Resolved_by_user
  | "policy" -> Resolved_by_policy
  | "llmJudge" -> Resolved_by_llm_judge
  | other -> Unrecognized_resolver other
;;

type approval_resolution =
  { decision : approval_decision
  ; resolved_by : approval_resolver
  }

type rpc_error_kind =
  | Rpc_parse_error
  | Rpc_invalid_request
  | Rpc_not_initialized
  | Rpc_already_initialized
  | Rpc_method_not_found
  | Rpc_experimental_required
  | Rpc_invalid_params
  | Rpc_internal
  | Rpc_page_event_too_large
  | Rpc_output_result_too_large
  | Rpc_overloaded
  | Rpc_input_too_large
  | Rpc_capability_required
  | Rpc_not_found
  | Rpc_interrupted
  | Rpc_cancelled
  | Rpc_session_not_found
  | Rpc_session_in_use
  | Rpc_session_ambiguous
  | Rpc_fork_boundary_invalid
  | Rpc_session_not_loaded
  | Rpc_session_stream_mismatch
  | Rpc_command_rejected
  | Rpc_backpressured
  | Rpc_skill_not_found
  | Rpc_view_truncated
  | Rpc_output_unavailable
  | Rpc_boundary_pruned
  | Rpc_boundary_unusable
  | Rpc_no_boundary
  | Rpc_approval_not_found
  | Rpc_approval_choice_invalid
  | Rpc_approval_requirement_stale
  | Rpc_approval_reviewer_unavailable
  | Rpc_user_input_not_found
  | Rpc_user_input_already_settled
  | Rpc_user_input_answer_invalid
  | Unrecognized_rpc_error_kind of string

type rpc_error_data =
  | Approval_already_resolved of approval_resolution option
  | Rpc_error_kind of rpc_error_kind

(* [approvalAlreadyResolved] is not here: [parse_rpc_error_data] reads it
   into its own case, with the resolution it carries. *)
let rpc_error_kind_of_string = function
  | "parseError" -> Rpc_parse_error
  | "invalidRequest" -> Rpc_invalid_request
  | "notInitialized" -> Rpc_not_initialized
  | "alreadyInitialized" -> Rpc_already_initialized
  | "methodNotFound" -> Rpc_method_not_found
  | "experimentalRequired" -> Rpc_experimental_required
  | "invalidParams" -> Rpc_invalid_params
  | "internal" -> Rpc_internal
  | "pageEventTooLarge" -> Rpc_page_event_too_large
  | "outputResultTooLarge" -> Rpc_output_result_too_large
  | "overloaded" -> Rpc_overloaded
  | "inputTooLarge" -> Rpc_input_too_large
  | "capabilityRequired" -> Rpc_capability_required
  | "notFound" -> Rpc_not_found
  | "interrupted" -> Rpc_interrupted
  | "cancelled" -> Rpc_cancelled
  | "sessionNotFound" -> Rpc_session_not_found
  | "sessionInUse" -> Rpc_session_in_use
  | "sessionAmbiguous" -> Rpc_session_ambiguous
  | "forkBoundaryInvalid" -> Rpc_fork_boundary_invalid
  | "sessionNotLoaded" -> Rpc_session_not_loaded
  | "sessionStreamMismatch" -> Rpc_session_stream_mismatch
  | "commandRejected" -> Rpc_command_rejected
  | "backpressured" -> Rpc_backpressured
  | "skillNotFound" -> Rpc_skill_not_found
  | "viewTruncated" -> Rpc_view_truncated
  | "outputUnavailable" -> Rpc_output_unavailable
  | "boundaryPruned" -> Rpc_boundary_pruned
  | "boundaryUnusable" -> Rpc_boundary_unusable
  | "noBoundary" -> Rpc_no_boundary
  | "approvalNotFound" -> Rpc_approval_not_found
  | "approvalChoiceInvalid" -> Rpc_approval_choice_invalid
  | "approvalRequirementStale" -> Rpc_approval_requirement_stale
  | "approvalReviewerUnavailable" -> Rpc_approval_reviewer_unavailable
  | "userInputNotFound" -> Rpc_user_input_not_found
  | "userInputAlreadySettled" -> Rpc_user_input_already_settled
  | "userInputAnswerInvalid" -> Rpc_user_input_answer_invalid
  | other -> Unrecognized_rpc_error_kind other
;;

let parse_approval_resolution stage json =
  let* fields = assoc_at stage json in
  let* decision = required_string stage "decision" fields in
  let* resolved_by = required_string stage "resolvedBy" fields in
  Ok
    { decision = approval_decision_of_string decision
    ; resolved_by = approval_resolver_of_string resolved_by
    }
;;

let parse_rpc_error_data json =
  let stage = "error.data" in
  let* fields = assoc_at stage json in
  let* kind = required_string stage "kind" fields in
  match kind with
  | "approvalAlreadyResolved" ->
    let* resolution =
      match List.assoc_opt "resolution" fields with
      | None | Some `Null -> Ok None
      | Some resolution ->
        let* resolution = parse_approval_resolution stage resolution in
        Ok (Some resolution)
    in
    Ok (Approval_already_resolved resolution)
  | other -> Ok (Rpc_error_kind (rpc_error_kind_of_string other))
;;

let parse_usage_read_result json =
  let stage = "usage/read" in
  let* fields = assoc_at stage json in
  let* usage = optional_assoc stage "usage" fields in
  match usage with
  | None -> Ok None
  | Some usage ->
    let* usage = parse_subscription_usage stage usage in
    Ok (Some usage)
;;
