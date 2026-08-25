open Alcotest

module Official_client_session_store =
  Masc.Keeper_official_client_session_store

type http_result = {
  status: int option;
  headers: (string * string) list;
  body: string;
  curl_exit: int;
  stderr: string;
}

let read_all ic =
  let buf = Buffer.create 1024 in
  (try
     while true do
       Buffer.add_channel buf ic 4096
     done
   with End_of_file -> ());
  Buffer.contents buf

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)

let trim_cr s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s

let parse_headers raw =
  let lines = String.split_on_char '\n' raw |> List.map trim_cr in
  let rec collect blocks current = function
    | [] ->
        let blocks =
          if current = [] then blocks else List.rev current :: blocks
        in
        List.rev blocks
    | line :: rest ->
        if line = "" then
          let blocks =
            if current = [] then blocks else List.rev current :: blocks
          in
          collect blocks [] rest
        else
          collect blocks (line :: current) rest
  in
  let blocks = collect [] [] lines in
  let last_http_block =
    List.fold_left
      (fun acc block ->
         match block with
         | status_line :: _ when String.length status_line >= 5
                                && String.sub status_line 0 5 = "HTTP/" ->
             Some block
         | _ -> acc)
      None blocks
  in
  match last_http_block with
  | None -> (None, [])
  | Some (status_line :: header_lines) ->
      let status =
        match String.split_on_char ' ' status_line with
        | _proto :: code :: _ -> (try Some (int_of_string code) with _ -> None)
        | _ -> None
      in
      let headers =
        List.filter_map
          (fun line ->
             match String.index_opt line ':' with
             | None -> None
             | Some idx ->
                 let key =
                   String.sub line 0 idx |> String.trim |> String.lowercase_ascii
                 in
                 let value =
                   String.sub line (idx + 1) (String.length line - idx - 1)
                   |> String.trim
                 in
                 Some (key, value))
          header_lines
      in
      (status, headers)
  | Some [] -> (None, [])

let run_curl ?(headers=[]) ?max_time ?(method_="GET") ?body ~port ~path () =
  let header_file = Filename.temp_file "sse-storm-header-" ".txt" in
  let body_file = Filename.temp_file "sse-storm-body-" ".txt" in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let max_time_args =
    match max_time with
    | None -> []
    | Some t -> ["--max-time"; Printf.sprintf "%.3f" t]
  in
  let header_args =
    List.concat_map
      (fun (k, v) -> ["-H"; Printf.sprintf "%s: %s" k v])
      headers
  in
  let body_args =
    match body with
    | None -> []
    | Some body -> [ "--data-binary"; body ]
  in
  let args =
    [|
      "curl";
      "-sS";
      "--http1.1";
      "-X";
      method_;
      "-o";
      body_file;
      "-D";
      header_file;
    |]
    |> Array.to_list
    |> fun base -> base @ max_time_args @ header_args @ body_args @ [url]
    |> Array.of_list
  in
  let (ic, oc, ec) = Unix.open_process_args_full "curl" args (Unix.environment ()) in
  close_out_noerr oc;
  let _stdout = read_all ic in
  let stderr = read_all ec in
  let curl_exit =
    match Unix.close_process_full (ic, oc, ec) with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED code -> 128 + code
    | Unix.WSTOPPED code -> 256 + code
  in
  let header_raw = read_file header_file in
  let body = read_file body_file in
  (try Sys.remove header_file with _ -> ());
  (try Sys.remove body_file with _ -> ());
  let (status, headers) = parse_headers header_raw in
  { status; headers; body; curl_exit; stderr }

let header_value result name =
  let name = String.lowercase_ascii name in
  result.headers
  |> List.find_map (fun (key, value) ->
    if String.equal (String.lowercase_ascii key) name then Some value else None)

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.setsockopt socket Unix.SO_REUSEADDR true;
      match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
      | () ->
          begin
            match Unix.getsockname socket with
            | Unix.ADDR_INET (_, port) -> Some port
            | _ -> fail "unexpected socket address"
          end
      | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) -> None)

