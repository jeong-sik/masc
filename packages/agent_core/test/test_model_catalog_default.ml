open Alcotest
module Capabilities = Llm_provider.Capabilities
module Capability_vocab = Llm_provider.Capability_vocab
module Model_catalog = Llm_provider.Model_catalog
module Serving_constraint = Llm_provider.Serving_constraint

let first_id_prefix ~suite catalog =
  match Model_catalog.model_entries catalog with
  | [] -> failf "%s: repo model catalog should not be empty" suite
  | (entry : Model_catalog.model_entry) :: _ -> entry.id_prefix
;;

let with_clean_model_catalog_override f =
  Model_catalog.clear_global ();
  Fun.protect ~finally:Model_catalog.clear_global f
;;

(* Model ids masc declares in runtime.toml for the Claude Code, Codex and
   Antigravity subscriptions. [Model_catalog.lookup] is a longest-prefix match,
   so a missing row fails in one of two silent ways: an id that no row prefixes
   resolves to [None] and [Runtime] disables that runtime at boot, while an id
   that only a *shorter* row prefixes inherits that row's capabilities with no
   error. Asserting the resolved [id_prefix] — rather than merely that the
   lookup succeeded — is what separates "gpt-5.6-sol found its own row" from
   "gpt-5.6-sol silently landed on gpt-5". *)
let subscription_model_rows =
  [ "claude-opus-5", "claude-opus-5"
  ; "claude-fable-5", "claude-fable-5"
    (* Fable 5.1 needs a row of its own even though "claude-fable-5" prefixes
       it: 5.1 reads cached tokens at 0.025x the base input price and 5 reads
       them at 0.1x. Landing 5.1 on the shorter row would bill its cache reads
       at four times the real rate, which no lookup failure would announce. *)
  ; "claude-fable-5-1", "claude-fable-5-1"
  ; "claude-sonnet-5", "claude-sonnet-5"
  ; "gpt-5.6-sol", "gpt-5.6-sol"
  ; "gpt-5.6-terra", "gpt-5.6-terra"
  ; "gpt-5.6-luna", "gpt-5.6"
  ; "gpt-5.3-codex-spark", "gpt-5.3-codex-spark"
  ; "gemini-3.7-flash-high", "gemini-3.7-flash"
  ; "gemini-3.7-flash-medium", "gemini-3.7-flash"
  ; "gemini-3.7-flash-low", "gemini-3.7-flash"
  ; "gemini-3.6-flash-high", "gemini-3.6-flash"
  ; "gemini-3.6-flash-medium", "gemini-3.6-flash"
  ; "gemini-3.6-flash-low", "gemini-3.6-flash"
  ; "gemini-3.5-flash-high", "gemini-3.5-flash"
  ; "gemini-3.1-pro-high", "gemini-3.1-pro"
  ; "gpt-oss-120b-medium", "gpt-oss-120b"
  ]
;;

let test_subscription_models_resolve_their_own_rows () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog ~suite:"subscription model rows"
  in
  List.iter
    (fun (model_id, expected_prefix) ->
       match Model_catalog.lookup catalog model_id with
       | None ->
         failf
           "%s resolves to no catalog row; Runtime disables uncatalogued runtimes at boot"
           model_id
       | Some (entry : Model_catalog.model_entry) ->
         check
           string
           (Printf.sprintf "%s resolves to its own row" model_id)
           expected_prefix
           entry.id_prefix)
    subscription_model_rows
;;

(* The effort ladders are written out as literals rather than read back from the
   row under test: a comparison that sources both sides from the catalog passes
   whatever the catalog happens to say, including a row that admits nothing. *)
