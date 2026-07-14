open Printf

type tool_exec_result = {
  text : string;
  is_error : bool;
}

type run_result = {
  output : string;
  model_used : string;
  input_tokens : int option;
  output_tokens : int option;
  cost_usd : float option;
  tool_call_count : int;
  tool_names : string list;
  session_id : string;
  raw_trace_run : Agent_sdk.Raw_trace.run_ref option;
  api_response : Agent_sdk.Types.api_response option;
}

type worker_container_state =
  | Worker_missing
  | Worker_pending
  | Worker_ready

type worker_container_meta = {
  version : int;
  worker_name : string;
  mcp_session_id : string;
  workspace_path : string;
  role : string option;
  selection_note : string option;
  runtime_backend : Worker_execution_backend.t;
  thinking_enabled : bool option;
  timeout_seconds : int option;
  effective_model : string;
  checkpoint_path : string;
  turn_log_path : string;
  mcp_client_session_started_at : float option;
  last_run_at : float option;
}

let worker_container_version = 1

let jsonrpc_id = Atomic.make 1000

let next_jsonrpc_id () =
  Atomic.fetch_and_add jsonrpc_id 1

let strip_mcp_prefix name =
  let prefix = "mcp__masc__" in
  if String.starts_with name ~prefix
  then
    String.sub name (String.length prefix) (String.length name - String.length prefix)
  else
    name


let has_agent_name_field (schema : Masc_domain.tool_schema) =
  match (match Json_util.assoc_member_opt "properties" schema.input_schema with Some x -> Json_util.assoc_member_opt "agent_name" x | None -> None) with
  | Some `Null | None -> false
  | Some _ -> true

let inject_default_agent_name ~(worker_name : string)
    ~(schema : Masc_domain.tool_schema option) (args : Yojson.Safe.t) =
  match (schema, args) with
  | Some schema, `Assoc fields
    when has_agent_name_field schema && not (List.mem_assoc "agent_name" fields) ->
      `Assoc (("agent_name", `String worker_name) :: fields)
  | _ -> args

let extract_prompt_block ~start_marker ~end_marker (text : string) =
  (* Markers are caller-supplied so we can't hoist; but they're literal
     bytes, so a byte-wise [find_substring] is cheaper than building a
     fresh DFA per call. *)
  match String_util.find_substring text start_marker with
  | None -> None
  | Some marker_pos ->
    let start_idx = marker_pos + String.length start_marker in
    (match String_util.find_substring ~pos:start_idx text end_marker with
    | None -> None
    | Some end_idx ->
      let raw = String.sub text start_idx (end_idx - start_idx) |> String.trim in
      if raw = "" then None else Some raw)

let masc_http_base_url () =
  Env_config.masc_http_base_url ()

let mcp_endpoint_url ~(auth_token : string option) =
  ignore auth_token;
  masc_http_base_url () ^ "/mcp"

let request_id_matches request_id json =
  match Json_util.assoc_member_opt "id" json with
  | Some (`Int value) -> value = request_id
  | Some (`Intlit value) -> (
      match int_of_string_opt value with
      | Some v -> v = request_id
      | None -> false)
  | Some (`String value) -> String.equal value (string_of_int request_id)
  | _ -> false

let normalize_mcp_body ~request_id body =
  let lines = String.split_on_char '\n' body in
  let data_lines =
    List.filter_map
      (fun line ->
        let prefix = "data: " in
        if String.starts_with line ~prefix
        then
          Some (String.sub line (String.length prefix) (String.length line - String.length prefix))
        else
          None)
      lines
  in
  let matching_line =
    List.find_map
      (fun line ->
        try
          let json = Yojson.Safe.from_string line in
          if request_id_matches request_id json then Some line else None
        with Yojson.Json_error _ -> None)
      data_lines
  in
  match matching_line with
  | Some line -> line
  | None -> (
      match List.rev data_lines with
      | last :: _ -> last
      | [] -> body)

let extract_tool_text json =
  match (match Json_util.assoc_member_opt "result" json with Some x -> Json_util.assoc_member_opt "content" x | None -> None) with
  | Some (`List (`Assoc fields :: _)) -> (
      match List.assoc_opt "text" fields with
      | Some (`String s) -> s
      | _ -> Yojson.Safe.to_string json)
  | _ -> Yojson.Safe.to_string json

