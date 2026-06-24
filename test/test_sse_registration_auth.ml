(** Regression tests for SSE registration token + session validation.
    PR-MASC-3: Sse.register now requires a valid (token, session) pair and
    returns a typed [registration_error] on failure.

    Security fix: validate_registration uses Session.McpSessionStore.peek
    instead of get_or_create, so a client-provided session_id cannot
    auto-bootstrap a new session. Unknown session_ids now return
    Unknown_session; session creation remains in the initialize handler
    (RFC-0099 session lifecycle; credential/auth context RFC-0008 / RFC-0019). *)

open Alcotest

module Sse = Masc.Sse
module Session = Masc.Session

let setup () =
  let workspace = Masc_test_deps.setup_test_workspace () in
  let auth = Masc_test_deps.make_sse_auth workspace "sse-reg-test-agent" in
  (workspace, auth)

let cleanup workspace = Masc_test_deps.cleanup_test_workspace workspace

let test_valid_token_registers () =
  let workspace, auth = setup () in
  Fun.protect ~finally:(fun () -> cleanup workspace) (fun () ->
    let session_id = "valid-reg-session" in
    let (_ : Session.McpSessionStore.mcp_session) =
      Session.McpSessionStore.get_or_create ~id:session_id
        ~agent_name:"sse-reg-test-agent" ()
    in
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
    let bad_auth = { Sse.config = workspace; token = "" } in
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
    let bad_auth = { Sse.config = workspace; token = "not-a-real-token" } in
    match Sse.register ~auth:bad_auth "forged-token-session" ~last_event_id:0 with
    | Ok _ -> fail "registration with forged token should fail"
    | Error (Sse.Invalid_token _) -> ()
    | Error e ->
        fail
          (Printf.sprintf "expected Invalid_token, got: %s"
             (Sse.registration_error_to_string e)))

let test_unknown_session_rejected () =
  let workspace, auth = setup () in
  Fun.protect ~finally:(fun () -> cleanup workspace) (fun () ->
    (* No session created; the client-provided id must not auto-create. *)
    let session_id = "unknown-session" in
    match Sse.register ~auth session_id ~last_event_id:0 with
    | Ok _ -> fail "registration with unknown session should fail"
    | Error (Sse.Unknown_session { session_id = sid }) ->
        check string "unknown session id" session_id sid
    | Error e ->
        fail
          (Printf.sprintf "expected Unknown_session, got: %s"
             (Sse.registration_error_to_string e)))

let test_expired_session_rejected () =
  let workspace, auth = setup () in
  Fun.protect ~finally:(fun () -> cleanup workspace) (fun () ->
    let session_id = "expired-session" in
    (* Create the session bound to the token owner.  The test dune stanza
       sets [MASC_SESSION_MAX_AGE_SEC] to a small value so the session
       expires after a short sleep. *)
    let (_ : Session.McpSessionStore.mcp_session) =
      Session.McpSessionStore.get_or_create ~id:session_id
        ~agent_name:"sse-reg-test-agent" ()
    in
    Unix.sleepf 0.6;
    match Sse.register ~auth session_id ~last_event_id:0 with
    | Ok _ -> fail "registration with expired session should fail"
    | Error (Sse.Session_expired { session_id = sid }) ->
        check string "expired session id" session_id sid
    | Error e ->
        fail
          (Printf.sprintf "expected Session_expired, got: %s"
             (Sse.registration_error_to_string e)))

let test_session_owner_mismatch_rejected () =
  let workspace, _auth = setup () in
  Fun.protect ~finally:(fun () -> cleanup workspace) (fun () ->
    (* Session belongs to agent-a; token belongs to agent-b. *)
    let session_id = "owner-mismatch-session" in
    let (_ : Session.McpSessionStore.mcp_session) =
      Session.McpSessionStore.get_or_create ~id:session_id ~agent_name:"agent-a"
        ()
    in
    let auth = Masc_test_deps.make_sse_auth workspace "agent-b" in
    match Sse.register ~auth session_id ~last_event_id:0 with
    | Ok _ -> fail "registration with session owner mismatch should fail"
    | Error (Sse.Session_owner_mismatch { session_agent; token_agent }) ->
        check string "session agent" "agent-a" session_agent;
        check string "token agent" "agent-b" token_agent
    | Error e ->
        fail
          (Printf.sprintf "expected Session_owner_mismatch, got: %s"
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
          test_case "unknown session rejected" `Quick test_unknown_session_rejected;
          test_case "expired session rejected" `Quick test_expired_session_rejected;
          test_case "session owner mismatch rejected" `Quick
            test_session_owner_mismatch_rejected;
        ] );
    ]
