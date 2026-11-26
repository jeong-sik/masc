type t = int [@@deriving show, eq]

let to_int (t : t) = t

type budget =
  { max_context_tokens : int
  ; reserved_output_tokens : int
  ; max_input_tokens : t
  }
[@@deriving show, eq]

type context_fit =
  { input_tokens : int
  ; reserved_output_tokens : int
  ; max_context_tokens : int
  }
[@@deriving show, eq]

type error =
  | Missing_context_window of { model_id : string }
  | Non_positive_context_window of
      { model_id : string
      ; max_context_tokens : int
      }
  | Missing_required_output_reservation of { model_id : string }
  | Output_reservation_exceeds_window of
      { model_id : string
      ; max_context_tokens : int
      ; reserved_output_tokens : int
      }
[@@deriving show, eq]

let error_to_string = function
  | Missing_context_window { model_id } ->
    Printf.sprintf "Input_budget: context window unknown for model %S" model_id
  | Non_positive_context_window { model_id; max_context_tokens } ->
    Printf.sprintf
      "Input_budget: non-positive context window %d for model %S"
      max_context_tokens
      model_id
  | Missing_required_output_reservation { model_id } ->
    Printf.sprintf
      "Input_budget: required output token reservation missing for model %S"
      model_id
  | Output_reservation_exceeds_window
      { model_id; max_context_tokens; reserved_output_tokens } ->
    Printf.sprintf
      "Input_budget: reserved output tokens %d >= context window %d for model %S"
      reserved_output_tokens
      max_context_tokens
      model_id
;;

type receipt_fit_error =
  | Receipt_budget_error of error
  | Receipt_context_exceeded of context_fit
[@@deriving show, eq]

(* The [None] arm is load-bearing (SSOT F6): catalog-silent ids under
   numeric providers (and the open operator set) reach their preset from
   here. Deleting or None-ing the presets without closing every such id
   first would turn these budgets into typed unknowns. *)
let capabilities_of_config (config : Provider_config.t) =
  match config.kind with
  | Provider_config.Anthropic
  | Provider_config.Kimi
  | Provider_config.OpenAI_compat
  | Provider_config.Ollama
  | Provider_config.Glm
  | Provider_config.Gemini ->
    (match Provider_config.capabilities_for_config_model config with
     | Some caps -> caps
     | None ->
       (match config.kind with
        | Provider_config.Ollama -> Capabilities.ollama_capabilities
        | Provider_config.Kimi -> Capabilities.kimi_capabilities
        | Provider_config.Glm -> Capabilities.glm_capabilities
        | Provider_config.Gemini -> Capabilities.gemini_capabilities
        | Provider_config.Anthropic -> Capabilities.anthropic_capabilities
        | Provider_config.OpenAI_compat -> Capabilities.openai_compat_chat_capabilities))
;;

let output_token_ceiling (config : Provider_config.t) =
  (* [model_capabilities_override] is the typed declaration boundary documented
     by [Provider_config.t]: it includes caller declarations and
     provider/runtime catalog binding declarations.  It is intentionally
     distinct from the model catalog lookup below. *)
  match config.model_capabilities_override with
  | Some caps ->
    Option.map
      (fun value ->
         Types.output_token_ceiling ~value ~source:Types.Declared_capability_override)
      caps.max_output_tokens
  | None ->
    let caps, source =
      match Provider_config.capabilities_for_config_model config with
      | Some caps -> caps, Types.Catalog_model
      | None -> capabilities_of_config config, Types.Provider_default
    in
    Option.map
      (fun value -> Types.output_token_ceiling ~value ~source)
      caps.max_output_tokens
;;

let output_token_envelope (config : Provider_config.t) =
  Provider_http_codec.of_config config |> Provider_http_codec.output_token_envelope
;;

let optional_output_token_receipt ~envelope (config : Provider_config.t) =
  Types.optional_output_token_receipt
    ~envelope
    ~requested:config.max_tokens
    ~ceiling:(output_token_ceiling config)
