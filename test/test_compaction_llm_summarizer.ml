(** Provider and Runtime selection tests for the compaction LLM boundary.
    Atomic plan decoding/application is owned by [test_keeper_compaction_unit]. *)

open Masc
module C = Keeper_compaction_llm_summarizer

let temperature_runtime_id = "local.kimi_like"

let temperature_runtime_toml =
  "[providers.local]\n\
   display-name = \"Local\"\n\
   protocol = \"ollama-http\"\n\
   endpoint = \"http://localhost:11434\"\n\
   \n\
   [providers.fallback]\n\
   display-name = \"Fallback\"\n\
   protocol = \"ollama-http\"\n\
   endpoint = \"http://localhost:11435\"\n\
   \n\
   [models.kimi_like]\n\
   api-name = \"kimi-like\"\n\
   max-context = 1024\n\
   temperature = 1.0\n\
   \n\
   [models.kimi_like.capabilities]\n\
   supports-structured-output = true\n\
   \n\
   [local.kimi_like]\n\
   \n\
   [fallback.kimi_like]\n\
   \n\
   [runtime]\n\
   default = \"local.kimi_like\"\n\
   librarian = \"local.kimi_like\"\n\
   \n\
   [runtime.lanes.compaction]\n\
   strategy = \"ordered\"\n\
   candidates = [\"local.kimi_like\", \"fallback.kimi_like\"]\n"

let with_temperature_runtime f =
  let path = Filename.temp_file "compaction_temperature_runtime" ".toml" in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let oc = open_out path in
  output_string oc temperature_runtime_toml;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
      match Runtime.save_config_text ~runtime_config_path:path temperature_runtime_toml with
      | Error detail -> Alcotest.failf "runtime config should load: %s" detail
      | Ok () ->
        (match Runtime.get_runtime_by_id temperature_runtime_id with
         | None -> Alcotest.fail "temperature runtime should resolve"
         | Some runtime -> f runtime.Runtime.provider_config))

let test_provider_for_plan_preserves_runtime_temperature () =
  with_temperature_runtime (fun provider_cfg ->
    let cfg =
      C.For_testing.provider_for_plan provider_cfg
    in
    Alcotest.(check (option (float 0.0001)))
      "runtime.toml temperature is preserved"
      (Some 1.0)
      cfg.temperature)

let test_provider_for_plan_preserves_temperature_omission () =
  let provider_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"test-model"
      ~base_url:"http://example.invalid"
      ()
  in
  let cfg = C.For_testing.provider_for_plan provider_cfg in
  Alcotest.(check (option (float 0.0001)))
    "temperature remains omitted"
    None
    cfg.temperature

let test_lane_candidates_keep_declared_order () =
  with_temperature_runtime @@ fun _ ->
  let actual =
    C.For_testing.candidate_runtime_ids_for_assignment
      ~keeper_name:"keeper-test"
      ~runtime_id:"compaction"
  in
  Alcotest.(check (option (list string))) "declared candidate order"
    (Some [ "local.kimi_like"; "fallback.kimi_like" ])
    actual

let test_make_uses_caller_owned_eio_resources () =
  with_temperature_runtime @@ fun _ ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let called_with_exact_resources = ref false in
  let complete
        ~sw:received_sw
        ~net:received_net
        ?clock:received_clock
        ~config:_
        ~messages:_
        ()
    =
    called_with_exact_resources :=
      received_sw == sw
      && received_net == net
      && Option.fold
           ~none:false
           ~some:(fun received_clock -> received_clock == clock)
           received_clock;
    Ok
      { Agent_sdk.Types.id = "compaction-explicit-resources"
      ; model = "test-model"
      ; stop_reason = Agent_sdk.Types.EndTurn
      ; content =
          [ Agent_sdk.Types.Text
              {|{"kept_indices":[0],"dropped_indices":[],"summarized_units":[]}|}
          ]
      ; usage = None
      ; telemetry = None
      }
  in
  let summarizer =
    match
      C.make
        ~complete
        ~sw
        ~net
        ~clock
        ~runtime_id:temperature_runtime_id
        ~keeper_name:"keeper-test"
        ()
    with
    | Some summarizer -> summarizer
    | None -> Alcotest.fail "explicit-resource summarizer should resolve"
  in
  let outcome =
    summarizer
      ~messages:
        [ Agent_sdk.Types.text_message Agent_sdk.Types.User "keep this exact unit" ]
  in
  Alcotest.(check bool)
    "provider received the caller-owned switch, net, and clock"
    true
    !called_with_exact_resources;
  Alcotest.(check bool)
    "valid terminal no-compaction judgment is preserved"
    true
    (match outcome with
     | Some C.No_compaction -> true
     | Some (C.Planned _) | None -> false)

let () =
  Alcotest.run "compaction_llm_summarizer"
    [ ( "provider"
      , [ Alcotest.test_case "runtime temperature is authoritative" `Quick
            test_provider_for_plan_preserves_runtime_temperature
        ; Alcotest.test_case "temperature omission is preserved" `Quick
            test_provider_for_plan_preserves_temperature_omission
        ; Alcotest.test_case "lane candidates keep declared order" `Quick
            test_lane_candidates_keep_declared_order
        ; Alcotest.test_case "make uses caller-owned Eio resources" `Quick
            test_make_uses_caller_owned_eio_resources
        ] )
    ]