let subscription_model_efforts =
  [ None, "claude-opus-5", [ "low"; "medium"; "high"; "xhigh"; "max" ]
    (* Probed on /v1/responses 2026-09-07: sol, terra and luna each answer 400
       for "minimal" -- the message names the model -- and 200 for none, low,
       medium, high, xhigh and max. The list this replaces came from the
       2026-06-29 gpt-5.1 reference and was wrong at both ends. These observations
       belong to the Responses provider, not the separate bare model rows. *)
  ; Some "openai-responses", "gpt-5.6-sol", [ "none"; "low"; "medium"; "high"; "xhigh"; "max" ]
  ; Some "openai-responses", "gpt-5.6-terra", [ "none"; "low"; "medium"; "high"; "xhigh"; "max" ]
  ; Some "openai-responses", "gpt-5.6-luna", [ "none"; "low"; "medium"; "high"; "xhigh"; "max" ]
  ; None, "gpt-5.3-codex-spark", [ "none"; "minimal"; "low"; "medium"; "high"; "xhigh" ]
  ; None, "gemini-3.7-flash-high", [ "low"; "medium"; "high" ]
  ; None, "gemini-3.6-flash-high", [ "minimal"; "low"; "medium"; "high" ]
  ]
;;

let test_subscription_models_admit_their_reasoning_efforts () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog
      ~suite:"subscription model efforts"
  in
  List.iter
    (fun (provider_name, model_id, expected) ->
       let entry =
         match provider_name with
         | None -> Model_catalog.lookup catalog model_id
         | Some provider_name -> Model_catalog.lookup_for_provider catalog ~provider_name ~model_id
       in
       match entry with
       | None -> failf "%s resolves to no catalog row" model_id
       | Some (entry : Model_catalog.model_entry) ->
         check
           (option (list string))
           (Printf.sprintf "%s admits its declared reasoning efforts" model_id)
           (Some expected)
           entry.accepted_reasoning_efforts)
    subscription_model_efforts
;;

(* Cache pricing the fleet's Anthropic rows have to carry: [Pricing.estimate_cost]
   returns [Incomplete] when a usage record reports cache tokens the row prices
   with no multiplier, and [annotate_usage_cost] then leaves [cost_usd] at None.
   A row that prices only input and output therefore records no cost at all for
   a cached turn, which is every turn once a system prompt is cached.

   The list covers the Anthropic models masc runs. The Mythos rows are left out
   because they are not part of that set; they carry the same gap, and Mythos
   5.1 shares Fable 5.1's 0.025x cache read, so a row of its own comes with
   whichever change starts running them. *)
let anthropic_cache_pricing_rows =
  [ "claude-opus-5", 1.25, 0.1
  ; "claude-sonnet-5", 1.25, 0.1
  ; "claude-fable-5", 1.25, 0.1
  ; "claude-fable-5-1", 1.25, 0.025
  ]
;;

let test_anthropic_rows_price_cache_tokens () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog ~suite:"anthropic cache pricing"
  in
  List.iter
    (fun (model_id, expected_write, expected_read) ->
       match Model_catalog.lookup catalog model_id with
       | None -> failf "%s resolves to no catalog row" model_id
       | Some (entry : Model_catalog.model_entry) ->
         check
           (option (float 0.0001))
           (Printf.sprintf "%s prices cache writes" model_id)
           (Some expected_write)
           entry.cache_write_multiplier;
         check
           (option (float 0.0001))
           (Printf.sprintf "%s prices cache reads" model_id)
           (Some expected_read)
           entry.cache_read_multiplier)
    anthropic_cache_pricing_rows
;;

let test_load_default_catalog () =
  let expected =
    Model_catalog_test_support.load_repo_model_catalog ~suite:"model catalog default"
  in
  match Model_catalog.load_default () with
  | Error msg -> failf "default model catalog should load: %s" msg
  | Ok catalog ->
    check
      bool
      "embedded default is exactly the AGENT_CORE models.toml catalog"
      true
      (Model_catalog.model_entries expected = Model_catalog.model_entries catalog
       && Model_catalog.provider_entries expected = Model_catalog.provider_entries catalog
      )
;;

