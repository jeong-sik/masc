module Lib = Masc_mcp
open Alcotest

let assoc key attrs = List.assoc_opt key attrs
let cascade_name raw = Lib.Keeper_cascade_profile.Runtime_name raw
let attr_string = function
  | Some (`String s) -> Some s
  | _ -> None

let attr_bool = function
  | Some (`Bool b) -> Some b
  | _ -> None

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
    (attr_string (assoc Lib.Otel_genai.Attr_key.gen_ai_operation_name attrs));
  check
    (option (of_pp Fmt.Dump.string))
    "gen_ai provider"
    (Some "masc")
    (attr_string (assoc Lib.Otel_genai.Attr_key.gen_ai_provider_name attrs));
  check
    (option (of_pp Fmt.Dump.string))
    "agent name"
    (Some "ani1999")
    (attr_string (assoc Lib.Otel_genai.Attr_key.gen_ai_agent_name attrs));
  check
    (option (of_pp Fmt.Dump.string))
    "conversation id"
    (Some "trace-123")
    (attr_string (assoc Lib.Otel_genai.Attr_key.gen_ai_conversation_id attrs));
  check
    (option (of_pp Fmt.Dump.string))
    "masc keeper extension"
    (Some "ani1999")
    (attr_string (assoc Lib.Otel_genai.Attr_key.masc_gen_ai_keeper_name attrs));
  check
    (option (of_pp Fmt.Dump.string))
    "masc cascade extension"
    (Some "research")
    (attr_string (assoc Lib.Otel_genai.Attr_key.masc_gen_ai_cascade_name attrs));
  check
    (option (of_pp Fmt.Dump.string))
    "legacy cascade"
    (Some "research")
    (attr_string (assoc Lib.Otel_genai.Attr_key.keeper_cascade_name attrs));
  check
    (option (of_pp Fmt.Dump.string))
    "task id"
    (Some "task-161")
    (attr_string (assoc Lib.Otel_genai.Attr_key.keeper_current_task_id attrs))
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
  check
    bool
    "omits missing task id"
    false
    (List.mem_assoc Lib.Otel_genai.Attr_key.keeper_current_task_id attrs);
  check
    (option bool)
    "retry attr"
    (Some true)
    (attr_bool (assoc Lib.Otel_genai.Attr_key.keeper_is_retry attrs))
;;

let test_attr_key_registry_boundaries () =
  check
    bool
    "operation key is official"
    true
    (Lib.Otel_genai.Attr_key.is_official_gen_ai
       Lib.Otel_genai.Attr_key.gen_ai_operation_name);
  check
    bool
    "tool key is official"
    true
    (Lib.Otel_genai.Attr_key.is_official_gen_ai
       Lib.Otel_genai.Attr_key.gen_ai_tool_name);
  check
    bool
    "masc keeper key is extension"
    true
    (Lib.Otel_genai.Attr_key.is_masc_extension
       Lib.Otel_genai.Attr_key.masc_gen_ai_keeper_name);
  check
    bool
    "extension is not official"
    false
    (Lib.Otel_genai.Attr_key.is_official_gen_ai
       Lib.Otel_genai.Attr_key.masc_gen_ai_keeper_name);
  check
    bool
    "legacy key is not extension"
    false
    (Lib.Otel_genai.Attr_key.is_masc_extension
       Lib.Otel_genai.Attr_key.keeper_name)
;;

let test_tool_execution_attrs () =
  let attrs = Lib.Otel_genai.tool_execution_attrs ~tool_name:"keeper_shell" in
  check
    (option (of_pp Fmt.Dump.string))
    "tool operation"
    (Some "execute_tool")
    (attr_string (assoc Lib.Otel_genai.Attr_key.gen_ai_operation_name attrs));
  check
    (option (of_pp Fmt.Dump.string))
    "tool name"
    (Some "keeper_shell")
    (attr_string (assoc Lib.Otel_genai.Attr_key.gen_ai_tool_name attrs))
;;

let () =
  run
    "otel_genai"
    [ ( "keeper turn"
      , [ test_case "span name" `Quick test_keeper_turn_span_name
        ; test_case "dual emit attrs" `Quick test_keeper_turn_attrs_dual_emit
        ; test_case "omit missing task id" `Quick test_keeper_turn_attrs_omit_missing_task
        ; test_case "attr key registry boundaries" `Quick
            test_attr_key_registry_boundaries
        ; test_case "tool execution attrs" `Quick test_tool_execution_attrs
        ] )
    ]
;;
