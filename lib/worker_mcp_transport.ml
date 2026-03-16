(** Worker_mcp_transport — JSON-RPC communication, MCP tool listing, and HTTP transport for worker agents. *)

open Printf

type tool_exec_result = {
  text : string;
  is_error : bool;
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