type client_operation_error =
  { message : string
  ; error_type : string
  ; rpc_response_status_code : string option
  }

let client_operation_error ?rpc_response_status_code ~error_type message =
  { message; error_type; rpc_response_status_code }

let jsonrpc_error_code_string fields =
  match List.assoc_opt "code" fields with
  | Some (`Int code) -> Some (string_of_int code)
  | Some (`Intlit code) when String.trim code <> "" -> Some code
  | Some (`String code) when String.trim code <> "" -> Some code
  | _ -> None

let extract_jsonrpc_error_detail json =
  match json with
  | `Assoc fields -> (
    match List.assoc_opt "error" fields with
    | Some (`Assoc err_fields) ->
      let message =
        match List.assoc_opt "message" err_fields with
        | Some (`String s) when String.trim s <> "" -> s
        | _ -> Yojson.Safe.to_string json
      in
      let rpc_response_status_code = jsonrpc_error_code_string err_fields in
      let error_type =
        match rpc_response_status_code with
        | Some code -> code
        | None -> "jsonrpc_error"
      in
      Some (client_operation_error ?rpc_response_status_code ~error_type message)
    | _ -> None)
  | _ -> None

let option_label key = function
  | Some value when String.trim value <> "" -> [ key, value ]
  | _ -> []

let tool_name_from_params = function
  | `Assoc fields -> (
    match List.assoc_opt "name" fields with
    | Some (`String name) when String.trim name <> "" -> Some name
    | _ -> None)
  | _ -> None

let server_labels_of_url url =
  try
    let uri = Uri.of_string url in
    option_label Otel_genai.Mcp_attr_key.server_address (Uri.host uri)
    @ option_label
        Otel_genai.Mcp_attr_key.server_port
        (Option.map string_of_int (Uri.port uri))
  with _ -> []

let mcp_client_operation_duration_labels ~url ~method_name ~params ?error () =
  [ Otel_genai.Mcp_attr_key.mcp_method_name, method_name
  ; ( Otel_genai.Mcp_attr_key.mcp_protocol_version
    , Mcp_transport_protocol.default_protocol_version )
  ; Otel_genai.Mcp_attr_key.network_protocol_name, "http"
  ; Otel_genai.Mcp_attr_key.network_protocol_version, "1.1"
  ; Otel_genai.Mcp_attr_key.network_transport, "tcp"
  ]
  @
  (if String.equal method_name Otel_genai.Mcp_value.tools_call_method
   then
     [ Otel_genai.Attr_key.gen_ai_operation_name, "execute_tool" ]
     @ option_label Otel_genai.Attr_key.gen_ai_tool_name (tool_name_from_params params)
   else [])
  @ server_labels_of_url url
  @
  match error with
  | None -> []
  | Some error ->
    [ Otel_genai.Mcp_attr_key.error_type, error.error_type ]
    @ option_label
        Otel_genai.Mcp_attr_key.rpc_response_status_code
        error.rpc_response_status_code

let mcp_client_session_duration_labels ~url ?error_type () =
  [ ( Otel_genai.Mcp_attr_key.mcp_protocol_version
    , Mcp_transport_protocol.default_protocol_version )
  ; Otel_genai.Mcp_attr_key.network_protocol_name, "http"
  ; Otel_genai.Mcp_attr_key.network_protocol_version, "1.1"
  ; Otel_genai.Mcp_attr_key.network_transport, "tcp"
  ]
  @ server_labels_of_url url
  @ option_label Otel_genai.Mcp_attr_key.error_type error_type