let test_ollama_cloud_v1_vendor_rows_preserve_probe_truth () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog
      ~suite:"Ollama Cloud v1 vendor rows"
  in
  let entries = Model_catalog.model_entries catalog in
  List.iter
    (fun model_id ->
       let matches =
         List.filter
           (fun (entry : Model_catalog.model_entry) ->
              entry.id_prefix = model_id && entry.provider_name = Some "ollama_cloud")
           entries
       in
       match matches with
       | [ entry ] ->
         check
           (option string)
           (model_id ^ " capability base")
           (Some "ollama_cloud")
           entry.base_label;
         check
           (option int)
           (model_id ^ " context")
           (Some 262_144)
           entry.max_context_tokens;
         check (option bool) (model_id ^ " tools") (Some true) entry.supports_tools;
         check
           (option bool)
           (model_id ^ " reasoning")
           (Some true)
           entry.supports_reasoning;
         (* The row states no thinking control of its own. It used to, and the
            value it stated was a wire: ollama_cloud is reachable over both
            the native /api/chat and the OpenAI-compatible /v1, and a row
            cannot know which one a deployment points it at. The wire now
            selects the base at resolution time, so an undeclared field here
            is the row saying the right thing rather than staying silent. *)
         check
           bool
           (model_id ^ " leaves the thinking control to the wire")
           true
           (entry.thinking_control_format = None);
         check
           (option bool)
           (model_id ^ " json mode")
           (Some true)
           entry.supports_response_format_json;
         check
           (option bool)
           (model_id ^ " no native schema guarantee")
           (Some false)
           entry.supports_structured_output;
         check
           (option bool)
           (model_id ^ " image input")
           (Some true)
           entry.supports_image_input;
         check
           (option bool)
           (model_id ^ " native streaming")
           (Some true)
           entry.supports_native_streaming
       | [] -> failf "missing ollama_cloud/%s catalog row" model_id
       | _ -> failf "duplicate ollama_cloud/%s catalog rows" model_id)
    [ "qwen3.5:cloud"; "gemma4:31b-cloud" ]
;;

(* No ollama_cloud row states a thinking control of its own.

   The value such a row would state is a wire, and this provider is reachable
   over two ([[providers]] identity_kinds = ["ollama", "openai_compat"]). A row
   cannot know which one a deployment points it at, so a row that states one is
   guessing, and the guess is wrong for every deployment on the other wire.
   [capabilities_base_by_identity_kind] answers instead, at resolution time.

   Before that existed the same declaration was edited five times in five
   weeks, each edit correct for the row it touched and each leaving the class
   open — 17 rows saying ollama_think (unencodable on /v1) and 8 hand-corrected
   to "none" (which claims a control does not exist when one does). This is the
   ratchet against that returning: adding a row is fine, adding a wire to a row
   is not.

   Rows that declare supports_reasoning = false keep their own declaration. A
   model that does not reason has no control on either wire, so nothing about
   the wire is being guessed (RFC-one-provider-two-wires §5). *)
let test_no_ollama_cloud_row_states_a_wire () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog
      ~suite:"Ollama Cloud rows leave the wire to the provider"
  in
  let offenders =
    Model_catalog.model_entries catalog
    |> List.filter (fun (entry : Model_catalog.model_entry) ->
      match entry.provider_name with
      | Some "ollama_cloud" ->
        entry.supports_reasoning = Some true
        && Option.is_some entry.thinking_control_format
      | Some _ | None -> false)
    |> List.map (fun (entry : Model_catalog.model_entry) -> entry.id_prefix)
    |> List.sort String.compare
  in
  check
    (list string)
    "no reasoning-capable ollama_cloud row states a thinking control"
    []
    offenders
;;

let test_in_memory_catalog_rejects_invalid_generated_input () =
  match
    Model_catalog.of_toml_string
      ~source:"invalid embedded candidate"
      "[[models]]\nid_prefix = \"broken\"\nsupports_tools = \"yes\""
  with
  | Error msg ->
    check
      string
      "invalid field is diagnosed"
      "model entry \"broken\" field \"supports_tools\" expected bool"
      msg
  | Ok _ -> fail "invalid in-memory catalog must fail validation"
;;

let test_global_loads_default_catalog_for_capabilities () =
  let expected =
    Model_catalog_test_support.load_repo_model_catalog
      ~suite:"model catalog default production path"
  in
  let model_id =
    first_id_prefix ~suite:"model catalog default production path" expected
  in
  with_clean_model_catalog_override (fun () ->
    match Capabilities.for_model_id_catalog model_id with
    | Some _ -> ()
    | None ->
      failf
        "Capabilities.for_model_id_catalog should resolve %S through embedded/default \
         Model_catalog.global"
        model_id)
;;