let wait_for_health ~port ~timeout_s =
  let has_ready_flag body =
    let needle = "\"state_ready\":true" in
    let needle_len = String.length needle in
    let body_len = String.length body in
    let rec loop idx =
      if idx + needle_len > body_len then false
      else if String.sub body idx needle_len = needle then true
      else loop (idx + 1)
    in
    loop 0
  in
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if Unix.gettimeofday () > deadline then
      false
    else
      let res = run_curl ~max_time:0.2 ~port ~path:"/health" () in
      match res.status with
      | Some 200 when has_ready_flag res.body -> true
      | _ ->
          Unix.sleepf 0.1;
          loop ()
  in
  loop ()

let wait_pid_exit ~pid ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    match Unix.waitpid [Unix.WNOHANG] pid with
    | 0, _ ->
        if Unix.gettimeofday () > deadline then
          false
        else begin
          Unix.sleepf 0.05;
          loop ()
        end
    | _pid, _status -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  loop ()

let dashboard_dev_token ~port =
  let result =
    run_curl ~max_time:2.0 ~port ~path:"/api/v1/dashboard/dev-token" ()
  in
  match result.status with
  | Some 200 ->
      begin
        match Yojson.Safe.from_string result.body with
        | `Assoc fields ->
          (match
             ( List.assoc_opt "token" fields
             , List.assoc_opt "actor" fields
             , List.assoc_opt "role" fields )
           with
           (* [Server_routes_http_dashboard_dev_token.dashboard_dev_role] is
              [Masc_domain.Admin] since #28354; this arm still required the
              pre-#28354 [worker] and so failed every run against a server that
              honours the current contract. *)
           | ( Some (`String token)
             , Some (`String "dashboard")
             , Some (`String "admin") )
             when String.trim token <> "" ->
             token
           | _ ->
             fail
               ("dashboard dev-token response violates token/actor/role contract: "
                ^ result.body))
        | _ -> fail ("dashboard dev-token response is not an object: " ^ result.body)
        | exception Yojson.Json_error msg ->
            fail ("dashboard dev-token response is invalid JSON: " ^ msg)
      end
  | Some code ->
      fail
        (Printf.sprintf
           "dashboard dev-token returned HTTP %d (curl_exit=%d stderr=%s body=%s)"
           code result.curl_exit result.stderr result.body)
  | None ->
      fail
        (Printf.sprintf
           "dashboard dev-token missing HTTP status (curl_exit=%d stderr=%s body=%s)"
           result.curl_exit result.stderr result.body)

let initialize_mcp_session ~port ~auth_token =
  let body =
    {|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"sse-storm-e2e","version":"1.0"},"capabilities":{}}}|}
  in
  let result =
    run_curl
      ~headers:
        [
          ("Content-Type", "application/json");
          ("Accept", "application/json, text/event-stream");
          ("Authorization", "Bearer " ^ auth_token);
        ]
      ~method_:"POST" ~body ~max_time:2.0 ~port ~path:"/mcp" ()
  in
  (match result.status with
  | Some 200 -> ()
  | Some code ->
      fail
        (Printf.sprintf
           "initialize returned HTTP %d (curl_exit=%d stderr=%s body=%s)"
           code result.curl_exit result.stderr result.body)
  | None ->
      fail
        (Printf.sprintf
           "initialize missing HTTP status (curl_exit=%d stderr=%s body=%s)"
           result.curl_exit result.stderr result.body));
  match header_value result "mcp-session-id" with
  | Some sid when String.trim sid <> "" -> sid
  | _ ->
      fail
        (Printf.sprintf
           "initialize response missing Mcp-Session-Id (curl_exit=%d stderr=%s body=%s)"
           result.curl_exit result.stderr result.body)

let merge_env_overrides ?(remove = []) overrides =
  let override_keys =
    remove @ List.map fst overrides
  in
  let is_override_key entry =
    match String.index_opt entry '=' with
    | None -> false
    | Some idx ->
        let key = String.sub entry 0 idx in
        List.mem key override_keys
  in
  let base =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun entry -> not (is_override_key entry))
  in
  let injected =
    List.map (fun (k, v) -> k ^ "=" ^ v) overrides
  in
  Array.of_list (base @ injected)

