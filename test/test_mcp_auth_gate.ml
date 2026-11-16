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
  ignore (Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Auth.create_token base_path ~agent_name:"test-agent" ~role:Masc_domain.Worker with
    | Ok (token, _cred) -> token
    | Error e -> fail (Masc_domain.masc_error_to_string e)
  in
  base_path, state, raw_token
;;

(* The dispatcher's answer to [request_str] from the sender [sender ()]
   makes. [sender] runs inside the Eio run, since a door reads the auth
   store. *)
let run_request ~sender ?auth_token state request_str =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  Mcp_eio.handle_request ~sender:(sender ()) ?auth_token ~clock ~sw state request_str
;;

(* A request no door admitted: a WebSocket message, or this test calling the
   dispatcher directly without a bearer. *)
let unadmitted () = Mcp_eio.Unadmitted

(* What the /mcp door admits for [token] on [base_path]'s workspace. *)
let admit ?internal_keeper_agent base_path token =
  Auth.admit_request base_path ~auth_cfg:(Auth.load_auth_config base_path) ~token
    ~internal_keeper_agent
;;

let admitted ?internal_keeper_agent base_path token () =
  match admit ?internal_keeper_agent base_path token with
  | Ok principal -> Mcp_eio.Admitted principal
  | Error (Auth.Token_required | Auth.Bearer_refused _) ->
    fail "the door refused a request the case expects it to admit"
;;

let tools_list_request id = request ~id ~method_:"tools/list" ~params:(`Assoc []) ()

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
       let response = run_request ~sender:unadmitted state req in
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
           ~params:
             (`Assoc
                [ "_meta", `Assoc
                    [ Mcp_transport_protocol.protocol_version_meta_key, `String "2026-07-28"
                    ; Mcp_transport_protocol.client_capabilities_meta_key, `Assoc [] ] ])
           ()
       in
       let response = run_request ~sender:unadmitted state req in
       check bool "server/discover succeeds without token" true (has_result response))
;;

let test_tools_list_requires_auth_missing_token () =
  let base_path, state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let req = request ~id:(`Int 2) ~method_:"tools/list" ~params:(`Assoc []) () in
       let response = run_request ~sender:unadmitted state req in
       check int "auth error code" (-32001) (error_code_exn response);
       check bool "missing token message"
         true
         (String_util.contains_substring (error_message_exn response) "bearer token required"))
;;

(* An invalid bearer never reaches the dispatcher: the door refuses it
   (RFC a-request-reads-its-bearer-once-at-the-door, D3). *)
let test_the_door_refuses_an_invalid_token () =
  let base_path, _state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       match admit base_path (Some "not-a-valid-token") with
       | Error
           (Auth.Bearer_refused
              (Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken _))) -> ()
       | Error (Auth.Bearer_refused err) ->
         failf "the door refused for another reason: %s"
           (Masc_domain.masc_error_to_string err)
       | Error Auth.Token_required -> fail "the door asked for a token it was given"
       | Ok _ -> fail "the door admitted an invalid token")
;;

let test_tools_list_succeeds_with_valid_token () =
  let base_path, state, token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let response =
         run_request ~sender:(admitted base_path (Some token)) ~auth_token:token state
           (tools_list_request (`Int 4))
       in
       check bool "tools/list succeeds with token" true (has_result response))
;;

(* Where no token is required, the door admits a request without one, and
   the dispatcher still keeps the methods that require auth from it. *)
let test_anonymous_reaches_only_public_methods () =
  let base_path, state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (Auth.enable_auth base_path ~require_token:false ~agent_name:"bootstrap-admin");
       let response =
         run_request ~sender:(admitted base_path None) state (tools_list_request (`Int 8))
       in
       check int "auth error code" (-32001) (error_code_exn response);
       check bool "missing token message"
         true
         (String_util.contains_substring (error_message_exn response) "bearer token required"))
;;

let test_auth_off_passes_every_method () =
  let base_path, state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       Auth.disable_auth base_path;
       let response =
         run_request ~sender:(admitted base_path None) state (tools_list_request (`Int 9))
       in
       check bool "tools/list succeeds with auth off" true (has_result response))
;;

(* The store holds no credential for the internal Keeper token, so a method
   that requires auth answers "invalid bearer token" for it, as it did
   before the door named the bearer. *)
let test_internal_keeper_bearer_keeps_the_store_answer () =
  let base_path, state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let internal = Auth.ensure_internal_keeper_token base_path in
       let response =
         run_request
           ~sender:(admitted ~internal_keeper_agent:"keeper-a" base_path (Some internal))
           ~auth_token:internal state (tools_list_request (`Int 10))
       in
       check int "auth error code" (-32001) (error_code_exn response);
       check bool "invalid token message"
         true
         (String_util.contains_substring (error_message_exn response) "invalid bearer token"))
;;

let test_resources_list_requires_auth () =
  let base_path, state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let req = request ~id:(`Int 5) ~method_:"resources/list" ~params:(`Assoc []) () in
       let response = run_request ~sender:unadmitted state req in
       check int "auth error code" (-32001) (error_code_exn response))
;;

let test_prompts_list_requires_auth () =
  let base_path, state, _token = setup_auth_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let req = request ~id:(`Int 6) ~method_:"prompts/list" ~params:(`Assoc []) () in
       let response = run_request ~sender:unadmitted state req in
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
       let response = run_request ~sender:unadmitted state req in
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
        ; test_case "the door refuses an invalid token" `Quick
            test_the_door_refuses_an_invalid_token
        ; test_case "anonymous reaches only public methods" `Quick
            test_anonymous_reaches_only_public_methods
        ; test_case "the internal Keeper bearer keeps the store answer" `Quick
            test_internal_keeper_bearer_keeps_the_store_answer
        ; test_case "resources/list missing token" `Quick test_resources_list_requires_auth
        ; test_case "prompts/list missing token" `Quick test_prompts_list_requires_auth
        ; test_case "tools/call missing token" `Quick test_tools_call_requires_auth
        ] )
    ; ( "authenticated handlers accept valid credentials"
      , [ test_case "tools/list with valid token" `Quick test_tools_list_succeeds_with_valid_token
        ; test_case "auth off passes every method" `Quick test_auth_off_passes_every_method
        ] )
    ]
;;
