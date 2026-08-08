(** Catalog-backed cost observation.

    Pricing is declared exclusively by {!Model_catalog}.  This module does not
    infer provider identity from a model ID, strip namespaces, maintain a
    fallback table, or treat an unknown model as free. *)

type pricing =
  { input_per_million : float
  ; output_per_million : float
  ; cache_write_multiplier : float option
  ; cache_read_multiplier : float option
  }

type cache_price_component =
  | Cache_creation
  | Cache_read

type cost_estimate =
  | Estimated of float
  | Incomplete of cache_price_component list

let pricing_of_catalog_entry (entry : Model_catalog.model_entry) =
  match entry.input_per_million, entry.output_per_million with
  | Some input_per_million, Some output_per_million ->
    Some
      { input_per_million
      ; output_per_million
      ; cache_write_multiplier = entry.cache_write_multiplier
      ; cache_read_multiplier = entry.cache_read_multiplier
      }
  | None, _ | _, None -> None
;;

let catalog_entry_for_model catalog ?provider_id model_id =
  match provider_id with
  | None -> Model_catalog.lookup catalog model_id
  | Some provider_id ->
    (match
       Model_catalog.lookup_for_provider catalog ~provider_name:provider_id ~model_id
     with
     | Some _ as exact -> exact
     | None -> Model_catalog.lookup catalog model_id)
;;

let pricing_for_model_opt ?provider_id model_id =
  match Model_catalog.global () with
  | None -> None
  | Some catalog ->
    Option.bind
      (catalog_entry_for_model catalog ?provider_id model_id)
      pricing_of_catalog_entry
;;

let estimate_cost
      ~(pricing : pricing)
      ~input_tokens
      ~output_tokens
      ?(cache_creation_input_tokens = 0)
      ?(cache_read_input_tokens = 0)
      ()
  =
  let regular_input =
    max 0 (input_tokens - cache_creation_input_tokens - cache_read_input_tokens)
  in
  let missing_cache_components =
    let creation =
      if cache_creation_input_tokens > 0 && Option.is_none pricing.cache_write_multiplier
      then [ Cache_creation ]
      else []
    in
    let read =
      if cache_read_input_tokens > 0 && Option.is_none pricing.cache_read_multiplier
      then [ Cache_read ]
      else []
    in
    creation @ read
  in
  match missing_cache_components with
  | _ :: _ as missing -> Incomplete missing
  | [] ->
    let rate = pricing.input_per_million /. 1_000_000.0 in
    let input_cost = Float.of_int regular_input *. rate in
    let cache_cost token_count = function
      | Some multiplier -> Float.of_int token_count *. rate *. multiplier
      | None -> 0.0
    in
    let cache_write_cost =
      cache_cost cache_creation_input_tokens pricing.cache_write_multiplier
    in
    let cache_read_cost =
      cache_cost cache_read_input_tokens pricing.cache_read_multiplier
    in
    let output_cost =
      Float.of_int output_tokens *. pricing.output_per_million /. 1_000_000.0
    in
    Estimated (input_cost +. cache_write_cost +. cache_read_cost +. output_cost)
;;

let annotate_usage_cost ?provider_id ~model_id (usage : Types.api_usage) =
  match usage.cost_usd with
  | Some _ -> usage
  | None ->
    (match pricing_for_model_opt ?provider_id model_id with
     | None -> usage
     | Some pricing ->
       (match
          estimate_cost
            ~pricing
            ~input_tokens:usage.input_tokens
            ~output_tokens:usage.output_tokens
            ~cache_creation_input_tokens:usage.cache_creation_input_tokens
            ~cache_read_input_tokens:usage.cache_read_input_tokens
            ()
        with
        | Estimated cost_usd -> { usage with cost_usd = Some cost_usd }
        | Incomplete _ -> usage))
;;

let annotate_response_cost ?provider_id (response : Types.api_response) =
  match response.usage with
  | None -> response
  | Some usage ->
    { response with
      usage = Some (annotate_usage_cost ?provider_id ~model_id:response.model usage)
    }
;;

[@@@coverage off]

let close_enough a b = Float.abs (a -. b) < 1e-9

let option_close_enough expected = function
  | Some actual -> close_enough expected actual
  | None -> false
;;

let test_catalog_entry ?provider_name ?input ?output ?cache_write ?cache_read id_prefix =
  { Model_catalog.id_prefix
  ; base_label = None
  ; provider_name
  ; max_context_tokens = None
  ; serving_constraint = None
  ; max_output_tokens = None
  ; supports_tools = None
  ; supports_tool_choice = None
  ; supports_required_tool_choice = None
  ; supports_named_tool_choice = None
  ; supports_parallel_tool_calls = None
  ; assistant_tool_content_format = None
  ; supports_reasoning = None
  ; supports_extended_thinking = None
  ; supports_reasoning_budget = None
  ; accepted_reasoning_efforts = None
  ; supports_response_format_json = None
  ; supports_structured_output = None
  ; supports_multimodal_inputs = None
  ; supports_image_input = None
  ; supports_audio_input = None
  ; supports_video_input = None
  ; supports_document_input = None
  ; modality_priority = None
  ; task = None
  ; supported_models = None
  ; supports_native_streaming = None
  ; supports_system_prompt = None
  ; supports_caching = None
  ; supports_prompt_caching = None
  ; supports_top_k = None
  ; supports_min_p = None
  ; supports_seed = None
  ; ignored_sampling_parameters = None
  ; supports_computer_use = None
  ; supports_code_execution = None
  ; thinking_control_format = None
  ; anthropic_thinking_control = None
  ; preserve_thinking_control_format = None
  ; reasoning_output_format = None
  ; reasoning_streaming_format = None
  ; reasoning_replay = None
  ; input_per_million = input
  ; output_per_million = output
  ; cache_write_multiplier = cache_write
  ; cache_read_multiplier = cache_read
  }