let ensure_dir path =
  if Sys.file_exists path then
    if not (Sys.is_directory path) then
      fail (Printf.sprintf "expected directory path: %s" path)
    else ()
  else
    Unix.mkdir path 0o755

let runtime_seed =
  {|
[runtime]
default = "deepseek.smoke"

[runtime.exact_output_lanes.hitl_auto_judge]
slots = ["deepseek.smoke"]

[runtime.exact_output_lanes.board_attention_exact]
slots = ["deepseek.smoke"]

[providers.deepseek]
display-name = "SSE Storm Smoke"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[models.smoke]
# The SSE storm harness never reaches this provider endpoint, but strict
# runtime bootstrap still requires catalog-backed capability metadata.
api-name = "deepseek-v4-flash"
max-context = 32768
tools-support = true
streaming = true

[deepseek.smoke]
is-default = true
max-concurrent = 1
max-request-body-bytes = 65536
|}

let catalog_overlay_seed =
  {|
[[providers]]
id = "deepseek"
kind = "openai_compat"
base_url = "http://127.0.0.1:9/v1"
request_path = "/chat/completions"
api_key_env = ""
capabilities_base = "openai_chat"

[[models]]
id_prefix = "deepseek-v4-flash"
provider_name = "deepseek"
base = "openai_chat"
max_context_tokens = 32768
max_output_tokens = 1024
supports_tools = true
supports_tool_choice = true
supports_response_format_json = false
supports_structured_output = false

[[targets]]
id = "deepseek.smoke"
provider_ref = "deepseek"
model_id = "deepseek-v4-flash"
|}

let main_eio_test_admin_token = "sse-storm-admin-token"

let seed_server_config ~base_path =
  let masc_dir = Filename.concat base_path ".masc" in
  let config_dir = Filename.concat masc_dir "config" in
  ensure_dir masc_dir;
  ensure_dir config_dir;
  List.iter
    (fun name -> ensure_dir (Filename.concat config_dir name))
    [ "keepers"; "prompts" ];
  let runtime_dst = Filename.concat config_dir "runtime.toml" in
  if not (Sys.file_exists runtime_dst) then
    let oc = open_out runtime_dst in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc runtime_seed);
  let overlay_dst = Filename.concat config_dir "agent-core-models-overlay.toml" in
  if not (Sys.file_exists overlay_dst) then
    let oc = open_out overlay_dst in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc catalog_overlay_seed)

let with_server f =
  let exe = Masc_test_runtime.find_main_eio_exe () in
  let port =
    match find_free_port () with
    | Some p -> p
    | None -> Alcotest.skip ()
  in
  let log_file = Filename.temp_file "sse-storm-e2e-" ".log" in
  let base_path = Filename.temp_dir "sse-storm-base-" "" in
  seed_server_config ~base_path;
  let log_fd =
    Unix.openfile log_file [Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC] 0o644
  in
  let env =
    merge_env_overrides ~remove:[ "AGENT_CORE_MODEL_CATALOG" ]
      [
        ("MASC_BASE_PATH", base_path);
        ("MASC_BASE_PATH_INPUT", base_path);
        ("MASC_ADMIN_TOKEN", main_eio_test_admin_token);
        ("MASC_KEEPER_AUTONOMOUS_ENABLED", "0");
        ("GRAPHQL_API_KEY", "");
        ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
      ]
  in
  let argv =
    [|
      exe;
      "--port";
      string_of_int port;
      "--base-path";
      base_path;
    |]
  in
  let pid =
    Unix.create_process_env exe argv env Unix.stdin log_fd log_fd
  in
  Unix.close log_fd;
  let cleanup () =
    (try Unix.kill pid Sys.sigterm with _ -> ());
    if not (wait_pid_exit ~pid ~timeout_s:2.0) then
      (try Unix.kill pid Sys.sigkill with _ -> ());
    ignore (wait_pid_exit ~pid ~timeout_s:1.0)
  in
  if not (wait_for_health ~port ~timeout_s:20.0) then begin
    cleanup ();
    let logs = read_file log_file in
    fail (Printf.sprintf "server failed to become ready on port %d\n%s" port logs)
  end;
  Fun.protect ~finally:cleanup (fun () ->
    let auth_token = dashboard_dev_token ~port in
    f ~port ~auth_token ~base_path)