let constraint_catalog ?expires_at ?rejected_from () =
  Printf.sprintf
    "[[models]]\n\
     id_prefix = \"evidence-model\"\n\
     provider_name = \"evidence-runtime\"\n\
     max_context_tokens = 1048576\n\
     serving_constraint_source_kind = \"probe\"\n\
     serving_constraint_source = \"probe://incident/2793\"\n\
     serving_constraint_checked_at_unix_s = 100\n\
     serving_constraint_confidence = \"high\"\n\
     %sserving_constraint_accepted_through_tokens = 524298\n\
     %s"
    (Option.fold
       ~none:""
       ~some:(Printf.sprintf "serving_constraint_expires_at_unix_s = %d\n")
       expires_at)
    (Option.fold
       ~none:""
       ~some:(Printf.sprintf "serving_constraint_rejected_from_tokens = %d\n")
       rejected_from)
;;

let parsed_constraint toml =
  match Model_catalog.of_toml_string ~source:"serving constraint fixture" toml with
  | Error message -> fail message
  | Ok catalog ->
    (match Model_catalog.model_entries catalog with
     | [ { Model_catalog.serving_constraint = Some constraint_; _ } ] -> constraint_
     | _ -> fail "expected exactly one model with one serving constraint")
;;

let test_serving_constraint_projects_exact_interval () =
  let constraint_ =
    parsed_constraint (constraint_catalog ~expires_at:200 ~rejected_from:524299 ())
  in
  check
    bool
    "accepted observation is admitted"
    true
    (Serving_constraint.admit ~now_unix_s:150 ~input_tokens:524298 constraint_ = Ok ());
  match Serving_constraint.admit ~now_unix_s:150 ~input_tokens:524299 constraint_ with
  | Error
      (Serving_constraint.Input_rejected
         { input_tokens = 524299; accepted_through = 524298; rejected_from = 524299 }) ->
    ()
  | Ok () | Error _ -> fail "rejected observation did not remain exact"
;;

let test_serving_constraint_stale_evidence_fails_closed () =
  let constraint_ =
    parsed_constraint (constraint_catalog ~expires_at:200 ~rejected_from:524299 ())
  in
  match Serving_constraint.check_evidence ~now_unix_s:200 constraint_ with
  | Error
      (Serving_constraint.Evidence_expired { now_unix_s = 200; expires_at_unix_s = 200 })
    -> ()
  | Ok () | Error _ -> fail "expired serving evidence was accepted"
;;

let test_probe_serving_constraint_requires_expiry () =
  match
    Serving_constraint.make
      ~source_kind:Serving_constraint.Probe
      ~source_ref:"probe://incident/2793"
      ~checked_at_unix_s:100
      ~confidence:Serving_constraint.Medium
      ~accepted_through:524298
      ~rejected_from:524299
      ()
  with
  | Error Serving_constraint.Missing_probe_expiry -> ()
  | Error _ | Ok _ -> fail "probe evidence without explicit expiry was accepted"
;;

let test_catalog_only_runtime_projects_serving_constraint () =
  let catalog =
    Model_catalog.of_toml_string
      ~source:"catalog-only serving constraint fixture"
      (constraint_catalog ~expires_at:200 ~rejected_from:524299 ())
    |> Result.get_ok
  in
  with_clean_model_catalog_override (fun () ->
    Model_catalog.set_global catalog;
    match
      Capabilities.for_provider_model_id
        ~wire:None
        ~allow_bare_fallback:false
        ~provider_label:"evidence-runtime"
        ~model_id:"evidence-model"
    with
    | Some { Capabilities.serving_constraint = Some constraint_; _ } ->
      check
        int
        "resolved runtime preserves observed acceptance"
        524298
        constraint_.Serving_constraint.observation.accepted_through
    | Some _ | None -> fail "catalog-only normal runtime lost its serving constraint")
;;

let test_serving_constraint_partial_group_fails_closed () =
  match
    Model_catalog.of_toml_string
      ~source:"partial serving constraint fixture"
      "[[models]]\n\
       id_prefix = \"partial-evidence\"\n\
       serving_constraint_source_kind = \"probe\"\n\
       serving_constraint_accepted_through_tokens = 524298\n"
  with
  | Error message ->
    check
      bool
      "diagnostic identifies the grouped declaration"
      true
      (String.starts_with ~prefix:"model entry \"partial-evidence\"" message)
  | Ok _ -> fail "partial serving-constraint declaration must fail closed"
