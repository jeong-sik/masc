open Alcotest

module Bridge = Discord_presence_bridge
module Gateway = Discord_gateway_state

let keeper ?(running = false) ?(bound_channels = []) keeper_name =
  Bridge.{ keeper_name; running; bound_channels }
;;

let status_name = function
  | None -> "none"
  | Some status -> Gateway.presence_status_to_string status
;;

let check_status label expected actual =
  check string label (status_name expected) (status_name actual)
;;

let test_disconnected_gateway_is_noop () =
  let keepers = [ keeper ~running:true ~bound_channels:[ "C123" ] "verifier" ] in
  check_status
    "disconnected gateway"
    None
    (Bridge.presence_status_for_keepers ~gateway_connected:false keepers)
;;

let test_running_bound_keeper_sets_online () =
  let keepers =
    [ keeper ~running:false ~bound_channels:[ "C-paused" ] "paused"
    ; keeper ~running:true ~bound_channels:[ "C-active" ] "active"
    ]
  in
  check_status
    "active bound keeper"
    (Some Gateway.Online)
    (Bridge.presence_status_for_keepers ~gateway_connected:true keepers)
;;

let test_no_running_bound_keeper_sets_idle () =
  let keepers =
    [ keeper ~running:true "unbound"
    ; keeper ~running:false ~bound_channels:[ "C-paused" ] "paused"
    ]
  in
  check_status
    "no active bound keeper"
    (Some Gateway.Idle)
    (Bridge.presence_status_for_keepers ~gateway_connected:true keepers)
;;

let check_transition label ~last computed ~send ~remember =
  let to_send, next_last = Bridge.presence_transition ~last computed in
  check string (label ^ ": send") (status_name send) (status_name to_send);
  check string (label ^ ": remember") (status_name remember) (status_name next_last)
;;

(* Every 30 s poll used to re-send the same status: 61 identical
   "presence update: online" lines in 41 minutes (2026-09-09). *)
let test_unchanged_status_is_not_resent () =
  check_transition "first poll" ~last:None (Some Gateway.Online)
    ~send:(Some Gateway.Online) ~remember:(Some Gateway.Online);
  check_transition "same again" ~last:(Some Gateway.Online) (Some Gateway.Online)
    ~send:None ~remember:(Some Gateway.Online);
  check_transition "changed" ~last:(Some Gateway.Online) (Some Gateway.Idle)
    ~send:(Some Gateway.Idle) ~remember:(Some Gateway.Idle)
;;

let test_disconnect_forgets_the_last_send () =
  check_transition "disconnected" ~last:(Some Gateway.Online) None
    ~send:None ~remember:None;
  check_transition "reconnected" ~last:None (Some Gateway.Online)
    ~send:(Some Gateway.Online) ~remember:(Some Gateway.Online)
;;

let () =
  run
    "discord_presence_bridge"
    [ ( "presence decision"
      , [ test_case
            "does nothing while gateway is disconnected"
            `Quick
            test_disconnected_gateway_is_noop
        ; test_case
            "sets online when any running keeper has a Discord binding"
            `Quick
            test_running_bound_keeper_sets_online
        ; test_case
            "sets idle when no running keeper has a Discord binding"
            `Quick
            test_no_running_bound_keeper_sets_idle
        ] )
    ; ( "send on change"
      , [ test_case
            "an unchanged status is not re-sent"
            `Quick
            test_unchanged_status_is_not_resent
        ; test_case
            "a disconnect forgets the last send"
            `Quick
            test_disconnect_forgets_the_last_send
        ] )
    ]
;;