let check_status label expected result =
  match result.status with
  | Some code -> check int label expected code
  | None ->
      fail
        (Printf.sprintf
           "%s: no HTTP status (curl_exit=%d, stderr=%s)"
           label
           result.curl_exit
           result.stderr)

let publish_masc_broadcast ~port ~auth_token ~session_id =
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [ "jsonrpc", `String "2.0"
        ; "id", `Int 2
        ; "method", `String "tools/call"
        ; ( "params"
          , `Assoc
              [ "name", `String "masc_broadcast"
              ; ( "arguments"
                , `Assoc
                    [ "agent_name", `String "dashboard"
                    ; "content", `String "sse-ag-ui-wire-encoding"
                    ] )
              ] )
        ])
  in
  let result =
    run_curl
      ~headers:
        [ ("Content-Type", "application/json")
        ; ("Accept", "application/json, text/event-stream")
        ; ("X-MASC-Force-JSON", "true")
        ; ("Authorization", "Bearer " ^ auth_token)
        ; ("Mcp-Session-Id", session_id)
        ]
      ~method_:"POST"
      ~body
      ~max_time:2.0
      ~port
      ~path:"/mcp"
      ()
  in
  check_status "observer source broadcast accepted" 200 result;
  match Yojson.Safe.from_string result.body with
  | `Assoc fields ->
      (match List.assoc_opt "result" fields with
       | Some (`Assoc result_fields) ->
           (match List.assoc_opt "isError" result_fields with
            | Some (`Bool false) -> ()
            | Some (`Bool true) ->
                fail
                  (Printf.sprintf
                     "observer source broadcast returned a tool error: %s"
                     result.body)
            | Some _ | None ->
                fail
                  (Printf.sprintf
                     "observer source broadcast result omitted boolean isError: %s"
                     result.body))
       | Some _ ->
           fail
             (Printf.sprintf
                "observer source broadcast returned a non-object result: %s"
                result.body)
       | None when List.mem_assoc "error" fields ->
           fail
             (Printf.sprintf
                "observer source broadcast returned an MCP error: %s"
                result.body)
       | None ->
           fail
             (Printf.sprintf
                "observer source broadcast returned an invalid MCP response: %s"
                result.body))
  | _ ->
      fail
        (Printf.sprintf
           "observer source broadcast returned an invalid MCP response: %s"
           result.body)
  | exception Yojson.Json_error message ->
      fail
        (Printf.sprintf
           "observer source broadcast returned invalid JSON: %s body=%s"
           message
           result.body)

let test_mcp_reconnect_stays_accepted () =
  with_server @@ fun ~port ~auth_token ~base_path:_ ->
  let sid = initialize_mcp_session ~port ~auth_token in
  let headers =
    [
      ("Accept", "text/event-stream");
      ("Authorization", "Bearer " ^ auth_token);
      ("Mcp-Session-Id", sid);
    ]
  in

  let first = run_curl ~headers ~max_time:2.0 ~port ~path:"/mcp" () in
  check_status "first /mcp connect accepted" 200 first;

  let second = run_curl ~headers ~max_time:2.0 ~port ~path:"/mcp" () in
  check_status "follow-up /mcp reconnect accepted" 200 second

let body_contains needle body =
  let nl = String.length needle and bl = String.length body in
  let rec scan i = i + nl <= bl && (String.sub body i nl = needle || scan (i + 1)) in
  nl > 0 && scan 0

let sse_data_jsons body =
  String.split_on_char '\n' body
  |> List.filter_map (fun line ->
    let prefix = "data:" in
    if String.starts_with ~prefix line then
      let payload =
        String.sub line (String.length prefix) (String.length line - String.length prefix)
        |> String.trim
      in
      try Some (Yojson.Safe.from_string payload) with Yojson.Json_error _ -> None
    else None)

