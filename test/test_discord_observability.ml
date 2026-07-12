open Alcotest

module Obs = Discord_observability
module Metrics = Otel_metric_store_core
module Names = Otel_transport_metric_names

let check_delta ?(labels = []) metric_name f =
  let before = Metrics.metric_value_or_zero metric_name ~labels () in
  f ();
  let after = Metrics.metric_value_or_zero metric_name ~labels () in
  check (float 0.0001) "metric delta" 1.0 (after -. before)

let test_label_contract () =
  check string "route control" "control" (Obs.gateway_route_label Obs.Control);
  check string "route triggered" "triggered"
    (Obs.gateway_route_label Obs.Triggered);
  check string "event message_create" "message_create"
    (Obs.gateway_event_label Obs.Message_create);
  check string "dispatch dropped_unbound" "dropped_unbound"
    (Obs.inbound_outcome_label Obs.Dropped_unbound);
  check string "dispatch unavailable" "dispatch_unavailable"
    (Obs.inbound_outcome_label Obs.Dispatch_unavailable);
  check string "ambient too_long" "dropped_too_long"
    (Obs.ambient_outcome_label Obs.Ambient_dropped_too_long);
  check string "ambient persistence failure" "persistence_failed"
    (Obs.ambient_outcome_label Obs.Ambient_persistence_failed);
  check string "reply failed" "send_error"
    (Obs.reply_outcome_label Obs.Reply_send_failed)

let test_gateway_event_counter () =
  let labels = [ "event", "message_create"; "route", "triggered" ] in
  check_delta Names.metric_discord_gateway_events ~labels (fun () ->
    Obs.record_gateway_event ~route:Obs.Triggered Obs.Message_create)

let test_gateway_close_counter () =
  let labels = [ "code", "1001" ] in
  check_delta Names.metric_discord_gateway_closes ~labels (fun () ->
    Obs.record_gateway_close ~code:1001)

let test_gateway_reconnect_counter () =
  check_delta Names.metric_discord_gateway_reconnect_scheduled (fun () ->
    Obs.record_gateway_reconnect_scheduled ())

let test_gateway_ack_timeout_counter () =
  check_delta Names.metric_discord_gateway_ack_timeouts (fun () ->
    Obs.record_gateway_ack_timeout ())

let test_inbound_dispatch_counter () =
  let labels = [ "outcome", "dispatch_unavailable" ] in
  check_delta Names.metric_discord_inbound_dispatch ~labels (fun () ->
    Obs.record_inbound_dispatch Obs.Dispatch_unavailable)

let test_ambient_counter () =
  let labels = [ "outcome", "recorded" ] in
  check_delta Names.metric_discord_ambient_record ~labels (fun () ->
    Obs.record_ambient Obs.Ambient_recorded)

let test_reply_counter () =
  let labels = [ "outcome", "sent" ] in
  check_delta Names.metric_discord_outbound_replies ~labels (fun () ->
    Obs.record_reply Obs.Reply_send_ok)

let () =
  run "discord_observability"
    [ ( "labels"
      , [ test_case "low-cardinality labels are stable" `Quick
            test_label_contract
        ] )
    ; ( "metrics"
      , [ test_case "gateway event counter" `Quick test_gateway_event_counter
        ; test_case "gateway close counter" `Quick test_gateway_close_counter
        ; test_case "gateway reconnect counter" `Quick
            test_gateway_reconnect_counter
        ; test_case "gateway ack timeout counter" `Quick
            test_gateway_ack_timeout_counter
        ; test_case "inbound dispatch counter" `Quick
            test_inbound_dispatch_counter
        ; test_case "ambient counter" `Quick test_ambient_counter
        ; test_case "reply counter" `Quick test_reply_counter
        ] )
    ]
