(* The attention row and the queue entry that makes a Keeper judge it are two
   separate writes, and only the queue side drains the row: a turn settles the
   row it consumed, and nothing else does. So a row whose queue entry never
   landed sits pending forever -- the wake is edge-triggered, and only a new
   ambient message re-arms it.

   That is not a hypothesis. On 2026-08-23 the live runtime lost a batch of
   pending stimuli when the queue snapshot came back undecodable, and eleven
   days later 68 rows were still standing on the operator's attention panel,
   holding workspace health at "warning" over three Discord asides nobody was
   ever going to answer.

   These are the two facts the type checker cannot hold: that both gateways
   deliver through one function rather than building the stimulus themselves,
   and that the function marks the row [Quarantined] when the queue refuses
   the entry. What [Quarantined] then does to the pending projection is
   already measured, in test_keeper_external_attention. *)

let delivery = "lib/server/server_connector_attention_delivery.ml"
let discord = "lib/server/server_discord_in_process_gateway.ml"
let slack = "lib/server/server_slack_in_process_gateway.ml"

let builds_the_stimulus_itself module_path =
  Ast_grep.count_constructors_in_value_binding ~module_path
    ~binding_name:"handle_ambient" ~constructors:[ "Keeper_event_queue.Connector_attention" ]

let test_both_gateways_deliver_through_one_function () =
  Alcotest.(check int) "Discord builds no stimulus of its own" 0
    (builds_the_stimulus_itself discord);
  Alcotest.(check int) "Slack builds no stimulus of its own" 0
    (builds_the_stimulus_itself slack);
  Alcotest.(check int) "Discord delivers through the shared function" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:discord
       ~binding_name:"handle_ambient"
       ~callee:"Server_connector_attention_delivery.deliver");
  Alcotest.(check int) "Slack delivers through the shared function" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:slack
       ~binding_name:"handle_ambient"
       ~callee:"Server_connector_attention_delivery.deliver")

let test_a_refused_enqueue_closes_the_row () =
  Alcotest.(check int) "the refused branch marks the row quarantined" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:delivery
       ~binding_name:"quarantine_undelivered"
       ~callee:"Keeper_external_attention.mark_quarantined");
  Alcotest.(check int) "and delivery reaches that branch" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:delivery
       ~binding_name:"deliver" ~callee:"quarantine_undelivered")

let () =
  Alcotest.run "connector_attention_delivery_wiring"
    [ ( "delivery"
      , [ Alcotest.test_case "both gateways deliver through one function"
            `Quick test_both_gateways_deliver_through_one_function
        ; Alcotest.test_case "a refused enqueue closes the row" `Quick
            test_a_refused_enqueue_closes_the_row
        ] )
    ]
