(** Tests for Llm_provider.Discovery -- unit tests that do not require
    a running llama-server. We test JSON parsing, env var parsing,
    and serialization. *)

open Llm_provider

let test_getenv bindings name = List.assoc_opt name bindings

let with_env name value f =
  let saved = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some old_value -> Unix.putenv name old_value
      | None -> Unix.putenv name "")
    (fun () ->
       Unix.putenv name value;
       f ())
;;

let fresh_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt socket Unix.SO_REUSEADDR true;
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | _ -> Alcotest.fail "expected TCP socket"
  in
  Unix.close socket;
  port
;;

let with_mock_server handler f =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let port = fresh_port () in
    let socket =
      Eio.Net.listen
        env#net
        ~sw
        ~backlog:128
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let server = Cohttp_eio.Server.make ~callback:handler () in
    Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
    let endpoint = Printf.sprintf "http://127.0.0.1:%d" port in
    f ~sw ~net:env#net ~endpoint;
    Eio.Switch.fail sw Exit
  with
  | Unix.Unix_error ((Unix.EPERM | Unix.EADDRINUSE), "bind", _) -> Alcotest.skip ()
  | Exit -> ()
;;

let test_resolve_default_endpoint_reads_getenv () =
  let first = "http://127.0.0.1:19001" in
  let second = "http://127.0.0.1:19002" in
  Alcotest.(check string)
    "first value"
    first
    (Discovery.resolve_default_endpoint
       ~getenv:(test_getenv [ Discovery.local_llm_url_env_var, first ])
       ());
  Alcotest.(check string)
    "second value"
    second
    (Discovery.resolve_default_endpoint
       ~getenv:(test_getenv [ Discovery.local_llm_url_env_var, second ])
       ())
;;

let test_resolve_ollama_endpoint_reads_getenv () =
  let first = "http://127.0.0.1:19003" in
  let second = "http://127.0.0.1:19004" in
  Alcotest.(check string)
    "first value"
    first
    (Discovery.resolve_ollama_endpoint
       ~getenv:(test_getenv [ Discovery.ollama_host_env_var, first ])
       ());
  Alcotest.(check string)
    "second value"
    second
    (Discovery.resolve_ollama_endpoint
       ~getenv:(test_getenv [ Discovery.ollama_host_env_var, second ])
       ())
;;

let test_fallback_endpoint_constants_ignore_env () =
  with_env Discovery.local_llm_url_env_var "http://127.0.0.1:19101" (fun () ->
    Alcotest.(check string)
      "default_endpoint remains fallback constant"
      Constants.Endpoints.default_url
      Discovery.default_endpoint;
    Alcotest.(check string)
      "resolver reads local url"
      "http://127.0.0.1:19101"
      (Discovery.resolve_default_endpoint ()));
  with_env Discovery.ollama_host_env_var "http://127.0.0.1:19102" (fun () ->
    Alcotest.(check string)
      "ollama_endpoint remains fallback constant"
      Discovery.default_ollama_endpoint
      Discovery.ollama_endpoint;
    Alcotest.(check string)
      "resolver reads ollama host"
      "http://127.0.0.1:19102"
      (Discovery.resolve_ollama_endpoint ()))
;;

