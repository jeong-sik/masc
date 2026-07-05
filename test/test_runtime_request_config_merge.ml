(* Runtime_agent.request_runtime_fields_on_base_config — structured output 병합 회귀 가드.

   base provider config는 빌드 시 validate까지 통과한 schema-carrying 계약을 나를 수
   있다 (Keeper_structured_output_schema.apply_to_provider_config). OAS Agent의
   per-request config는 [Agent_sdk.Provider.config](라우팅 삼중항)에서 파생되어
   schema 필드를 구조적으로 운반할 수 없으므로 언제나 response_format=Off /
   output_schema=None으로 도착한다. 이전 병합은 이 무의견 값을 base 위에 무조건
   복사해 계약을 와이어 직전에 조용히 증발시켰다 — #22768 이후 fusion judge/panel·
   verifier·dashboard judge의 native schema가 HTTP body에 실린 적이 없었다
   (2026-07-02 hop-by-hop 추적, masc#23003 후속). 여기서는 "요청이 의견을 낼 때만
   요청 우선" 병합을 핀한다. *)

open Alcotest
open Masc

let schema : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "object")
    ; ("properties", `Assoc [ ("answer", `Assoc [ ("type", `String "string") ]) ])
    ; ("required", `List [ `String "answer" ])
    ]

let alternate_schema : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "object")
    ; ( "properties"
      , `Assoc [ ("verdict", `Assoc [ ("type", `String "string") ]) ] )
    ; ("required", `List [ `String "verdict" ])
    ]

let base_with_schema () =
  let cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Anthropic
      ~model_id:"claude-test"
      ~base_url:"https://api.anthropic.test"
      ()
  in
  { cfg with
    Llm_provider.Provider_config.response_format = Agent_sdk.Types.JsonSchema schema
  ; output_schema = Some schema
  }

let request_without_opinion () =
  (* OAS Agent 요청 config의 실제 도착 형태: schema 무의견 + 요청 런타임 필드. *)
  let cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Anthropic
      ~model_id:"claude-test"
      ~base_url:"https://api.anthropic.test"
      ()
  in
  { cfg with
    Llm_provider.Provider_config.max_tokens = Some 777
  ; system_prompt = Some "req prompt"
  }

let merge = Runtime_agent.For_testing.request_runtime_fields_on_base_config

let test_base_schema_survives_opinionless_request () =
  let merged = merge ~base:(base_with_schema ()) (request_without_opinion ()) in
  check bool "base JsonSchema survives request Off" true
    (match merged.Llm_provider.Provider_config.response_format with
     | Agent_sdk.Types.JsonSchema s -> Yojson.Safe.equal s schema
     | Agent_sdk.Types.Off | Agent_sdk.Types.JsonMode -> false);
  check bool "base output_schema survives request None" true
    (match merged.Llm_provider.Provider_config.output_schema with
     | Some s -> Yojson.Safe.equal s schema
     | None -> false);
  (* 요청 런타임 필드는 여전히 요청이 이긴다 — 병합의 원래 목적 유지. *)
  check (option int) "request max_tokens still wins" (Some 777)
    merged.Llm_provider.Provider_config.max_tokens;
  check (option string) "request system_prompt still wins" (Some "req prompt")
    merged.Llm_provider.Provider_config.system_prompt

let test_request_json_mode_clears_base_schema () =
  let req =
    { (request_without_opinion ()) with
      Llm_provider.Provider_config.response_format = Agent_sdk.Types.JsonMode
    }
  in
  let merged = merge ~base:(base_with_schema ()) req in
  check bool "explicit request JsonMode overrides base JsonSchema" true
    (match merged.Llm_provider.Provider_config.response_format with
     | Agent_sdk.Types.JsonMode -> true
     | Agent_sdk.Types.Off | Agent_sdk.Types.JsonSchema _ -> false);
  check bool "explicit request JsonMode clears base output_schema" true
    (Option.is_none merged.Llm_provider.Provider_config.output_schema)

