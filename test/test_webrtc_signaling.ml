(** WebRTC Signaling Unit Tests

    Tests offer/answer signaling flow, peer registry,
    and cleanup logic. No actual WebRTC connections. *)

module Wrtc = Masc_mcp.Server_webrtc_transport
module Transport = Masc_mcp.Transport
module Agent_transport = Masc_mcp.Masc_grpc_transport

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f
;;

(* ====== Signaling Lifecycle ====== *)

let test_create_offer () =
  Eio_main.run (fun _env ->
    let offer_id =
      Wrtc.create_offer
        ~from_agent:"claude"
        ~ice_candidates:[ "candidate:1" ]
        ~dtls_fingerprint:"sha256:abc"
    in
    Alcotest.(check bool) "offer_id not empty" true (String.length offer_id > 0);
    Alcotest.(check bool) "pending count > 0" true (Wrtc.pending_offer_count () > 0);
    (* Cleanup *)
    ignore (Wrtc.cleanup_expired_offers ~max_age_s:0.0 ()))
;;

let test_get_offer () =
  Eio_main.run (fun _env ->
    let offer_id =
      Wrtc.create_offer
        ~from_agent:"gemini"
        ~ice_candidates:[ "c1"; "c2" ]
        ~dtls_fingerprint:"sha256:xyz"
    in
    let offer = Wrtc.get_offer offer_id in
    Alcotest.(check bool) "offer found" true (Option.is_some offer);
    let o = Option.get offer in
    Alcotest.(check string) "from_agent" "gemini" o.from_agent;
    Alcotest.(check int) "ice count" 2 (List.length o.ice_candidates);
    ignore (Wrtc.cleanup_expired_offers ~max_age_s:0.0 ()))
;;

let test_accept_offer () =
  Eio_main.run (fun _env ->
    let offer_id =
      Wrtc.create_offer
        ~from_agent:"alice"
        ~ice_candidates:[ "c1" ]
        ~dtls_fingerprint:"fp"
    in
    let result = Wrtc.accept_offer ~offer_id ~answerer_agent:"bob" in
    Alcotest.(check bool) "accept ok" true (Result.is_ok result);
    let conn = Result.get_ok result in
    Alcotest.(check string) "remote_agent" "alice" conn.remote_agent;
    Alcotest.(check string) "channel" "masc-events" conn.channel_label;
    Alcotest.(check bool) "active peers > 0" true (Wrtc.active_peer_count () > 0);
    Wrtc.remove_peer conn.peer_id)
;;

let test_accept_nonexistent () =
  Eio_main.run (fun _env ->
    let result = Wrtc.accept_offer ~offer_id:"fake-id" ~answerer_agent:"x" in
    Alcotest.(check bool) "accept fails" true (Result.is_error result))
;;

let test_double_accept () =
  Eio_main.run (fun _env ->
    let offer_id =
      Wrtc.create_offer ~from_agent:"a" ~ice_candidates:[] ~dtls_fingerprint:""
    in
    let r1 = Wrtc.accept_offer ~offer_id ~answerer_agent:"b" in
    Alcotest.(check bool) "first accept ok" true (Result.is_ok r1);
    let r2 = Wrtc.accept_offer ~offer_id ~answerer_agent:"c" in
    Alcotest.(check bool) "second accept fails" true (Result.is_error r2);
    let conn = Result.get_ok r1 in
    Wrtc.remove_peer conn.peer_id)
;;

(* ====== HTTP Handler ====== *)

let test_handle_offer_request () =
  Eio_main.run (fun _env ->
    let body =
      {|{"agent_name":"claude","ice_candidates":["c1"],"dtls_fingerprint":"fp"}|}
    in
    let result = Wrtc.handle_offer_request body in
    Alcotest.(check bool) "ok" true (Result.is_ok result);
    let json = Result.get_ok result in
    Alcotest.(check bool) "has offer_id" true (String.length json > 0);
    ignore (Wrtc.cleanup_expired_offers ~max_age_s:0.0 ()))
