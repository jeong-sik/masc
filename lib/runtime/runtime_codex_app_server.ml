(** Native Codex app-server single-turn execution.

    The official CLI keeps ownership of ChatGPT credentials. We deliberately
    remove API-key fallback variables from the child environment and then gate
    on [account/read = chatgpt] before starting a thread. *)

type subscription =
  { plan_type : string
  ; email : string option
  }

type probe_result =
  { subscription : subscription
  ; user_agent : string option
  }

type config =
  { cli_path : string
  ; model : string option
  ; developer_instructions : string option
  ; native : Runtime_native_tools.posture
  ; admission_timeout_s : float
  ; timeout_s : float option
  ; wall_clock_ceiling_s : float option
  ; output_schema : Yojson.Safe.t option
  }

let default_timeout_s = 300.0
let process_termination_grace_s = 2.0

(* [None] installs no deadline. The vendor client owns when its own turn ends;
   a declared bound is the operator's optional liveness guard over a silent
   client, not a limit on how long legitimate work may take. *)
let stderr_chunk_bytes = 4096
let stderr_tail_bytes = 4096
let max_wire_line_bytes = 8 * 1024 * 1024
let approval_policy = "never"
let thread_is_ephemeral = false

let client_version = Runtime_build_version.current

let default_config () =
  { cli_path = "codex"
  ; model = None
  ; developer_instructions = None
  ; native = Runtime_native_tools.codex_default
  ; admission_timeout_s = default_timeout_s
  ; timeout_s = Some default_timeout_s
  ; wall_clock_ceiling_s = None
  ; output_schema = None
  }
;;

type image_input =
  { media_type : string
  ; base64_data : string
  }

type thread_mode =
  | Start
  | Resume of { thread_id : string }

type turn_result =
  { thread_id : string
  ; turn_id : string
  ; model : string
  ; text : string
  ; dynamic_tool_calls : int
  ; subscription : subscription
  ; user_agent : string option
  ; resumed : bool
  }

type terminal_boundary_outcome = Runtime_official_client_tool.terminal_boundary_outcome =
  | Terminal_completed
  | Durable_stimulus_deferred
  | Terminal_failed of
      { failure_class : Tool_result.tool_failure_class
      ; effect_disposition : Tool_result.failure_effect_disposition
      ; diagnostic : string
      }

type host_stop = Runtime_official_client_tool.host_stop =
  | Repeated_tool_call of
      { tool_name : string
      ; repeated_count : int
      }
  | Terminal_tool_boundary of
      { tool_name : string
      ; outcome : terminal_boundary_outcome
      }

type dynamic_tool_result = Runtime_official_client_tool.dynamic_tool_result =
  { success : bool
  ; content : string
  ; abort_turn : host_stop option
  }

type dynamic_tool = Runtime_official_client_tool.dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

type stream_event =
  | Turn_started of
      { turn_id : string
      ; model : string
      }
  | Text_delta of string
  | Dynamic_tool_started of
      { call_id : string
      ; tool_name : string
      ; arguments : Yojson.Safe.t
      }
  | Dynamic_tool_finished of { call_id : string }
  | Native_tool_started of Runtime_native_tools.observation
  | Native_tool_finished of Runtime_native_tools.observation
  | Turn_finished of { text : string }

let emit_stream_event on_stream_event event =
  match on_stream_event with
  | None -> ()
  | Some callback ->
    (try callback event with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Runtime_agent.warn
         "Codex app-server stream callback raised: %s"
         (Printexc.to_string exn))

type history_role =
  | User
  | Assistant

type history_message =
  { role : history_role
  ; text : string
  }

let history_bytes messages =
  List.fold_left (fun acc message -> acc + String.length message.text) 0 messages
;;

let dynamic_tool_bytes = Runtime_official_client_tool.dynamic_tool_bytes

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Rpc_error of
      { method_ : string
      ; code : int option
      ; message : string
      }
  | Subscription_required of string
  | Unsupported_server_request of string
  | Context_window_exceeded of
      { message : string
      ; tool_effect_attempted : bool
      }
  | Turn_failed of string
  | Stopped_by_host of host_stop
  | Turn_interrupted
  | Runtime_shutting_down
  | Process_exited of string
  | Timeout of
      { seconds : float
      ; turn_accepted : bool
      }

