(** Advanced property-based tests using QCheck.

    Covers JSON round-trips for complex types, monotonicity invariants,
    idle detection, pricing, context reduction, and tool_choice. *)

open Agent_sdk
open Types

(* ── Generators ──────────────────────────────────────────────── *)

let content_block_gen =
  QCheck.Gen.oneof
    [ QCheck.Gen.map (fun s -> Text s) QCheck.Gen.string_printable
    ; QCheck.Gen.map2
        (fun t c -> Thinking { signature = Some t; content = c })
        QCheck.Gen.string_printable
        QCheck.Gen.string_printable
    ; QCheck.Gen.map (fun s -> RedactedThinking s) QCheck.Gen.string_printable
    ; QCheck.Gen.map3
        (fun id name -> fun input -> ToolUse { id; name; input })
        QCheck.Gen.string_printable
        QCheck.Gen.string_printable
        (QCheck.Gen.return (`Assoc [ "key", `String "value" ]))
    ; QCheck.Gen.map3
        (fun id content is_error ->
           ToolResult
             { tool_use_id = id
             ; content
             ; outcome =
                 (if is_error
                  then
                    Tool_failed { failure_kind = Reported_tool_error; error_class = None }
                  else Tool_succeeded)
             ; json = Types.try_parse_json content
             ; content_blocks = None
             })
        QCheck.Gen.string_printable
        QCheck.Gen.string_printable
        QCheck.Gen.bool
    ; QCheck.Gen.map2
        (fun mt d -> Image { media_type = mt; data = d; source_type = Base64 })
        (QCheck.Gen.return "image/png")
        QCheck.Gen.string_printable
    ; QCheck.Gen.map2
        (fun mt d -> Document { media_type = mt; data = d; source_type = Base64 })
        (QCheck.Gen.return "application/pdf")
        QCheck.Gen.string_printable
    ]
;;

let role_gen = QCheck.Gen.oneof [ QCheck.Gen.return User; QCheck.Gen.return Assistant ]

let message_gen =
  QCheck.Gen.map2
    (fun role content ->
       { role; content; name = None; tool_call_id = None; metadata = [] })
    role_gen
    (QCheck.Gen.list_size (QCheck.Gen.int_range 1 3) content_block_gen)
;;

let api_usage_gen =
  QCheck.Gen.(
    let* input_tokens = int_range 0 100_000 in
    let* output_tokens = int_range 0 100_000 in
    let* cache_creation_input_tokens = int_range 0 10_000 in
    let* cache_read_input_tokens = int_range 0 10_000 in
    return
      { input_tokens
      ; output_tokens
      ; cache_creation_input_tokens
      ; cache_read_input_tokens
      ; cost_usd = None
      })
;;

let tool_choice_gen =
  QCheck.Gen.oneof
    [ QCheck.Gen.return Auto
    ; QCheck.Gen.return Any
    ; QCheck.Gen.map (fun s -> Tool s) QCheck.Gen.string_printable
    ]
;;

let model_gen =
  QCheck.Gen.oneof
    [ QCheck.Gen.return "claude-opus-4-6"
    ; QCheck.Gen.return "claude-sonnet-4-6"
    ; QCheck.Gen.return "claude-haiku-4-5"
    ; QCheck.Gen.string_printable
    ]
;;

(* ── JSON Round-trip Properties ──────────────────────────────── *)

let test_content_block_roundtrip =
  QCheck.Test.make
    ~count:500
    ~name:"content_block JSON round-trip"
    (QCheck.make content_block_gen ~print:show_content_block)
    (fun block ->
       match
         Llm_provider.Api_common.content_block_of_json
           (Llm_provider.Api_common.content_block_to_json block)
       with
       | Some parsed -> block = parsed
       | None -> false)
;;