let sse_id_data_jsons body =
  let rec collect current_id acc = function
    | [] -> List.rev acc
    | line :: rest when String.starts_with ~prefix:"id:" line ->
      let raw =
        String.sub line 3 (String.length line - 3) |> String.trim
      in
      collect (int_of_string_opt raw) acc rest
    | line :: rest when String.starts_with ~prefix:"data:" line ->
      let payload =
        String.sub line 5 (String.length line - 5) |> String.trim
      in
      let acc =
        match current_id with
        | None -> acc
        | Some event_id ->
          (match Yojson.Safe.from_string payload with
           | json -> (event_id, json) :: acc
           | exception Yojson.Json_error _ -> acc)
      in
      collect None acc rest
    | _ :: rest -> collect current_id acc rest
  in
  collect None [] (String.split_on_char '\n' body)

let has_numeric_sse_id body =
  String.split_on_char '\n' body
  |> List.exists (fun line ->
    let prefix = "id:" in
    if String.starts_with ~prefix line then
      let raw =
        String.sub line (String.length prefix) (String.length line - String.length prefix)
        |> String.trim
      in
      Option.is_some (int_of_string_opt raw)
    else false)

let is_masc_event = function
  | `Assoc fields ->
    List.assoc_opt "name" fields = Some (`String "MASC_EVENT")
    && List.assoc_opt "value" fields <> None
  | _ -> false

(* Guards that /ag-ui/events applies the MASC -> AG-UI encoder to a deterministic
   observer replay frame rather than forwarding a raw MASC SSE frame.  The
   source event is produced through the public MCP dispatch path before the
   reconnect, so this test does not depend on unrelated startup telemetry or
   timing.  The exact MASC_EVENT envelope check prevents an encoding-error
   response from becoming a substring false positive; the numeric [id:] check
   pins the resumability cursor carried by the transformed frame. *)
let test_ag_ui_frames_are_wire_encoded () =
  with_server @@ fun ~port ~auth_token ~base_path:_ ->
  let sid = initialize_mcp_session ~port ~auth_token in
  publish_masc_broadcast ~port ~auth_token ~session_id:sid;
  let headers =
    [
      ("Accept", "text/event-stream");
      ("Authorization", "Bearer " ^ auth_token);
      ("Mcp-Session-Id", sid);
      ("Last-Event-ID", "0");
    ]
  in
  let res = run_curl ~headers ~max_time:1.0 ~port ~path:"/ag-ui/events" () in
  check_status "/ag-ui/events connect accepted" 200 res;
  let events = sse_data_jsons res.body in
  if not (List.exists is_masc_event events) then
    fail
      (Printf.sprintf
         "/ag-ui/events frames are not AG-UI encoded (no exact MASC_EVENT envelope): %S"
         res.body);
  if not (has_numeric_sse_id res.body) then
    fail
      (Printf.sprintf "/ag-ui/events discarded every SSE cursor: %S" res.body);
  let first_masc_events =
    sse_id_data_jsons res.body
    |> List.filter (fun (_event_id, json) -> is_masc_event json)
  in
  let second_sid = initialize_mcp_session ~port ~auth_token in
  let second_headers =
    [ ("Accept", "text/event-stream")
    ; ("Authorization", "Bearer " ^ auth_token)
    ; ("Mcp-Session-Id", second_sid)
    ; ("Last-Event-ID", "0")
    ]
  in
  let second =
    run_curl ~headers:second_headers ~max_time:1.0 ~port ~path:"/ag-ui/events" ()
  in
  check_status "second /ag-ui/events replay accepted" 200 second;
  let second_by_id = sse_id_data_jsons second.body in
  List.iter
    (fun (event_id, expected_json) ->
       match List.assoc_opt event_id second_by_id with
       | Some actual_json ->
         if actual_json <> expected_json then
           fail
             (Printf.sprintf
                "AG-UI replay changed payload for SSE id %d\nfirst=%s\nsecond=%s"
                event_id
                (Yojson.Safe.to_string expected_json)
                (Yojson.Safe.to_string actual_json))
       | None ->
         fail
           (Printf.sprintf
              "second AG-UI replay omitted prior SSE id %d"
              event_id))
    first_masc_events