let tools_call_result_is_error ~method_name json =
  String.equal method_name Otel_genai.Mcp_value.tools_call_method
  &&
  match Json_util.assoc_member_opt "result" json with
  | Some result -> (
    match Json_util.assoc_member_opt "isError" result with
    | Some (`Bool true) -> true
    | _ -> false)
  | None -> false

let record_mcp_client_operation_duration ~url ~method_name ~params ~started_at result =
  let error =
    match result with
    | Ok json when tools_call_result_is_error ~method_name json ->
      Some
        (client_operation_error
           ~error_type:Otel_genai.Mcp_value.tool_error_type
           "MCP tools/call result isError=true")
    | Ok _ -> None
    | Error error -> Some error
  in
  Otel_metric_store.observe_histogram
    Otel_genai.Mcp_metric_name.client_operation_duration
    ~labels:(mcp_client_operation_duration_labels ~url ~method_name ~params ?error ())
    (* NDT-OK: client operation duration is telemetry only; admission and
       result semantics use [result], not this wall-clock sample. *)
    (max 0.0 (Unix.gettimeofday () -. started_at) (* NDT-OK: telemetry sample. *))

let record_mcp_client_session_duration ~url ~started_at ?error_type () =
  Otel_metric_store.observe_histogram
    Otel_genai.Mcp_metric_name.client_session_duration
    ~labels:(mcp_client_session_duration_labels ~url ?error_type ())
    (* NDT-OK: client session duration is a runtime telemetry observation. *)
    (max 0.0 (Unix.gettimeofday () -. started_at) (* NDT-OK: telemetry sample. *))

module For_testing = struct
  let client_operation_error_opt ?rpc_response_status_code = function
    | None -> None
    | Some error_type ->
      Some
        (client_operation_error
           ?rpc_response_status_code
           ~error_type
           "test error")
  ;;

  let mcp_client_operation_duration_labels ~url ~method_name ~params ?error_type
      ?rpc_response_status_code () =
    let error = client_operation_error_opt ?rpc_response_status_code error_type in
    mcp_client_operation_duration_labels ~url ~method_name ~params ?error ()
  ;;

  let record_mcp_client_operation_duration ~url ~method_name ~params ~started_at
      ?error_type ?rpc_response_status_code ?(tool_result_is_error = false) () =
    let result =
      match client_operation_error_opt ?rpc_response_status_code error_type with
      | None ->
        Ok
          (`Assoc
            [ ( "result"
              , `Assoc [ "isError", `Bool tool_result_is_error ] )
            ])
      | Some error -> Error error
    in
    record_mcp_client_operation_duration ~url ~method_name ~params ~started_at result
  ;;

  let mcp_client_session_duration_labels ~url ?error_type () =
    mcp_client_session_duration_labels ~url ?error_type ()
  ;;

  let record_mcp_client_session_duration ~url ~started_at ?error_type () =
    record_mcp_client_session_duration ~url ~started_at ?error_type ()
  ;;
end

let post_json_via_eio ~sw:_ ~(auth_token : string option) ~session_id
    ~(request_body : string) : (string, string) result =
  match Eio_context.get_net_opt () with
  | None -> Error "Eio net not initialized"
  | Some net ->
      try
        let headers =
            [
               ("content-type", "application/json");
               ("accept", "application/json, text/event-stream");
               ("x-masc-force-json", "1");
               ("mcp-session-id", session_id);
             ]
            @
            (match auth_token with
            | Some token when String.trim token <> "" ->
                [ ("authorization", "Bearer " ^ token) ]
            | _ -> [])
        in
        let url = mcp_endpoint_url ~auth_token in
        (match Masc_http_client.post_sync ~url ~headers ~body:request_body () with
        | Error e -> Error (sprintf "MASC HTTP request failed: %s" e)
        | Ok (status, raw_body) ->
            if Cohttp.Code.is_success status then Ok raw_body
            else Error (sprintf "MASC HTTP %d: %s" status raw_body))
      with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)