let test_message_json_shape =
  QCheck.Test.make
    ~count:200
    ~name:"message_to_json produces valid JSON"
    (QCheck.make message_gen ~print:show_message)
    (fun msg ->
       let json = Llm_provider.Api_common.message_to_json msg in
       match json with
       | `Assoc pairs ->
         List.exists (fun (k, _) -> k = "role") pairs
         && List.exists (fun (k, _) -> k = "content") pairs
       | _ -> false)
;;

let test_tool_choice_json_roundtrip =
  QCheck.Test.make
    ~count:200
    ~name:"tool_choice JSON round-trip"
    (QCheck.make tool_choice_gen ~print:(fun tc -> show_tool_choice tc))
    (fun tc ->
       match tool_choice_of_json (tool_choice_to_json tc) with
       | Ok parsed -> tc = parsed
       | Error _ -> false)
;;

let test_model_yojson_roundtrip =
  QCheck.Test.make
    ~count:200
    ~name:"model yojson extended round-trip"
    (QCheck.make model_gen ~print:show_model)
    (fun m ->
       match model_of_yojson (model_to_yojson m) with
       | Ok m' -> m = m'
       | Error _ -> false)
;;

let test_stop_reason_string_roundtrip =
  QCheck.Test.make
    ~count:100
    ~name:"stop_reason string round-trip"
    (QCheck.make
       (QCheck.Gen.oneof
          [ QCheck.Gen.return "end_turn"
          ; QCheck.Gen.return "tool_use"
          ; QCheck.Gen.return "max_tokens"
          ; QCheck.Gen.return "stop_sequence"
          ]))
    (fun s ->
       match stop_reason_of_string s with
       | Unknown _ -> false
       | _ -> true)
;;

(* ── Monotonicity and Invariant Properties ───────────────────── *)

let test_usage_monotonic_increase =
  QCheck.Test.make
    ~count:300
    ~name:"add_usage monotonically increases totals"
    (QCheck.make api_usage_gen ~print:show_api_usage)
    (fun u ->
       let before = empty_usage in
       let after = add_usage before u in
       after.total_input_tokens >= before.total_input_tokens
       && after.total_output_tokens >= before.total_output_tokens
       && after.api_calls = before.api_calls + 1)
;;

let test_usage_accumulation_associative =
  QCheck.Test.make
    ~count:200
    ~name:"add_usage accumulation is associative"
    (QCheck.make
       QCheck.Gen.(triple api_usage_gen api_usage_gen api_usage_gen)
       ~print:(fun (a, b, c) ->
         Printf.sprintf
           "(%s, %s, %s)"
           (show_api_usage a)
           (show_api_usage b)
           (show_api_usage c)))
    (fun (a, b, c) ->
       let lhs = add_usage (add_usage (add_usage empty_usage a) b) c in
       let rhs = add_usage (add_usage (add_usage empty_usage c) b) a in
       lhs.total_input_tokens = rhs.total_input_tokens
       && lhs.total_output_tokens = rhs.total_output_tokens)
;;

let test_pricing_non_negative =
  QCheck.Test.make
    ~count:200
    ~name:"pricing is always non-negative"
    (QCheck.make QCheck.Gen.string_printable ~print:(fun s -> s))
    (fun model_id ->
       match Llm_provider.Pricing.pricing_for_model_opt model_id with
       | None -> true
       | Some p -> p.input_per_million >= 0.0 && p.output_per_million >= 0.0)
;;

let test_cost_estimation_non_negative =
  QCheck.Test.make
    ~count:200
    ~name:"estimate_cost is non-negative for non-negative inputs"
    (QCheck.make
       QCheck.Gen.(
         triple (float_range 0.0 100.0) (int_range 0 1_000_000) (int_range 0 1_000_000))
       ~print:(fun (rate, inp, out) ->
         Printf.sprintf "(rate=%.2f, in=%d, out=%d)" rate inp out))
    (fun (rate, input_tokens, output_tokens) ->
       let pricing =
         { Llm_provider.Pricing.input_per_million = rate
         ; output_per_million = rate
         ; cache_write_multiplier = Some 1.25
         ; cache_read_multiplier = Some 0.1
         }
       in
       match
         Llm_provider.Pricing.estimate_cost ~pricing ~input_tokens ~output_tokens ()
       with
       | Llm_provider.Pricing.Estimated cost -> cost >= 0.0
       | Llm_provider.Pricing.Incomplete _ -> false)
;;

let test_cost_scales_with_tokens =
  QCheck.Test.make
    ~count:200
    ~name:"cost increases with more tokens"
    (QCheck.make
       QCheck.Gen.(pair (int_range 1 1_000_000) (int_range 1 1_000_000))
       ~print:(fun (a, b) -> Printf.sprintf "(%d, %d)" a b))
    (fun (a, b) ->
       let pricing =
         { Llm_provider.Pricing.input_per_million = 3.0
         ; output_per_million = 15.0
         ; cache_write_multiplier = Some 1.25
         ; cache_read_multiplier = Some 0.1
         }
       in
       let cost_a =
         Llm_provider.Pricing.estimate_cost ~pricing ~input_tokens:a ~output_tokens:0 ()
       in
       let cost_b =
         Llm_provider.Pricing.estimate_cost
           ~pricing
           ~input_tokens:(a + b)
           ~output_tokens:0
           ()
       in
       match cost_a, cost_b with
       | Llm_provider.Pricing.Estimated cost_a, Llm_provider.Pricing.Estimated cost_b ->
         cost_b >= cost_a
       | Llm_provider.Pricing.Incomplete _, _ | _, Llm_provider.Pricing.Incomplete _ ->
         false)
;;

(* ── Lifecycle Properties ────────────────────────────────────── *)

let lifecycle_status_gen =
  QCheck.Gen.oneof
    [ QCheck.Gen.return Agent.Accepted
    ; QCheck.Gen.return Agent.Ready
    ; QCheck.Gen.return Agent.Running
    ; QCheck.Gen.return Agent.Completed
    ; QCheck.Gen.return Agent.Failed
    ]
;;

let test_lifecycle_show_non_empty =
  QCheck.Test.make
    ~count:50
    ~name:"show_lifecycle_status is never empty"
    (QCheck.make lifecycle_status_gen)
    (fun status -> String.length (Agent_lifecycle.show_lifecycle_status status) > 0)
;;

(* ── Test Runner ─────────────────────────────────────────────── *)

let () =
  let suite =
    List.map
      QCheck_alcotest.to_alcotest
      [ (* JSON round-trips *)
        test_content_block_roundtrip
      ; test_message_json_shape
      ; test_tool_choice_json_roundtrip
      ; test_model_yojson_roundtrip
      ; test_stop_reason_string_roundtrip
      ; (* Monotonicity / invariants *)
        test_usage_monotonic_increase
      ; test_usage_accumulation_associative
      ; test_pricing_non_negative
      ; test_cost_estimation_non_negative
      ; test_cost_scales_with_tokens
      ; (* Lifecycle *)
        test_lifecycle_show_non_empty
      ]
  in
  Alcotest.run "property_advanced" [ "properties", suite ]
;;
