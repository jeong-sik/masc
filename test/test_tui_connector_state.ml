open Alcotest
module State = Masc_tui_connector_state
module Reading = Masc.Tui_decode

let connections =
  [ ("connected", Reading.Connector_connected)
  ; ("connected / unavailable", Reading.Connector_connected_unavailable)
  ; ("disconnected", Reading.Connector_disconnected)
  ; ("offline", Reading.Connector_offline)
  ; ("stale", Reading.Connector_stale)
  ]

let test_every_connection_spells_its_own_badge () =
  let words = List.map (fun (_, c) -> State.badge_word c) connections in
  check int "one word per connection" (List.length connections)
    (List.length (List.sort_uniq String.compare words));
  List.iter
    (fun word ->
      check bool (word ^ " is spelled for the badge") true
        (String.equal word (String.uppercase_ascii word)))
    words

(* The connector the server sends, read through the same decoder the pane
   reads it through. [status]/[available]/[connected] pick the badge. *)
let connector ~status ~available ~connected ?gateway_state ?poll_state () =
  let optional name = function
    | None -> []
    | Some value -> [ (name, `String value) ]
  in
  let json =
    `Assoc
      [ ( "connectors"
        , `List
            [ `Assoc
                ([ ("connector_id", `String "transport")
                 ; ("display_name", `String "Transport")
                 ; ("status", `String status)
                 ; ("available", `Bool available)
                 ; ("connected", `Bool connected)
                 ; ("configured_bindings", `List [])
                 ]
                @ optional "gateway_state" gateway_state
                @ optional "poll_state" poll_state)
            ] )
      ; ("total", `Int 1)
      ; ("active_count", `Int 1)
      ]
  in
  match Reading.decode_connector_snapshot json with
  | Ok { Reading.cs_connectors = [ c ]; _ } -> c
  | Ok _ -> fail "expected one connector"
  | Error err -> failf "decode failed: %s" err

(* The Discord row read "Connection ● CONNECTED" above "Runtime state
   connected": the gateway's state and the badge's are the same reading. *)
let test_a_runtime_state_the_badge_already_names_is_not_drawn () =
  check (option string) "a connected gateway under CONNECTED" None
    (State.runtime_state_to_draw
       (connector ~status:"connected" ~available:true ~connected:true
          ~gateway_state:"connected" ()));
  check (option string) "a disconnected gateway under DISCONNECTED" None
    (State.runtime_state_to_draw
       (connector ~status:"disconnected" ~available:true ~connected:false
          ~gateway_state:"disconnected" ()))

(* Slack's transport read "○ UNAVAILABLE" with a gateway that said
   "disconnected", which is the reading this row exists for. *)
let test_a_runtime_state_the_badge_does_not_name_is_drawn () =
  check (option string) "a disconnected gateway under UNAVAILABLE"
    (Some "disconnected")
    (State.runtime_state_to_draw
       (connector ~status:"offline" ~available:false ~connected:false
          ~gateway_state:"disconnected" ()));
  check (option string) "a resuming gateway under CONNECTED"
    (Some "resuming")
    (State.runtime_state_to_draw
       (connector ~status:"connected" ~available:true ~connected:true
          ~gateway_state:"resuming" ()));
  check (option string) "a poller under CONNECTED" (Some "polling")
    (State.runtime_state_to_draw
       (connector ~status:"connected" ~available:true ~connected:true
          ~poll_state:"polling" ()));
  check (option string) "a transport with no state of its own draws none" None
    (State.runtime_state_to_draw
       (connector ~status:"offline" ~available:false ~connected:false ()))

let () =
  run "tui connector state"
    [ ( "badge"
      , [ test_case "every connection spells its own badge" `Quick
            test_every_connection_spells_its_own_badge
        ] )
    ; ( "runtime state"
      , [ test_case "a state the badge already names is not drawn" `Quick
            test_a_runtime_state_the_badge_already_names_is_not_drawn
        ; test_case "a state the badge does not name is drawn" `Quick
            test_a_runtime_state_the_badge_does_not_name_is_drawn
        ] )
    ]