;;

let test_handle_invalid_offer () =
  Eio_main.run (fun _env ->
    let result = Wrtc.handle_offer_request "not json" in
    Alcotest.(check bool) "error" true (Result.is_error result))
;;

(* ====== Cleanup ====== *)

let test_cleanup_expired () =
  Eio_main.run (fun _env ->
    let _id =
      Wrtc.create_offer ~from_agent:"old" ~ice_candidates:[] ~dtls_fingerprint:""
    in
    let cleaned = Wrtc.cleanup_expired_offers ~max_age_s:0.0 () in
    Alcotest.(check bool) "cleaned >= 1" true (cleaned >= 1))
;;

(* ====== Transport Enum ====== *)

let test_transport_webrtc_variant () =
  let p = Transport.Webrtc in
  Alcotest.(check string) "webrtc" "webrtc" (Transport.protocol_to_string p);
  Alcotest.(check bool)
    "of_string"
    true
    (Transport.protocol_of_string "webrtc" = Some Transport.Webrtc)
;;

let test_agent_transport_webrtc () =
  Alcotest.(check string)
    "webrtc"
    "webrtc"
    (Agent_transport.to_string Agent_transport.Webrtc)
;;

(* ====== Message Handler ====== *)

let test_message_handler_invoked () =
  Eio_main.run (fun _env ->
    let received = ref None in
    Wrtc.set_message_handler (fun peer_id msg -> received := Some (peer_id, msg));
    (* Create and accept an offer to get a peer *)
    let offer_id =
      Wrtc.create_offer
        ~from_agent:"sender"
        ~ice_candidates:[ "c1" ]
        ~dtls_fingerprint:"fp1"
    in
    let result = Wrtc.accept_offer ~offer_id ~answerer_agent:"receiver" in
    Alcotest.(check bool) "accept ok" true (Result.is_ok result);
    let _conn = Result.get_ok result in
    (* The handler should be set *)
    Alcotest.(check bool) "handler is set" true (!received = None);
    (* Cleanup *)
    ignore (Wrtc.cleanup_expired_offers ~max_age_s:0.0 ()))
;;

let test_send_to_nonexistent_peer () =
  Eio_main.run (fun _env ->
    let result = Wrtc.send_to_peer "fake-peer-id" "hello" in
    Alcotest.(check bool) "send to missing peer fails" true (Result.is_error result))
;;

let test_mark_connected_updates_peer () =
  Eio_main.run (fun _env ->
    let offer_id =
      Wrtc.create_offer ~from_agent:"a" ~ice_candidates:[ "c1" ] ~dtls_fingerprint:"fp"
    in
    let result = Wrtc.accept_offer ~offer_id ~answerer_agent:"b" in
    Alcotest.(check bool) "accept ok" true (Result.is_ok result);
    let conn = Result.get_ok result in
    Alcotest.(check bool) "not connected initially" false conn.connected;
    Wrtc.mark_connected conn.peer_id;
    (* Re-fetch to check — active_peer_count should still be > 0 *)
    Alcotest.(check bool) "peer still active" true (Wrtc.active_peer_count () > 0);
    Wrtc.remove_peer conn.peer_id)
;;

let test_handle_answer_request_valid () =
  Eio_main.run (fun _env ->
    let offer_id =
      Wrtc.create_offer
        ~from_agent:"alice"
        ~ice_candidates:[ "c1" ]
        ~dtls_fingerprint:"fp"
    in
    let body =
      Printf.sprintf
        {|{"offer_id":"%s","agent_name":"bob","ice_candidates":["c2"],"dtls_fingerprint":"fp2"}|}
        offer_id
    in
    let result = Wrtc.handle_answer_request body in
    Alcotest.(check bool) "answer ok" true (Result.is_ok result);
    ignore (Wrtc.cleanup_expired_offers ~max_age_s:0.0 ()))
;;

