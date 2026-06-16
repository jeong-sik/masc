(** Test Reasoning_dialect registry (P3-1). *)

open Masc

let cfg ?(enable_thinking = None) ?(thinking_budget = None)
    ?(preserve_thinking = None) ~kind ~model_id () =
  let base =
    Llm_provider.Provider_config.make ~kind ~model_id
      ~base_url:"http://localhost" ()
  in
  { base with
    Llm_provider.Provider_config.enable_thinking
  ; thinking_budget
  ; preserve_thinking
  }
;;

let anthropic_reasoning () =
  let d =
    Reasoning_dialect.of_provider_config
      (cfg ~kind:Llm_provider.Provider_config.Anthropic
         ~model_id:"claude-opus-4" ~enable_thinking:(Some true)
         ~thinking_budget:(Some 16000) ())
  in
  Alcotest.(check bool) "supports reasoning" true d.supports_reasoning;
  (match d.dialect with
   | Reasoning_dialect.Anthropic_extended { budget_tokens = Some 16000 } -> ()
   | _ -> Alcotest.fail "expected Anthropic_extended with budget 16000");
  Alcotest.(check bool) "stop at tool call" true
    (d.continuation_boundary = Reasoning_dialect.Stop_at_tool_call)
;;

let openai_o1_reasoning () =
  let d =
    Reasoning_dialect.of_provider_config
      (cfg ~kind:Llm_provider.Provider_config.OpenAI_compat ~model_id:"o1-mini" ())
  in
  Alcotest.(check bool) "supports reasoning" true d.supports_reasoning;
  (match d.dialect with
   | Reasoning_dialect.Openai_o1 { reasoning_effort = "low" } -> ()
   | _ -> Alcotest.fail "expected Openai_o1 with low effort");
  Alcotest.(check bool) "stop at tool call" true
    (d.continuation_boundary = Reasoning_dialect.Stop_at_tool_call)
;;

let no_reasoning () =
  let d =
    Reasoning_dialect.of_provider_config
      (cfg ~kind:Llm_provider.Provider_config.OpenAI_compat ~model_id:"gpt-4o" ())
  in
  Alcotest.(check bool) "does not support reasoning" false
    d.supports_reasoning;
  Alcotest.(check bool) "no dialect" true
    (d.dialect = Reasoning_dialect.No_reasoning);
  Alcotest.(check bool) "no boundary" true
    (d.continuation_boundary = Reasoning_dialect.No_boundary);
  Alcotest.(check bool) "exclude replay" true
    (d.replay_policy = Reasoning_dialect.Exclude)
;;

let preserve_thinking_replay () =
  let d =
    Reasoning_dialect.of_provider_config
      (cfg ~kind:Llm_provider.Provider_config.Anthropic
         ~model_id:"claude-opus-4" ~enable_thinking:(Some true)
         ~preserve_thinking:(Some true) ())
  in
  Alcotest.(check bool) "include replay" true
    (d.replay_policy = Reasoning_dialect.Include)
;;

let () =
  Alcotest.run
    "Reasoning_dialect P3-1"
    [ ( "registry"
      , [ Alcotest.test_case "anthropic reasoning" `Quick anthropic_reasoning
        ; Alcotest.test_case "openai o1 reasoning" `Quick openai_o1_reasoning
        ; Alcotest.test_case "no reasoning" `Quick no_reasoning
        ; Alcotest.test_case "preserve thinking replay" `Quick
            preserve_thinking_replay
        ] )
    ]
;;
