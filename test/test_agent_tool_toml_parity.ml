(** What the published surface says: that no agent tool appeared or vanished.

    The descriptions and input schemas this suite also pinned were literals
    read off the same published values before the declarations moved into
    [config/tools/*.toml] -- one producer against a snapshot of itself, so the
    only thing it could report was that someone edited a sentence. Those cases
    are gone; every case that stays reads the published value. *)

open Alcotest
(* name, description, input_schema (keys sorted) *)
let expected =
  [ ( {|masc_agent_fitness|}
    , {|Fitness scores for agents: completion rate, reliability, speed.|}
    , {|{"additionalProperties":false,"properties":{"agent_name":{"description":"Optional: Get fitness for specific agent. If omitted, returns all agents.","type":"string"},"days":{"default":7,"description":"Number of days to analyze (default: 7)","type":"integer"}},"type":"object"}|}
    )
  ; ( {|masc_get_metrics|}
    , {|Raw performance metrics for one agent.

Task completion, timing, error rates, and collaboration history.|}
    , {|{"additionalProperties":false,"properties":{"agent_name":{"description":"Agent name to get metrics for","type":"string"},"days":{"default":7,"description":"Number of days of history (default: 7)","maximum":90,"minimum":1,"type":"integer"}},"required":["agent_name"],"type":"object"}|}
    )
  ; ( {|masc_agent_card|}
    , {|Return the MASC server agent card and optional live agent summary.|}
    , {|{"additionalProperties":false,"properties":{"action":{"default":"get","description":"Card action: get or refresh.","enum":["get","refresh"],"type":"string"},"agent_name":{"description":"Optional live agent name to include in the card.","type":"string"}},"type":"object"}|}
    )
  ]
;;

let published = Tool_schemas_agent.schemas

(* The list is a published surface: a tool appearing or vanishing changes what
   a Keeper is offered, so the count is pinned too. *)
let test_no_extras () =
  check int "published count" (List.length expected) (List.length published)
;;

let () =
  run
    "agent tool toml parity"
    [ ( "parity"
      , [ test_case "no tool appeared or vanished" `Quick test_no_extras
        ] )
    ]
;;
