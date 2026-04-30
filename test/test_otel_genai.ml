module Lib = Masc_mcp
open Alcotest

let assoc key attrs = List.assoc_opt key attrs
let cascade_name raw = Lib.Keeper_cascade_profile.Runtime_name raw

let test_keeper_turn_span_name () =
  check
    string
    "span name"
    "invoke_agent ani1999"
    (Lib.Otel_genai.keeper_turn_span_name ~keeper_name:"ani1999")
;;

let test_keeper_turn_attrs_dual_emit () =
  let attrs =
    Lib.Otel_genai.keeper_turn_attrs
      ~keeper_name:"ani1999"
      ~agent_name:"ani1999"
      ~cascade_name:(cascade_name "research")
      ~trace_id:"trace-123"
      ~generation:7
      ~max_context:120000
      ~max_turns:4
      ~max_idle_turns:2
      ~channel:"scheduled_autonomous"
      ~is_retry:false
      ~current_task_id:(Some "task-161")
  in
  check
    (option (of_pp Fmt.Dump.string))
    "gen_ai operation"
    (Some "invoke_agent")
    (Option.map
       (function
         | `String s -> s
         | _ -> "?")
       (assoc "gen_ai.operation.name" attrs));
  check
    (option (of_pp Fmt.Dump.string))
    "gen_ai provider"
    (Some "masc")
    (Option.map
       (function
         | `String s -> s
         | _ -> "?")
       (assoc "gen_ai.provider.name" attrs));
  check
    (option (of_pp Fmt.Dump.string))
    "agent name"
    (Some "ani1999")
    (Option.map
       (function
         | `String s -> s
         | _ -> "?")
       (assoc "gen_ai.agent.name" attrs));
  check
    (option (of_pp Fmt.Dump.string))
    "conversation id"
    (Some "trace-123")
    (Option.map
       (function
         | `String s -> s
         | _ -> "?")
       (assoc "gen_ai.conversation.id" attrs));
  check
    (option (of_pp Fmt.Dump.string))
    "legacy cascade"
    (Some "research")
    (Option.map
       (function
         | `String s -> s
         | _ -> "?")
       (assoc "keeper.cascade.name" attrs));
  check
    (option (of_pp Fmt.Dump.string))
    "task id"
    (Some "task-161")
    (Option.map
       (function
         | `String s -> s
         | _ -> "?")
       (assoc "keeper.current_task_id" attrs))
;;

let test_keeper_turn_attrs_omit_missing_task () =
  let attrs =
    Lib.Otel_genai.keeper_turn_attrs
      ~keeper_name:"ani1999"
      ~agent_name:"ani1999"
      ~cascade_name:(cascade_name "research")
      ~trace_id:"trace-123"
      ~generation:7
      ~max_context:120000
      ~max_turns:4
      ~max_idle_turns:2
      ~channel:"reactive"
      ~is_retry:true
      ~current_task_id:None
  in
  check bool "omits missing task id" false (List.mem_assoc "keeper.current_task_id" attrs);
  check
    (option bool)
    "retry attr"
    (Some true)
    (Option.map
       (function
         | `Bool b -> b
         | _ -> false)
       (assoc "keeper.is_retry" attrs))
;;

let () =
  run
    "otel_genai"
    [ ( "keeper turn"
      , [ test_case "span name" `Quick test_keeper_turn_span_name
        ; test_case "dual emit attrs" `Quick test_keeper_turn_attrs_dual_emit
        ; test_case "omit missing task id" `Quick test_keeper_turn_attrs_omit_missing_task
        ] )
    ]
;;
