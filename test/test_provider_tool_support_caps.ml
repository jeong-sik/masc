(* Characterization guard for [Provider_tool_support.oas_capabilities_of_config]
   passthrough (issue #22771).

   The operator-level [providers.<id>.capabilities] supports-runtime-mcp-tools /
   supports-runtime-tool-events flags declared in config/runtime.toml are parsed
   into [Runtime_schema.provider.capabilities] but read by no runtime consumer,
   and the [runtime_mcp_lane] upgrade in [oas_capabilities_of_config] is
   unreachable (binding-derived [tool_policy] never sets either source). So the
   consumer-facing predicate [provider_supports_runtime_mcp_lane] resolves to
   [false] for a cloud OpenAI_compat provider regardless of config intent.

   This test pins that passthrough invariant: wiring the honor path (#22771
   Option A) flips the predicate to [true] and must be a conscious test update,
   not a silent behavior change. *)

let cloud_openai_compat_provider_cfg () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id:"deepseek-v4-flash"
    ~base_url:"https://api.deepseek.com"
    ()
;;

let test_no_silent_runtime_mcp_lane_for_cloud_provider () =
  let provider_cfg = cloud_openai_compat_provider_cfg () in
  Alcotest.(check bool)
    "provider_supports_runtime_mcp_lane stays false (no silent upgrade) #22771"
    false
    (Provider_tool_support.provider_supports_runtime_mcp_lane provider_cfg)
;;

let () =
  Alcotest.run
    "provider_tool_support_caps"
    [ ( "runtime_mcp_lane"
      , [ Alcotest.test_case
            "no silent runtime-mcp lane for cloud OpenAI_compat (#22771)"
            `Quick
            test_no_silent_runtime_mcp_lane_for_cloud_provider
        ] )
    ]
;;