let test_request_json_schema_replaces_base_schema () =
  let req =
    { (request_without_opinion ()) with
      Llm_provider.Provider_config.response_format =
        Agent_sdk.Types.JsonSchema alternate_schema
    }
  in
  let merged = merge ~base:(base_with_schema ()) req in
  check bool "explicit request JsonSchema overrides base JsonSchema" true
    (match merged.Llm_provider.Provider_config.response_format with
     | Agent_sdk.Types.JsonSchema s -> Yojson.Safe.equal s alternate_schema
     | Agent_sdk.Types.Off | Agent_sdk.Types.JsonMode -> false);
  check bool "explicit request JsonSchema replaces base output_schema" true
    (match merged.Llm_provider.Provider_config.output_schema with
     | Some s -> Yojson.Safe.equal s alternate_schema
     | None -> false)

let test_request_output_schema_normalizes_response_format () =
  let req =
    { (request_without_opinion ()) with
      Llm_provider.Provider_config.output_schema = Some alternate_schema
    }
  in
  let merged = merge ~base:(base_with_schema ()) req in
  check bool "explicit request output_schema sets JsonSchema response_format" true
    (match merged.Llm_provider.Provider_config.response_format with
     | Agent_sdk.Types.JsonSchema s -> Yojson.Safe.equal s alternate_schema
     | Agent_sdk.Types.Off | Agent_sdk.Types.JsonMode -> false);
  check bool "explicit request output_schema replaces base output_schema" true
    (match merged.Llm_provider.Provider_config.output_schema with
     | Some s -> Yojson.Safe.equal s alternate_schema
     | None -> false)

let test_both_opinionless_stays_off () =
  let base =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Anthropic
      ~model_id:"claude-test"
      ~base_url:"https://api.anthropic.test"
      ()
  in
  let merged = merge ~base (request_without_opinion ()) in
  check bool "no schema anywhere stays Off" true
    (match merged.Llm_provider.Provider_config.response_format with
     | Agent_sdk.Types.Off -> true
     | Agent_sdk.Types.JsonMode | Agent_sdk.Types.JsonSchema _ -> false);
  check bool "no output_schema anywhere stays None" true
    (Option.is_none merged.Llm_provider.Provider_config.output_schema)

let test_base_json_mode_survives_opinionless_request () =
  let base =
    let cfg =
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.Anthropic
        ~model_id:"claude-test"
        ~base_url:"https://api.anthropic.test"
        ()
    in
    { cfg with
      Llm_provider.Provider_config.response_format = Agent_sdk.Types.JsonMode
    ; output_schema = None
    }
  in
  let merged = merge ~base (request_without_opinion ()) in
  check bool "base JsonMode survives request Off" true
    (match merged.Llm_provider.Provider_config.response_format with
     | Agent_sdk.Types.JsonMode -> true
     | Agent_sdk.Types.Off | Agent_sdk.Types.JsonSchema _ -> false);
  check bool "base output_schema None survives request None" true
    (Option.is_none merged.Llm_provider.Provider_config.output_schema)

let test_base_sampling_survives_opinionless_request () =
  let base =
    { (base_with_schema ()) with
      Llm_provider.Provider_config.top_p = Some 0.91
    ; top_k = Some 42
    ; min_p = Some 0.07
    }
  in
  let merged = merge ~base (request_without_opinion ()) in
  check (option (float 0.0001)) "base top_p survives request None" (Some 0.91)
    merged.Llm_provider.Provider_config.top_p;
  check (option int) "base top_k survives request None" (Some 42)
    merged.Llm_provider.Provider_config.top_k;
  check (option (float 0.0001)) "base min_p survives request None" (Some 0.07)
    merged.Llm_provider.Provider_config.min_p

let test_request_sampling_overrides_base_sampling () =
  let base =
    { (base_with_schema ()) with
      Llm_provider.Provider_config.top_p = Some 0.91
    ; top_k = Some 42
    ; min_p = Some 0.07
    }
  in
  let req =
    { (request_without_opinion ()) with
      Llm_provider.Provider_config.top_p = Some 0.12
    ; top_k = Some 7
    ; min_p = Some 0.02
    }
  in
  let merged = merge ~base req in
  check (option (float 0.0001)) "request top_p wins" (Some 0.12)
    merged.Llm_provider.Provider_config.top_p;
  check (option int) "request top_k wins" (Some 7)
    merged.Llm_provider.Provider_config.top_k;
  check (option (float 0.0001)) "request min_p wins" (Some 0.02)
    merged.Llm_provider.Provider_config.min_p

