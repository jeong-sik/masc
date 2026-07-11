open Alcotest

type http_result = {
  status : int option;
  body : string;
  curl_exit : int;
  stderr : string;
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

let parse_status header_raw =
  let lines = String.split_on_char '\n' header_raw |> List.map trim_cr in
  let rec find_http = function
    | [] -> None
    | line :: rest ->
        if String.length line >= 5 && String.sub line 0 5 = "HTTP/" then
          (match String.split_on_char ' ' line with
           | _proto :: code :: _ ->
               (try Some (int_of_string code) with _ -> None)
           | _ -> None)
        else
          find_http rest
  in
  find_http lines

let run_curl ?(headers = []) ~port ~path () =
  let header_file = Filename.temp_file "openapi-api-header-" ".txt" in
  let body_file = Filename.temp_file "openapi-api-body-" ".txt" in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let header_args =
    List.fold_right (fun header acc -> "-H" :: header :: acc) headers []
  in
  let args =
    Array.of_list
      ([
      "curl";
      "-sS";
      "--http1.1";
      "--max-time";
      "5";
      "-X";
      "GET";
      "-o";
      body_file;
      "-D";
      header_file;
      ]
      @ header_args
      @ [ url ])
  in
  let (ic, oc, ec) =
    Unix.open_process_args_full "curl" args (Unix.environment ())
  in
  close_out_noerr oc;
  let _stdout = read_all ic in
  let stderr = read_all ec in
  let curl_exit =
    match Unix.close_process_full (ic, oc, ec) with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED code -> 128 + code
    | Unix.WSTOPPED code -> 256 + code
  in
  let status = parse_status (read_file header_file) in
  let body = read_file body_file in
  (try Sys.remove header_file with _ -> ());
  (try Sys.remove body_file with _ -> ());
  { status; body; curl_exit; stderr }

let find_main_eio_exe () =
  let env_override = Sys.getenv_opt "MASC_MAIN_EIO_EXE" in
  let candidates =
    match env_override with
    | Some p -> [ p ]
    | None ->
        let build_roots = [ "."; ".."; "../.."; "../../.."; "../../../.." ] in
        let build_candidates =
          List.map
            (fun root -> Filename.concat root "_build/default/bin/main_eio.exe")
            build_roots
        in
        [
          "./bin/main_eio.exe";
          "../bin/main_eio.exe";
          "../../bin/main_eio.exe";
          "../../../bin/main_eio.exe";
          "../../../../bin/main_eio.exe";
        ]
        @ build_candidates
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None ->
      fail
        "main_eio executable not found. Set MASC_MAIN_EIO_EXE or build with `dune build bin/main_eio.exe`."

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.setsockopt socket Unix.SO_REUSEADDR true;
      match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
      | () -> (
          match Unix.getsockname socket with
          | Unix.ADDR_INET (_, port) -> Some port
          | _ -> fail "unexpected socket address")
      | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) ->
          None)

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
      let res = run_curl ~port ~path:"/health" () in
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
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
        if Unix.gettimeofday () > deadline then
          false
        else (
          Unix.sleepf 0.05;
          loop ())
    | _pid, _status -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  loop ()

let merge_env_overrides overrides =
  let override_keys = List.map fst overrides in
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
  let injected = List.map (fun (k, v) -> k ^ "=" ^ v) overrides in
  Array.of_list (base @ injected)

let with_server f =
  let exe = find_main_eio_exe () in
  let port =
    match find_free_port () with
    | Some port -> port
    | None -> Alcotest.skip ()
  in
  let log_file = Filename.temp_file "openapi-api-e2e-" ".log" in
  let base_path = Filename.temp_file "openapi-api-base-" "" in
  (try Sys.remove base_path with _ -> ());
  Unix.mkdir base_path 0o755;
  let log_fd =
    Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
  in
  let env =
    merge_env_overrides
      [
        ("MASC_AUTONOMY_ENABLED", "0");
        ("GRAPHQL_API_KEY", "");
        ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
        ("MASC_BOARD_BACKEND", "jsonl");
      ]
  in
  let argv =
    [| exe; "--port"; string_of_int port; "--base-path"; base_path |]
  in
  let pid = Unix.create_process_env exe argv env Unix.stdin log_fd log_fd in
  Unix.close log_fd;
  let cleanup () =
    (try Unix.kill pid Sys.sigterm with _ -> ());
    if not (wait_pid_exit ~pid ~timeout_s:2.0) then
      (try Unix.kill pid Sys.sigkill with _ -> ());
    ignore (wait_pid_exit ~pid ~timeout_s:1.0)
  in
  if not (wait_for_health ~port ~timeout_s:20.0) then (
    cleanup ();
    let logs = read_file log_file in
    fail (Printf.sprintf "server failed to become ready on port %d\n%s" port logs)
  );
  Fun.protect ~finally:cleanup (fun () -> f ~port ~base_path)