let call_jsonrpc ~sw ~(auth_token : string option) ~session_id ~(method_name : string)
    ~(params : Yojson.Safe.t) : (Yojson.Safe.t, string) result =
  let request_id = next_jsonrpc_id () in
  let url = mcp_endpoint_url ~auth_token in
  let request_body =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ("id", `Int request_id);
        ("method", `String method_name);
        ("params", params);
      ]
    |> Yojson.Safe.to_string
  in
  let curl_fallback () =
    let argv =
      [
        "curl";
        "-sS";
        "--http1.1";
        "--max-time";
        "15";
        "-X";
        "POST";
        url;
        "-H";
        "content-type: application/json";
        "-H";
        "accept: application/json, text/event-stream";
        "-H";
        "x-masc-force-json: 1";
        "-H";
        ("mcp-session-id: " ^ session_id);
      ]
      @
      match auth_token with
      | Some token when String.trim token <> "" ->
          [ "-H"; "authorization: Bearer " ^ token ]
      | _ -> []
    in
    try
      let argv = argv @ [ "--data-binary"; "@-" ] in
      let raw_source = String.concat " " (List.map Filename.quote argv) in
      let status, raw_body =
        Masc_exec.Exec_gate.run_argv_with_stdin_and_status
          ~actor:(Masc_exec.Agent_id.of_string "system/worker_container_types")
          ~raw_source
          ~summary:"worker container curl fallback"

          ~stdin_content:request_body
          argv
      in
      match status with
      | Unix.WEXITED 0 -> Ok raw_body
      | Unix.WEXITED code ->
          Error (sprintf "curl exited with code %d: %s" code raw_body)
      | Unix.WSIGNALED code ->
          Error (sprintf "curl signaled: %d" code)
      | Unix.WSTOPPED code ->
          Error (sprintf "curl stopped: %d" code)
    with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)
  in
  let perform_request () =
    match Eio_context.get_net_opt () with
    | Some _ -> post_json_via_eio ~sw ~auth_token ~session_id ~request_body
    | None -> curl_fallback ()
  in
  let rec decode attempts_left =
    match perform_request () with
    | Error e ->
        Error (client_operation_error ~error_type:"transport_error" e)
    | Ok raw_body ->
        let normalized = normalize_mcp_body ~request_id raw_body in
        if String.trim normalized = "" && attempts_left > 0 then
          decode (attempts_left - 1)
        else
          try
            let json = Yojson.Safe.from_string normalized in
            match extract_jsonrpc_error_detail json with
            | Some error -> Error error
            | None -> Ok json
          with Yojson.Json_error msg ->
            if attempts_left > 0 then decode (attempts_left - 1)
            else
              Error
                (client_operation_error ~error_type:"json_parse_error"
                   ("invalid JSON-RPC response: " ^ msg))
  in
  (* NDT-OK: request-boundary timestamp feeds only the OTel duration histogram. *)
  let started_at = Unix.gettimeofday () (* NDT-OK: telemetry sample. *) in
  let result = decode 1 in
  record_mcp_client_operation_duration ~url ~method_name ~params ~started_at result;
  Result.map_error (fun error -> error.message) result

