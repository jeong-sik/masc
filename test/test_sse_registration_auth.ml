(** Regression tests for observer-stream bearer-token admission. *)

open Alcotest

module Sse = Masc.Sse
let setup () =
  let workspace = Masc_test_deps.setup_test_workspace () in
  let auth = Masc_test_deps.make_sse_auth workspace "sse-reg-test-agent" in
  (workspace, auth)

let cleanup workspace = Masc_test_deps.cleanup_test_workspace workspace

let test_valid_token_registers () =
  let workspace, auth = setup () in
  Fun.protect ~finally:(fun () -> cleanup workspace) (fun () ->
    let session_id = "valid-reg-session" in
    match Sse.register ~auth session_id ~last_event_id:0 with
    | Ok (client_id, _stream, _evicted) ->
        check bool "registered" true (Sse.exists session_id);
        check bool "positive client id" true (client_id > 0);
        Sse.unregister session_id
    | Error e ->
        fail
          (Printf.sprintf "valid registration should succeed: %s"
             (Sse.registration_error_to_string e)))

let test_missing_token_rejected () =
  let workspace, _auth = setup () in
  Fun.protect ~finally:(fun () -> cleanup workspace) (fun () ->
    let bad_auth = { Sse.config = workspace; token = None } in
    match Sse.register ~auth:bad_auth "missing-token-session" ~last_event_id:0 with
    | Ok _ -> fail "registration with missing token should fail"
    | Error Sse.Missing_token -> ()
    | Error e ->
        fail
          (Printf.sprintf "expected Missing_token, got: %s"
             (Sse.registration_error_to_string e)))

let test_forged_token_rejected () =
  let workspace, _auth = setup () in
  Fun.protect ~finally:(fun () -> cleanup workspace) (fun () ->
    let bad_auth = { Sse.config = workspace; token = Some "not-a-real-token" } in
    match Sse.register ~auth:bad_auth "forged-token-session" ~last_event_id:0 with
    | Ok _ -> fail "registration with forged token should fail"
    | Error (Sse.Invalid_token _) -> ()
    | Error e ->
        fail
          (Printf.sprintf "expected Invalid_token, got: %s"
             (Sse.registration_error_to_string e)))

let test_client_selected_stream_id_registers () =
  let workspace, auth = setup () in
  Fun.protect ~finally:(fun () -> cleanup workspace) (fun () ->
    let session_id = "fresh-observer-stream" in
    match Sse.register ~auth session_id ~last_event_id:0 with
    | Ok _ -> Sse.unregister session_id
    | Error e ->
        fail
          (Printf.sprintf "client-selected observer stream id was rejected: %s"
             (Sse.registration_error_to_string e)))

let () =
  Mirage_crypto_rng_unix.use_default ();
  run "sse_registration_auth"
    [
      ( "register",
        [
          test_case "valid token registers" `Quick test_valid_token_registers;
          test_case "missing token rejected" `Quick test_missing_token_rejected;
          test_case "forged token rejected" `Quick test_forged_token_rejected;
          test_case "client-selected stream id registers" `Quick
            test_client_selected_stream_id_registers;
        ] );
    ]
