(* Characterization guard for [Provider_tool_support.oas_capabilities_of_config]
   passthrough (issue #22771).

   The deprecated operator-level [providers.<id>.capabilities]
   supports-runtime-mcp-* flags are ignored: runtime-MCP capability truth comes
   from OAS provider bindings. So the consumer-facing predicate
   [provider_supports_runtime_mcp_lane] resolves to [false] for a cloud
   OpenAI_compat provider regardless of stale config intent.

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

let test_keeper_tool_lane_preserves_exact_inline_tools () =
  let tool =
    Agent_sdk.Tool.create
      ~name:"keeper_probe"
      ~description:"Keeper tool visibility probe"
      ~parameters:[]
      (fun _ -> Ok { Agent_sdk.Types.content = "ok"; _meta = None })
  in
  match
    Runtime_transport.resolve_tool_lane_for_oas_tools
      ~base_path:"/unused"
      ~agent_name:"keeper-probe"
      ~provider_cfg:(cloud_openai_compat_provider_cfg ())
      ~tools:[ tool ]
      ()
  with
  | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)
  | Ok (_, Some _) -> Alcotest.fail "Keeper tool lane must not become runtime MCP"
  | Ok (resolved, None) ->
    Alcotest.(check (list string))
      "provider and credential state cannot remove Keeper Tool.t values"
      [ "keeper_probe" ]
      (List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) resolved)
;;

let () =
  Alcotest.run
    "provider_tool_support_caps"
    [ ( "runtime_mcp_lane"
      , [ Alcotest.test_case
            "no silent runtime-mcp lane for cloud OpenAI_compat (#22771)"
            `Quick
            test_no_silent_runtime_mcp_lane_for_cloud_provider
        ; Alcotest.test_case
            "Keeper tools remain exact inline Tool.t values"
            `Quick
            test_keeper_tool_lane_preserves_exact_inline_tools
        ] )
    ]
;;