(* A credential the server accepts as a genuine non-admin caller. The loopback
   dashboard dev-token used to serve that role here, but #28354 issues it as
   [Masc_domain.Admin], so probing a CanAdmin gate with it stopped proving the
   gate exists. Mint the negative probe explicitly instead of borrowing a
   credential whose role is someone else's decision. *)
let create_worker_token base_path ~agent_name =
  match Auth.create_token base_path ~agent_name ~role:Masc_domain.Worker with
  | Ok (raw_token, _) -> raw_token
  | Error error ->
    fail ("create_token failed: " ^ Masc_domain.masc_error_to_string error)

let gate_mode_post ~port ~token =
  run_curl
    ~headers:
      [ ("Accept", "application/json")
      ; ("Authorization", "Bearer " ^ token)
      ; ("Content-Type", "application/json")
      ]
    ~method_:"POST"
    ~body:"{}"
    ~max_time:2.0
    ~port
    ~path:"/api/v1/dashboard/gate/mode"
    ()

let test_gate_mode_route_is_admin_gated () =
  with_server @@ fun ~port ~auth_token ~base_path ->
  let worker_token = create_worker_token base_path ~agent_name:"sse-storm-worker" in
  check_status
    "Worker token denied CanAdmin route"
    403
    (gate_mode_post ~port ~token:worker_token);
  (* The dashboard dev-token is Admin since #28354, so it clears authorization
     and the empty body is what the route rejects. Asserting "not 403" rather
     than a specific success code keeps this pinned to the authorization
     decision, which is the subject, and leaves the request schema free to
     change. *)
  match (gate_mode_post ~port ~token:auth_token).status with
  | Some 403 -> fail "dashboard dev-token was denied a CanAdmin route (#28354 issues it as Admin)"
  | Some _ -> ()
  | None -> fail "dashboard dev-token gate/mode request produced no HTTP status"

let check_operation_error label expected_code result =
  match Yojson.Safe.from_string result.body with
  | `Assoc fields ->
    (match List.assoc_opt "error" fields with
     | Some (`String code) -> check string label expected_code code
     | _ -> fail (label ^ ": missing typed operation error: " ^ result.body))
  | _ -> fail (label ^ ": non-object operation error: " ^ result.body)
  | exception Yojson.Json_error detail ->
    fail (label ^ ": invalid JSON operation error: " ^ detail)
;;

let test_dashboard_dev_token_can_use_keeper_operation_routes () =
  with_server @@ fun ~port ~auth_token ~base_path:_ ->
  let headers =
    [ "Accept", "application/json"
    ; "Authorization", "Bearer " ^ auth_token
    ; "Content-Type", "application/json"
    ]
  in
  let operation_path =
    "/api/v1/keepers/absent-keeper/chat/operations/kmsg-worker-auth"
  in
  let get_result =
    run_curl ~headers ~max_time:2.0 ~port ~path:operation_path ()
  in
  check_status "dashboard Worker operation lookup reaches handler" 404 get_result;
  check_operation_error
    "dashboard Worker operation lookup typed error"
    "unknown_operation"
    get_result;
  let cancel_result =
    run_curl
      ~headers
      ~method_:"POST"
      ~body:"{}"
      ~max_time:2.0
      ~port
      ~path:(operation_path ^ "/cancel")
      ()
  in
  check_status "dashboard Worker operation cancel reaches handler" 404 cancel_result;
  check_operation_error
    "dashboard Worker operation cancel typed error"
    "unknown_operation"
    cancel_result
;;