;;

let with_catalog entries f =
  let original = Model_catalog.global () in
  Model_catalog.set_global (Model_catalog.of_model_entries entries);
  Fun.protect
    ~finally:(fun () ->
      match original with
      | Some catalog -> Model_catalog.set_global catalog
      | None -> Model_catalog.clear_global ())
    f
;;

let%test "catalog-declared pricing is returned" =
  with_catalog
    [ test_catalog_entry
        ~input:3.0
        ~output:15.0
        ~cache_write:1.25
        ~cache_read:0.1
        "declared-model"
    ]
    (fun () ->
       match pricing_for_model_opt "declared-model" with
       | None -> false
       | Some pricing ->
         close_enough pricing.input_per_million 3.0
         && close_enough pricing.output_per_million 15.0
         && option_close_enough 1.25 pricing.cache_write_multiplier
         && option_close_enough 0.1 pricing.cache_read_multiplier)
;;

let%test "catalog miss remains absent" =
  with_catalog
    [ test_catalog_entry ~input:1.0 ~output:2.0 "declared-model" ]
    (fun () -> pricing_for_model_opt "unknown-model" = None)
;;

let%test "partial catalog pricing remains absent" =
  with_catalog
    [ test_catalog_entry ~input:1.0 "partial-model" ]
    (fun () -> pricing_for_model_opt "partial-model" = None)
;;

let%test "catalog pricing preserves absent cache multipliers" =
  with_catalog
    [ test_catalog_entry ~input:1.0 ~output:2.0 "partial-cache-pricing" ]
    (fun () ->
       match pricing_for_model_opt "partial-cache-pricing" with
       | Some
           { input_per_million = 1.0
           ; output_per_million = 2.0
           ; cache_write_multiplier = None
           ; cache_read_multiplier = None
           } -> true
       | Some _ | None -> false)
;;

let%test "exact provider pricing precedes provider-independent pricing" =
  with_catalog
    [ test_catalog_entry
        ~input:9.0
        ~output:90.0
        ~cache_write:1.0
        ~cache_read:1.0
        "shared-model"
    ; test_catalog_entry
        ~provider_name:"deepseek"
        ~input:1.0
        ~output:2.0
        ~cache_write:1.0
        ~cache_read:0.1
        "shared-model"
    ]
    (fun () ->
       match
         ( pricing_for_model_opt "shared-model"
         , pricing_for_model_opt ~provider_id:"deepseek" "shared-model" )
       with
       | Some generic, Some exact ->
         close_enough generic.input_per_million 9.0
         && close_enough exact.input_per_million 1.0
       | None, _ | _, None -> false)
;;

let%test "an exact incomplete provider row does not fall through to generic pricing" =
  with_catalog
    [ test_catalog_entry
        ~input:9.0
        ~output:90.0
        ~cache_write:1.0
        ~cache_read:1.0
        "shared-model"
    ; test_catalog_entry ~provider_name:"ollama_cloud" ~input:0.0 "shared-model"
    ]
    (fun () -> pricing_for_model_opt ~provider_id:"ollama_cloud" "shared-model" = None)
;;

let%test "unknown provider can use provider-independent pricing" =
  with_catalog
    [ test_catalog_entry
        ~input:9.0
        ~output:90.0
        ~cache_write:1.0
        ~cache_read:1.0
        "shared-model"
    ]
    (fun () ->
       match pricing_for_model_opt ~provider_id:"unknown" "shared-model" with
       | Some pricing -> close_enough pricing.input_per_million 9.0
       | None -> false)
;;

let%test "explicit catalog zero is distinguishable from absence" =
  with_catalog
    [ test_catalog_entry
        ~input:0.0
        ~output:0.0
        ~cache_write:1.0
        ~cache_read:1.0
        "declared-free-model"
    ]
    (fun () ->
       match pricing_for_model_opt "declared-free-model" with
       | Some pricing ->
         close_enough pricing.input_per_million 0.0
         && close_enough pricing.output_per_million 0.0
       | None -> false)
;;

let%test "estimate_cost uses declared rates" =
  let pricing =
    { input_per_million = 3.0
    ; output_per_million = 15.0
    ; cache_write_multiplier = Some 1.25
    ; cache_read_multiplier = Some 0.1
    }
  in
  match estimate_cost ~pricing ~input_tokens:1_000_000 ~output_tokens:100_000 () with
  | Estimated cost -> close_enough cost 4.5
  | Incomplete _ -> false
;;

let%test "absent cache prices do not block a non-cache estimate" =
  let pricing =
    { input_per_million = 3.0
    ; output_per_million = 15.0
    ; cache_write_multiplier = None
    ; cache_read_multiplier = None
    }
  in
  match estimate_cost ~pricing ~input_tokens:1_000_000 ~output_tokens:100_000 () with
  | Estimated cost -> close_enough cost 4.5
  | Incomplete _ -> false
;;

let%test "observed cache tokens expose every missing cache price" =
  let pricing =
    { input_per_million = 3.0
    ; output_per_million = 15.0
    ; cache_write_multiplier = None
    ; cache_read_multiplier = None
    }
  in
  match
    estimate_cost
      ~pricing
      ~input_tokens:100
      ~output_tokens:10
      ~cache_creation_input_tokens:20
      ~cache_read_input_tokens:30
      ()
  with
  | Incomplete [ Cache_creation; Cache_read ] -> true
  | Estimated _ | Incomplete _ -> false
;;

[@@@coverage on]
