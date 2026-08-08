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

let test_load_default_catalog () =
  let expected =
    Model_catalog_test_support.load_repo_model_catalog ~suite:"model catalog default"
  in
  match Model_catalog.load_default () with
  | Error msg -> failf "default model catalog should load: %s" msg
  | Ok catalog ->
    check
      bool
      "embedded default is exactly the OAS models.toml catalog"
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
         check
           (option bool)
           (model_id ^ " no reasoning budget control")
           (Some false)
           entry.supports_reasoning_budget;
         check
           bool
           (model_id ^ " inherent thinking has no request control")
           true
           (entry.thinking_control_format = Some Capability_vocab.No_thinking_control);
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

let () =
  run
    "model catalog default"
    [ ( "embedded catalog"
      , [ test_case "load_default" `Quick test_load_default_catalog
        ; test_case
            "Ollama Cloud v1 vendor rows preserve probe truth"
            `Quick
            test_ollama_cloud_v1_vendor_rows_preserve_probe_truth
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
        ] )
    ]
;;