let test_official_client_recovery_uses_real_admin_route () =
  with_server @@ fun ~port ~auth_token ~base_path ->
  let keeper_name = "official-client-http-fixture" in
  let claim =
    Official_client_session_store.claim
      ~base_path
      ~keeper_name
      ~expected:None
      ~client_kind:Official_client_session_store.Codex
      ~owner_epoch:"11111111-1111-4111-8111-111111111111"
      ~runtime_id:"codex.codex"
      ~tool_surface_sha256:
        (Official_client_session_store.tool_surface_sha256
           ~native_posture:Runtime_native_tools.codex_default
           [])
      ~updated_at:1.0
    |> Result.get_ok
  in
  let recovery =
    Official_client_session_store.require_recovery
      ~base_path
      ~keeper_name
      ~expected:claim
      ~failure:Official_client_session_store.Protocol_failed
      ~detail:"real HTTP recovery fixture"
      ~required_at:2.0
    |> Result.get_ok
  in
  let recovery_id =
    match recovery.phase with
    | Official_client_session_store.Recovery_required required -> required.recovery_id
    | Official_client_session_store.Ready
    | Official_client_session_store.Start _
    | Official_client_session_store.Active _
    | Official_client_session_store.Turn_inflight _
    | Official_client_session_store.Settled _ ->
      fail "HTTP fixture did not enter recovery-required"
  in
  let session_path =
    "/api/v1/runtime/sessions/official-client?keeper_name=" ^ keeper_name
  in
  (* Probe with a minted Worker rather than the dashboard dev-token: #28354
     issues that token as Admin, so it now reads this route successfully and
     would turn the assertion into a claim about nothing. *)
  let worker_token =
    create_worker_token base_path ~agent_name:"sse-storm-recovery-worker"
  in
  let worker =
    run_curl
      ~headers:[ "Authorization", "Bearer " ^ worker_token ]
      ~max_time:2.0
      ~port
      ~path:session_path
      ()
  in
  check_status "Worker cannot read official-client recovery" 403 worker;
  let admin_headers =
    [ "Accept", "application/json"
    ; "Authorization", "Bearer " ^ main_eio_test_admin_token
    ; "Content-Type", "application/json"
    ]
  in
  let before =
    run_curl ~headers:admin_headers ~max_time:2.0 ~port ~path:session_path ()
  in
  check_status "Admin reads official-client recovery" 200 before;
  let open Yojson.Safe.Util in
  check string
    "real route recovery phase"
    "recovery_required"
    (Yojson.Safe.from_string before.body
     |> member "session"
     |> member "phase"
     |> member "kind"
     |> to_string);
  let body =
    `Assoc
      [ "keeper_name", `String keeper_name
      ; "recovery_id", `String recovery_id
      ; "resolution", `String "restart_fresh"
      ]
    |> Yojson.Safe.to_string
  in
  let resolved =
    run_curl
      ~headers:admin_headers
      ~method_:"POST"
      ~body
      ~max_time:2.0
      ~port
      ~path:"/api/v1/runtime/sessions/official-client/resolve"
      ()
  in
  check_status "Admin resolves official-client recovery" 200 resolved;
  let refreshed =
    run_curl ~headers:admin_headers ~max_time:2.0 ~port ~path:session_path ()
  in
  check_status "Admin refreshes official-client session" 200 refreshed;
  let refreshed_json = Yojson.Safe.from_string refreshed.body in
  check string
    "real route refreshed phase"
    "ready"
    (refreshed_json |> member "session" |> member "phase" |> member "kind"
     |> to_string);
  check string
    "real route persisted recovery fence"
    recovery_id
    (refreshed_json
     |> member "session"
     |> member "last_recovery_resolution"
     |> member "recovery_id"
     |> to_string)

