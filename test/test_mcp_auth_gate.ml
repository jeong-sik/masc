(** Auth gate tests for {!Mcp_server_eio_protocol}.

    These tests exercise the typed authentication requirement that is applied
    to every JSON-RPC method before its handler runs.  They deliberately
    re-enable workspace authentication after
    {!Mcp_server_eio.For_testing.create_state} because that test-only
    constructor explicitly disables auth to keep handler tests lightweight.
*)

open Alcotest

module Mcp_eio = Masc.Mcp_server_eio
module Mcp_server = Masc.Mcp_server

let () = Mirage_crypto_rng_unix.use_default ()

let temp_dir () =
  let dir = Filename.temp_file "test_mcp_auth_gate_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  rm dir
;;

let request ~id ~method_ ?params () =
  let params_field =
    match params with
    | None -> []
    | Some p -> [ "params", p ]
  in
  Yojson.Safe.to_string
    (`Assoc
        ([ "jsonrpc", `String "2.0"
         ; "id", id
         ; "method", `String method_
         ]
         @ params_field))
;;

let error_code_exn response =
  match response with
  | `Assoc fields ->
    (match List.assoc_opt "error" fields with
     | Some (`Assoc error_fields) ->
       (match List.assoc_opt "code" error_fields with
        | Some (`Int value) -> value
        | _ -> fail "error code missing")
     | _ -> fail "error object missing")
  | _ -> fail "response not an object"
;;

let contains_substring text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  if needle_len = 0
  then true
  else if needle_len > text_len
  then false
  else (
    let rec loop i =
      if i + needle_len > text_len
      then false
      else if String.sub text i needle_len = needle
      then true
      else loop (i + 1)
    in
    loop 0)
;;

let error_message_exn response =
  match response with
  | `Assoc fields ->
    (match List.assoc_opt "error" fields with
     | Some (`Assoc error_fields) ->
       (match List.assoc_opt "message" error_fields with
        | Some (`String value) -> value
        | _ -> fail "error message missing")
     | _ -> fail "error object missing")
  | _ -> fail "response not an object"
;;

let has_result response =
  match response with
  | `Assoc fields -> Option.is_some (List.assoc_opt "result" fields)
  | _ -> false
;;

let setup_auth_workspace () =
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  ignore (Masc.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Masc.Auth.create_token base_path ~agent_name:"test-agent" ~role:Masc_domain.Worker with
    | Ok (token, _cred) -> token
    | Error e -> fail (Masc_domain.masc_error_to_string e)
  in
  base_path, state, raw_token
;;

let run_request ?auth_token state request_str =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  Mcp_eio.handle_request ?auth_token ~clock ~sw state request_str
;;

let test_initialize_is_public () =
  let base_path, state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let req =
         request
           ~id:(`Int 1)
           ~method_:"initialize"
           ~params:
             (`Assoc
                 [ ("protocolVersion", `String "2025-06-18")
                 ; ("capabilities", `Assoc [])
                 ; ( "clientInfo"
                   , `Assoc [ ("name", `String "test"); ("version", `String "1.0") ] )
                 ])
           ()
       in
       let response = run_request state req in
       check bool "initialize succeeds without token" true (has_result response))
;;

let test_server_discover_is_public () =
  let base_path, state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let req =
         request
           ~id:(`String "discover-1")
           ~method_:"server/discover"
           ~params:(`Assoc [ "_meta", `Assoc [] ])
           ()
       in
       let response = run_request state req in
       check bool "server/discover succeeds without token" true (has_result response))
;;

let test_tools_list_requires_auth_missing_token () =
  let base_path, state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let req = request ~id:(`Int 2) ~method_:"tools/list" ~params:(`Assoc []) () in
       let response = run_request state req in
       check int "auth error code" (-32001) (error_code_exn response);
       check bool "missing token message"
         true
         (contains_substring (error_message_exn response) "bearer token required"))
;;

let test_tools_list_requires_auth_invalid_token () =
  let base_path, state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let req = request ~id:(`Int 3) ~method_:"tools/list" ~params:(`Assoc []) () in
       let response = run_request state ~auth_token:"not-a-valid-token" req in
       check int "auth error code" (-32001) (error_code_exn response);
       check bool "invalid token message"
         true
         (contains_substring (error_message_exn response) "invalid bearer token"))
;;

let test_tools_list_succeeds_with_valid_token () =
  let base_path, state, token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let req = request ~id:(`Int 4) ~method_:"tools/list" ~params:(`Assoc []) () in
       let response = run_request state ~auth_token:token req in
       check bool "tools/list succeeds with token" true (has_result response))
;;

let test_resources_list_requires_auth () =
  let base_path, state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let req = request ~id:(`Int 5) ~method_:"resources/list" ~params:(`Assoc []) () in
       let response = run_request state req in
       check int "auth error code" (-32001) (error_code_exn response))
;;

let test_prompts_list_requires_auth () =
  let base_path, state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let req = request ~id:(`Int 6) ~method_:"prompts/list" ~params:(`Assoc []) () in
       let response = run_request state req in
       check int "auth error code" (-32001) (error_code_exn response))
;;

let test_tools_call_requires_auth () =
  let base_path, state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let req =
         request
           ~id:(`Int 7)
           ~method_:"tools/call"
           ~params:(`Assoc [ "name", `String "masc_status"; "arguments", `Assoc [] ])
           ()
       in
       let response = run_request state req in
       check int "auth error code" (-32001) (error_code_exn response))
;;

let () =
  run
    "MCP protocol auth gate"
    [ ( "public handlers"
      , [ test_case "initialize without token" `Quick test_initialize_is_public
        ; test_case "server/discover without token" `Quick test_server_discover_is_public
        ] )
    ; ( "authenticated handlers reject unauthenticated calls"
      , [ test_case "tools/list missing token" `Quick test_tools_list_requires_auth_missing_token
        ; test_case "tools/list invalid token" `Quick test_tools_list_requires_auth_invalid_token
        ; test_case "resources/list missing token" `Quick test_resources_list_requires_auth
        ; test_case "prompts/list missing token" `Quick test_prompts_list_requires_auth
        ; test_case "tools/call missing token" `Quick test_tools_call_requires_auth
        ] )
    ; ( "authenticated handlers accept valid credentials"
      , [ test_case "tools/list with valid token" `Quick test_tools_list_succeeds_with_valid_token
        ] )
    ]
;;
