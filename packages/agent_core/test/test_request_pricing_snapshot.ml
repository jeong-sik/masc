open Agent_core
open Llm_provider

let get = function Ok value -> value | Error detail -> Alcotest.fail detail

let catalog ?(priced = true) ?(bare = false) multiplier =
  let row model input output =
    Printf.sprintf
      "[[models]]\nmodel_id = %S\n%sbase = \"openai_chat\"\nmax_context_tokens = 4096\n%s"
      model
      (if bare then "" else "provider_name = \"pricing-provider\"\n")
      (if priced then Printf.sprintf "input_per_million = %.1f\noutput_per_million = %.1f\n"
          (input *. multiplier) (output *. multiplier) else "")
  in
  let source = {|
[[providers]]
id = "pricing-provider"
kind = "openai_compat"
base_url = "https://pricing.invalid"
request_path = "/v1/chat/completions"
auth = "none"
capabilities_base = "openai_chat"
default_model = "request-model"
serves_bare_models = ["request-model", "returned-model"]
|} ^ row "request-model" 1.0 2.0 ^ row "returned-model" 4.0 8.0 in
  Model_catalog.of_toml_string ~source:"request pricing fixture" source |> get

let with_catalog catalog run =
  let previous = Model_catalog.global () in
  Fun.protect ~finally:(fun () -> match previous with
    | Some previous -> Model_catalog.set_global previous
    | None -> Model_catalog.clear_global ())
    (fun () -> Model_catalog.set_global catalog; run ())

let binding ?providers catalog =
  let declarations = Provider_declarations.of_catalogs ~models:(Some catalog) ~providers
    |> Result.map_error Provider_declarations.error_to_string |> get in
  match Provider_runtime_binding.find_in_declarations declarations "pricing-provider" with
  | Some binding -> binding
  | None -> Alcotest.fail "declared pricing provider missing"

let config binding = Provider_runtime_binding.to_provider_config binding
  |> Result.map_error Agent_core.Error.to_string |> get

let raw_config () = Provider_config.make ~kind:OpenAI_compat
    ~provider_id:"pricing-provider" ~model_id:"request-model"
    ~base_url:"https://pricing.invalid" ()

let response ?(model = "request-model") ?cost () : Llm_provider.Types.api_response =
  { id = "pricing-response"; model; stop_reason = EndTurn; content = [Text "ok"]
  ; usage = Some {input_tokens = 1_000_000; output_tokens = 1_000_000;
      cache_creation_input_tokens = 0; cache_read_input_tokens = 0; cost_usd = cost}
  ; telemetry = None }

let transport ~before_response response = Llm_transport.custom
  { complete_sync = (fun _ -> before_response (); {response = Ok response; latency_ms = Some 0})
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _ -> before_response (); Ok response) }

let complete ~stream ~config ~before_response response =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let transport = transport ~before_response response in
    let result = if stream then
        Complete.complete_stream ~sw ~net:env#net ~transport ~config
          ~messages:[Llm_provider.Types.user_msg "answer"] ~on_event:(fun _ -> ()) ()
      else Complete.complete ~sw ~net:env#net ~transport ~config
          ~messages:[Llm_provider.Types.user_msg "answer"] () in
    match result.Completion_outcome.result with
    | Ok response -> response
    | Error _ -> Alcotest.fail "injected completion failed before its pricing observation"))

let check_cost expected response =
  Alcotest.(check (option (float 1e-9))) "cost uses the request-owned price authority"
    expected (Option.bind response.Llm_provider.Types.usage (fun usage -> usage.cost_usd))

let test_selected_before_config () =
  let original = catalog 1.0 and replacement = catalog 10.0 in
  with_catalog original (fun () ->
    let selected = binding original in
    Model_catalog.set_global replacement;
    let selected = config selected in
    check_cost (Some 3.0) (complete ~stream:false ~config:selected
      ~before_response:(fun () -> ()) (response ())))

let test_frozen_before_call () =
  with_catalog (catalog 1.0) (fun () ->
    let frozen = Provider_config.freeze_for_request (raw_config ()) in
    Model_catalog.set_global (catalog 10.0);
    check_cost (Some 3.0) (complete ~stream:false ~config:frozen
      ~before_response:(fun () -> ()) (response ())))

