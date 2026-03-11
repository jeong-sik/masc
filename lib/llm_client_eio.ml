(** LLM Client for Eio - HTTP client for llm-mcp server

    @deprecated This module is deprecated since v2.59.0.
    Use {!Llm_client.run_prompt_cascade} with {!Lodge_cascade.get_cascade}
    instead.

    This module is kept for backward compatibility with tests.
    It will be removed in a future version. *)

(* Eio modules are referenced with full paths for clarity *)

(** {1 Types} *)

type model =
  | Gemini      (** Fast, good for classification *)
  | Claude      (** Balanced, good for reasoning *)
  | Codex       (** Code-focused *)
  | Ollama of string  (** Local model *)

type response = {
  content: string;
  model: string;
  tokens_used: int option;
}

type error =
  | ConnectionError of string
  | ParseError of string
  | ServerError of int * string
  | Timeout

(** {1 Configuration} *)

let default_host = "127.0.0.1"
let default_port = 8932
let default_timeout_sec = 30.0

(** {1 Internal Helpers} *)

let model_to_string = function
  | Gemini -> "gemini"
  | Claude -> "claude-cli"
  | Codex -> "codex"
  | Ollama name -> Printf.sprintf "ollama:%s" name

(** Build MCP JSON-RPC request for LLM call *)
let build_request ~model ~prompt =
  let model_str = model_to_string model in
  Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String model_str);
      ("arguments", `Assoc [
        ("prompt", `String prompt);
        ("response_format", `String "verbose");
      ]);
    ]);
  ])

(** Parse LLM response from MCP JSON-RPC response *)
let parse_response json_str =
  try
    let json = Yojson.Safe.from_string json_str in
    match json with
    | `Assoc fields ->
        (match List.assoc_opt "result" fields with
         | Some (`Assoc result_fields) ->
             let content = match List.assoc_opt "content" result_fields with
               | Some (`String s) -> s
               | Some (`List [`Assoc text_fields]) ->
                   (match List.assoc_opt "text" text_fields with
                    | Some (`String s) -> s
                    | _ -> "")
               | _ -> ""
             in
             let model = match List.assoc_opt "model" result_fields with
               | Some (`String s) -> s
               | _ -> "unknown"
             in
             Ok { content; model; tokens_used = None }
         | Some (`String s) -> Ok { content = s; model = "unknown"; tokens_used = None }
         | _ ->
             (match List.assoc_opt "error" fields with
              | Some (`Assoc err) ->
                  let msg = match List.assoc_opt "message" err with
                    | Some (`String s) -> s
                    | _ -> "Unknown error"
                  in
                  Error (ServerError (500, msg))
              | _ -> Error (ParseError "No result or error in response")))
    | _ -> Error (ParseError "Invalid JSON structure")
  with
  | Yojson.Json_error msg -> Error (ParseError msg)
  | _ -> Error (ParseError "Unknown parse error")

(** {1 HTTP Transport Layer} *)

(** HTTP POST function type for dependency injection *)
type http_post_fn = host:string -> port:int -> path:string -> body:string -> (string, error) result

(** Eio-based HTTP POST implementation *)
let eio_http_post ~net : http_post_fn = fun ~host ~port ~path ~body ->
  try
    Eio.Net.with_tcp_connect ~host ~service:(string_of_int port) net @@ fun flow ->
    let request = Printf.sprintf
      "POST %s HTTP/1.1\r\n\
       Host: %s:%d\r\n\
       Content-Type: application/json\r\n\
       Content-Length: %d\r\n\
       Connection: close\r\n\
       \r\n\
       %s"
      path host port (String.length body) body
    in
    Eio.Flow.copy_string request flow;
    Eio.Flow.shutdown flow `Send;

    let buf = Buffer.create 4096 in
    let rec read_all () =
      let chunk = Cstruct.create 4096 in
      match Eio.Flow.single_read flow chunk with
      | n ->
          Buffer.add_string buf (Cstruct.to_string ~len:n chunk);
          read_all ()
      | exception End_of_file -> ()
    in
    read_all ();

    let response_str = Buffer.contents buf in
    let body_start =
      try
        let idx = Str.search_forward (Str.regexp "\r\n\r\n") response_str 0 in
        idx + 4
      with Not_found -> 0
    in
    Ok (String.sub response_str body_start (String.length response_str - body_start))
  with
  | Unix.Unix_error (err, _, _) -> Error (ConnectionError (Unix.error_message err))
  | exn -> Error (ConnectionError (Printexc.to_string exn))

(** {1 Public API} *)

(** Call LLM model with prompt (testable version with injected HTTP)

    @param http_post HTTP POST function (use eio_http_post ~net for production)
    @param model LLM model to use (default: Gemini for speed)
    @param host llm-mcp server host (default: 127.0.0.1)
    @param port llm-mcp server port (default: 8932)
    @param prompt The prompt to send
    @return Response or error *)
let call_with_http ~http_post ?(model=Gemini) ?(host=default_host) ?(port=default_port) ~prompt () =
  let request_body = build_request ~model ~prompt in
  match http_post ~host ~port ~path:"/mcp" ~body:request_body with
  | Ok body -> parse_response body
  | Error e -> Error e

(** Call LLM model with prompt (Eio-native, non-blocking)

    @param net Eio network capability
    @param clock Eio clock for timeout (optional)
    @param timeout_sec Timeout in seconds (default: from env config)
    @param model LLM model to use (default: Gemini for speed)
    @param host llm-mcp server host (default: 127.0.0.1)
    @param port llm-mcp server port (default: 8932)
    @param prompt The prompt to send
    @return Response or error *)
let call ~net ?clock ?(timeout_sec=Env_config.Llm.timeout_seconds) ?(model=Gemini) ?(host=default_host) ?(port=default_port) ~prompt () =
  let do_call () =
    call_with_http ~http_post:(eio_http_post ~net) ~model ~host ~port ~prompt ()
  in
  match clock with
  | None -> do_call ()
  | Some clk ->
    try
      Eio.Time.with_timeout_exn clk timeout_sec (fun () -> do_call ())
    with
    | Eio.Time.Timeout -> Error Timeout

(** Convenience function for quick classification tasks *)
let classify ~net ?clock ~prompt () =
  call ~net ?clock ~model:Gemini ~prompt ()

(** {1 Walph Intent Classification} *)

(** Walph command intent *)
type walph_intent =
  | Start of { preset: string; target: string option }
  | Stop
  | Pause
  | Resume
  | Status
  | Ignore

(** Classify natural language message into Walph intent

    @param net Eio network capability
    @param clock Eio clock for timeout (optional)
    @param message Natural language message to classify
    @return Classified intent with confidence *)
let classify_walph_intent ~net ?clock ~message () =
  let prompt = Printf.sprintf {|You are a command classifier for Walph automation system.

Classify this message into exactly one intent:
- START: 작업 시작 요청 (커버리지, 리팩토링, 문서화, drain 등)
- STOP: 정지/종료/그만 요청
- PAUSE: 일시정지/멈춰 요청
- RESUME: 재개/계속 요청
- STATUS: 상태 조회/뭐해 요청
- IGNORE: Walph 관련 아님

Message: "%s"

Output JSON only (no markdown):
{"intent": "START|STOP|PAUSE|RESUME|STATUS|IGNORE", "preset": "drain|coverage|refactor|docs|null", "target": "file/path or null", "confidence": 0.0-1.0}|} message
  in
  match call ~net ?clock ~model:Gemini ~prompt () with
  | Error e -> Error e
  | Ok response ->
      try
        (* Extract JSON from response, handling potential markdown code blocks *)
        let json_str =
          let content = String.trim response.content in
          if String.length content > 0 && content.[0] = '{' then content
          else
            (* Try to extract JSON from markdown code block *)
            let re = Str.regexp {|```json?\n?\(.*\)\n?```|} in
            if Str.string_match re content 0 then
              Str.matched_group 1 content
            else content
        in
        let json = Yojson.Safe.from_string json_str in
        match json with
        | `Assoc fields ->
            let intent_str = match List.assoc_opt "intent" fields with
              | Some (`String s) -> String.uppercase_ascii s
              | _ -> "IGNORE"
            in
            let preset = match List.assoc_opt "preset" fields with
              | Some (`String s) when s <> "null" -> s
              | _ -> "drain"
            in
            let target = match List.assoc_opt "target" fields with
              | Some (`String s) when s <> "null" -> Some s
              | _ -> None
            in
            let confidence = match List.assoc_opt "confidence" fields with
              | Some (`Float f) -> f
              | Some (`Int i) -> float_of_int i
              | _ -> 0.5
            in
            let intent = match intent_str with
              | "START" -> Start { preset; target }
              | "STOP" -> Stop
              | "PAUSE" -> Pause
              | "RESUME" -> Resume
              | "STATUS" -> Status
              | _ -> Ignore
            in
            (* Only return intent if confidence is high enough *)
            if confidence >= 0.7 then Ok intent
            else Ok Ignore
        | _ -> Ok Ignore
      with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> Ok Ignore

(** {1 Chain Orchestration} *)

(** Build MCP JSON-RPC request for chain.orchestrate
    @param goal The goal description for orchestration
    @param chain_id Optional explicit chain ID to use (bypasses auto-selection)
    @param timeout Timeout in seconds (default: 120)
    @param max_replans Maximum re-planning attempts (default: 2) *)
let build_chain_request ~goal ?chain_id ?(timeout=120) ?(max_replans=2) () =
  let chain_id_fields = match chain_id with
    | Some id -> [("chain_id", `String id)]
    | None -> []
  in
  Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "chain.orchestrate");
      ("arguments", `Assoc (chain_id_fields @ [
        ("goal", `String goal);
        ("timeout", `Int timeout);
        ("max_replans", `Int max_replans);
        ("trace", `Bool false);
        ("verify_on_complete", `Bool true);
      ]));
    ]);
  ])

(** Call chain.orchestrate on llm-mcp server
    @param net Eio network capability
    @param clock Eio clock capability for hard timeout
    @param goal Goal description for orchestration
    @param chain_id Optional explicit chain ID (bypasses auto-selection)
    @param host llm-mcp server host (default: 127.0.0.1)
    @param port llm-mcp server port (default: 8932)
    @param timeout_sec Timeout in seconds (default: 120 for long chains)
    @return Response content or error *)
let call_chain ~net ~clock ~goal ?chain_id ?(host=default_host) ?(port=default_port) ?(timeout_sec=120.0) () =
  let request_body = build_chain_request ~goal ?chain_id ~timeout:(int_of_float timeout_sec) () in
  try
    Eio.Net.with_tcp_connect ~host ~service:(string_of_int port) net @@ fun flow ->
    let request = Printf.sprintf
      "POST /mcp HTTP/1.1\r\n\
       Host: %s:%d\r\n\
       Content-Type: application/json\r\n\
       Accept: application/json, text/event-stream\r\n\
       Content-Length: %d\r\n\
       Connection: close\r\n\
       \r\n\
       %s"
      host port (String.length request_body) request_body
    in
    Eio.Flow.copy_string request flow;
    Eio.Flow.shutdown flow `Send;

    (* Read response with hard timeout *)
    let buf = Buffer.create 16384 in
    let deadline = Eio.Time.now clock +. timeout_sec in
    let rec read_all () =
      let now = Eio.Time.now clock in
      if now >= deadline then
        Error Timeout
      else
        let remaining = deadline -. now in
        let read_once () =
          let chunk = Cstruct.create 4096 in
          match Eio.Flow.single_read flow chunk with
          | n ->
              Buffer.add_string buf (Cstruct.to_string ~len:n chunk);
              `Data
          | exception End_of_file -> `Eof
        in
        match Eio.Fiber.first read_once (fun () ->
          Eio.Time.sleep clock remaining;
          `Timeout) with
        | `Data -> read_all ()
        | `Eof -> Ok ()
        | `Timeout -> Error Timeout
    in
    match read_all () with
    | Error Timeout -> Error Timeout
    | Error e -> Error e
    | Ok () ->
        (* Parse HTTP response - prefer SSE data lines, fallback to JSON body *)
        let response_str = Buffer.contents buf in
        let body_start =
          try
            let idx = Str.search_forward (Str.regexp "\r\n\r\n") response_str 0 in
            idx + 4
          with Not_found -> 0
        in
        let body =
          String.sub response_str body_start (String.length response_str - body_start)
        in
        let parse_chain_json json_str =
          try
            let json = Yojson.Safe.from_string json_str in
            match json with
            | `Assoc fields ->
                (match List.assoc_opt "result" fields with
                 | Some (`Assoc result_fields) ->
                     (match List.assoc_opt "content" result_fields with
                      | Some (`List [`Assoc text_fields]) ->
                          (match List.assoc_opt "text" text_fields with
                           | Some (`String s) -> Ok s
                           | _ -> Ok json_str)
                      | Some (`String s) -> Ok s
                      | _ -> Ok json_str)
                 | _ ->
                     (match List.assoc_opt "error" fields with
                      | Some (`Assoc err) ->
                          let msg = match List.assoc_opt "message" err with
                            | Some (`String s) -> s
                            | _ -> "Unknown chain error"
                          in
                          Error (ServerError (500, msg))
                      | _ -> Ok json_str))
            | _ -> Ok json_str
          with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> Ok json_str
        in
        let lines = String.split_on_char '\n' body in
        let data_lines = List.filter_map (fun line ->
          let line = String.trim line in
          if String.length line > 6 && String.sub line 0 6 = "data: " then
            Some (String.sub line 6 (String.length line - 6))
          else None
        ) lines in
        match List.rev data_lines with
        | last_data :: _ -> parse_chain_json last_data
        | [] ->
            let trimmed = String.trim body in
            if trimmed = "" then Error (ParseError "No data in response")
            else parse_chain_json trimmed
  with
  | Unix.Unix_error (err, _, _) ->
      Error (ConnectionError (Unix.error_message err))
  | exn ->
      Error (ConnectionError (Printexc.to_string exn))

type endpoint = {
  host : string;
  port : int;
  base_path : string;
  api_key : string option;
}

type tool_response = {
  text : string;
  extra : (string * string) list;
}

type chain_run_response = {
  output : string;
  chain_id : string option;
  run_id : string option;
  duration_ms : int option;
  trace_count : int option;
}

type chain_orchestrate_response = {
  summary : string;
  success : bool option;
  total_replans : int option;
  chain_id : string option;
  run_id : string option;
}

let normalize_env = function
  | Some raw ->
      let value = String.trim raw in
      if value = "" then None else Some value
  | None -> None

let configured_api_key () =
  match normalize_env (Sys.getenv_opt "LLM_MCP_API_KEY") with
  | Some value -> Some value
  | None -> normalize_env (Sys.getenv_opt "MCP_API_KEY")

let normalize_base_path path =
  let trimmed = String.trim path in
  if trimmed = "" || String.equal trimmed "/" then ""
  else if trimmed.[0] = '/' then trimmed
  else "/" ^ trimmed

let resolve_endpoint ?host ?port () =
  let default_endpoint =
    {
      host = default_host;
      port = default_port;
      base_path = "";
      api_key = configured_api_key ();
    }
  in
  let from_url =
    match normalize_env (Sys.getenv_opt "LLM_MCP_URL") with
    | None -> default_endpoint
    | Some url ->
        let uri = Uri.of_string url in
        {
          host = Option.value ~default:default_endpoint.host (Uri.host uri);
          port = Option.value ~default:default_endpoint.port (Uri.port uri);
          base_path = normalize_base_path (Uri.path uri);
          api_key = configured_api_key ();
        }
  in
  {
    from_url with
    host = Option.value ~default:from_url.host host;
    port = Option.value ~default:from_url.port port;
  }

let endpoint_path endpoint path =
  let normalized =
    if path = "" then "/"
    else if path.[0] = '/' then path
    else "/" ^ path
  in
  endpoint.base_path ^ normalized

let parse_http_response raw =
  let body_start =
    try
      let idx = Str.search_forward (Str.regexp "\r\n\r\n") raw 0 in
      idx + 4
    with Not_found -> 0
  in
  let headers =
    if body_start >= 4 then String.sub raw 0 (body_start - 4) else ""
  in
  let status_code =
    match String.split_on_char '\n' headers with
    | status_line :: _ ->
        let cleaned = String.trim status_line in
        (match String.split_on_char ' ' cleaned with
        | _http :: code :: _ -> (try int_of_string code with Failure _ -> 200)
        | _ -> 200)
    | [] -> 200
  in
  let body =
    if body_start >= String.length raw then ""
    else String.sub raw body_start (String.length raw - body_start)
  in
  (status_code, body)

let http_request ~net ~clock ?(timeout_sec=default_timeout_sec) ?(meth="GET")
    ?(headers=[]) ?body endpoint ~path () =
  let request_body = Option.value ~default:"" body in
  let path = endpoint_path endpoint path in
  let extra_headers =
    headers
    @
    match endpoint.api_key with
    | Some value -> [("Authorization", "Bearer " ^ value)]
    | None -> []
  in
  let has_header name =
    List.exists (fun (key, _) -> String.equal (String.lowercase_ascii key) name) extra_headers
  in
  let header_lines =
    [
      ("Host", Printf.sprintf "%s:%d" endpoint.host endpoint.port);
      ("Accept", "application/json, text/event-stream");
      ("Connection", "close");
    ]
    @ (if request_body <> "" && not (has_header "content-type") then [("Content-Type", "application/json")] else [])
    @ (if request_body <> "" then [("Content-Length", string_of_int (String.length request_body))] else [])
    @ extra_headers
  in
  let request =
    Printf.sprintf "%s %s HTTP/1.1\r\n%s\r\n\r\n%s" meth path
      (String.concat "\r\n" (List.map (fun (key, value) -> key ^ ": " ^ value) header_lines))
      request_body
  in
  let do_request () =
    Eio.Net.with_tcp_connect ~host:endpoint.host ~service:(string_of_int endpoint.port) net
    @@ fun flow ->
    Eio.Flow.copy_string request flow;
    Eio.Flow.shutdown flow `Send;
    let buf = Buffer.create 16384 in
    let rec read_all () =
      let chunk = Cstruct.create 4096 in
      match Eio.Flow.single_read flow chunk with
      | n ->
          Buffer.add_string buf (Cstruct.to_string ~len:n chunk);
          read_all ()
      | exception End_of_file -> ()
    in
    read_all ();
    let status_code, response_body = parse_http_response (Buffer.contents buf) in
    if status_code >= 200 && status_code < 300 then Ok response_body
    else Error (ServerError (status_code, response_body))
  in
  try Eio.Time.with_timeout_exn clock timeout_sec do_request
  with
  | Eio.Time.Timeout -> Error Timeout
  | Unix.Unix_error (err, _, _) -> Error (ConnectionError (Unix.error_message err))
  | exn -> Error (ConnectionError (Printexc.to_string exn))

let build_jsonrpc_request ~name ~arguments =
  Yojson.Safe.to_string
    (`Assoc
      [
        ("jsonrpc", `String "2.0");
        ("id", `Int 1);
        ("method", `String "tools/call");
        ("params", `Assoc [ ("name", `String name); ("arguments", arguments) ]);
      ])

let extract_response_payload body =
  let lines = String.split_on_char '\n' body in
  let data_lines =
    List.filter_map
      (fun line ->
        let trimmed = String.trim line in
        if String.length trimmed > 6 && String.sub trimmed 0 6 = "data: " then
          Some (String.sub trimmed 6 (String.length trimmed - 6))
        else None)
      lines
  in
  match List.rev data_lines with
  | payload :: _ -> payload
  | [] -> String.trim body

let parse_extra_block text =
  let marker = "\n\n[Extra]\n" in
  try
    let idx = Str.search_forward (Str.regexp_string marker) text 0 in
    let prefix = String.sub text 0 idx in
    let suffix_start = idx + String.length marker in
    let suffix = String.sub text suffix_start (String.length text - suffix_start) in
    let extra =
      match Yojson.Safe.from_string suffix with
      | `Assoc fields ->
          fields
          |> List.filter_map (fun (key, value) ->
                 match value with
                 | `String raw -> Some (key, raw)
                 | other -> Some (key, Yojson.Safe.to_string other))
      | _ -> []
    in
    { text = prefix; extra }
  with
  | Not_found | Yojson.Json_error _ -> { text; extra = [] }

let parse_tool_response body =
  let payload = extract_response_payload body in
  if payload = "" then Error (ParseError "No data in response")
  else
    try
      let json = Yojson.Safe.from_string payload in
      match json with
      | `Assoc fields -> (
          match List.assoc_opt "result" fields, List.assoc_opt "error" fields with
          | Some (`Assoc result_fields), _ ->
              let is_error =
                match List.assoc_opt "isError" result_fields with
                | Some (`Bool value) -> value
                | _ -> false
              in
              let text =
                match List.assoc_opt "content" result_fields with
                | Some (`List [`Assoc content_fields]) -> (
                    match List.assoc_opt "text" content_fields with
                    | Some (`String value) -> value
                    | _ -> "")
                | Some (`String value) -> value
                | _ -> ""
              in
              if is_error then Error (ServerError (500, text))
              else Ok (parse_extra_block text)
          | _, Some (`Assoc err) ->
              let message =
                match List.assoc_opt "message" err with
                | Some (`String value) -> value
                | _ -> "Unknown error"
              in
              Error (ServerError (500, message))
          | _ -> Error (ParseError "Invalid JSON-RPC response"))
      | _ -> Error (ParseError "Invalid JSON structure")
    with
    | Yojson.Json_error msg -> Error (ParseError msg)
    | exn -> Error (ParseError (Printexc.to_string exn))

let call_jsonrpc_tool ~net ~clock ?host ?port ?(timeout_sec=120.0) ~name ~arguments () =
  let endpoint = resolve_endpoint ?host ?port () in
  let body = build_jsonrpc_request ~name ~arguments in
  match http_request ~net ~clock ~timeout_sec ~meth:"POST" ~body endpoint ~path:"/mcp" () with
  | Ok response_body -> parse_tool_response response_body
  | Error _ as err -> err

let int_of_extra extra key =
  Option.bind (List.assoc_opt key extra) (fun value ->
      try Some (int_of_string value) with Failure _ -> None)

let bool_of_extra extra key =
  Option.bind (List.assoc_opt key extra) (fun value ->
      try Some (bool_of_string value) with Invalid_argument _ -> None)

let call_chain_run ~net ~clock ?host ?port ?chain_id ?mermaid ?input_json
    ?(trace=true) ?(checkpoint_enabled=true) ?(timeout_sec=120.0) () =
  let fields =
    []
    |> (fun acc ->
         match chain_id with Some value -> ("chain_id", `String value) :: acc | None -> acc)
    |> (fun acc ->
         match mermaid with Some value -> ("mermaid", `String value) :: acc | None -> acc)
    |> (fun acc ->
         match input_json with Some value -> ("input", value) :: acc | None -> acc)
  in
  let arguments =
    `Assoc
      (List.rev
         (("trace", `Bool trace)
          :: ("checkpoint_enabled", `Bool checkpoint_enabled)
          :: ("timeout", `Int (int_of_float timeout_sec))
          :: fields))
  in
  match call_jsonrpc_tool ~net ~clock ?host ?port ~timeout_sec ~name:"chain.run" ~arguments () with
  | Ok response ->
      Ok
        {
          output = response.text;
          chain_id = List.assoc_opt "chain_id" response.extra;
          run_id = List.assoc_opt "run_id" response.extra;
          duration_ms = int_of_extra response.extra "duration_ms";
          trace_count = int_of_extra response.extra "trace_count";
        }
  | Error _ as err -> err

let call_chain_orchestrate ~net ~clock ?host ?port ~goal ?chain_id
    ?(timeout_sec=120.0) ?(max_replans=2) () =
  let fields =
    match chain_id with
    | Some value -> [ ("chain_id", `String value) ]
    | None -> []
  in
  let arguments =
    `Assoc
      (fields
       @ [
           ("goal", `String goal);
           ("timeout", `Int (int_of_float timeout_sec));
           ("max_replans", `Int max_replans);
           ("trace", `Bool false);
           ("verify_on_complete", `Bool true);
         ])
  in
  match
    call_jsonrpc_tool ~net ~clock ?host ?port ~timeout_sec ~name:"chain.orchestrate"
      ~arguments ()
  with
  | Ok response ->
      Ok
        {
          summary = response.text;
          success = bool_of_extra response.extra "success";
          total_replans = int_of_extra response.extra "total_replans";
          chain_id = List.assoc_opt "chain_id" response.extra;
          run_id = List.assoc_opt "run_id" response.extra;
        }
  | Error _ as err -> err

let fetch_chain_status_json ~net ~clock ?host ?port ?(timeout_sec=15.0) () =
  let endpoint = resolve_endpoint ?host ?port () in
  match http_request ~net ~clock ~timeout_sec endpoint ~path:"/chain/status" () with
  | Ok body -> (try Ok (Yojson.Safe.from_string body) with Yojson.Json_error msg -> Error (ParseError msg))
  | Error _ as err -> err

let fetch_chain_history_json ~net ~clock ?host ?port ?(timeout_sec=15.0) () =
  let endpoint = resolve_endpoint ?host ?port () in
  match http_request ~net ~clock ~timeout_sec endpoint ~path:"/chain/history" () with
  | Ok body -> (try Ok (Yojson.Safe.from_string body) with Yojson.Json_error msg -> Error (ParseError msg))
  | Error _ as err -> err

let fetch_chain_run_json ~net ~clock ?host ?port ?(timeout_sec=15.0) ~run_id () =
  let endpoint = resolve_endpoint ?host ?port () in
  match http_request ~net ~clock ~timeout_sec endpoint ~path:("/chain/runs/" ^ run_id) () with
  | Ok body -> (try Ok (Yojson.Safe.from_string body) with Yojson.Json_error msg -> Error (ParseError msg))
  | Error _ as err -> err