(* These are named permissions profile ids, which the app-server keeps in a
   different value space from sandbox modes. [ThreadStartParams] carries both
   and admits only one: [permissions] is "Named profile id for this thread.
   Cannot be combined with `sandbox`." The field list below writes
   [permissions], so a [SandboxMode] value here names nothing.

   The ids are read off the app-server rather than guessed. codex-cli 0.153.2,
   [permissionProfile/list] over stdio (initialize, initialized, list — no
   thread and no prompt) answers with exactly three:
     ":read-only", ":workspace", ":danger-full-access".
   The CLI's -s read-only|workspace-write|danger-full-access is [SandboxMode],
   the [sandbox] field's vocabulary; "workspace-write" is absent from the
   profile list and from the binary's own profile table. [Native_full] takes
   ":workspace", which the vendor describes as allowing "writes inside the
   active workspace roots and system temp directories"
   (https://learn.chatgpt.com/docs/permissions).

   [Native_none] never reaches here: neither Codex nor its caller can disable
   the built-in tools, so the keeper layer rejects it first and this function
   refuses it as config. *)
let permissions_profile_of_posture = function
  | Runtime_native_tools.Native_read -> Ok ":read-only"
  | Runtime_native_tools.Native_full -> Ok ":workspace"
  | Runtime_native_tools.Native_none ->
    Error
      (Invalid_config
         "Codex cannot disable its built-in tools; use native read or full")
;;

let error_to_string = function
  | Invalid_config detail -> "invalid Codex app-server config: " ^ detail
  | Spawn_failed detail -> "failed to start Codex app-server: " ^ detail
  | Protocol_error { stage; detail } ->
    Printf.sprintf "Codex app-server protocol error during %s: %s" stage detail
  | Rpc_error { method_; code; message } ->
    let code = Option.fold ~none:"" ~some:(Printf.sprintf " (code %d)") code in
    Printf.sprintf "Codex app-server RPC %s failed%s: %s" method_ code message
  | Subscription_required detail ->
    "Codex ChatGPT subscription login required: " ^ detail
  | Unsupported_server_request method_ ->
    "Codex app-server requested unsupported host action: " ^ method_
  | Context_window_exceeded { message; tool_effect_attempted } ->
    Printf.sprintf
      "Codex app-server context window exceeded (tool_effect_attempted=%b): %s"
      tool_effect_attempted
      message
  | Turn_failed detail -> "Codex app-server turn failed: " ^ detail
  | Stopped_by_host (Repeated_tool_call { tool_name; repeated_count }) ->
    Printf.sprintf
      "Codex app-server stopped after repeated tool call: tool=%s count=%d"
      tool_name
      repeated_count
  | Stopped_by_host (Terminal_tool_boundary { tool_name; _ }) ->
    Printf.sprintf "Codex app-server stopped at terminal tool boundary: tool=%s" tool_name
  | Turn_interrupted -> "Codex app-server turn was interrupted"
  | Runtime_shutting_down ->
    "MASC runtime shutdown interrupted the active Codex turn"
  | Process_exited detail -> "Codex app-server exited before completion: " ^ detail
  | Timeout { seconds; turn_accepted } ->
    if turn_accepted
    then
      Printf.sprintf
        "Codex app-server stream was idle for %.3fs after turn/start was accepted"
        seconds
    else Printf.sprintf "Codex app-server stream was idle for %.3fs" seconds
;;

let error_kind = function
  | Invalid_config _ -> "invalid_config"
  | Spawn_failed _ -> "spawn_failed"
  | Protocol_error _ -> "protocol_error"
  | Rpc_error _ -> "rpc_error"
  | Subscription_required _ -> "subscription_required"
  | Unsupported_server_request _ -> "unsupported_server_request"
  | Context_window_exceeded _ -> "context_window_exceeded"
  | Turn_failed _ -> "turn_failed"
  | Stopped_by_host _ -> "stopped_by_host"
  | Turn_interrupted -> "turn_interrupted"
  | Runtime_shutting_down -> "runtime_shutting_down"
  | Process_exited _ -> "process_exited"
  | Timeout _ -> "timeout"
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

let bounded_tail = Runtime_official_client_json.bounded_tail

(* Names the first field carrying invalid UTF-8 so a refused write points at
   its producer rather than at a byte offset. *)
let invalid_utf8_field json =
  let rec walk path json =
    match json with
    | `String s when not (String_util.is_valid_utf8 s) ->
      Some (if path = "" then "<root>" else path)
    | `Assoc fields ->
      List.find_map
        (fun (k, v) -> walk (if path = "" then k else path ^ "." ^ k) v)
        fields
    | `List items -> List.find_map (walk (path ^ "[]")) items
    | _ -> None
  in
  walk "" json
;;

(* Present and a string, with no constraint on its contents. For payload
   fields whose value this decoder does not read: an emptiness rule there
   ends the turn over a byte nobody looks at. *)
let required_string_any stage name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a string" name)
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

let required_int stage name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be an integer" name)
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

type wire_message =
  | Response of
      { id : int
      ; result : Yojson.Safe.t
      }
  | Response_error of
      { id : int
      ; code : int option
      ; message : string
      }
  | Notification of
      { method_ : string
      ; params : Yojson.Safe.t
      }
  | Server_request of
      { id : Yojson.Safe.t
      ; method_ : string
      ; params : Yojson.Safe.t
      }

let parse_rpc_error id fields =
  let stage = "JSON-RPC error" in
  let* error_json = required_member stage "error" fields in
  let* error_fields = assoc_at stage error_json in
  let* message = required_string stage "message" error_fields in
  let* code = required_int stage "code" error_fields in
  Ok (Response_error { id; code = Some code; message })
;;

let parse_wire_line line =
  let stage = "JSON-RPC message" in
  let json_result =
    try Ok (Yojson.Safe.from_string line) with
    | Yojson.Json_error detail -> protocol_error stage ("invalid JSON: " ^ detail)
  in
  let* json = json_result in
  let* () = validate_unique_object_keys ~stage ~path:"$" json in
  let* fields = assoc_at stage json in
  match List.assoc_opt "id" fields, List.assoc_opt "method" fields with
  | Some id, Some (`String method_) ->
    let* params = required_member stage "params" fields in
    Ok (Server_request { id; method_; params })
  | Some (`Int id), None ->
    (match List.assoc_opt "error" fields with
     | Some _ -> parse_rpc_error id fields
     | None ->
       let* result = required_member stage "result" fields in
       Ok (Response { id; result }))
  | Some _, None -> protocol_error stage "response id must be an integer"
  | None, Some (`String method_) ->
    let* params = required_member stage "params" fields in
    Ok (Notification { method_; params })
  | Some _, Some _ | None, Some _ -> protocol_error stage "method must be a string"
  | None, None -> protocol_error stage "message has neither id nor method"
;;

type io =
  { send : Yojson.Safe.t -> unit
  ; receive : unit -> (wire_message, error) result
  ; set_receive_timeout_s : float option -> unit
  }

