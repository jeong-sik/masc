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
}

let jsonrpc_id = ref 1000

let next_jsonrpc_id () =
  incr jsonrpc_id;
  !jsonrpc_id

let strip_mcp_prefix name =
  let prefix = "mcp__masc__" in
  if String.length name >= String.length prefix
     && String.sub name 0 (String.length prefix) = prefix
  then
    String.sub name (String.length prefix) (String.length name - String.length prefix)
  else
    name

let unique_preserve_order items =
  let rec loop seen = function
    | [] -> List.rev seen
    | x :: xs ->
        if List.mem x seen then loop seen xs else loop (x :: seen) xs
  in
  loop [] items

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
  try
    let start_idx =
      Str.search_forward (Str.regexp_string start_marker) text 0
      + String.length start_marker
    in
    let end_idx =
      Str.search_forward (Str.regexp_string end_marker) text start_idx
    in
    let raw = String.sub text start_idx (end_idx - start_idx) |> String.trim in
    if raw = "" then None else Some raw
  with Not_found -> None

let inject_prompt_full_context ~(prompt : string) ~(tool_name : string)
    (args : Yojson.Safe.t) =
  match (tool_name, args) with
  | "masc_memento_mori", `Assoc fields
    when not (List.mem_assoc "full_context" fields) -> (
      match
        extract_prompt_block ~start_marker:"[FULL_CONTEXT_BEGIN]"
          ~end_marker:"[FULL_CONTEXT_END]" prompt
      with
      | Some full_context ->
          `Assoc (("full_context", `String full_context) :: fields)
      | None -> args)
  | _ -> args

let masc_http_base_url () =
  Env_config.masc_http_base_url ()

let mcp_endpoint_url ~(auth_token : string option) =
  let base = masc_http_base_url () ^ "/mcp" in
  match auth_token with
  | Some token when String.trim token <> "" ->
      (* Keep auth in the query as a loopback-only fallback for local workers.
         execute_tool_eio already accepts query token auth, and this avoids
         header transport edge cases when we self-call through curl. *)
      base ^ "?token=" ^ token
  | _ -> base

let request_id_matches request_id json =
  let open Yojson.Safe.Util in
  match member "id" json with
  | `Int value -> value = request_id
  | `Intlit value -> (
      try int_of_string value = request_id with Failure _ -> false)
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

let post_json_via_eio ~sw ~(auth_token : string option) ~session_id
    ~(request_body : string) : (string, string) result =
  match Eio_context.get_net_opt () with
  | None -> Error "Eio net not initialized"
  | Some net ->
      let client = Cohttp_eio.Client.make ~https:None net in
      let headers =
        Cohttp.Header.of_list
          ([
             ("content-type", "application/json");
             ("accept", "application/json, text/event-stream");
             ("x-masc-force-json", "1");
             ("mcp-session-id", session_id);
           ]
          @
          match auth_token with
          | Some token when String.trim token <> "" ->
              [ ("authorization", "Bearer " ^ token) ]
          | _ -> [])
      in
      try
        let uri = Uri.of_string (mcp_endpoint_url ~auth_token) in
        let body = Eio.Flow.string_source request_body in
        let response, response_body =
          Cohttp_eio.Client.post client ~sw uri ~headers ~body
        in
        let status = Cohttp.Response.status response |> Cohttp.Code.code_of_status in
        let raw_body =
          Eio.Buf_read.(parse_exn take_all) response_body
            ~max_size:(8 * 1024 * 1024)
        in
        if Cohttp.Code.is_success status then Ok raw_body
        else Error (sprintf "MASC HTTP %d: %s" status raw_body)
      with exn -> Error (Printexc.to_string exn)

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
      let status, raw_body =
        Process_eio.run_argv_with_stdin_and_status
          ~timeout_sec:20.0 ~stdin_content:request_body
          (argv @ [ "--data-binary"; "@-" ])
      in
      match status with
      | Unix.WEXITED 0 -> Ok raw_body
      | Unix.WEXITED code ->
          Error (sprintf "curl exited with code %d: %s" code raw_body)
      | Unix.WSIGNALED code ->
          Error (sprintf "curl signaled: %d" code)
      | Unix.WSTOPPED code ->
          Error (sprintf "curl stopped: %d" code)
    with exn -> Error (Printexc.to_string exn)
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

let tool_defs_of_schemas schemas =
  List.map
    (fun (schema : Types.tool_schema) ->
      {
        Llm_client.tool_name = schema.name;
        tool_description = schema.description;
        parameters = schema.input_schema;
      })
    schemas

let safe_text_for_followup text =
  let trimmed = String.trim text in
  if String.length trimmed <= 1200 then trimmed
  else String.sub trimmed 0 1200 ^ "...[truncated]"

let followup_prompt ~original_prompt ~tool_outputs ~already_used =
  let tool_lines =
    tool_outputs
    |> List.mapi (fun idx ((tc : Llm_client.tool_call), output) ->
           sprintf "%d. %s(%s)\n%s" (idx + 1) tc.call_name tc.call_arguments
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

let parse_text_tool_calls (content : string) : Llm_client.tool_call list =
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
                  ({
                     Llm_client.call_id = sprintf "text-fallback-%d" call_id;
                     call_name = tool_name;
                     call_arguments = Yojson.Safe.to_string args_json;
                   }
                  :: acc)
            | Error msg ->
                eprintf "[local-worker] ignored text tool call (%s): %s\n%!"
                  tool_name msg;
                collect (close_idx + 1) call_id acc)
  in
  collect 0 1 []

let make_usage ?(input_tokens = 0) ?(output_tokens = 0) () =
  {
    Llm_client.input_tokens;
    output_tokens;
    total_tokens = input_tokens + output_tokens;
    cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0;
  }

let merge_usage a b =
  {
    Llm_client.input_tokens = a.Llm_client.input_tokens + b.Llm_client.input_tokens;
    output_tokens = a.output_tokens + b.output_tokens;
    total_tokens = a.total_tokens + b.total_tokens;
    cache_creation_input_tokens =
      a.cache_creation_input_tokens + b.cache_creation_input_tokens;
    cache_read_input_tokens =
      a.cache_read_input_tokens + b.cache_read_input_tokens;
  }

let estimate_cost_usd (model : Llm_client.model_spec)
    (usage : Llm_client.token_usage) : float option =
  let input_cost =
    (float_of_int usage.input_tokens /. 1000.0) *. model.cost_per_1k_input
  in
  let output_cost =
    (float_of_int usage.output_tokens /. 1000.0) *. model.cost_per_1k_output
  in
  Some (input_cost +. output_cost)

let local_worker_max_tokens () =
  match Sys.getenv_opt "MASC_LOCAL_WORKER_MAX_TOKENS" with
  | None -> 1024
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some value -> max 64 (min 2048 value)
      | None -> 1024)

let local_worker_heartbeat_interval_sec () =
  match Sys.getenv_opt "MASC_LOCAL_WORKER_HEARTBEAT_SEC" with
  | None -> 60
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some value -> max 0 (min 600 value)
      | None -> 60)

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

let default_system_prompt ~worker_name ~model_id ?session_id ?role
    ?selection_note () =
  let session_line =
    match session_id with
    | Some value when String.trim value <> "" ->
        sprintf "Team session: %s\n" (String.trim value)
    | _ -> ""
  in
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
%s%s%s
Operate through the provided MASC tools.
Use tools when state inspection, task coordination, work delegation, or room updates are needed.
Keep responses concise and task-focused.
If a tool schema includes agent_name and you omit it, the runtime will inject %s automatically.
Do not invent tool names or arguments that are not in schema.
If you are operating inside a team session, record your own work with masc_team_session_step as the worker.
Inside a team session, record at least one note turn with masc_team_session_step(session_id="...", turn_kind="note", message="...") and a non-empty message that states your concrete contribution.
A note turn without a message is invalid and will be rejected.
When the task is complete, return a short final result summarizing what you changed or learned.|}
    worker_name model_id session_line role_line selection_line worker_name

let worker_session_id worker_name =
  let digest =
    Digest.string (worker_name ^ string_of_float (Time_compat.now ())) |> Digest.to_hex
  in
  sprintf "llama-%s" (String.sub digest 0 12)

let worker_auth_token ~base_path ~worker_name =
  let auth_cfg = Auth.load_auth_config base_path in
  if auth_cfg.enabled && auth_cfg.require_token then
    match Auth.create_token base_path ~agent_name:worker_name ~role:Types.Worker with
    | Ok (token, _cred) -> Ok (Some token)
    | Error err -> Error (Types.masc_error_to_string err)
  else
    Ok None

let start_worker_heartbeat ~sw ~(auth_token : string option) ~session_id
    ~worker_name =
  let interval = local_worker_heartbeat_interval_sec () in
  match (interval, Eio_context.get_clock_opt ()) with
  | interval, _ when interval <= 0 -> fun () -> ()
  | _, None -> fun () -> ()
  | interval, Some clock ->
      let active = ref true in
      Eio.Fiber.fork ~sw (fun () ->
          let rec loop () =
            if !active then (
              Eio.Time.sleep clock (float_of_int interval);
              if !active then (
                match
                  call_masc_tool ~sw ~auth_token ~session_id
                    ~tool_name:"masc_heartbeat" ~args:(`Assoc [])
                with
                | Ok _ -> ()
                | Error e ->
                    eprintf "[local-worker] heartbeat error for %s: %s\n%!"
                      worker_name e;
                loop ()))
          in
          try loop ()
          with
          | Eio.Cancel.Cancelled _ as ex -> raise ex
          | exn ->
            eprintf "[local-worker] heartbeat loop error for %s: %s\n%!"
              worker_name (Printexc.to_string exn));
      fun () -> active := false