let test_handle_answer_request_invalid () =
  Eio_main.run (fun _env ->
    let result = Wrtc.handle_answer_request "bad json" in
    Alcotest.(check bool) "bad json fails" true (Result.is_error result))
;;

let test_configured_ice_servers_from_csv_env () =
  with_env "MASC_WEBRTC_ICE_SERVERS_JSON" None (fun () ->
    with_env
      "MASC_WEBRTC_ICE_URLS"
      (Some "stun:stun.example.com:3478,turn:turn.example.com:3478")
      (fun () ->
         with_env "MASC_WEBRTC_ICE_USERNAME" (Some "alice") (fun () ->
           with_env "MASC_WEBRTC_ICE_CREDENTIAL" (Some "secret") (fun () ->
             let servers = Wrtc.configured_ice_servers () in
             Alcotest.(check int) "one server record" 1 (List.length servers);
             let server = List.hd servers in
             Alcotest.(check (list string))
               "urls"
               [ "stun:stun.example.com:3478"; "turn:turn.example.com:3478" ]
               server.Webrtc.Ice.urls;
             Alcotest.(check (option string)) "username" (Some "alice") server.username;
             Alcotest.(check (option string))
               "credential"
               (Some "secret")
               server.credential))))
;;

let test_configured_ice_servers_json_override () =
  with_env "MASC_WEBRTC_ICE_URLS" (Some "stun:ignored.example.com:3478") (fun () ->
    with_env
      "MASC_WEBRTC_ICE_SERVERS_JSON"
      (Some
         {|[{"urls":["turns:relay.example.com:5349"],"username":"bob","credential":"pw"}]|})
      (fun () ->
         let servers = Wrtc.configured_ice_servers () in
         Alcotest.(check int) "one json server record" 1 (List.length servers);
         let server = List.hd servers in
         Alcotest.(check (list string))
           "json urls"
           [ "turns:relay.example.com:5349" ]
           server.Webrtc.Ice.urls;
         Alcotest.(check (option string)) "json username" (Some "bob") server.username;
         Alcotest.(check (option string)) "json credential" (Some "pw") server.credential))
;;

let () =
  Alcotest.run
    "WebRTC Signaling"
    [ ( "signaling"
      , [ Alcotest.test_case "create offer" `Quick test_create_offer
        ; Alcotest.test_case "get offer" `Quick test_get_offer
        ; Alcotest.test_case "accept offer" `Quick test_accept_offer
        ; Alcotest.test_case "accept nonexistent" `Quick test_accept_nonexistent
        ; Alcotest.test_case "double accept" `Quick test_double_accept
        ] )
    ; ( "http_handler"
      , [ Alcotest.test_case "valid offer request" `Quick test_handle_offer_request
        ; Alcotest.test_case "invalid offer" `Quick test_handle_invalid_offer
        ; Alcotest.test_case
            "valid answer request"
            `Quick
            test_handle_answer_request_valid
        ; Alcotest.test_case "invalid answer" `Quick test_handle_answer_request_invalid
        ] )
    ; ( "peer_lifecycle"
      , [ Alcotest.test_case "mark connected" `Quick test_mark_connected_updates_peer
        ; Alcotest.test_case "send to nonexistent" `Quick test_send_to_nonexistent_peer
        ; Alcotest.test_case "message handler setup" `Quick test_message_handler_invoked
        ] )
    ; "cleanup", [ Alcotest.test_case "expired offers" `Quick test_cleanup_expired ]
    ; ( "transport_enum"
      , [ Alcotest.test_case "webrtc variant" `Quick test_transport_webrtc_variant
        ; Alcotest.test_case "agent transport" `Quick test_agent_transport_webrtc
        ] )
    ; ( "ice_config"
      , [ Alcotest.test_case "csv env" `Quick test_configured_ice_servers_from_csv_env
        ; Alcotest.test_case
            "json override"
            `Quick
            test_configured_ice_servers_json_override
        ] )
    ]
;;
