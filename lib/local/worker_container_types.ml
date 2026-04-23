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
  raw_trace_run : Oas.Raw_trace.run_ref option;
  api_response : Oas.Types.api_response option;
  proof : Oas.Cdal_proof.t option;
}

type worker_container_state =
  | Worker_missing
  | Worker_pending
  | Worker_ready

type tool_profile =
  | Profile_session_min
  | Profile_session_dev

type shell_profile =
  | Shell_none
  | Shell_readonly
  | Shell_dev

type worker_container_meta = {
  version : int;
  worker_name : string;
  mcp_session_id : string;
  workspace_path : string;
  role : string option;
  selection_note : string option;
  thinking_enabled : bool option;
  max_turns_override : int option;
  timeout_seconds : int option;
  tool_profile : tool_profile;
  shell_profile : shell_profile;
  worker_class : Worker_types.worker_class option;
  effective_model : string;
  checkpoint_path : string;
  turn_log_path : string;
  last_run_at : float option;
}

let worker_container_version = 1

let jsonrpc_id = Atomic.make 1000

let next_jsonrpc_id () =
  Atomic.fetch_and_add jsonrpc_id 1

let strip_mcp_prefix name =
  let prefix = "mcp__masc__" in
  if String.length name >= String.length prefix
     && String.sub name 0 (String.length prefix) = prefix
  then
    String.sub name (String.length prefix) (String.length name - String.length prefix)
  else
    name

let unique_preserve_order = Json_util.dedupe_keep_order

let has_agent_name_field (schema : Types.tool_schema) =
  let open Yojson.Safe.Util in
  match schema.input_schema |> member "properties" |> member "agent_name" with
  | `Null -> false
  | _ -> true

let inject_default_agent_name ~(worker_name : string)
    ~(schema : Types.tool_schema option) (args : Yojson.Safe.t) =
  match (schema, args) with
  | Some schema, `Assoc fields
    when has_agent_name_field schema && not (List.mem_assoc "agent_name" fields) ->
      `Assoc (("agent_name", `String worker_name) :: fields)
  | _ -> args

let extract_prompt_block ~start_marker ~end_marker (text : string) =
  let start_re = Re.str start_marker |> Re.compile in
  let end_re = Re.str end_marker |> Re.compile in
  match Re.exec_opt start_re text with
  | None -> None
  | Some g ->
    let start_idx = Re.Group.stop g 0 in
    (match Re.exec_opt ~pos:start_idx end_re text with
    | None -> None
    | Some g2 ->
      let end_idx = Re.Group.start g2 0 in
      let raw = String.sub text start_idx (end_idx - start_idx) |> String.trim in
      if raw = "" then None else Some raw)

let masc_http_base_url () =
  Env_config.masc_http_base_url ()

let mcp_endpoint_url ~(auth_token : string option) =
  ignore auth_token;
  masc_http_base_url () ^ "/mcp"

let request_id_matches request_id json =
  let open Yojson.Safe.Util in
  match member "id" json with
  | `Int value -> value = request_id
  | `Intlit value -> (
      match int_of_string_opt value with
      | Some v -> v = request_id
      | None -> false)
  | `String value -> String.equal value (string_of_int request_id)
  | _ -> false

let normalize_mcp_body ~request_id body =
  let lines = String.split_on_char '\n' body in
  let data_lines =
    List.filter_map
      (fun line ->
        let prefix = "data: " in
        if String.length line >= String.length prefix
           && String.sub line 0 (String.length prefix) = prefix
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
  let open Yojson.Safe.Util in
  match json |> member "result" |> member "content" with
  | `List (`Assoc fields :: _) -> (
      match List.assoc_opt "text" fields with
      | Some (`String s) -> s
      | _ -> Yojson.Safe.to_string json)
  | _ -> Yojson.Safe.to_string json

let extract_jsonrpc_error json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "error" fields with
      | Some (`Assoc err_fields) -> (
          match List.assoc_opt "message" err_fields with
          | Some (`String s) when String.trim s <> "" -> Some s
          | _ -> None)
      | _ -> None)
  | _ -> None

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
        (match Masc_http_client.post_sync ~net ~url ~headers ~body:request_body () with
        | Error e -> Error (sprintf "MASC HTTP request failed: %s" e)
        | Ok (status, raw_body) ->
            if Cohttp.Code.is_success status then Ok raw_body
            else Error (sprintf "MASC HTTP %d: %s" status raw_body))
      with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)

