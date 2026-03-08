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

let masc_http_base_url () =
  match Sys.getenv_opt "MASC_HTTP_BASE_URL" with
  | Some raw when String.trim raw <> "" -> String.trim raw
  | _ ->
      let port =
        match Sys.getenv_opt "MASC_HTTP_PORT" with
        | Some raw when String.trim raw <> "" -> String.trim raw
        | _ -> "8935"
      in
      sprintf "http://127.0.0.1:%s" port

let mcp_endpoint_url ~(auth_token : string option) =
  let base = masc_http_base_url () ^ "/mcp" in
  match auth_token with
  | Some token when String.trim token <> "" ->
      (* Keep auth in the query as a loopback-only fallback for local workers.
         execute_tool_eio already accepts query token auth, and this avoids
         header transport edge cases when we self-call through curl. *)
      base ^ "?token=" ^ token
  | _ -> base

let normalize_mcp_body body =
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
  match List.rev data_lines with
  | last :: _ -> last
  | [] -> body

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

let call_jsonrpc ~sw ~(auth_token : string option) ~session_id ~(method_name : string)
    ~(params : Yojson.Safe.t) : (Yojson.Safe.t, string) result =
  let _ = sw in
  let request_body =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ("id", `Int (next_jsonrpc_id ()));
        ("method", `String method_name);
        ("params", params);
      ]
    |> Yojson.Safe.to_string
  in
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
    let (status, raw_body) =
      Process_eio.run_argv_with_stdin_and_status
        ~timeout_sec:20.0 ~stdin_content:request_body
        (argv @ [ "--data-binary"; "@-" ])
    in
    (match status with
     | Unix.WEXITED 0 ->
         let normalized = normalize_mcp_body raw_body in
         let json = Yojson.Safe.from_string normalized in
         (match extract_jsonrpc_error json with
          | Some msg -> Error msg
          | None -> Ok json)
     | Unix.WEXITED code ->
         Error (sprintf "curl exited with code %d: %s" code raw_body)
     | Unix.WSIGNALED code ->
         Error (sprintf "curl signaled: %d" code)
     | Unix.WSTOPPED code ->
         Error (sprintf "curl stopped: %d" code))
  with exn ->
    Error (Printexc.to_string exn)

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

let list_masc_tools ~sw ~(auth_token : string option) ~session_id
    ?(names : string list option = None) () :
    (Types.tool_schema list, string) result =
  let open Yojson.Safe.Util in
  let params =
    match names with
    | None -> `Assoc []
    | Some values ->
        `Assoc
          [
            ( "names",
              `List (List.map (fun value -> `String value) values) );
          ]
  in
  match call_jsonrpc ~sw ~auth_token ~session_id ~method_name:"tools/list"
          ~params
  with
  | Error e -> Error e
  | Ok json ->
      let tools_json =
        match json |> member "result" |> member "tools" with
        | `List items -> items
        | _ -> []
      in
      let schemas =
        List.filter_map
          (fun tool_json ->
            match tool_json with
            | `Assoc fields -> (
                match
                  List.assoc_opt "name" fields,
                  List.assoc_opt "description" fields,
                  List.assoc_opt "inputSchema" fields
                with
                | Some (`String name), Some (`String description), Some input_schema ->
                    Some { Types.name; description; input_schema }
                | _ -> None)
            | _ -> None)
          tools_json
      in
      Ok schemas

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
Inside a team session, record at least one note turn with masc_team_session_step(turn_kind="note", message="...") and a non-empty message that states your concrete contribution.
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
      Fun.protect
        ~finally:(fun () ->
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
                  max_tokens = 1024;
                  tools = tool_defs;
                  response_format = `Text;
                }
              in
              match Llm_client.complete ~timeout_sec request with
              | Error e -> Error e
              | Ok resp ->
                  let usage_acc = merge_usage usage_acc resp.usage in
                  if resp.tool_calls = [] then
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
                            inject_default_agent_name ~worker_name ~schema parsed_args
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
                        resp.tool_calls
                    in
                    let round_tools =
                      List.map (fun (tc : Llm_client.tool_call) -> tc.call_name) resp.tool_calls
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