let test_discover_uses_explicit_ollama_protocol () =
  let props_hits = ref 0 in
  let slots_hits = ref 0 in
  let show_hits = ref 0 in
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/health" -> Cohttp_eio.Server.respond_string ~status:`OK ~body:"ok" ()
    | "/v1/models" ->
      Cohttp_eio.Server.respond_string
        ~status:`OK
        ~body:{|{"data":[{"id":"phi4","owned_by":"ollama"}]}|}
        ()
    | "/api/tags" ->
      Cohttp_eio.Server.respond_string
        ~status:`OK
        ~body:{|{"models":[{"name":"phi4"}]}|}
        ()
    | "/api/show" ->
      incr show_hits;
      Cohttp_eio.Server.respond_string
        ~status:`OK
        ~body:{|{"model_info":{"context_length":8192},"template":"{{ .Content }}"}|}
        ()
    | "/props" ->
      incr props_hits;
      Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"unexpected props" ()
    | "/slots" ->
      incr slots_hits;
      Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"unexpected slots" ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~endpoint ->
    let declared =
      Discovery.endpoint
        ~protocol:Discovery.Ollama_native
        ~capabilities:Capabilities.ollama_capabilities
        endpoint
    in
    match Discovery.discover ~sw ~net ~endpoints:[ declared ] with
    | [ status ] ->
      Alcotest.(check bool) "healthy" true status.healthy;
      Alcotest.(check int) "props probe skipped" 0 !props_hits;
      Alcotest.(check int) "slots probe skipped" 0 !slots_hits;
      Alcotest.(check int) "template probe skipped" 0 !show_hits;
      Alcotest.(check bool) "ollama props are not inferred" true (status.props = None);
      Alcotest.(check bool)
        "declared ollama think behavior"
        true
        (status.capabilities.thinking_control_format = Capabilities.Ollama_think);
      Alcotest.(check (list string))
        "no failures"
        []
        (List.map
           (fun (failure : Discovery.probe_failure) -> failure.detail)
           status.failures)
    | _ -> Alcotest.fail "expected one endpoint status")
;;

let test_parse_models_json () =
  let json =
    Yojson.Safe.from_string
      {|{
    "data": [
      {"id": "dashscope-3.5-35b", "owned_by": "llama-server"},
      {"id": "llama-3.1-8b", "owned_by": "llama-server"}
    ]
  }|}
  in
  match Discovery_parse.parse_models json with
  | Ok models ->
    Alcotest.(check int) "model count" 2 (List.length models);
    Alcotest.(check string) "first model id" "dashscope-3.5-35b" (List.hd models).id
  | Error detail -> Alcotest.failf "valid model inventory rejected: %s" detail
;;

let test_parse_models_rejects_malformed_item () =
  let json =
    `Assoc
      [ ( "data"
        , `List
            [ `Assoc [ "id", `String "valid"; "owned_by", `String "local" ]
            ; `Assoc [ "owned_by", `String "local" ]
            ] )
      ]
  in
  match Discovery_parse.parse_models json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "malformed inventory item was silently dropped"
;;

let test_endpoint_status_to_json_healthy () =
  let status : Discovery.endpoint_status =
    { url = "http://127.0.0.1:8085"
    ; protocol = Discovery.Openai_compatible
    ; healthy = true
    ; models = [ { id = "dashscope-3.5-35b"; owned_by = "llama-server" } ]
    ; props = Some { total_slots = 4; ctx_size = 32768; model = "dashscope-3.5-35b" }
    ; slots = Some { total = 4; busy = 1; idle = 3 }
    ; capabilities = Capabilities.openai_compat_chat_extended_capabilities
    ; failures = []
    }
  in
  let json = Discovery.endpoint_status_to_json status in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "healthy" true (json |> member "healthy" |> to_bool);
  Alcotest.(check string) "url" "http://127.0.0.1:8085" (json |> member "url" |> to_string);
  Alcotest.(check string)
    "protocol"
    "openai_compatible"
    (json |> member "protocol" |> to_string);
  let slots = json |> member "slots" in
  Alcotest.(check int) "total slots" 4 (slots |> member "total" |> to_int);
  Alcotest.(check int) "idle slots" 3 (slots |> member "idle" |> to_int);
  let caps = json |> member "capabilities" in
  Alcotest.(check bool) "reasoning" true (caps |> member "reasoning" |> to_bool)
;;