let call_masc_tool ~sw ~(auth_token : string option) ~session_id ~tool_name
    ~(args : Yojson.Safe.t) :
    (tool_exec_result, string) result =
  let args =
    match (auth_token, args) with
    | Some token, `Assoc fields when not (List.mem_assoc "token" fields) ->
        `Assoc (("token", `String token) :: fields)
    | _ -> args
  in
  match
    call_jsonrpc ~sw ~auth_token ~session_id ~method_name:"tools/call"
      ~params:(`Assoc [ ("name", `String tool_name); ("arguments", args) ])
  with
  | Error e -> Error e
  | Ok json ->
      let is_error =
        match (match Json_util.assoc_member_opt "result" json with Some x -> Json_util.assoc_member_opt "isError" x | None -> None) with
        | Some (`Bool b) -> b
        | _ -> false
      in
      Ok { text = extract_tool_text json; is_error }

let list_masc_tools ~sw:_sw ~(auth_token : string option) ~session_id
    ?(names : string list option = None) () :
    (Masc_domain.tool_schema list, string) result =
  ignore (_sw, auth_token, session_id);
  Keeper_tool_surfaces.local_worker_tool_schemas ?names ()

let tool_schema_of_name schemas tool_name =
  List.find_opt (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name tool_name) schemas

let tool_defs_of_schemas (schemas : Masc_domain.tool_schema list) : Masc_domain.tool_schema list =
  schemas

let safe_text_for_followup text =
  let trimmed = String.trim text in
  if String.length trimmed <= 1200 then trimmed
  else String.sub trimmed 0 1200 ^ "...[truncated]"

let followup_prompt ~original_prompt ~tool_outputs ~already_used =
  let tool_lines =
    tool_outputs
    |> List.mapi (fun idx (name, input, output) ->
           sprintf "%d. %s(%s)\n%s" (idx + 1) name
             (Yojson.Safe.to_string input)
             (safe_text_for_followup output))
    |> String.concat "\n\n"
  in
  sprintf
    {|Continue the same worker task.

Original task:
%s

Tool results:
%s

Already used tools: %s

If more tools are required, call them. Otherwise return the final result.|}
    original_prompt tool_lines
    (if already_used = [] then "none" else String.concat ", " already_used)

let split_top_level delimiter (text : string) =
  let len = String.length text in
  let buf = Buffer.create len in
  let acc = ref [] in
  let in_string = ref false in
  let escaped = ref false in
  let paren_depth = ref 0 in
  let bracket_depth = ref 0 in
  let brace_depth = ref 0 in
  let flush () =
    let item = Buffer.contents buf |> String.trim in
    Buffer.clear buf;
    if item <> "" then acc := item :: !acc
  in
  for idx = 0 to len - 1 do
    let ch = text.[idx] in
    if !in_string then (
      Buffer.add_char buf ch;
      if !escaped then
        escaped := false
      else
        match ch with
        | '\\' -> escaped := true
        | '"' -> in_string := false
        | '\000' .. '\255' -> ())
    else
      match ch with
      | '"' ->
          in_string := true;
          Buffer.add_char buf ch
      | '(' ->
          incr paren_depth;
          Buffer.add_char buf ch
      | ')' ->
          decr paren_depth;
          Buffer.add_char buf ch
      | '[' ->
          incr bracket_depth;
          Buffer.add_char buf ch
      | ']' ->
          decr bracket_depth;
          Buffer.add_char buf ch
      | '{' ->
          incr brace_depth;
          Buffer.add_char buf ch
      | '}' ->
          decr brace_depth;
          Buffer.add_char buf ch
      | c
        when c = delimiter && !paren_depth = 0 && !bracket_depth = 0
             && !brace_depth = 0 ->
          flush ()
      | _ -> Buffer.add_char buf ch
  done;
  flush ();
  List.rev !acc

let find_top_level_char target (text : string) =
  let len = String.length text in
  let in_string = ref false in
  let escaped = ref false in
  let paren_depth = ref 0 in
  let bracket_depth = ref 0 in
  let brace_depth = ref 0 in
  let result = ref None in
  let idx = ref 0 in
  while !idx < len && !result = None do
    let ch = text.[!idx] in
    if !in_string then
      if !escaped then
        escaped := false
      else
        match ch with
        | '\\' -> escaped := true
        | '"' -> in_string := false
        | '\000' .. '\255' -> ()
    else
      match ch with
      | '"' -> in_string := true
      | '(' -> incr paren_depth
      | ')' -> decr paren_depth
      | '[' -> incr bracket_depth
      | ']' -> decr bracket_depth
      | '{' -> incr brace_depth
      | '}' -> decr brace_depth
      | _ when ch = target && !paren_depth = 0 && !bracket_depth = 0 && !brace_depth = 0 ->
          result := Some !idx
      | '\000' .. '\255' -> ();
    incr idx
  done;
  !result

let parse_text_tool_args (args_text : string) =
  let trimmed = String.trim args_text in
  if trimmed = "" then Ok (`Assoc [])
  else
    let parts = split_top_level ',' trimmed in
    let rec build acc = function
      | [] -> Ok (`Assoc (List.rev acc))
      | part :: rest -> (
          match find_top_level_char '=' part with
          | None ->
              Error (sprintf "invalid tool arg assignment: %s" part)
          | Some idx ->
              let key = String.sub part 0 idx |> String.trim in
              let value_text =
                String.sub part (idx + 1) (String.length part - idx - 1)
                |> String.trim
              in
              if key = "" then
                Error "empty tool arg key"
              else
                match Yojson.Safe.from_string value_text with
                | value -> build ((key, value) :: acc) rest
                | exception Yojson.Json_error msg ->
                    Error
                      (sprintf "invalid tool arg JSON for %s: %s" key msg))
    in
    build [] parts

let parse_text_tool_calls (content : string) : Agent_sdk.Types.content_block list =
  let prefix = "mcp__masc__" in
  let prefix_len = String.length prefix in
  let len = String.length content in
  let is_name_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  let rec parse_args idx depth in_string escaped =
    if idx >= len then None
    else
      let ch = content.[idx] in
      if in_string then
        if escaped then
          parse_args (idx + 1) depth true false
        else
          match ch with
          | '\\' -> parse_args (idx + 1) depth true true
          | '"' -> parse_args (idx + 1) depth false false
          | _ -> parse_args (idx + 1) depth true false
      else
        match ch with
        | '"' -> parse_args (idx + 1) depth true false
        | '(' -> parse_args (idx + 1) (depth + 1) false false
        | ')' ->
            if depth = 1 then Some idx
            else parse_args (idx + 1) (depth - 1) false false
        | _ -> parse_args (idx + 1) depth false false
  in
  let rec collect idx call_id acc =
    if idx >= len - prefix_len then List.rev acc
    else if String.sub content idx prefix_len <> prefix then
      collect (idx + 1) call_id acc
    else
      let name_start = idx in
      let name_end = ref (idx + prefix_len) in
      while !name_end < len && is_name_char content.[!name_end] do
        incr name_end
      done;
      if !name_end >= len || content.[!name_end] <> '(' then
        collect (!name_end) call_id acc
      else
        match parse_args (!name_end + 1) 1 false false with
        | None -> collect (!name_end + 1) call_id acc
        | Some close_idx ->
            let tool_name =
              String.sub content name_start (!name_end - name_start)
              |> strip_mcp_prefix
            in
            let args_raw =
              String.sub content (!name_end + 1) (close_idx - !name_end - 1)
            in
            (match parse_text_tool_args args_raw with
            | Ok args_json ->
                collect (close_idx + 1) (call_id + 1)
                  (Agent_sdk.Types.ToolUse {
                     id = sprintf "text-fallback-%d" call_id;
                     name = tool_name;
                     input = args_json;
                   }
                  :: acc)
            | Error msg ->
                Log.LocalWorker.warn "ignored text tool call (%s): %s"
                  tool_name msg;
                collect (close_idx + 1) call_id acc)
  in
  collect 0 1 []

let make_usage ?(input_tokens = 0) ?(output_tokens = 0) () : Agent_sdk.Types.api_usage =
  { Agent_sdk.Types.input_tokens;
    output_tokens;
    cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0;
    cost_usd = None }

let merge_usage (a : Agent_sdk.Types.api_usage) (b : Agent_sdk.Types.api_usage) : Agent_sdk.Types.api_usage =
  { Agent_sdk.Types.input_tokens = a.input_tokens + b.input_tokens;
    output_tokens = a.output_tokens + b.output_tokens;
    cache_creation_input_tokens =
      a.cache_creation_input_tokens + b.cache_creation_input_tokens;
    cache_read_input_tokens =
      a.cache_read_input_tokens + b.cache_read_input_tokens;
    cost_usd =
      (match a.cost_usd, b.cost_usd with
       | Some x, Some y -> Some (x +. y)
       | Some x, None | None, Some x -> Some x
       | None, None -> None) }

let local_worker_heartbeat_interval_sec () = Env_config.Worker.local_worker_heartbeat_sec

let default_system_prompt ~worker_name ~model_id ?role
    ?selection_note () =
  let role_line =
    match role with
    | Some value when String.trim value <> "" ->
        sprintf "Assigned role: %s\n" (String.trim value)
    | _ -> ""
  in
  let selection_line =
    match selection_note with
    | Some value when String.trim value <> "" ->
        sprintf "Leader-selected model context: %s\n" (String.trim value)
    | _ -> ""
  in
  sprintf
    {|You are a MASC-managed tool-aware worker.
Worker name: %s
Model: %s
%s%s
Operate through the provided MASC tools.
Use tools when state inspection, task updates, work delegation, or status updates are needed.
Keep responses concise and task-focused.
If a tool schema includes agent_name and you omit it, the runtime will inject %s automatically.
Do not invent tool names or arguments that are not in schema.
When the task is complete, return a short final result summarizing what you changed or learned.|}
    worker_name model_id role_line selection_line worker_name

let worker_session_id worker_name =
  let digest =
    Digest.string (worker_name ^ string_of_float (Time_compat.now ())) |> Digest.to_hex
  in
  sprintf "local-%s" (String.sub digest 0 12)

let worker_auth_token ~base_path ~worker_name =
  let auth_cfg = Auth.load_auth_config base_path in
  if auth_cfg.enabled && auth_cfg.require_token then
    match Auth.create_token base_path ~agent_name:worker_name ~role:Masc_domain.Worker with
    | Ok (token, _cred) -> Ok (Some token)
    | Error err -> Error (Masc_domain.masc_error_to_string err)
  else
    Ok None