let call_jsonrpc ~sw ~(auth_token : string option) ~session_id ~(method_name : string)
    ~(params : Yojson.Safe.t) : (Yojson.Safe.t, string) result =
  let request_id = next_jsonrpc_id () in
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
        (mcp_endpoint_url ~auth_token);
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
          ~actor:"system/worker_container_types"
          ~raw_source
          ~summary:"worker container curl fallback"
          ~timeout_sec:20.0
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
    | Error e -> Error e
    | Ok raw_body ->
        let normalized = normalize_mcp_body ~request_id raw_body in
        if String.trim normalized = "" && attempts_left > 0 then
          decode (attempts_left - 1)
        else
          try
            let json = Yojson.Safe.from_string normalized in
            match extract_jsonrpc_error json with
            | Some msg -> Error msg
            | None -> Ok json
          with Yojson.Json_error msg ->
            if attempts_left > 0 then decode (attempts_left - 1)
            else Error ("invalid JSON-RPC response: " ^ msg)
  in
  decode 1

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
        let open Yojson.Safe.Util in
        match json |> member "result" |> member "isError" with
        | `Bool b -> b
        | _ -> false
      in
      Ok { text = extract_tool_text json; is_error }

let list_masc_tools ~sw:_sw ~(auth_token : string option) ~session_id
    ?(names : string list option = None) () :
    (Types.tool_schema list, string) result =
  ignore (_sw, auth_token, session_id);
  Agent_tool_surfaces.local_worker_tool_schemas ?names ()

let tool_schema_of_name schemas tool_name =
  List.find_opt (fun (schema : Types.tool_schema) -> String.equal schema.name tool_name) schemas

let tool_defs_of_schemas (schemas : Types.tool_schema list) : Types.tool_schema list =
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
        | _ -> ())
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
        | _ -> ()
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
      | _ -> ();
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

let parse_text_tool_calls (content : string) : Oas.Types.content_block list =
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
                  (Oas.Types.ToolUse {
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

let make_usage ?(input_tokens = 0) ?(output_tokens = 0) () : Oas.Types.api_usage =
  { Oas.Types.input_tokens;
    output_tokens;
    cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0;
    cost_usd = None }

let merge_usage (a : Oas.Types.api_usage) (b : Oas.Types.api_usage) : Oas.Types.api_usage =
  { Oas.Types.input_tokens = a.input_tokens + b.input_tokens;
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

let estimate_cost_usd ~(model_id : string)
    (usage : Oas.Types.api_usage) : float option =
  let pricing = Llm_provider.Pricing.pricing_for_model model_id in
  Some (Llm_provider.Pricing.estimate_cost ~pricing
    ~input_tokens:usage.input_tokens ~output_tokens:usage.output_tokens ())

let local_worker_max_tokens () = Env_config.Worker.local_worker_max_tokens

let local_worker_heartbeat_interval_sec () = Env_config.Worker.local_worker_heartbeat_sec

let join_worker ~sw ~(auth_token : string option) ~session_id ~worker_name =
  let args =
    `Assoc
      [
        ("agent_name", `String worker_name);
        ( "capabilities",
          `List
            [
              `String "llama";
              `String "mcp-worker";
              `String "local-tool-loop";
            ] );
      ]
  in
  call_masc_tool ~sw ~auth_token ~session_id ~tool_name:"masc_join" ~args

let leave_worker ~sw ~(auth_token : string option) ~session_id ~worker_name =
  let args = `Assoc [ ("agent_name", `String worker_name) ] in
  call_masc_tool ~sw ~auth_token ~session_id ~tool_name:"masc_leave" ~args

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
Use tools when state inspection, task coordination, work delegation, or room updates are needed.
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
    match Auth.create_token base_path ~agent_name:worker_name ~role:Types.Worker with
    | Ok (token, _cred) -> Ok (Some token)
    | Error err -> Error (Types.masc_error_to_string err)
  else
    Ok None