let test_during_call stream () =
  with_catalog (catalog 1.0) (fun () ->
    check_cost (Some 3.0) (complete ~stream ~config:(raw_config ())
      ~before_response:(fun () -> Model_catalog.set_global (catalog 10.0)) (response ())))

let test_returned_model () =
  with_catalog (catalog 1.0) (fun () ->
    check_cost (Some 12.0) (complete ~stream:false ~config:(raw_config ())
      ~before_response:(fun () -> Model_catalog.set_global (catalog 10.0))
      (response ~model:"returned-model" ())))

let test_absence_and_agent_usage () =
  let original = catalog ~priced:false 1.0 in
  with_catalog original (fun () ->
    let selected = config (binding original) in
    Model_catalog.set_global (catalog 10.0);
    let result = complete ~stream:false ~config:selected ~before_response:(fun () -> ()) (response ()) in
    check_cost None result;
    let usage = Agent_turn.accumulate_usage ~current_usage:Agent_core.Types.empty_usage
      ~provider_config:(Some selected) ~response_model:(Some result.model) ~response_usage:result.usage in
    Alcotest.(check (float 1e-9)) "Agent does not acquire a late price" 0.0 usage.estimated_cost_usd;
    Alcotest.(check bool) "missing selected price remains an explicit gap" true
      (usage.pricing_gap = Some (Agent_core.Types.Pricing_unavailable "request-model")))

let test_agent_fallback () =
  let original = catalog 1.0 in
  with_catalog original (fun () ->
    let selected = config (binding original) in
    Model_catalog.set_global (catalog 10.0);
    let response = response () in
    let usage = Agent_turn.accumulate_usage ~current_usage:Agent_core.Types.empty_usage
      ~provider_config:(Some selected) ~response_model:(Some response.model) ~response_usage:response.usage in
    Alcotest.(check (float 1e-9)) "Agent fallback uses selected rates" 3.0 usage.estimated_cost_usd)

let test_provider_reported_cost () =
  with_catalog (catalog 1.0) (fun () ->
    List.iter (fun cost ->
      check_cost (Some cost) (complete ~stream:false ~config:(raw_config ())
        ~before_response:(fun () -> Model_catalog.set_global (catalog 10.0)) (response ~cost ())))
      [0.0; 0.25])

let test_overlay_permission () =
  let original = catalog ~bare:true 1.0 in
  let providers = Provider_catalog.of_json (Yojson.Safe.from_string {|
{"schema_version":1,"providers":[{"id":"pricing-provider","kind":"openai_compat",
"base_url":"https://pricing.invalid","request_path":"/v1/chat/completions",
"auth":{"type":"none"},"capabilities_base":"openai_chat","default_model":"request-model"}]}
|}) |> get in
  with_catalog original (fun () ->
    let selected = config (binding ~providers original) in
    check_cost None (complete ~stream:false ~config:selected ~before_response:(fun () -> ()) (response ())))

let test_fresh_selection () =
  let original = catalog 1.0 and replacement = catalog 10.0 in
  with_catalog original (fun () ->
    let selected = config (binding original) in
    Model_catalog.set_global replacement;
    check_cost (Some 30.0) (complete ~stream:false ~config:(config (binding replacement))
      ~before_response:(fun () -> ()) (response ()));
    check_cost (Some 3.0) (complete ~stream:false
      ~config:{selected with Provider_config.base_url = "https://rotated.invalid"}
      ~before_response:(fun () -> ()) (response ())))

let () = Alcotest.run "request pricing snapshot"
  ["price authority", List.map (fun (name, run) -> Alcotest.test_case name `Quick run)
    ["selection before config conversion", test_selected_before_config;
     "frozen config before dispatch", test_frozen_before_call;
     "sync catalog replacement during call", test_during_call false;
     "stream catalog replacement during call", test_during_call true;
     "exact returned model in captured catalog", test_returned_model;
     "absent rates remain absent in response and Agent", test_absence_and_agent_usage;
     "Agent fallback uses selected authority", test_agent_fallback;
     "provider charge and zero retain precedence", test_provider_reported_cost;
     "provider overlay cannot regain seed bare permission", test_overlay_permission;
     "fresh selection and endpoint rotation", test_fresh_selection]]
