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
    ]
;;