let run_worker ~sw ~base_path ~worker_name ~model ~team_session_id ~role
    ~selection_note
    ~(prompt : string) ~(allowed_tools : string list) ~(timeout_sec : int) :
    (run_result, string) result =
  let mcp_session_id = worker_session_id worker_name in
  match worker_auth_token ~base_path ~worker_name with
  | Error e -> Error e
  | Ok auth_token ->
      let _ =
        match join_worker ~sw ~auth_token ~session_id:mcp_session_id ~worker_name with
        | Ok _ -> ()
        | Error e -> raise (Failure ("worker join failed: " ^ e))
      in
      let stop_heartbeat =
        start_worker_heartbeat ~sw ~auth_token ~session_id:mcp_session_id
          ~worker_name
      in
      Fun.protect
        ~finally:(fun () ->
          stop_heartbeat ();
          ignore (leave_worker ~sw ~auth_token ~session_id:mcp_session_id ~worker_name))
        (fun () ->
          let allowed_names =
            allowed_tools |> List.map strip_mcp_prefix |> unique_preserve_order
          in
          let listed_schemas =
            match
              list_masc_tools ~sw ~auth_token ~session_id:mcp_session_id
                ~names:(Some allowed_names) ()
            with
            | Ok schemas -> schemas
            | Error e -> raise (Failure ("tools/list failed: " ^ e))
          in
          let tool_schemas =
            List.filter
              (fun (schema : Types.tool_schema) ->
                List.mem schema.name allowed_names)
              listed_schemas
          in
          let tool_defs = tool_defs_of_schemas tool_schemas in
          if tool_defs = [] then
            Error "no MASC tool definitions available for local worker"
          else
            let zero_usage = make_usage () in
            let rec loop ~round ~usage_acc ~tools_used current_prompt =
              let request : Llm_client.completion_request =
                {
                  model;
                  messages =
                    [
                      Llm_client.system_msg
                        (default_system_prompt ~worker_name
                           ~model_id:model.model_id ?session_id:team_session_id
                           ?role ?selection_note ());
                      Llm_client.user_msg current_prompt;
                    ];
                  temperature = 0.2;
                  max_tokens = local_worker_max_tokens ();
                  tools = tool_defs;
                  response_format = `Text;
                }
              in
              match Llm_client.complete ~timeout_sec request with
              | Error e -> Error e
              | Ok resp ->
                  let tool_calls =
                    match resp.tool_calls with
                    | [] -> parse_text_tool_calls resp.content
                    | calls -> calls
                  in
                  let usage_acc = merge_usage usage_acc resp.usage in
                  if tool_calls = [] then
                    let output =
                      let trimmed = String.trim resp.content in
                      if trimmed <> "" then trimmed
                      else if tools_used <> [] then
                        sprintf "(tools executed: %s)"
                          (String.concat ", " (unique_preserve_order tools_used))
                      else
                        "(no output)"
                    in
                    Ok
                      {
                        output;
                        model_used = resp.model_used;
                        input_tokens = Some usage_acc.input_tokens;
                        output_tokens = Some usage_acc.output_tokens;
                        cost_usd = estimate_cost_usd model usage_acc;
                        tool_call_count = List.length tools_used;
                        tool_names = unique_preserve_order tools_used;
                        session_id = mcp_session_id;
                      }
                  else
                    let tool_outputs =
                      List.map
                        (fun (tc : Llm_client.tool_call) ->
                          let schema =
                            tool_schema_of_name tool_schemas tc.call_name
                          in
                          let parsed_args =
                            match Yojson.Safe.from_string tc.call_arguments with
                            | json -> json
                            | exception Yojson.Json_error msg ->
                                `Assoc [ ("error", `String ("invalid tool args: " ^ msg)) ]
                          in
                          let args =
                            parsed_args
                            |> inject_default_agent_name ~worker_name ~schema
                            |> inject_prompt_full_context ~prompt ~tool_name:tc.call_name
                          in
                          let output =
                            match
                              call_masc_tool ~sw ~auth_token
                                ~session_id:mcp_session_id
                                ~tool_name:tc.call_name ~args
                            with
                            | Ok result ->
                                if result.is_error then
                                  Yojson.Safe.to_string
                                    (`Assoc
                                       [
                                         ("tool", `String tc.call_name);
                                         ("error", `String result.text);
                                       ])
                                else result.text
                            | Error e ->
                                Yojson.Safe.to_string
                                  (`Assoc
                                     [ ("tool", `String tc.call_name); ("error", `String e) ])
                          in
                          ((tc : Llm_client.tool_call), output))
                        tool_calls
                    in
                    let round_tools =
                      List.map (fun (tc : Llm_client.tool_call) -> tc.call_name) tool_calls
                    in
                    let tools_used = tools_used @ round_tools in
                    let output =
                      let trimmed = String.trim resp.content in
                      if trimmed <> "" then trimmed
                      else
                        sprintf "(tools executed: %s)"
                          (String.concat ", " (unique_preserve_order tools_used))
                    in
                    if round >= 3 then
                      Ok
                        {
                          output;
                          model_used = resp.model_used;
                          input_tokens = Some usage_acc.input_tokens;
                          output_tokens = Some usage_acc.output_tokens;
                          cost_usd = estimate_cost_usd model usage_acc;
                          tool_call_count = List.length tools_used;
                          tool_names = unique_preserve_order tools_used;
                          session_id = mcp_session_id;
                        }
                    else
                      loop ~round:(round + 1) ~usage_acc ~tools_used
                        (followup_prompt ~original_prompt:prompt ~tool_outputs
                           ~already_used:tools_used)
            in
            loop ~round:1 ~usage_acc:zero_usage ~tools_used:[] prompt)
