open Alcotest

module Client = Discord_gateway_client
module State = Discord_gateway_state

let dummy_frame : State.frame =
  { op = State.Op_hello
  ; s = None
  ; t = None
  ; d = `Assoc [ ("heartbeat_interval", `Int 41_250) ]
  }

let check_continue label input expected =
  check bool label expected
    (Client.For_testing.reader_should_continue_after_input input)

let test_reader_stops_after_close_input () =
  check_continue "close input stops reader"
    (State.Wss_closed { code = 1000; reason = "remote close" })
    false

let test_reader_continues_after_non_close_inputs () =
  let cases =
    [ "connect", State.Connect_requested
    ; "frame", State.Frame_received dummy_frame
    ; "parse_error", State.Frame_parse_error "bad json"
    ; "heartbeat_tick", State.Heartbeat_tick
    ; "heartbeat_ack_timeout", State.Heartbeat_ack_timeout
    ; "backoff_elapsed", State.Backoff_elapsed
    ; "status_change", State.Status_change State.Online
    ]
  in
  List.iter
    (fun (label, input) -> check_continue label input true)
    cases

let () =
  run "discord_gateway_client"
    [
      ( "reader_policy"
      , [
          test_case "stops after WSS close input" `Quick
            test_reader_stops_after_close_input
        ; test_case "continues after non-close inputs" `Quick
            test_reader_continues_after_non_close_inputs
        ] )
    ]