let send_request io ~id ~method_ ~params =
  io.send (`Assoc [ "id", `Int id; "method", `String method_; "params", params ])
;;

let send_notification io method_ = io.send (`Assoc [ "method", `String method_ ])

let reject_server_request io id =
  io.send
    (`Assoc
       [ "id", id
       ; ( "error"
         , `Assoc
             [ "code", `Int (-32601)
             ; "message", `String "MASC does not support this app-server host request"
             ] )
       ])
;;

(* Every Keeper tool is declared once, under one namespace, deferred.

   The app-server takes two encodings of [dynamicTools] and refuses a mix
   ("dynamic tools must use either canonical or legacy format consistently").
   The legacy one is tagged ["type": "function"] and cannot defer: it answers
   [deferLoading: true] with "deferred dynamic tool must include a namespace",
   and it has nowhere to put one. The canonical one carries no type tag and
   takes [namespace] as a string, which is what a deferred tool needs, so that
   is the one written here.

   Deferring means the app-server holds the schema and decides when the model
   sees it, rather than every schema riding in the model's context from the
   first token of every turn. The schemas still cross this wire once at
   thread/start; what changes is the context they are spent from. Measured
   2026-08-30 against the live surface: 83 tools, 81,270 bytes of spec. The
   saving itself is not observable here — turn/completed carries no token
   usage — so what is verified is that the model still resolves and calls a
   deferred tool, not how much it costs. *)
let tool_namespace = "masc"

let dynamic_tool_spec (tool : dynamic_tool) =
  `Assoc
    [ "name", `String tool.name
    ; "description", `String tool.description
    ; "inputSchema", tool.input_schema
    ; "namespace", `String tool_namespace
    ; "deferLoading", `Bool true
    ]
;;

let find_dynamic_tool tools name =
  List.find_opt (fun (tool : dynamic_tool) -> String.equal tool.name name) tools
;;

let send_dynamic_tool_response io ~id (result : dynamic_tool_result) =
  io.send
    (`Assoc
       [ "id", id
       ; ( "result"
         , `Assoc
             [ "success", `Bool result.success
             ; ( "contentItems"
               , `List
                   [ `Assoc
                       [ "type", `String "inputText"
                       ; "text", `String result.content
                       ]
                   ] )
             ] )
       ])
;;

let handle_dynamic_tool_call io ~tools ~thread_id ~turn_id ~tool_call_count
    ~on_stream_event ~id params =
  let stage = "item/tool/call" in
  let* fields = assoc_at stage params in
  let* request_thread_id = required_string stage "threadId" fields in
  let* request_turn_id = required_string stage "turnId" fields in
  let* call_id = required_string stage "callId" fields in
  let* tool_name = required_string stage "tool" fields in
  let* namespace = optional_string stage "namespace" fields in
  let* arguments = required_member stage "arguments" fields in
  if request_thread_id <> thread_id || request_turn_id <> turn_id
  then protocol_error stage "tool call identity does not match the active turn"
  else if
    (* Every tool is declared under [tool_namespace], so a call names it back.
       A call naming any other namespace belongs to tools this host did not
       declare and must not be answered from this table. *)
    not
      (match namespace with
       | None -> true
       | Some declared -> String.equal declared tool_namespace)
  then
    protocol_error
      stage
      (Printf.sprintf
         "tool call declared namespace %s, not %s"
         (Option.value namespace ~default:"<none>")
         tool_namespace)
  else
    match find_dynamic_tool tools tool_name with
    | None -> protocol_error stage (Printf.sprintf "unknown dynamic tool %S" tool_name)
    | Some tool ->
      emit_stream_event
        on_stream_event
        (Dynamic_tool_started { call_id; tool_name; arguments });
      let result =
        try tool.call ~call_id arguments with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Log.Runtime_agent.warn
            "Codex dynamic tool handler raised (tool=%s error=%s)"
            tool_name
            (Printexc.to_string exn);
          { success = false
          ; content = "dynamic tool handler raised"
          ; abort_turn = None
          }
      in
      incr tool_call_count;
      emit_stream_event on_stream_event (Dynamic_tool_finished { call_id });
      send_dynamic_tool_response io ~id result;
      (match result.abort_turn with
       | None -> Ok ()
       | Some stop -> Error (Stopped_by_host stop))
;;

let rec await_response io ~id ~method_ =
  let* message = io.receive () in
  match message with
  | Response { id = response_id; result } when response_id = id -> Ok result
  | Response { id = response_id; _ } ->
    protocol_error method_
      (Printf.sprintf "received response id %d while waiting for %d" response_id id)
  | Response_error { id = response_id; code; message } when response_id = id ->
    Error (Rpc_error { method_; code; message })
  | Response_error { id = response_id; _ } ->
    protocol_error method_
      (Printf.sprintf "received error response id %d while waiting for %d" response_id id)
  | Notification _ -> await_response io ~id ~method_
  | Server_request { id; method_ = requested_method; _ } ->
    reject_server_request io id;
    Error (Unsupported_server_request requested_method)
;;

let parse_initialize result =
  let stage = "initialize" in
  let* fields = assoc_at stage result in
  optional_string stage "userAgent" fields
;;

let parse_subscription result =
  let stage = "account/read" in
  let* fields = assoc_at stage result in
  (* [requiresOpenaiAuth] is in the response and is not read: the decision
     below is account.type = "chatgpt". Requiring it to be a bool made the
     subscription probe depend on a field this tree ignores (#28010). *)
  let* account = required_member stage "account" fields in
  match account with
  | `Null -> Error (Subscription_required "the official CLI has no active account")
  | `Assoc account_fields ->
    let* account_type = required_string stage "type" account_fields in
    if account_type <> "chatgpt"
    then
      Error
        (Subscription_required
           (Printf.sprintf "account/read reported account type %S" account_type))
    else
      let* plan_type = required_string stage "planType" account_fields in
      let* email = optional_string stage "email" account_fields in
      Ok { plan_type; email }
  | _ -> protocol_error stage "account must be an object or null"
;;

let probe_protocol io =
  send_request
    io
    ~id:1
    ~method_:"initialize"
    ~params:
      (`Assoc
         [ ( "clientInfo"
           , `Assoc
               [ "name", `String "masc"
               ; "title", `String "MASC"
               ; "version", `String Runtime_build_version.current
               ] )
         ; "capabilities", `Assoc [ "experimentalApi", `Bool true ]
         ]);
  let* initialize = await_response io ~id:1 ~method_:"initialize" in
  let* user_agent = parse_initialize initialize in
  send_notification io "initialized";
  send_request
    io
    ~id:2
    ~method_:"account/read"
    ~params:(`Assoc [ "refreshToken", `Bool false ]);
  let* account = await_response io ~id:2 ~method_:"account/read" in
  let* subscription = parse_subscription account in
  Ok { subscription; user_agent }
;;

let parse_thread_response ~stage result =
  let* fields = assoc_at stage result in
  let* thread_json = required_member stage "thread" fields in
  let* thread_fields = assoc_at stage thread_json in
  let* thread_id = required_string stage "id" thread_fields in
  let* model = required_string stage "model" fields in
  Ok (thread_id, model)
;;

let parse_turn_start result =
  let stage = "turn/start" in
  let* fields = assoc_at stage result in
  let* turn_json = required_member stage "turn" fields in
  let* turn_fields = assoc_at stage turn_json in
  required_string stage "id" turn_fields
;;

let agent_message_of_item ~stage item =
  let* fields = assoc_at stage item in
  match List.assoc_opt "type" fields with
  | Some (`String "agentMessage") ->
    (* The app-server schema requires [text] to be a string, not a non-empty
       string. In particular, a tool-only turn may complete an agent-message
       item with empty text after the tool result has been committed. Such an
       item is valid protocol but is not a visible assistant-message candidate. *)
    let* text = required_string_any stage "text" fields in
    let* phase = optional_string stage "phase" fields in
    if String.trim text = "" then Ok None else Ok (Some (phase, text))
  | Some (`String _) -> Ok None
  | Some _ -> protocol_error stage "item type must be a string"
  | None -> protocol_error stage "item is missing type"
;;

let native_tool_observation_of_item ~stage item =
  let* fields = assoc_at stage item in
  match List.assoc_opt "type" fields with
  | Some (`String (("commandExecution" | "fileChange") as tool_name)) ->
    let* call_id = required_string stage "id" fields in
    Ok
      (Some
         { Runtime_native_tools.identity = Some (Call_id call_id)
         ; tool_name = Some tool_name
         ; origin = Runtime_native_tools.Built_in
         })
  | Some (`String _) -> Ok None
  | Some _ -> protocol_error stage "item type must be a string"
  | None -> protocol_error stage "item is missing type"
;;

let active_turn_item ~stage ~thread_id ~turn_id params =
  let* fields = assoc_at stage params in
  let* item_thread_id = required_string stage "threadId" fields in
  let* item_turn_id = required_string stage "turnId" fields in
  if item_thread_id <> thread_id || item_turn_id <> turn_id
  then protocol_error stage "item identity does not match the active turn"
  else required_member stage "item" fields
;;

let messages_of_items ~stage = function
  | `List items ->
    let rec loop final fallback = function
      | [] -> Ok (final, fallback)
      | item :: rest ->
        let* message = agent_message_of_item ~stage item in
        (match message with
         | Some (Some "final_answer", text) -> loop (Some text) fallback rest
         | Some (_, text) -> loop final (Some text) rest
         | None -> loop final fallback rest)
    in
    loop None None items
  | _ -> protocol_error stage "turn items must be an array"
;;

(* [CodexErrorInfo] is part of Codex app-server's generated protocol schema.
   The exact [contextWindowExceeded] enum is the provider-owned classification;
   human prose and ad-hoc scalar fields remain observational detail only. *)
let turn_error_detail ~message error_fields =
  let annotation (name, value) =
    if String.equal name "message"
    then None
    else (
      match value with
      | `String value when String.trim value <> "" ->
        Some (name ^ "=" ^ String.trim value)
      | `Int value -> Some (name ^ "=" ^ string_of_int value)
      | `Intlit value -> Some (name ^ "=" ^ value)
      | `Bool value -> Some (name ^ "=" ^ string_of_bool value)
      | `Float value -> Some (name ^ "=" ^ Printf.sprintf "%g" value)
      | `String _ | `Null | `Assoc _ | `List _ -> None)
  in
  match List.filter_map annotation error_fields with
  | [] -> message
  | annotations -> message ^ " (" ^ String.concat " " annotations ^ ")"
;;

let turn_error_of_fields ~tool_effect_attempted ~message error_fields =
  match List.assoc_opt "codexErrorInfo" error_fields with
  | Some (`String "contextWindowExceeded") ->
    Context_window_exceeded { message; tool_effect_attempted }
  | Some _ | None -> Turn_failed (turn_error_detail ~message error_fields)
;;

let turn_error ~tool_effect_attempted fields =
  match List.assoc_opt "error" fields with
  | Some (`Assoc error_fields) ->
    let message =
      match List.assoc_opt "message" error_fields with
      | Some (`String message) when String.trim message <> "" ->
        String.trim message
      | _ -> "turn failed without a typed error message"
    in
    turn_error_of_fields ~tool_effect_attempted ~message error_fields
  | Some _ | None -> Turn_failed "turn failed without an error object"
;;

let terminal_result ~thread_id ~turn_id ~seen_final ~seen_fallback
    ~tool_effect_attempted params =
  let stage = "turn/completed" in
  let* fields = assoc_at stage params in
  let* terminal_thread_id = required_string stage "threadId" fields in
  if terminal_thread_id <> thread_id
  then protocol_error stage "terminal threadId does not match thread/start"
  else
    let* turn_json = required_member stage "turn" fields in
    let* turn_fields = assoc_at stage turn_json in
    let* terminal_turn_id = required_string stage "id" turn_fields in
    if terminal_turn_id <> turn_id
    then protocol_error stage "terminal turn id does not match turn/start"
    else
      let* status = required_string stage "status" turn_fields in
      match status with
      | "failed" -> Error (turn_error ~tool_effect_attempted turn_fields)
      | "interrupted" -> Error Turn_interrupted
      | "inProgress" -> protocol_error stage "terminal notification carried inProgress status"
      | "completed" ->
        let* items = required_member stage "items" turn_fields in
        let* terminal_final, terminal_fallback = messages_of_items ~stage items in
        let visible_text = function
          | Some text when String.trim text <> "" -> Some text
          | Some _ | None -> None
        in
        let text =
          match
            visible_text terminal_final,
            visible_text seen_final,
            visible_text terminal_fallback,
            visible_text seen_fallback
          with
          | Some text, _, _, _ | None, Some text, _, _
          | None, None, Some text, _ | None, None, None, Some text -> Some text
          | None, None, None, None -> None
        in
        (match text with
         | Some text -> Ok text
         | None when tool_effect_attempted -> Ok ""
         | None -> protocol_error stage "completed turn has no assistant message")
      | other -> protocol_error stage (Printf.sprintf "unknown turn status %S" other)
;;

(* What this decides is identity: does this delta belong to the turn we are
   awaiting. threadId, turnId and itemId are identifiers, so emptiness in one
   of them is malformed and stays rejected.

   delta carries stream payload forwarded to the turn's typed stream callback,
   and an empty or whitespace chunk is ordinary in a streaming protocol. Requiring it to be
   non-empty turned such a chunk into a terminal protocol error, which put the
   official-client session into Recovery_required and made every later turn for
   that keeper fail closed on `official_client_session.claim` until an operator
   resolved it by hand. Three such chunks accounted for 3,236 rejected turns
   across three Keepers in one retained log window (#27967). *)
let item_delta_notification ~method_ ~thread_id ~turn_id params =
  let* fields = assoc_at method_ params in
  let* notification_thread_id = required_string method_ "threadId" fields in
  let* notification_turn_id = required_string method_ "turnId" fields in
  (* [delta] stays required: its presence is what makes this frame an item
     delta, and the identity check below is only meaningful on one. Its
     *content* is forwarded without non-empty validation -- #27967 rejected empty chunks a provider
     legitimately sends. [itemId] carries neither role. Nothing here reads it,
     so a frame that omits it or sends it empty changes nothing this function
     decides, while requiring it adds one more way to end a turn (#28010). *)
  let* delta = required_string_any method_ "delta" fields in
  if notification_thread_id <> thread_id || notification_turn_id <> turn_id
  then protocol_error method_ "item delta identity does not match the active turn"
  else Ok delta
;;

let rec await_turn_terminal io ~tools ~tool_call_count ~thread_id ~turn_id ~seen_final
    ~seen_fallback ~on_stream_event =
  let* message = io.receive () in
  match message with
  | Response _ | Response_error _ ->
    protocol_error "turn" "received an unsolicited JSON-RPC response"
  | Server_request { id; method_ = "item/tool/call"; params } ->
    let* () =
      handle_dynamic_tool_call
        io
        ~tools
        ~thread_id
        ~turn_id
        ~tool_call_count
        ~on_stream_event
        ~id
        params
    in
    await_turn_terminal
      io
      ~tools
      ~tool_call_count
      ~thread_id
      ~turn_id
      ~seen_final
      ~seen_fallback
      ~on_stream_event
  | Server_request { id; method_; _ } ->
    reject_server_request io id;
    Error (Unsupported_server_request method_)
  | Notification
      { method_ =
          (( "item/agentMessage/delta"
           | "item/commandExecution/outputDelta"
           | "item/fileChange/outputDelta"
           | "item/plan/delta" ) as method_)
      ; params
      } ->
    let* delta = item_delta_notification ~method_ ~thread_id ~turn_id params
    in
    let seen_fallback =
      if String.equal method_ "item/agentMessage/delta"
      then (
        emit_stream_event on_stream_event (Text_delta delta);
        match seen_fallback with
        | None -> Some delta
        | Some text -> Some (text ^ delta))
      else seen_fallback
    in
    await_turn_terminal
      io
      ~tools
      ~tool_call_count
      ~thread_id
      ~turn_id
      ~seen_final
      ~seen_fallback
      ~on_stream_event
  | Notification { method_ = "item/started"; params } ->
    let stage = "item/started" in
    let* item = active_turn_item ~stage ~thread_id ~turn_id params in
    let* observation = native_tool_observation_of_item ~stage item in
    Option.iter
      (fun observation ->
         emit_stream_event on_stream_event (Native_tool_started observation))
      observation;
    await_turn_terminal
      io ~tools ~tool_call_count ~thread_id ~turn_id ~seen_final ~seen_fallback
      ~on_stream_event
  | Notification { method_ = "item/completed"; params } ->
    let stage = "item/completed" in
    let* item = active_turn_item ~stage ~thread_id ~turn_id params in
    let* observation = native_tool_observation_of_item ~stage item in
    Option.iter
      (fun observation ->
         emit_stream_event on_stream_event (Native_tool_finished observation))
      observation;
      let* message = agent_message_of_item ~stage item in
      let seen_final, seen_fallback =
        match message with
        | Some (Some "final_answer", text) -> Some text, seen_fallback
        | Some (_, text) -> seen_final, Some text
        | None -> seen_final, seen_fallback
      in
    await_turn_terminal
      io
      ~tools
      ~tool_call_count
      ~thread_id
      ~turn_id
      ~seen_final
      ~seen_fallback
      ~on_stream_event
  | Notification { method_ = "error"; params } ->
    (* willRetry:true is a progress signal — the app-server itself is retrying
       upstream, so the turn is alive. Counting these and failing the turn at a
       cap preempted the declared liveness boundary below and, under one
       upstream degradation window, drove three keepers into
       Recovery_required twice in two hours. The per-message stream idle
       timeout remains the only liveness boundary; willRetry:false still
       carries the provider's terminal error. *)
    let stage = "error notification" in
    let* fields = assoc_at stage params in
    let* will_retry = required_bool stage "willRetry" fields in
    if will_retry
    then
      await_turn_terminal
        io
        ~tools
        ~tool_call_count
        ~thread_id
        ~turn_id
        ~seen_final
        ~seen_fallback
        ~on_stream_event
    else
      let* error_json = required_member stage "error" fields in
      let* error_fields = assoc_at stage error_json in
      let* message = required_string stage "message" error_fields in
      Error
        (turn_error_of_fields
           ~tool_effect_attempted:(!tool_call_count > 0)
           ~message
           error_fields)
  | Notification { method_ = "turn/completed"; params } ->
    terminal_result
      ~thread_id
      ~turn_id
      ~seen_final
      ~seen_fallback
      ~tool_effect_attempted:(!tool_call_count > 0)
      params
  (* App-server progress and account notifications are observational. Protocol
     evolution must not turn them into a computation failure; each valid wire
     message resets the stream-idle liveness boundary. *)
  | Notification _ ->
    await_turn_terminal
      io
      ~tools
      ~tool_call_count
      ~thread_id
      ~turn_id
      ~seen_final
      ~seen_fallback
      ~on_stream_event
;;

(* Media types the app-server image item accepts, mirroring the closed set the
   analyze_image tool and the dashboard composer already use. *)
let supported_image_media_types =
  [ "image/png"; "image/jpeg"; "image/gif"; "image/webp" ]
;;

(* The app-server README is explicit: the [image] input variant takes an inline
   data URL and rejects remote HTTP(S) URLs, so the payload is inlined here
   rather than handed over as a link the server would refuse. *)
let image_input_item (image : image_input) =
  `Assoc
    [ "type", `String "image"
    ; ( "url"
      , `String
          (Printf.sprintf "data:%s;base64,%s" image.media_type image.base64_data) )
    ]
;;

(* Fail closed before the process boundary. A malformed data URL comes back as a
   turn rejection several seconds later, attributed to the thread rather than to
   the caller that built it. *)
let validate_images images =
  let rec loop index = function
    | [] -> Ok ()
    | image :: rest ->
      let where = Printf.sprintf "images[%d]" index in
      if not (List.mem image.media_type supported_image_media_types)
      then
        Error
          (Invalid_config
             (Printf.sprintf
                "%s.media_type %S is not one of %s"
                where
                image.media_type
                (String.concat ", " supported_image_media_types)))
      else if String.trim image.base64_data = ""
      then Error (Invalid_config (where ^ ".base64_data must not be empty"))
      else if String.exists (fun c -> c = '\n' || c = '\r') image.base64_data
      then Error (Invalid_config (where ^ ".base64_data must not contain newlines"))
      else loop (index + 1) rest
  in
  loop 0 images
;;

let optional_field name = function
  | None -> []
  | Some value -> [ name, `String value ]
;;

let history_item (message : history_message) =
  let role, content_type =
    match message.role with
    | User -> "user", "input_text"
    | Assistant -> "assistant", "output_text"
  in
  `Assoc
    [ "type", `String "message"
    ; "role", `String role
    ; ( "content"
      , `List
          [ `Assoc
              [ "type", `String content_type
              ; "text", `String message.text
              ]
          ] )
    ]
;;

let run_protocol io (config : config) ~protocol_cwd ~dynamic_tools ~reasoning_effort
    ~thread_mode ~history ~prompt ~images ~on_thread_ready ~on_turn_starting ~on_turn_dispatched
    ~on_turn_started ~on_stream_event =
  send_request io ~id:1 ~method_:"initialize"
    ~params:
      (`Assoc
         [ ( "clientInfo"
           , `Assoc
               [ "name", `String "masc"
               ; "title", `String "MASC"
               ; "version", `String client_version
               ] )
         ; "capabilities", `Assoc [ "experimentalApi", `Bool true ]
         ]);
  let* initialize = await_response io ~id:1 ~method_:"initialize" in
  let* user_agent = parse_initialize initialize in
  send_notification io "initialized";
  send_request io ~id:2 ~method_:"account/read"
    ~params:(`Assoc [ "refreshToken", `Bool false ]);
  let* account = await_response io ~id:2 ~method_:"account/read" in
  let* subscription = parse_subscription account in
  let* permissions_profile = permissions_profile_of_posture config.native in
  let thread_method, thread_fields, resumed =
    match thread_mode with
    | Start ->
      ( "thread/start"
      , ([ "cwd", `String protocol_cwd
         ; "approvalPolicy", `String approval_policy
         ; "permissions", `String permissions_profile
         ; "ephemeral", `Bool thread_is_ephemeral
         ]
         @ optional_field "model" config.model
         @ optional_field "developerInstructions" config.developer_instructions
         @
         match dynamic_tools with
         | [] -> []
         | tools -> [ "dynamicTools", `List (List.map dynamic_tool_spec tools) ])
      , false )
    | Resume { thread_id } ->
      ( "thread/resume"
      , [ "threadId", `String thread_id
        ; "cwd", `String protocol_cwd
        ; "approvalPolicy", `String approval_policy
        ; "permissions", `String permissions_profile
        ]
        @ optional_field "model" config.model
        @ optional_field "developerInstructions" config.developer_instructions
        @
        (match dynamic_tools with
         | [] -> []
         | tools -> [ "dynamicTools", `List (List.map dynamic_tool_spec tools) ])
      , true )
  in
  send_request io ~id:3 ~method_:thread_method ~params:(`Assoc thread_fields);
  let* thread = await_response io ~id:3 ~method_:thread_method in
  let* thread_id, model = parse_thread_response ~stage:thread_method thread in
  let* () =
    match thread_mode with
    | Start -> Ok ()
    | Resume { thread_id = expected } when String.equal expected thread_id -> Ok ()
    | Resume { thread_id = expected } ->
      protocol_error
        thread_method
        (Printf.sprintf
           "resumed thread id mismatch: requested %S but server returned %S"
           expected
           thread_id)
  in
  let turn_request_id =
    match thread_mode, history with
    | Resume _, _ | Start, [] -> Ok 4
    | Start, messages ->
      send_request io ~id:4 ~method_:"thread/inject_items"
        ~params:
          (`Assoc
             [ "threadId", `String thread_id
             ; "items", `List (List.map history_item messages)
             ]);
      let* _ = await_response io ~id:4 ~method_:"thread/inject_items" in
      Ok 5
  in
  let* turn_request_id = turn_request_id in
  let* () =
    invoke_state_callback ~stage:"thread ready callback" (fun () ->
      on_thread_ready ~thread_id)
  in
  let* () =
    invoke_state_callback ~stage:"turn starting callback" (fun () ->
      on_turn_starting ~thread_id)
  in
  send_request io ~id:turn_request_id ~method_:"turn/start"
    ~params:
      (`Assoc
         ([ "threadId", `String thread_id
          ; ( "input"
            , `List
                (List.map image_input_item images
                 @ [ `Assoc [ "type", `String "text"; "text", `String prompt ] ]) )
          ]
          @ optional_field
              "effort"
              (Option.map Llm_provider.Reasoning_effort.to_string reasoning_effort)
          @ (match config.output_schema with
             | None -> []
             (* v2 TurnStartParams.outputSchema: "Optional JSON Schema used to
                constrain the final assistant message for this turn." Unlike the
                Antigravity CLI there is no second field to read -- the schema
                binds the message itself, so the existing text path already
                carries the constrained answer. *)
             | Some schema -> [ "outputSchema", schema ])));
  on_turn_dispatched ();
  (* The complete request is now outside this process. Admission stays finite
     through dispatch; only the subsequent model turn adopts its declared
     idle policy, including [None]. *)
  io.set_receive_timeout_s config.timeout_s;
  let* turn =
    match await_response io ~id:turn_request_id ~method_:"turn/start" with
    | Error (Timeout { seconds; turn_accepted = _ }) ->
      (* The request has been written. A missing response cannot prove that
         the app-server rejected it, so rotating here could duplicate a turn
         that is already executing upstream. *)
      Error (Timeout { seconds; turn_accepted = true })
    | response -> response
  in
  let* turn_id = parse_turn_start turn in
  let* () =
    invoke_state_callback ~stage:"turn started callback" (fun () ->
      on_turn_started ~thread_id ~turn_id)
  in
  emit_stream_event on_stream_event (Turn_started { turn_id; model });
  let tool_call_count = ref 0 in
  let* text =
    await_turn_terminal
      io
      ~tools:dynamic_tools
      ~tool_call_count
      ~thread_id
      ~turn_id
      ~seen_final:None
      ~seen_fallback:None
      ~on_stream_event
  in
  emit_stream_event on_stream_event (Turn_finished { text });
  Ok
    { thread_id
    ; turn_id
    ; model
    ; text
    ; dynamic_tool_calls = !tool_call_count
    ; subscription
    ; user_agent
    ; resumed
    }
;;

let env_key entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> entry
;;

let child_environment_key_allowed = function
  | "HOME"
  | "PATH"
  | "TMPDIR"
  | "CODEX_HOME"
  | "XDG_CONFIG_HOME"
  | "XDG_DATA_HOME"
  | "XDG_CACHE_HOME"
  | "SSL_CERT_FILE"
  | "SSL_CERT_DIR"
  | "LANG"
  | "LC_ALL"
  | "LC_CTYPE"
  | "TERM"
  | "NO_COLOR" -> true
  | _ -> false
;;

let subscription_only_environment () =
  Unix.environment ()
  |> Array.to_list
  |> List.filter (fun entry -> child_environment_key_allowed (env_key entry))
  |> Array.of_list
;;

let drain_stderr flow tail =
  let chunk = Cstruct.create stderr_chunk_bytes in
  try
    while true do
      let count = Eio.Flow.single_read flow chunk in
      let text = Cstruct.to_string (Cstruct.sub chunk 0 count) in
      tail := bounded_tail ~limit:stderr_tail_bytes !tail text
    done
  with
  | End_of_file -> ()
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Runtime_agent.debug
      "Codex app-server stderr drain failed: %s"
      (Printexc.to_string exn)
;;

let terminate_spawned_process ~clock proc stdin_w =
  let owning_switch_cancelled = Eio.Fiber.is_cancelled () in
  Eio.Cancel.protect (fun () ->
    (try Eio.Flow.close stdin_w with
     | exn ->
       Log.Runtime_agent.debug
         "Codex app-server stdin close failed: %s"
         (Printexc.to_string exn));
    (try Eio.Process.signal proc Sys.sigterm with
     | exn ->
       Log.Runtime_agent.debug
         "Codex app-server termination signal failed: %s"
         (Printexc.to_string exn));
    if not owning_switch_cancelled
    then
      try
        Eio.Time.with_timeout_exn clock process_termination_grace_s (fun () ->
          Eio.Process.await proc |> ignore)
      with
      | Eio.Time.Timeout ->
        (try
           Eio.Process.signal proc Sys.sigkill;
           Eio.Process.await proc |> ignore
         with
         | exn ->
           Log.Runtime_agent.warn
             "Codex app-server forced reap failed: %s"
             (Printexc.to_string exn))
      | exn ->
        Log.Runtime_agent.debug
          "Codex app-server reap observed an already-closed process: %s"
          (Printexc.to_string exn))
;;

let with_spawned_client ~mgr ~clock ~cwd ~initial_timeout_s config run =
  Eio.Switch.run (fun sw ->
    let stdin_r, stdin_w = Eio.Process.pipe ~sw mgr in
    let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
    let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
    let stderr_tail = ref "" in
    let proc =
      Eio.Process.spawn ~sw mgr ~cwd
        ~env:(subscription_only_environment ())
        ~stdin:stdin_r ~stdout:stdout_w ~stderr:stderr_w
        [ config.cli_path; "app-server"; "--stdio" ]
    in
    Eio.Flow.close stdin_r;
    Eio.Flow.close stdout_w;
    Eio.Flow.close stderr_w;
    Eio.Fiber.fork ~sw (fun () -> drain_stderr stderr_r stderr_tail);
    let reader = Eio.Buf_read.of_flow ~max_size:max_wire_line_bytes stdout_r in
    let wall_clock =
      Runtime_wall_clock.make ?ceiling_s:config.wall_clock_ceiling_s ~now:(fun () -> Eio.Time.now clock) ()
    in
    let active_receive_timeout_s = ref initial_timeout_s in
    let send json =
      let payload = Yojson.Safe.to_string json in
      (* The child decodes stdin as UTF-8 and exits on an invalid sequence,
         which loses every in-flight turn and leaves the producer unnamed.
         Refuse the write instead: the child survives and the field is named. *)
      if not (String_util.is_valid_utf8 payload)
      then
        failwith
          (Printf.sprintf
             "codex app-server stdin: refusing invalid UTF-8 payload (field %s)"
             (Option.value (invalid_utf8_field json) ~default:"<unknown>"));
      with_optional_timeout clock
        (Runtime_wall_clock.cap_window wall_clock (Some config.admission_timeout_s))
        (fun () ->
          Eio.Flow.copy_string payload stdin_w;
          Eio.Flow.copy_string "\n" stdin_w)
    in
    let receive () =
      if Runtime_wall_clock.expired wall_clock
      then
        (* The transport cannot know whether turn/start was already accepted;
           the entry points rewrap with the observed turn state. *)
        Error
          (Timeout
             { seconds =
                 Option.value config.wall_clock_ceiling_s
                   ~default:Runtime_wall_clock.default_ceiling_s
             ; turn_accepted = false
             })
      else
      try
        with_optional_timeout clock
          (Runtime_wall_clock.cap_window wall_clock !active_receive_timeout_s)
          (fun () -> Eio.Buf_read.line reader)
        |> parse_wire_line
      with
      | End_of_file ->
        if Runtime_host_lifecycle.is_shutting_down ()
        then Error Runtime_shutting_down
        else
          let detail = String.trim !stderr_tail in
          Error (Process_exited (if detail = "" then "stdout closed" else detail))
      | Idle_timeout seconds ->
        (* The transport cannot know whether turn/start was already accepted;
           the entry points rewrap with the observed turn state. *)
        Error (Timeout { seconds; turn_accepted = false })
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | Eio.Time.Timeout as exn -> raise exn
      | exn -> protocol_error "stdout read" (Printexc.to_string exn)
    in
    (* Cleanup must run before [Switch.run] waits for the stderr drainer. The
       child can be waiting for more stdin on typed early returns, so a switch
       release hook alone deadlocks. [Eio.Cancel.protect] inside the finalizer
       preserves cleanup across fiber cancellation. *)
    Fun.protect
      ~finally:(fun () -> terminate_spawned_process ~clock proc stdin_w)
      (fun () ->
         run
           { send
           ; receive
           ; set_receive_timeout_s =
               (fun timeout_s -> active_receive_timeout_s := timeout_s)
           }))
;;

let run_spawned ~mgr ~clock ~cwd ~protocol_cwd config ~dynamic_tools
    ~reasoning_effort ~thread_mode ~history ~prompt ~images ~on_thread_ready
    ~on_turn_starting ~on_turn_dispatched ~on_turn_started ~on_stream_event =
  with_spawned_client
    ~mgr
    ~clock
    ~cwd
    ~initial_timeout_s:(Some config.admission_timeout_s)
    config
    (fun io ->
    let with_admission_timeout callback =
      with_optional_timeout clock (Some config.admission_timeout_s) callback
    in
    run_protocol
      io
      config
      ~protocol_cwd
      ~dynamic_tools
      ~reasoning_effort
      ~thread_mode
      ~history
      ~prompt
      ~images
      ~on_thread_ready:(fun ~thread_id ->
        with_admission_timeout (fun () -> on_thread_ready ~thread_id))
      ~on_turn_starting:(fun ~thread_id ->
        with_admission_timeout (fun () -> on_turn_starting ~thread_id))
      ~on_turn_dispatched
      ~on_turn_started:(fun ~thread_id ~turn_id ->
        with_admission_timeout (fun () -> on_turn_started ~thread_id ~turn_id))
      ~on_stream_event)
;;

let native_cwd cwd =
  try
    let cwd = Eio.Path.native_exn cwd in
    if String.trim cwd = "" || Filename.is_relative cwd
    then Error (Invalid_config "cwd must be an absolute native path")
    else Ok cwd
  with
  | exn ->
    Error
      (Invalid_config
         ("cwd must be a native filesystem path: " ^ Printexc.to_string exn))
;;

let validate_process_config config =
  if String.trim config.cli_path = ""
  then Error (Invalid_config "cli_path must not be empty")
  else if
    not (Float.is_finite config.admission_timeout_s)
    || config.admission_timeout_s <= 0.0
  then Error (Invalid_config "admission_timeout_s must be positive and finite")
  else if
    (match config.timeout_s with
     | None -> false
     | Some seconds -> not (Float.is_finite seconds) || seconds <= 0.0)
  then Error (Invalid_config "a declared timeout_s must be positive and finite")
  else Ok ()
;;

let validate_config config ~cwd ~thread_mode ~prompt =
  let* () = validate_process_config config in
  if String.trim prompt = ""
  then Error (Invalid_config "prompt must not be empty")
  else
    let* cwd = native_cwd cwd in
    match thread_mode with
    | Resume { thread_id } when String.equal (String.trim thread_id) "" ->
      Error (Invalid_config "resume thread_id must not be empty")
    | Start | Resume _ -> Ok cwd
;;

let validate_dynamic_tools tools =
  let rec loop seen = function
    | [] -> Ok ()
    | (tool : dynamic_tool) :: rest ->
      let name = String.trim tool.name in
      if name = ""
      then Error (Invalid_config "dynamic tool name must not be empty")
      else if List.mem name seen
      then Error (Invalid_config (Printf.sprintf "duplicate dynamic tool name %S" name))
      else loop (name :: seen) rest
  in
  loop [] tools
;;

let validate_turn_input ~dynamic_tools ~thread_mode ~cwd config ~prompt ~images =
  match validate_images images with
  | Error _ as invalid -> invalid
  | Ok () ->
  match validate_config config ~cwd ~thread_mode ~prompt with
  | Error _ as error -> error
  | Ok protocol_cwd ->
    (match validate_dynamic_tools dynamic_tools with
     | Error _ as error -> error
     | Ok () -> Ok protocol_cwd)
;;

let validate_turn ?(dynamic_tools = []) ?(thread_mode = Start) ~cwd config ~prompt ~images =
  validate_turn_input ~dynamic_tools ~thread_mode ~cwd config ~prompt ~images
  |> Result.map (fun _ -> ())
;;

let probe_subscription ~mgr ~clock ~cwd config =
  let result =
    let* () = validate_process_config config in
    let* _ = native_cwd cwd in
    try
      with_spawned_client
        ~mgr
        ~clock
        ~cwd
        ~initial_timeout_s:(Some config.admission_timeout_s)
        config
        probe_protocol
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Idle_timeout seconds ->
      (* The probe never starts a turn. *)
      Error (Timeout { seconds; turn_accepted = false })
    | Eio.Time.Timeout as exn -> raise exn
    | exn -> Error (Spawn_failed (Printexc.to_string exn))
  in
  (match result with
   | Ok _ -> Log.Runtime_agent.info "Codex app-server subscription probe completed"
   | Error error ->
     Log.Runtime_agent.warn
       "Codex app-server subscription probe failed (kind=%s)"
       (error_kind error));
  result
;;

let run_turn ?(dynamic_tools = []) ?reasoning_effort ?(thread_mode = Start) ~mgr ~clock ~cwd
    ?(history = [])
    ?(on_thread_ready = fun ~thread_id:_ -> Ok ())
    ?(on_turn_starting = fun ~thread_id:_ -> Ok ())
    ?(on_turn_started = fun ~thread_id:_ ~turn_id:_ -> Ok ()) ?on_stream_event
    config ~prompt ~images =
  (* [turn/start] acceptance is the fact that decides whether a later idle
     timeout is ambiguous (the upstream turn may still commit effects). The
     transport constructs [Timeout] with [turn_accepted = false] because it
     cannot know; this entry point observes acceptance through the
     [on_turn_started] callback and rewraps timeout results with the truth. *)
  let turn_accepted = ref false in
  let on_turn_started ~thread_id ~turn_id =
    turn_accepted := true;
    on_turn_started ~thread_id ~turn_id
  in
  let result =
    match validate_turn_input ~dynamic_tools ~thread_mode ~cwd config ~prompt ~images with
    | Error _ as error -> error
    | Ok protocol_cwd ->
      (* Eight keepers starting a turn in the same second produced eight
         identical lines with nothing to tell them apart (2026-08-22
         01:36:25Z, seven within one second). The thread is the only identity
         this entry point holds before [on_thread_ready] fires. *)
      Log.Runtime_agent.info
        "Codex app-server subscription turn starting thread=%s model=%s"
        (match thread_mode with
         | Start -> "new"
         | Resume { thread_id } -> thread_id)
        (match config.model with
         | Some model -> model
         | None -> "-");
      (match
         (try
            run_spawned
              ~mgr
              ~clock
              ~cwd
              ~protocol_cwd
              config
              ~dynamic_tools
              ~reasoning_effort
              ~thread_mode
              ~history
              ~prompt
              ~images
              ~on_thread_ready
              ~on_turn_starting
              ~on_turn_dispatched:(fun () -> turn_accepted := true)
              ~on_turn_started
              ~on_stream_event
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | Idle_timeout seconds ->
            Error (Timeout { seconds; turn_accepted = !turn_accepted })
          | Eio.Time.Timeout as exn -> raise exn
          | exn -> Error (Spawn_failed (Printexc.to_string exn)))
       with
       | Error (Timeout { seconds; turn_accepted = dispatch_ambiguous }) ->
         Error
           (Timeout
              { seconds
              ; turn_accepted = dispatch_ambiguous || !turn_accepted
              })
       | other -> other)
  in
  (match result with
   | Ok turn ->
     Log.Runtime_agent.info
       "Codex app-server subscription turn completed (thread_id=%s turn_id=%s model=%s)"
       turn.thread_id
       turn.turn_id
       turn.model
   | Error error ->
     Log.Runtime_agent.warn
       "Codex app-server subscription turn failed (kind=%s)"
       (error_kind error));
  result
;;
