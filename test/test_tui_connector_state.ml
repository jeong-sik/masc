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

(* The Discord row read "Connection ● CONNECTED" above "Runtime state
   connected": the gateway's word and the badge's are the same reading. *)
let test_a_runtime_state_the_badge_already_spells_is_not_drawn () =
  check (option string) "the gateway repeats the badge" None
    (State.runtime_state_to_draw ~connection:Reading.Connector_connected
       (Some "connected"));
  check (option string) "case and padding do not make it a new reading" None
    (State.runtime_state_to_draw ~connection:Reading.Connector_connected
       (Some " CONNECTED "))

(* Slack's transport read "○ UNAVAILABLE" with a gateway that said
   "disconnected", which is the reading this row exists for. *)
let test_a_runtime_state_the_badge_does_not_spell_is_drawn () =
  check (option string) "the gateway says more than the badge"
    (Some "disconnected")
    (State.runtime_state_to_draw ~connection:Reading.Connector_offline
       (Some "disconnected"));
  check (option string) "a transport with no state of its own draws none" None
    (State.runtime_state_to_draw ~connection:Reading.Connector_offline None)

let () =
  run "tui connector state"
    [ ( "badge"
      , [ test_case "every connection spells its own badge" `Quick
            test_every_connection_spells_its_own_badge
        ] )
    ; ( "runtime state"
      , [ test_case "a state the badge already spells is not drawn" `Quick
            test_a_runtime_state_the_badge_already_spells_is_not_drawn
        ; test_case "a state the badge does not spell is drawn" `Quick
            test_a_runtime_state_the_badge_does_not_spell_is_drawn
        ] )
    ]