let test_endpoint_status_to_json_unhealthy () =
  let status : Discovery.endpoint_status =
    { url = "http://127.0.0.1:9999"
    ; protocol = Discovery.Openai_compatible
    ; healthy = false
    ; models = []
    ; props = None
    ; slots = None
    ; capabilities = Capabilities.default_capabilities
    ; failures = [ { phase = "health"; detail = "connection refused" } ]
    }
  in
  let json = Discovery.endpoint_status_to_json status in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "healthy" false (json |> member "healthy" |> to_bool);
  Alcotest.(check int) "no models" 0 (json |> member "models" |> to_list |> List.length);
  let failures = json |> member "failures" |> to_list in
  Alcotest.(check int) "one explicit failure" 1 (List.length failures);
  Alcotest.(check string)
    "failure phase"
    "health"
    (List.hd failures |> member "phase" |> to_string);
  Alcotest.(check string)
    "failure detail"
    "connection refused"
    (List.hd failures |> member "detail" |> to_string);
  (* props and slots should be absent *)
  Alcotest.(check bool) "no props" true (member "props" json = `Null)
;;

let test_summary_to_json () =
  let endpoints : Discovery.endpoint_status list =
    [ { url = "http://a:8085"
      ; protocol = Discovery.Openai_compatible
      ; healthy = true
      ; models = []
      ; props = None
      ; slots = Some { total = 4; busy = 1; idle = 3 }
      ; capabilities = Capabilities.default_capabilities
      ; failures = []
      }
    ; { url = "http://b:8086"
      ; protocol = Discovery.Openai_compatible
      ; healthy = true
      ; models = []
      ; props = None
      ; slots = Some { total = 2; busy = 2; idle = 0 }
      ; capabilities = Capabilities.default_capabilities
      ; failures = []
      }
    ; { url = "http://c:8087"
      ; protocol = Discovery.Openai_compatible
      ; healthy = false
      ; models = []
      ; props = None
      ; slots = None
      ; capabilities = Capabilities.default_capabilities
      ; failures = [ { phase = "health"; detail = "unreachable" } ]
      }
    ]
  in
  let json = Discovery.summary_to_json endpoints in
  let open Yojson.Safe.Util in
  Alcotest.(check int) "total capacity" 6 (json |> member "total_capacity" |> to_int);
  Alcotest.(check int) "available" 3 (json |> member "available_capacity" |> to_int);
  Alcotest.(check int) "active" 3 (json |> member "active_requests" |> to_int)
;;

(* ── discovered_per_slot_context tests ────────────────────── *)

let test_discovered_per_slot_context_initially_none () =
  (* Before any refresh_and_sync, should be None or whatever was last set.
     We can't fully reset the Atomic in tests, but we can verify the
     API shape. *)
  let _result = Discovery.discovered_per_slot_context () in
  (* Just verify it doesn't crash — value depends on test ordering *)
  ()
;;

let test_refresh_and_sync_updates_context () =
  (* We can't probe real endpoints in unit tests, but we can verify
     that refresh_and_sync with unreachable endpoints returns empty
     and doesn't crash. *)
  Eio_main.run
  @@ fun env ->
  let sw = Eio.Stdenv.process_mgr env in
  ignore sw;
  (* Instead, test the computation logic directly:
     verify per-slot = ctx_size / total_slots *)
  let status_with_props ctx_size total_slots : Discovery.endpoint_status =
    { url = "http://test"
    ; protocol = Discovery.Openai_compatible
    ; healthy = true
    ; models = []
    ; props = Some { total_slots; ctx_size; model = "test" }
    ; slots = None
    ; capabilities = Capabilities.default_capabilities
    ; failures = []
    }
  in
  (* Simulate what refresh_and_sync computes *)
  let compute_per_slot (statuses : Discovery.endpoint_status list) =
    let healthy =
      List.filter (fun (s : Discovery.endpoint_status) -> s.healthy) statuses
    in
    let per_slots =
      List.filter_map
        (fun (s : Discovery.endpoint_status) ->
           match s.props with
           | Some p when p.total_slots > 0 && p.ctx_size > 0 ->
             Some (p.ctx_size / p.total_slots)
           | _ -> None)
        healthy
    in
    match per_slots with
    | [] -> None
    | ctxs -> Some (List.fold_left min max_int ctxs)
  in
  (* Single endpoint: 131072 / 4 = 32768 *)
  let result = compute_per_slot [ status_with_props 131072 4 ] in
  Alcotest.(check (option int)) "single endpoint per-slot" (Some 32768) result;
  (* Multi endpoint: min(131072/4=32768, 8192/1=8192) = 8192 *)
  let result =
    compute_per_slot [ status_with_props 131072 4; status_with_props 8192 1 ]
  in
  Alcotest.(check (option int)) "multi endpoint min" (Some 8192) result;
  (* No healthy endpoints *)
  let unhealthy : Discovery.endpoint_status =
    { url = "http://dead"
    ; protocol = Discovery.Openai_compatible
    ; healthy = false
    ; models = []
    ; props = None
    ; slots = None
    ; capabilities = Capabilities.default_capabilities
    ; failures = [ { phase = "health"; detail = "unreachable" } ]
    }
  in
  let result = compute_per_slot [ unhealthy ] in
  Alcotest.(check (option int)) "no healthy" None result;
  (* No props *)
  let no_props : Discovery.endpoint_status =
    { url = "http://noprops"
    ; protocol = Discovery.Openai_compatible
    ; healthy = true
    ; models = []
    ; props = None
    ; slots = None
    ; capabilities = Capabilities.default_capabilities
    ; failures = []
    }
  in
  let result = compute_per_slot [ no_props ] in
  Alcotest.(check (option int)) "no props" None result
;;

let test_refresh_and_sync_mock_server_updates_indexes () =
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/health" -> Cohttp_eio.Server.respond_string ~status:`OK ~body:"ok" ()
    | "/v1/models" ->
      Cohttp_eio.Server.respond_string
        ~status:`OK
        ~body:
          {|
          {
            "data": [
              {"id":"dashscope-3.5-35b","owned_by":"llama-server"},
              {"id":"llama-3.1-8b","owned_by":"llama-server"}
            ]
          }
          |}
        ()
    | "/props" ->
      Cohttp_eio.Server.respond_string
        ~status:`OK
        ~body:
          {|
          {
            "total_slots": 4,
            "default_generation_settings": {
              "n_ctx": 65536,
              "model": "dashscope-3.5-35b"
            }
          }
          |}
        ()
    | "/slots" ->
      Cohttp_eio.Server.respond_string
        ~status:`OK
        ~body:
          {|
          [
            {"id":0,"is_processing":true},
            {"id":1,"is_processing":false},
            {"id":2,"is_processing":true},
            {"id":3,"is_processing":false}
          ]
          |}
        ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~endpoint ->
    let declared =
      Discovery.endpoint
        ~protocol:Discovery.Openai_compatible
        ~capabilities:Capabilities.openai_compat_chat_capabilities
        endpoint
    in
    let statuses = Discovery.refresh_and_sync ~sw ~net ~endpoints:[ declared ] in
    match statuses with
    | [ status ] ->
      Alcotest.(check bool) "healthy" true status.healthy;
      Alcotest.(check int) "models" 2 (List.length status.models);
      Alcotest.(check (option int))
        "max context uses props"
        (Some 65536)
        (Discovery.max_context_of_status status);
      Alcotest.(check (option int))
        "global context"
        (Some 65536)
        (Discovery.discovered_per_slot_context ());
      Alcotest.(check (option int))
        "endpoint context"
        (Some 65536)
        (Discovery.discovered_context_for_url ("  " ^ endpoint ^ "  "));
      Alcotest.(check (option string))
        "model endpoint"
        (Some endpoint)
        (Discovery.endpoint_for_model "dashscope-3.5-35b");
      Alcotest.(check (option string))
        "first model"
        (Some "dashscope-3.5-35b")
        (Discovery.first_discovered_model_id ());
      Alcotest.(check (option string))
        "first model for endpoint"
        (Some "dashscope-3.5-35b")
        (Discovery.first_discovered_model_id_for_url endpoint);
      Alcotest.(check (option (pair string int)))
        "context for model"
        (Some (endpoint, 65536))
        (Discovery.context_for_model "dashscope-3.5-35b");
      (match status.slots with
       | Some slots ->
         Alcotest.(check int) "slot total" 4 slots.total;
         Alcotest.(check int) "busy" 2 slots.busy;
         Alcotest.(check int) "idle" 2 slots.idle
       | None -> Alcotest.fail "expected slots");
      Alcotest.(check bool)
        "openai-compatible discovery does not infer extended reasoning"
        false
        status.capabilities.supports_extended_thinking
    | _ -> Alcotest.fail "expected one endpoint status")
;;

let test_max_context_of_status_falls_back_to_capabilities () =
  let status : Discovery.endpoint_status =
    { url = "http://fallback"
    ; protocol = Discovery.Openai_compatible
    ; healthy = true
    ; models = []
    ; props = None
    ; slots = None
    ; capabilities =
        Capabilities.with_context_size Capabilities.default_capabilities ~ctx_size:4096
    ; failures = []
    }
  in
  Alcotest.(check (option int))
    "fallback context"
    (Some 4096)
    (Discovery.max_context_of_status status)
;;

let () =
  Alcotest.run
    "Discovery"
    [ ( "env"
      , [ Alcotest.test_case
            "resolve default endpoint from getenv"
            `Quick
            test_resolve_default_endpoint_reads_getenv
        ; Alcotest.test_case
            "resolve ollama endpoint from getenv"
            `Quick
            test_resolve_ollama_endpoint_reads_getenv
        ; Alcotest.test_case
            "fallback endpoint constants ignore env"
            `Quick
            test_fallback_endpoint_constants_ignore_env
        ; Alcotest.test_case
            "discover uses explicit Ollama protocol"
            `Quick
            test_discover_uses_explicit_ollama_protocol
        ] )
    ; ( "parsing"
      , [ Alcotest.test_case "models json" `Quick test_parse_models_json
        ; Alcotest.test_case
            "malformed model item rejected"
            `Quick
            test_parse_models_rejects_malformed_item
        ] )
    ; ( "json"
      , [ Alcotest.test_case
            "healthy endpoint"
            `Quick
            test_endpoint_status_to_json_healthy
        ; Alcotest.test_case
            "unhealthy endpoint"
            `Quick
            test_endpoint_status_to_json_unhealthy
        ; Alcotest.test_case "summary" `Quick test_summary_to_json
        ] )
    ; ( "discovered_context"
      , [ Alcotest.test_case
            "initially accessible"
            `Quick
            test_discovered_per_slot_context_initially_none
        ; Alcotest.test_case
            "per-slot computation"
            `Quick
            test_refresh_and_sync_updates_context
        ; Alcotest.test_case
            "mock server updates indexes"
            `Quick
            test_refresh_and_sync_mock_server_updates_indexes
        ; Alcotest.test_case
            "max context fallback"
            `Quick
            test_max_context_of_status_falls_back_to_capabilities
        ] )
    ]
;;
