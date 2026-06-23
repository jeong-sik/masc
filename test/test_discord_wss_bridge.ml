(* RFC-0286 — Discord WSS bridge contract.

   [Discord_wss_connection] adapts ws-direct's callback-style endpoint
   (on_message / on_close / on_eof / on_error) to the gateway reader's
   blocking [read : conn -> inbound]. The adaptation is two pure steps:

   - [message_to_event] maps an endpoint data message to a bridge event
     (Text -> Some, Binary -> None — Discord with compress=false never sends
     Binary on application frames, and the FSM has no use for it);
   - [close_to_event] maps an endpoint Close (RFC 6455 §7.4 optional code) to a
     bridge event, defaulting a missing code to 1005;
   - [read_event] turns a bridge event back into [inbound], raising the
     exceptions the gateway reader already maps (End_of_file -> Wss_closed 1006,
     any other -> Wss_closed 1011).

   These tests pin that contract without a live socket. *)

open Alcotest
module B = Discord_wss_connection.For_testing
module Msg = Ws_direct_core.Connection.Message

let msg kind s = { Msg.kind; payload = Bigstringaf.of_string ~off:0 ~len:(String.length s) s }

let test_read_event_message () =
  match B.read_event (B.Ev_message "hello") with
  | B.Message s -> check string "payload preserved" "hello" s
  | B.Closed _ -> fail "expected Message"
;;

let test_read_event_closed () =
  match B.read_event (B.Ev_closed { code = 1000; reason = "bye" }) with
  | B.Closed { code; reason } ->
    check int "close code preserved" 1000 code;
    check string "close reason preserved" "bye" reason
  | B.Message _ -> fail "expected Closed"
;;

let test_read_event_eof_raises () =
  check_raises "Ev_eof raises End_of_file" End_of_file (fun () ->
    ignore (B.read_event B.Ev_eof))
;;

let test_read_event_error_raises () =
  check_raises "Ev_error raises Failure with the cause" (Failure "boom") (fun () ->
    ignore (B.read_event (B.Ev_error "boom")))
;;

let test_message_to_event_text () =
  match B.message_to_event (msg Msg.Text "{\"op\":1}") with
  | Some (B.Ev_message s) -> check string "text payload mapped" "{\"op\":1}" s
  | Some _ -> fail "expected Ev_message"
  | None -> fail "Text message must produce an event"
;;

let test_message_to_event_binary_dropped () =
  match B.message_to_event (msg Msg.Binary "\x00\x01") with
  | None -> ()
  | Some _ -> fail "Binary message must be dropped"
;;

let test_close_to_event_default_code () =
  match B.close_to_event ~code:None ~reason:"no status" with
  | B.Ev_closed { code; reason } ->
    check int "missing code defaults to 1005" B.close_code_no_status code;
    check string "reason preserved" "no status" reason
  | _ -> fail "expected Ev_closed"
;;

let test_close_to_event_explicit_code () =
  match B.close_to_event ~code:(Some 4000) ~reason:"app close" with
  | B.Ev_closed { code; reason } ->
    check int "explicit code preserved" 4000 code;
    check string "reason preserved" "app close" reason
  | _ -> fail "expected Ev_closed"
;;

let () =
  run "discord_wss_bridge"
    [ ( "read_event"
      , [ test_case "Ev_message -> Message" `Quick test_read_event_message
        ; test_case "Ev_closed -> Closed" `Quick test_read_event_closed
        ; test_case "Ev_eof raises End_of_file" `Quick test_read_event_eof_raises
        ; test_case "Ev_error raises Failure" `Quick test_read_event_error_raises
        ] )
    ; ( "message_to_event"
      , [ test_case "Text mapped to Ev_message" `Quick test_message_to_event_text
        ; test_case "Binary dropped" `Quick test_message_to_event_binary_dropped
        ] )
    ; ( "close_to_event"
      , [ test_case "missing code defaults to 1005" `Quick test_close_to_event_default_code
        ; test_case "explicit code preserved" `Quick test_close_to_event_explicit_code
        ] )
    ]
;;