(* Mismatched request-side response_format/output_schema pairs must be
   normalized by the merge rather than propagated to the wire.  A request can
   only express a schema opinion through [output_schema] or an explicit
   [response_format]; when the two fields disagree, [output_schema] wins because
   that is the field provider request builders inspect. *)

let pair_is_consistent cfg =
  Option.equal
    Yojson.Safe.equal
    cfg.Llm_provider.Provider_config.output_schema
    (Llm_provider.Provider_config.output_schema_of_response_format cfg.response_format)

let test_request_off_with_output_schema_normalizes () =
  let req =
    { (request_without_opinion ()) with
      Llm_provider.Provider_config.output_schema = Some schema
    }
  in
  let merged = merge ~base:(base_with_schema ()) req in
  check bool "Off + Some schema normalizes to consistent pair" true
    (pair_is_consistent merged);
  check bool "Off + Some schema becomes JsonSchema schema" true
    (match merged.response_format with
     | Agent_sdk.Types.JsonSchema s -> Yojson.Safe.equal s schema
     | Agent_sdk.Types.Off | Agent_sdk.Types.JsonMode -> false);
  check bool "Off + Some schema keeps output_schema" true
    (Option.equal Yojson.Safe.equal merged.output_schema (Some schema))

let test_request_json_mode_with_output_schema_normalizes () =
  let req =
    { (request_without_opinion ()) with
      Llm_provider.Provider_config.response_format = Agent_sdk.Types.JsonMode
    ; output_schema = Some schema
    }
  in
  let merged = merge ~base:(base_with_schema ()) req in
  check bool "JsonMode + Some schema normalizes to consistent pair" true
    (pair_is_consistent merged);
  check bool "JsonMode + Some schema becomes JsonSchema schema" true
    (match merged.response_format with
     | Agent_sdk.Types.JsonSchema s -> Yojson.Safe.equal s schema
     | Agent_sdk.Types.Off | Agent_sdk.Types.JsonMode -> false);
  check bool "JsonMode + Some schema keeps output_schema" true
    (Option.equal Yojson.Safe.equal merged.output_schema (Some schema))

let test_request_json_schema_with_different_output_schema_uses_output_schema () =
  let req =
    { (request_without_opinion ()) with
      Llm_provider.Provider_config.response_format =
        Agent_sdk.Types.JsonSchema alternate_schema
    ; output_schema = Some schema
    }
  in
  let merged = merge ~base:(base_with_schema ()) req in
  check bool "JsonSchema + different schema normalizes to consistent pair" true
    (pair_is_consistent merged);
  check bool "JsonSchema + different schema uses output_schema" true
    (match merged.response_format with
     | Agent_sdk.Types.JsonSchema s -> Yojson.Safe.equal s schema
     | Agent_sdk.Types.Off | Agent_sdk.Types.JsonMode -> false);
  check bool "JsonSchema + different schema keeps output_schema" true
    (Option.equal Yojson.Safe.equal merged.output_schema (Some schema))

let () =
  run "runtime_request_config_merge"
    [ ( "structured output merge"
      , [ test_case "base schema survives opinionless request" `Quick
            test_base_schema_survives_opinionless_request
        ; test_case "explicit request JsonMode clears base schema" `Quick
            test_request_json_mode_clears_base_schema
        ; test_case "explicit request JsonSchema replaces base schema" `Quick
            test_request_json_schema_replaces_base_schema
        ; test_case "explicit request output_schema normalizes response_format" `Quick
            test_request_output_schema_normalizes_response_format
        ; test_case "both opinionless stays Off" `Quick
            test_both_opinionless_stays_off
        ; test_case "base JsonMode survives opinionless request" `Quick
            test_base_json_mode_survives_opinionless_request
        ; test_case "base sampling survives opinionless request" `Quick
            test_base_sampling_survives_opinionless_request
        ; test_case "request sampling overrides base sampling" `Quick
            test_request_sampling_overrides_base_sampling
        ] )
    ; ( "response_format/output_schema mismatch normalization"
      , [ test_case "Off + Some schema" `Quick
            test_request_off_with_output_schema_normalizes
        ; test_case "JsonMode + Some schema" `Quick
            test_request_json_mode_with_output_schema_normalizes
        ; test_case "JsonSchema + different schema" `Quick
            test_request_json_schema_with_different_output_schema_uses_output_schema
        ] )
    ]