let test_openapi_route_serves_document () =
  with_server @@ fun ~port ~base_path:_ ->
  (* Retry up to 5 times: /health returns 200 before server_state is set,
     so the openapi route may initially return {"error":"not initialized"} *)
  let rec fetch_openapi retries =
    let res = run_curl ~port ~path:"/api/v1/openapi.json" () in
    (match res.status with
    | Some code -> check int "openapi route returns 200" 200 code
    | None ->
        fail
          (Printf.sprintf "missing HTTP status (curl_exit=%d, stderr=%s)"
             res.curl_exit res.stderr));
    let json = Yojson.Safe.from_string res.body in
    let open Yojson.Safe.Util in
    match json |> member "openapi" |> to_string_option with
    | Some _ -> json
    | None when retries > 0 ->
        Unix.sleepf 0.5;
        fetch_openapi (retries - 1)
    | None ->
        fail
          (Printf.sprintf "openapi field missing after retries\nbody=%s" res.body)
  in
  let json = fetch_openapi 5 in
  let open Yojson.Safe.Util in
  check string "openapi version" "3.1.0" (json |> member "openapi" |> to_string);
  check bool "/mcp path present" true
    (json |> member "paths" |> member "/mcp" <> `Null);
  let operations =
    json |> member "paths" |> member "/mcp" |> member "post"
    |> member "x-mcp-operations" |> to_list
  in
  check bool "masc_status exported" true
    (List.exists
       (fun row -> row |> member "operationId" |> to_string = "masc_status")
       operations)

let test_invalid_authority_is_rejected_before_authority_routes () =
  with_server @@ fun ~port ~base_path ->
  let dev_token_path =
    Server_routes_http_dashboard_dev_token.dashboard_dev_token_path base_path
  in
  check bool "dev token absent before invalid requests" false
    (Sys.file_exists dev_token_path);
  let routes =
    [ "/"
    ; "/dashboard"
    ; "/dashboard/keepers"
    ; "/api/v1/openapi.json"
    ; "/.well-known/agent.json"
    ; "/.well-known/agent-card.json"
    ; "/ws"
    ; "/health"
    ; "/api/v1/dashboard/dev-token"
    ]
  in
  let invalid_authorities =
    [ ( "missing"
      , [ "Host:" ]
      , "request_authority_missing" )
    ; ( "multiple"
      , [ "Host: localhost:8935"; "hOsT: attacker.example" ]
      , "request_authority_multiple" )
    ; ( "malformed"
      , [ "Host: user@localhost" ]
      , "request_authority_malformed" )
    ]
  in
  List.iter
    (fun (case, headers, expected_code) ->
      List.iter
        (fun path ->
          let result = run_curl ~headers ~port ~path () in
          let label = case ^ " " ^ path in
          check (option int) (label ^ " status") (Some 400) result.status;
          let json = Yojson.Safe.from_string result.body in
          check
            string
            (label ^ " error code")
            expected_code
            Yojson.Safe.Util.(json |> member "error_code" |> to_string))
        routes)
    invalid_authorities;
  check bool "invalid authority performs no dev-token I/O" false
    (Sys.file_exists dev_token_path)

let () =
  run "openapi_api_e2e"
    [
      ( "openapi",
        [
          test_case "route serves document" `Slow
            test_openapi_route_serves_document;
          test_case
            "invalid authority rejected before authority routes"
            `Slow
            test_invalid_authority_is_rejected_before_authority_routes;
        ] );
    ]