;;

let envelope_is_required = function
  | Types.Anthropic_messages_max_tokens -> true
  | Types.Openai_chat_max_tokens
  | Types.Openai_responses_max_output_tokens
  | Types.Gemini_generation_config_max_output_tokens
  | Types.Ollama_options_num_predict -> false
;;

let resolve_output_token_receipt ?envelope (config : Provider_config.t) =
  let envelope =
    match envelope with
    | Some env -> env
    | None -> output_token_envelope config
  in
  let receipt = optional_output_token_receipt ~envelope config in
  if envelope_is_required envelope
  then Types.required_output_token_receipt receipt
  else Ok receipt
;;

let resolve_context_limit (config : Provider_config.t) =
  match Provider_config.context_window config with
  | None -> Error (Missing_context_window { model_id = config.model_id })
  | Some max_context_tokens when max_context_tokens <= 0 ->
    Error
      (Non_positive_context_window { model_id = config.model_id; max_context_tokens })
  | Some max_context_tokens -> Ok max_context_tokens
;;

let reserved_output_tokens_of_receipt ~model_id receipt =
  match Types.output_token_receipt_effective receipt with
  | Some reserved_output_tokens when reserved_output_tokens >= 0 ->
    Ok reserved_output_tokens
  | Some _ | None ->
    (match Types.output_token_receipt_policy receipt with
     | Types.Omitted ->
       if envelope_is_required (Types.output_token_receipt_envelope receipt)
       then Error (Missing_required_output_reservation { model_id })
       else Ok 0
     | Types.Explicit
     | Types.Explicit_clamped
     | Types.Required_catalog_fallback
     | Types.Required_capability_override_fallback ->
       Error (Missing_required_output_reservation { model_id }))
;;

let budget_of_parts ~model_id ~max_context_tokens receipt =
  if max_context_tokens <= 0
  then Error (Non_positive_context_window { model_id; max_context_tokens })
  else (
    match reserved_output_tokens_of_receipt ~model_id receipt with
    | Error _ as err -> err
    | Ok reserved_output_tokens ->
      if reserved_output_tokens >= max_context_tokens
      then
        Error
          (Output_reservation_exceeds_window
             { model_id; max_context_tokens; reserved_output_tokens })
      else
        Ok
          { max_context_tokens
          ; reserved_output_tokens
          ; max_input_tokens = max_context_tokens - reserved_output_tokens
          })
;;

let resolve (config : Provider_config.t) =
  let ( let* ) = Result.bind in
  let* max_context_tokens = resolve_context_limit config in
  let* receipt =
    resolve_output_token_receipt config
    |> Result.map_error (function
      | Types.Required_output_token_ceiling_missing ->
        Missing_required_output_reservation { model_id = config.model_id })
  in
  budget_of_parts ~model_id:config.model_id ~max_context_tokens receipt
;;

let of_provider_config config =
  Result.map (fun b -> b.max_input_tokens) (resolve config)
;;

let of_agent_window ~model_id ~max_context_tokens =
  if max_context_tokens > 0
  then Ok max_context_tokens
  else Error (Non_positive_context_window { model_id; max_context_tokens })
;;

let admits (t : t) ~input_tokens = input_tokens >= 0 && input_tokens <= t

let admit_receipt ?(model_id = "") ~max_context_tokens ~input_tokens receipt =
  match budget_of_parts ~model_id ~max_context_tokens receipt with
  | Ok budget ->
    let fit =
      { input_tokens
      ; reserved_output_tokens = budget.reserved_output_tokens
      ; max_context_tokens = budget.max_context_tokens
      }
    in
    if admits budget.max_input_tokens ~input_tokens
    then Ok fit
    else Error (Receipt_context_exceeded fit)
  | Error (Output_reservation_exceeds_window { max_context_tokens; reserved_output_tokens; _ })
    ->
    Error
      (Receipt_context_exceeded
         { input_tokens; reserved_output_tokens; max_context_tokens })
  | Error
      (( Missing_context_window _
       | Non_positive_context_window _
       | Missing_required_output_reservation _ ) as err) ->
    Error (Receipt_budget_error err)
