open Alcotest

let test_provider_health_reachable_accepts_json_health () =
  check bool "json health body counts as reachable" true
    (Masc_mcp.Tool_local_runtime.provider_health_reachable ~status:(Some 200)
       ~body:(Some {|{"status":"ok"}|}));
  check bool "plain text health body counts as reachable" true
    (Masc_mcp.Tool_local_runtime.provider_health_reachable ~status:(Some 200)
       ~body:(Some "ok"));
  check bool "non-200 is unreachable" false
    (Masc_mcp.Tool_local_runtime.provider_health_reachable ~status:(Some 503)
       ~body:(Some {|{"status":"error"}|}))

let test_classify_runtime_blocker_prefers_slot_count_when_health_ok () =
  let blocker, detail =
    Masc_mcp.Tool_local_runtime.classify_runtime_blocker ~provider_reachable:true
      ~slot_reachable:true ~chat_contract_status:"confirmed"
      ~expected_model:(Some "qwen3.5-35b-a3b-ud-q8-xl")
      ~actual_model_id:(Some "qwen3.5-35b-a3b-ud-q8-xl")
      ~expected_slots:(Some 12) ~actual_slots_total:4
      ~expected_ctx:(Some 262144) ~actual_ctx:(Some 262144)
      ~chat_completion_compatible:true
  in
  check (option string) "slot blocker" (Some "slot_count_insufficient")
    blocker;
  check bool "detail mentions expected slots" true
    (match detail with
    | Some msg -> String.contains msg '1' && String.contains msg '4'
    | None -> false)

let make_endpoint ~url ~model_id ~ctx_size ~total_slots ~busy =
  let module D = Llm_provider.Discovery in
  {
    D.url;
    healthy = true;
    models = [ { D.id = model_id; owned_by = "llamacpp" } ];
    props = Some { D.total_slots; ctx_size; model = "" };
    slots = Some { D.total = total_slots; busy; idle = total_slots - busy };
    capabilities = Llm_provider.Capabilities.openai_chat_extended_capabilities;
  }

let test_runtime_verify_prefers_oas_discovery_cache () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let previous_endpoints = !(Masc_mcp.Discovery_cache.cached_endpoints) in
  let previous_updated_at = Atomic.get Masc_mcp.Discovery_cache.cache_updated_at in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Discovery_cache.cached_endpoints := previous_endpoints;
      Atomic.set Masc_mcp.Discovery_cache.cache_updated_at previous_updated_at)
    (fun () ->
      Masc_mcp.Discovery_cache.cached_endpoints :=
        [
          make_endpoint ~url:"http://127.0.0.1:19001"
            ~model_id:"qwen3.5-35b-a3b-ud-q4-xl" ~ctx_size:262144
            ~total_slots:4 ~busy:0;
          make_endpoint ~url:"http://127.0.0.1:19002"
            ~model_id:"qwen3.5-35b-a3b-ud-q4-xl" ~ctx_size:262144
            ~total_slots:4 ~busy:1;
          make_endpoint ~url:"http://127.0.0.1:19003"
            ~model_id:"qwen3.5-35b-a3b-ud-q4-xl" ~ctx_size:262144
            ~total_slots:4 ~busy:1;
        ];
      Atomic.set Masc_mcp.Discovery_cache.cache_updated_at (Time_compat.now ());
      let result =
        Masc_mcp.Tool_local_runtime.runtime_verify_json
          ~expected_slots:12 ~expected_ctx:262144
          ~expected_model:"qwen3.5-35b-a3b-ud-q4-xl" ()
      in
      let open Yojson.Safe.Util in
      check string "source" "oas_discovery"
        (result |> member "source" |> to_string);
      check bool "provider reachable" true
        (result |> member "provider_reachable" |> to_bool);
      check bool "slot reachable" true
        (result |> member "slot_reachable" |> to_bool);
      check int "actual slots" 12 (result |> member "actual_slots" |> to_int);
      check int "active slots now" 2
        (result |> member "active_slots_now" |> to_int);
      check bool "passes expected contract" true
        (result |> member "pass" |> to_bool))

let test_classify_runtime_blocker_flags_chat_contract_mismatch () =
  let blocker, detail =
    Masc_mcp.Tool_local_runtime.classify_runtime_blocker ~provider_reachable:true
      ~slot_reachable:true ~chat_contract_status:"rejected"
      ~expected_model:(Some "Qwen3.5-9B-Q4_K_M.gguf")
      ~actual_model_id:(Some "Qwen3.5-9B-Q4_K_M.gguf")
      ~expected_slots:(Some 4) ~actual_slots_total:4
      ~expected_ctx:(Some 131072) ~actual_ctx:(Some 131072)
      ~chat_completion_compatible:true
  in
  check (option string) "chat blocker" (Some "chat_contract_incompatible")
    blocker;
  check bool "detail mentions chat contract" true
    (match detail with
    | Some msg -> String.contains msg 'c'
    | None -> false)

let test_classify_runtime_blocker_allows_unknown_chat_status () =
  let blocker, detail =
    Masc_mcp.Tool_local_runtime.classify_runtime_blocker ~provider_reachable:true
      ~slot_reachable:true ~chat_contract_status:"unknown"
      ~expected_model:(Some "Qwen3.5-9B-Q4_K_M.gguf")
      ~actual_model_id:(Some "Qwen3.5-9B-Q4_K_M.gguf")
      ~expected_slots:(Some 4) ~actual_slots_total:4
      ~expected_ctx:(Some 131072) ~actual_ctx:(Some 131072)
      ~chat_completion_compatible:true
  in
  check (option string) "unknown chat is not blocker" None blocker;
  check (option string) "unknown chat detail absent" None detail

let () =
  run "tool_local_runtime_verify"
    [
      ( "provider_health_reachable",
        [
          test_case "accepts json health payload" `Quick
            test_provider_health_reachable_accepts_json_health;
        ] );
      ( "runtime_blocker",
        [
          test_case "slot shortage beats provider_unreachable" `Quick
            test_classify_runtime_blocker_prefers_slot_count_when_health_ok;
          test_case "runtime verify prefers oas discovery cache" `Quick
            test_runtime_verify_prefers_oas_discovery_cache;
          test_case "chat contract mismatch is reported" `Quick
            test_classify_runtime_blocker_flags_chat_contract_mismatch;
          test_case "unknown chat status is tolerated" `Quick
            test_classify_runtime_blocker_allows_unknown_chat_status;
        ] );
    ]
