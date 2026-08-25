(** Pins the connector outcome vocabulary that Slack and Discord share.

    These strings are metric label values, so changing one is a wire change
    for anything aggregating across connectors. Before
    {!Gate_connector_observability} existed the two modules each declared
    their own copy and [Slack_observability]'s docstring described itself as
    a mirror of Discord's — a mirror the compiler could not check.
    [test_discord_observability] pinned eight of the mappings from one side;
    the rest were unpinned.

    The [same_type_as_*] bindings below are the point of the module: they only
    compile while both connectors name the same constructor of the same type.
    A signature that re-declared the variants without the type equation would
    seal them and break these lines. *)

open Alcotest

module Shared = Gate_connector_observability
module Slack = Slack_observability
module Discord = Discord_observability

let same_type_as_slack : Shared.inbound_outcome = Slack.Reply_sent
let same_type_as_discord : Shared.inbound_outcome = Discord.Reply_sent
let ambient_shared : Shared.ambient_outcome = Slack.Ambient_recorded
let reply_shared : Shared.reply_outcome = Discord.Reply_send_ok
let route_shared : Shared.gateway_route = Slack.Triggered

let test_both_connectors_name_one_type () =
  check
    bool
    "Slack.Reply_sent and Discord.Reply_sent are the same value"
    true
    (same_type_as_slack = same_type_as_discord);
  check
    string
    "and the shared label function accepts either"
    (Discord.inbound_outcome_label same_type_as_slack)
    (Slack.inbound_outcome_label same_type_as_discord);
  check string "ambient" "recorded" (Shared.ambient_outcome_label ambient_shared);
  check string "reply" "sent" (Shared.reply_outcome_label reply_shared);
  check string "route" "triggered" (Shared.gateway_route_label route_shared)
;;

(* Exhaustive rather than a sample: the compiler forces a label for a new
   constructor, but it cannot tell you the label you chose is the one the
   dashboards already query. *)
let test_gateway_route_labels () =
  List.iter
    (fun (value, expected) ->
      check string expected expected (Shared.gateway_route_label value))
    [ Shared.Control, "control"; Shared.Triggered, "triggered"; Shared.Ambient, "ambient" ]
;;

let test_inbound_outcome_labels () =
  List.iter
    (fun (value, expected) ->
      check string expected expected (Shared.inbound_outcome_label value))
    [ Shared.Dropped_unbound, "dropped_unbound"
    ; Shared.Dispatch_unavailable, "dispatch_unavailable"
    ; Shared.Gate_error, "gate_error"
    ; Shared.Empty_reply, "empty_reply"
    ; Shared.Reply_sent, "reply_sent"
    ; Shared.Reply_send_error, "reply_send_error"
    ]
;;

let test_ambient_outcome_labels () =
  List.iter
    (fun (value, expected) ->
      check string expected expected (Shared.ambient_outcome_label value))
    [ Shared.Ambient_recorded, "recorded"
    ; Shared.Ambient_binding_store_error, "binding_store_error"
    ; Shared.Ambient_dropped_unbound, "dropped_unbound"
    ; Shared.Ambient_dropped_empty, "dropped_empty"
    ; Shared.Ambient_dropped_too_long, "dropped_too_long"
    ]
;;

let test_reply_outcome_labels () =
  List.iter
    (fun (value, expected) ->
      check string expected expected (Shared.reply_outcome_label value))
    [ Shared.Reply_empty, "empty"
    ; Shared.Reply_send_ok, "sent"
    ; Shared.Reply_send_failed, "send_error"
    ]
;;

(* The event vocabularies are deliberately not shared: the two platforms do
   not emit the same events. Pinning them here records that the split is a
   decision, not an oversight. *)
let test_event_vocabularies_stay_separate () =
  check string "slack hello" "hello" (Slack.gateway_event_label Slack.Hello);
  check string "discord ready" "ready" (Discord.gateway_event_label Discord.Ready);
  check
    string
    "discord open_wss has no Slack counterpart"
    "open_wss"
    (Discord.gateway_event_label Discord.Open_wss);
  check
    string
    "both spell the one event they share the same way"
    (Discord.gateway_event_label Discord.Message_create)
    (Slack.gateway_event_label Slack.Message_create)
;;

let () =
  run
    "gate connector observability"
    [ ( "one vocabulary"
      , [ test_case
            "both connectors name one type"
            `Quick
            test_both_connectors_name_one_type
        ; test_case "gateway_route labels" `Quick test_gateway_route_labels
        ; test_case "inbound_outcome labels" `Quick test_inbound_outcome_labels
        ; test_case "ambient_outcome labels" `Quick test_ambient_outcome_labels
        ; test_case "reply_outcome labels" `Quick test_reply_outcome_labels
        ] )
    ; ( "per-connector"
      , [ test_case
            "event vocabularies stay separate"
            `Quick
            test_event_vocabularies_stay_separate
        ] )
    ]
;;