let test_ag_ui_rejects_reconnect_then_recovers () =
  with_server @@ fun ~port ~auth_token ~base_path:_ ->
  let sid = initialize_mcp_session ~port ~auth_token in
  (* /ag-ui/events uses the observer SSE auth path; mirror /mcp by passing the
     dashboard dev token explicitly. *)
  let headers =
    [
      ("Accept", "text/event-stream");
      ("Authorization", "Bearer " ^ auth_token);
      ("Mcp-Session-Id", sid);
    ]
  in

  (* Stay well inside the 1s reconnect guard so the next request is truly immediate. *)
  let first = run_curl ~headers ~max_time:0.2 ~port ~path:"/ag-ui/events?workspace=default" () in
  check_status "first /ag-ui/events connect accepted" 200 first;
  (* Asserting the status alone let the bridge ship unconverted frames unnoticed.
     This checks the synthetic prime only — it does NOT cover the drain or replay
     conversion, which [test_ag_ui_frames_are_wire_encoded] below exercises. *)
  if not (body_contains "RUN_STARTED" first.body) then
    fail
      (Printf.sprintf "/ag-ui/events body is not AG-UI framed (no RUN_STARTED): %S"
         first.body);

  let second = run_curl ~headers ~max_time:0.5 ~port ~path:"/ag-ui/events?workspace=default" () in
  check_status "immediate /ag-ui/events reconnect rejected" 429 second;

  Unix.sleepf 2.0;
  let third = run_curl ~headers ~max_time:1.5 ~port ~path:"/ag-ui/events?workspace=default" () in
  check_status "cooldown /ag-ui/events reconnect recovers" 200 third

let check_invalid_request_response label result =
  check_status label 400 result;
  match Yojson.Safe.from_string result.body with
  | `Assoc fields ->
      (match List.assoc_opt "error" fields with
       | Some (`Assoc error_fields) ->
           (match List.assoc_opt "code" error_fields with
            | Some (`Int (-32600)) -> ()
            | _ ->
                fail
                  (Printf.sprintf
                     "%s returned wrong error code: %s" label result.body))
       | _ ->
           fail
             (Printf.sprintf "%s returned no JSON-RPC error: %s" label result.body))
  | exception Yojson.Json_error message ->
      fail
        (Printf.sprintf "%s returned invalid JSON: %s body=%s" label message
           result.body)
  | _ ->
      fail
        (Printf.sprintf "%s returned a non-object body: %s" label result.body)

let test_sse_endpoints_reject_malformed_last_event_id () =
  with_server @@ fun ~port ~auth_token ~base_path:_ ->
  let sid = initialize_mcp_session ~port ~auth_token in
  let headers cursor =
    [ ("Accept", "text/event-stream")
    ; ("Authorization", "Bearer " ^ auth_token)
    ; ("Mcp-Session-Id", sid)
    ; ("Last-Event-ID", cursor)
    ]
  in
  check_invalid_request_response "malformed /mcp cursor rejected"
    (run_curl ~headers:(headers "not-an-integer") ~max_time:2.0 ~port ~path:"/mcp" ());
  check_invalid_request_response "malformed /ag-ui/events cursor rejected"
    (run_curl ~headers:(headers "not-an-integer") ~max_time:2.0 ~port
       ~path:"/ag-ui/events" ());
  check_invalid_request_response "negative /mcp cursor rejected"
    (run_curl ~headers:(headers "-1") ~max_time:2.0 ~port ~path:"/mcp" ());
  check_invalid_request_response "negative /ag-ui/events cursor rejected"
    (run_curl ~headers:(headers "-1") ~max_time:2.0 ~port
       ~path:"/ag-ui/events" ())

let () =
  Random.self_init ();
  run "sse_storm_e2e"
    [
      ( "auth"
      , [ test_case
            "gate/mode is admin gated"
            `Slow
            test_gate_mode_route_is_admin_gated
        ; test_case
            "dev-token can use Keeper operation routes"
            `Slow
            test_dashboard_dev_token_can_use_keeper_operation_routes
        ; test_case
            "official-client recovery uses real CanAdmin route"
            `Slow
            test_official_client_recovery_uses_real_admin_route
        ] )
    ; ("mcp", [test_case "follow-up reconnect accepted" `Slow test_mcp_reconnect_stays_accepted])
     ; ( "ag_ui"
       , [ test_case
             "reconnect cooldown + recovery"
             `Slow
             test_ag_ui_rejects_reconnect_then_recovers
         ; test_case
             "malformed Last-Event-ID is rejected"
             `Slow
             test_sse_endpoints_reject_malformed_last_event_id
         ; test_case
             "frames are AG-UI wire encoded"
             `Slow
             test_ag_ui_frames_are_wire_encoded
         ] )
     ]