;;

[@@@coverage off]

let%test "of_provider_config derives Anthropic budget from catalog ceiling" =
  let caps =
    { Capabilities.anthropic_capabilities with
      max_context_tokens = Some 200_000
    ; max_output_tokens = Some 8_192
    }
  in
  let config =
    Provider_config.make
      ~kind:Provider_config.Anthropic
      ~model_id:"claude-sonnet"
      ~base_url:"https://api.anthropic.com"
      ~model_capabilities_override:caps
      ()
  in
  match resolve config, of_provider_config config with
  | Ok budget, Ok limit ->
    budget.max_context_tokens = 200_000
    && budget.reserved_output_tokens = 8_192
    && to_int limit = 191_808
    && (limit :> int) = 191_808
    && admits limit ~input_tokens:191_808
    && not (admits limit ~input_tokens:191_809)
  | (Ok _ | Error _), (Ok _ | Error _) -> false
;;

let%test "of_provider_config reserves 0 when optional envelope omits max_tokens" =
  let caps =
    { Capabilities.openai_compat_chat_capabilities with
      max_context_tokens = Some 400_000
    ; max_output_tokens = Some 128_000
    }
  in
  let config =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"gpt-5.4"
      ~base_url:"https://api.example.test"
      ~model_capabilities_override:caps
      ()
  in
  match resolve config with
  | Ok budget ->
    budget.max_context_tokens = 400_000
    && budget.reserved_output_tokens = 0
    && to_int budget.max_input_tokens = 400_000
  | Error _ -> false
;;

let%test "of_provider_config clamps OpenAI explicit max_tokens and tracks #53504 arithmetic" =
  let caps =
    { Capabilities.openai_compat_chat_capabilities with
      max_context_tokens = Some 400_000
    ; max_output_tokens = Some 128_000
    }
  in
  let config =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"gpt-5.4"
      ~base_url:"https://api.example.test"
      ~max_tokens:128_000
      ~model_capabilities_override:caps
      ()
  in
  match of_provider_config config with
  | Ok limit -> (limit :> int) = 272_000
  | Error _ -> false
;;

let%test "of_provider_config rejects reserved >= window and invalid windows" =
  let eq_window_caps =
    { Capabilities.openai_compat_chat_capabilities with
      max_context_tokens = Some 1_000
    ; max_output_tokens = Some 2_000
    }
  in
  let eq_cfg =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"eq-win"
      ~base_url:"https://api.example.test"
      ~max_tokens:1_000
      ~model_capabilities_override:eq_window_caps
      ()
  in
  let no_ctx =
    Provider_config.make
      ~kind:Provider_config.Anthropic
      ~model_id:"unknown-ctx"
      ~base_url:"https://api.anthropic.com"
      ~max_tokens:1024
      ()
  in
  let zero_ctx =
    Provider_config.make
      ~kind:Provider_config.Anthropic
      ~model_id:"zero-ctx"
      ~base_url:"https://api.anthropic.com"
      ~max_context:0
      ~max_tokens:1024
      ()
  in
  let same = Result.equal ~ok:equal ~error:equal_error in
  same
    (of_provider_config eq_cfg)
    (Error
       (Output_reservation_exceeds_window
          { model_id = "eq-win"
          ; max_context_tokens = 1_000
          ; reserved_output_tokens = 1_000
          }))
  && same
       (of_provider_config no_ctx)
       (Error (Missing_context_window { model_id = "unknown-ctx" }))
  && same
       (of_provider_config zero_ctx)
       (Error
          (Non_positive_context_window { model_id = "zero-ctx"; max_context_tokens = 0 }))
;;