;;

(* keeper_analyze_image on glm-coding.glm-4.6v died on HTTP 400 code 1210
   ("The max_tokens parameter is illegal. [1,32768]") at 2026-09-07T15:24:58Z:
   the vision tool asked for 65536, the clamp landed on 40960, and 40960 is the
   glm capabilities_base ceiling, not this model's. A runtime config always
   carries its provider id, so it resolves through the provider-scoped lookup
   with bare fallback off -- the path taken here -- and that path never read
   the bare glm-4.6v row. The provider-scoped rows are what make the model's
   own ceiling reachable from a runtime. *)
let test_glm_vision_rows_reach_a_runtime_lookup () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog ~suite:"glm vision runtime rows"
  in
  with_clean_model_catalog_override (fun () ->
    Model_catalog.set_global catalog;
    List.iter
      (fun provider_label ->
        match
          Capabilities.for_provider_model_id
            ~wire:(Some Llm_provider.Provider_kind.Glm)
            ~allow_bare_fallback:false
            ~provider_label
            ~model_id:"glm-4.6v"
        with
        | Some caps ->
          check
            (option int)
            (provider_label ^ " resolves glm-4.6v to its own output ceiling")
            (Some 32_768)
            caps.Capabilities.max_output_tokens;
          check
            bool
            (provider_label ^ " keeps glm-4.6v image-capable")
            true
            caps.Capabilities.supports_image_input;
          (* Z.AI's GLM-4.6V streaming example emits this typed delta field:
             https://docs.z.ai/guides/vlm/glm-4.6v *)
          (match (Llm_provider.Reasoning_dialect.of_capabilities caps).streaming with
           | Delta_field "reasoning_content" -> ()
           | No_streaming_reasoning | Delta_field _
           | Delta_field_and_details _ | Template_parser ->
             fail (provider_label ^ " drops GLM-4.6V reasoning deltas"))
        | None -> fail (provider_label ^ " resolves no capabilities for glm-4.6v"))
      [ "glm-coding"; "glm" ])
;;

(* The bare row and its two provider-scoped twins are three catalog keys
   ((provider_name, id_prefix) is the duplicate check), so nothing in the
   loader keeps them in step. They describe one Z.AI model; pin the limits
   and the vision flags to the same values so a later edit to one row cannot
   leave a runtime on a different ceiling than the bare-id callers see. *)
let test_glm_vision_rows_agree () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog ~suite:"glm vision row agreement"
  in
  let rows =
    List.filter
      (fun (entry : Model_catalog.model_entry) -> String.equal entry.id_prefix "glm-4.6v")
      (Model_catalog.model_entries catalog)
  in
  check
    (list (option string))
    "glm-4.6v has the bare row and its two provider-scoped twins"
    [ None; Some "glm"; Some "glm-coding" ]
    (List.sort
       compare
       (List.map (fun (entry : Model_catalog.model_entry) -> entry.provider_name) rows));
  List.iter
    (fun (entry : Model_catalog.model_entry) ->
      let label =
        match entry.provider_name with
        | Some provider -> provider
        | None -> "bare"
      in
      check (option int) (label ^ " output ceiling") (Some 32_768) entry.max_output_tokens;
      check (option int) (label ^ " context window") (Some 128_000) entry.max_context_tokens;
      check (option bool) (label ^ " image input") (Some true) entry.supports_image_input;
      check
        (option bool)
        (label ^ " multimodal inputs")
        (Some true)
        entry.supports_multimodal_inputs)
    rows
;;

(* Every number here was read from OpenRouter's own GET /api/v1/models
   metadata or measured on the wire on 2026-09-10
   (evidence/task-openrouter-support/). Provider-scoped lookup is an exact id
   match, so each row is asserted on its own rather than through a prefix. *)
let openrouter_rows =
  (* id, context, max output, input $/1M, output $/1M, image input *)
  [ "anthropic/claude-opus-5", 1_000_000, 128_000, 5.0, 25.0, None
  ; "anthropic/claude-sonnet-5", 1_000_000, 128_000, 2.0, 10.0, None
  ; "openai/gpt-5.5", 1_050_000, 128_000, 5.0, 30.0, None
  ; "openai/gpt-5.6-sol", 1_050_000, 128_000, 2.0, 10.0, None
  ; "google/gemini-3.8-flash", 1_048_576, 65_536, 0.75, 3.75, None
  ; "x-ai/grok-4.6", 500_000, 450_000, 2.0, 6.0, None
  ; "moonshotai/kimi-k3", 1_048_576, 943_718, 3.0, 15.0, None
  ; "z-ai/glm-5.3-flash", 1_310_720, 131_072, 0.075, 0.25, None
  ; "z-ai/glm-5.3", 1_310_720, 943_718, 1.4, 4.4, Some false
  ; "deepseek/deepseek-v4-flash", 1_048_576, 384_000, 0.088606, 0.177212, Some false
  ; "deepseek/deepseek-v4-pro", 1_048_576, 384_000, 0.95526, 1.91052, Some false
  ; "qwen/qwen3.8-max-0902", 1_000_000, 131_072, 2.0, 6.0, None
  ]
;;

let openrouter_entry entries model_id =
  match
    List.filter
      (fun (entry : Model_catalog.model_entry) ->
         entry.id_prefix = model_id && entry.provider_name = Some "openrouter")
      entries
  with
  | [ entry ] -> entry
  | [] -> Alcotest.failf "no openrouter row for %s" model_id
  | _ :: _ :: _ -> Alcotest.failf "duplicate openrouter rows for %s" model_id
;;

let test_openrouter_rows_preserve_probe_truth () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog ~suite:"OpenRouter rows"
  in
  let entries = Model_catalog.model_entries catalog in
  List.iter
    (fun (model_id, context, max_output, price_in, price_out, image_input) ->
       let entry = openrouter_entry entries model_id in
       check
         (option string)
         (model_id ^ " capability base")
         (Some "openai_chat_extended")
         entry.base_label;
       check (option int) (model_id ^ " context") (Some context) entry.max_context_tokens;
       check
         (option int)
         (model_id ^ " max output")
         (Some max_output)
         entry.max_output_tokens;
       check
         (option (float 1e-9))
         (model_id ^ " input price")
         (Some price_in)
         entry.input_per_million;
       check
         (option (float 1e-9))
         (model_id ^ " output price")
         (Some price_out)
         entry.output_per_million;
       (* The gateway mirrors reasoning into reasoning_details[] on every one
          of these models, and gpt-5.5 puts its only reasoning artifact there
          with delta.reasoning = null. A row declaring plain "delta:reasoning"
          would read that null and drop the item. *)
       check
         (option string)
         (model_id ^ " reasoning stream")
         (Some "delta_details:reasoning")
         entry.reasoning_streaming_format;
       check
         (option string)
         (model_id ^ " reasoning output")
         (Some "split_reasoning_fields")
         entry.reasoning_output_format;
       check
         (option string)
         (model_id ^ " reasoning replay")
         (Some "drop_without_tool")
         entry.reasoning_replay;
       check
         (option bool)
         (model_id ^ " image input")
         image_input
         entry.supports_image_input)
    openrouter_rows
;;

(* Rows that lower a claim the openai_chat_extended base makes. The tool_choice
   pair is a wire measurement; the modality trio is the gateway's own input
   list. Left at the base value each one would be a false claim. *)
let test_openrouter_rows_lower_contradicted_base_claims () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog ~suite:"OpenRouter overrides"
  in
  let entries = Model_catalog.model_entries catalog in
  let qwen = openrouter_entry entries "qwen/qwen3.8-max-0902" in
  check
    (option bool)
    "qwen refuses required tool choice"
    (Some false)
    qwen.supports_required_tool_choice;
  check
    (option bool)
    "qwen refuses named tool choice"
    (Some false)
    qwen.supports_named_tool_choice;
  List.iter
    (fun model_id ->
       let entry = openrouter_entry entries model_id in
       check
         (option bool)
         (model_id ^ " is text-only")
         (Some false)
         entry.supports_multimodal_inputs)
    [ "z-ai/glm-5.3"; "deepseek/deepseek-v4-flash"; "deepseek/deepseek-v4-pro" ]
;;

(* The effort ladder is the difference between a thinking turn and an
   Undeclared_reasoning_effort_capability, and five endpoints refuse the
   disable rung outright, so the split is measured rung by rung rather than
   assumed uniform (probe7-*, 12 models x 7 rungs, 2026-09-10). *)
let openrouter_effort_ladders =
  let with_disable =
    [ "none"; "minimal"; "low"; "medium"; "high"; "xhigh"; "max" ]
  in
  let without_disable = [ "minimal"; "low"; "medium"; "high"; "xhigh"; "max" ] in
  List.map
    (fun model_id -> model_id, without_disable)
    [ "google/gemini-3.8-flash"
    ; "x-ai/grok-4.6"
    ; "z-ai/glm-5.3"
    ; "z-ai/glm-5.3-flash"
    ; "qwen/qwen3.8-max-0902"
    ]
  @ List.map
      (fun model_id -> model_id, with_disable)
      [ "anthropic/claude-opus-5"
      ; "anthropic/claude-sonnet-5"
      ; "openai/gpt-5.5"
      ; "openai/gpt-5.6-sol"
      ; "moonshotai/kimi-k3"
      ; "deepseek/deepseek-v4-flash"
      ; "deepseek/deepseek-v4-pro"
      ]
;;

let test_openrouter_rows_declare_their_measured_effort_ladder () =
  let catalog =
    Model_catalog_test_support.load_repo_model_catalog ~suite:"OpenRouter efforts"
  in
  let entries = Model_catalog.model_entries catalog in
  check
    int
    "every OpenRouter row has a measured ladder"
    (List.length openrouter_rows)
    (List.length openrouter_effort_ladders);
  List.iter
    (fun (model_id, expected) ->
       let entry = openrouter_entry entries model_id in
       check
         (option (list string))
         (model_id ^ " effort ladder")
         (Some expected)
         entry.accepted_reasoning_efforts)
    openrouter_effort_ladders
;;

let () =
  run
    "model catalog default"
    [ ( "embedded catalog"
      , [ test_case "load_default" `Quick test_load_default_catalog
        ; test_case
            "anthropic rows price cache tokens"
            `Quick
            test_anthropic_rows_price_cache_tokens
        ; test_case
            "Ollama Cloud v1 vendor rows preserve probe truth"
            `Quick
            test_ollama_cloud_v1_vendor_rows_preserve_probe_truth
        ; test_case
            "no Ollama Cloud row states a wire"
            `Quick
            test_no_ollama_cloud_row_states_a_wire
        ; test_case
            "invalid generated input fails closed"
            `Quick
            test_in_memory_catalog_rejects_invalid_generated_input
        ; test_case
            "global uses embedded default"
            `Quick
            test_global_loads_default_catalog_for_capabilities
        ; test_case
            "serving constraint preserves exact interval"
            `Quick
            test_serving_constraint_projects_exact_interval
        ; test_case
            "stale serving evidence fails closed"
            `Quick
            test_serving_constraint_stale_evidence_fails_closed
        ; test_case
            "probe serving evidence requires expiry"
            `Quick
            test_probe_serving_constraint_requires_expiry
        ; test_case
            "catalog-only runtime projects serving evidence"
            `Quick
            test_catalog_only_runtime_projects_serving_constraint
        ; test_case
            "partial serving evidence fails closed"
            `Quick
            test_serving_constraint_partial_group_fails_closed
        ; test_case
            "subscription models resolve their own rows"
            `Quick
            test_subscription_models_resolve_their_own_rows
        ; test_case
            "subscription models admit their reasoning efforts"
            `Quick
            test_subscription_models_admit_their_reasoning_efforts
        ; test_case
            "glm vision rows reach a runtime lookup"
            `Quick
            test_glm_vision_rows_reach_a_runtime_lookup
        ; test_case
            "glm vision rows agree"
            `Quick
            test_glm_vision_rows_agree
        ; test_case
            "OpenRouter rows preserve probe truth"
            `Quick
            test_openrouter_rows_preserve_probe_truth
        ; test_case
            "OpenRouter rows lower contradicted base claims"
            `Quick
            test_openrouter_rows_lower_contradicted_base_claims
        ; test_case
            "OpenRouter rows declare their measured effort ladder"
            `Quick
            test_openrouter_rows_declare_their_measured_effort_ladder
        ] )
    ]
;;
