open Alcotest
open Llm_provider
open Types
module Count = Input_token_count

let msg role content : message =
  { role; content; name = None; tool_call_id = None; metadata = [] }
;;

let tool =
  `Assoc
    [ "name", `String "inspect"
    ; "description", `String "Inspect one artifact"
    ; ( "input_schema"
      , `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc [ "path", `Assoc [ "type", `String "string" ] ]
          ] )
    ]
;;

let messages =
  [ msg
      User
      [ Text "Inspect this image"
      ; Image { media_type = "image/png"; data = "AAAA"; source_type = Base64 }
      ]
  ; msg
      Assistant
      [ ToolUse
          { id = "tool-1"
          ; name = "inspect"
          ; input = `Assoc [ "path", `String "artifact.png" ]
          }
      ]
  ; msg
      User
      [ ToolResult
          { tool_use_id = "tool-1"
          ; content = "inspection complete"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks =
              Some
                [ Text "inspection complete"
                ; Image { media_type = "image/png"; data = "BBBB"; source_type = Base64 }
                ]
          }
      ]
  ]
;;

let config
      ?(kind = Provider_config.Anthropic)
      ?(request_path = "/proxy/messages")
      ?max_context
      ?max_concurrent_requests
      ?max_request_body_bytes
      ?model_capabilities_override
      base_url
  =
  Provider_config.make
    ~kind
    ~model_id:"input-count-fixture"
    ~base_url
    ~api_key:"test-key"
    ~headers:[ "Content-Type", "application/json"; "anthropic-version", "2023-06-01" ]
    ~request_path
    ~max_tokens:64
    ?max_context
    ~temperature:0.2
    ~top_p:0.8
    ~top_k:40
    ~system_prompt:"Count the exact projected input."
    ~cache_system_prompt:true
    ~tool_choice:Any
    ~disable_parallel_tool_use:true
    ~supports_tool_choice_override:true
    ~response_format:(Types.JsonSchema (`Assoc [ "type", `String "object" ]))
    ?max_concurrent_requests
    ?max_request_body_bytes
    ?model_capabilities_override
    ()
;;

let serialize_sync prepared =
  match Complete.admit_request_body ~stream:false prepared with
  | Ok serialized -> serialized
  | Error _ -> fail "request serialization admission failed"
;;

let kimi_config ?max_context base_url =
  { (config ~kind:Provider_config.Kimi ?max_context base_url) with response_format = Off }
;;

let response =
  { id = "prepared-response"
  ; model = "input-count-fixture"
  ; stop_reason = EndTurn
  ; content = [ Text "accepted" ]
  ; usage = None
  ; telemetry = None
  }
;;

let build_admission_agent
      ?model_input_projection
      ?body_timeout_s
      ?pre_dispatch_serialization_observer
      ~net
      ~provider_config
      ?transport
      ()
  =
  let builder =
    Agent_sdk.Builder.create ~net ~model:provider_config.Provider_config.model_id
    |> Agent_sdk.Builder.with_provider_config provider_config
    |> Agent_sdk.Builder.with_context_fit_admission Agent_sdk.Agent.Enforce_when_supported
    |> Agent_sdk.Builder.without_event_bus
  in
  let builder =
    match transport with
    | None -> builder
    | Some transport -> Agent_sdk.Builder.with_transport transport builder
  in
  let builder =
    match model_input_projection with
    | None -> builder
    | Some project -> Agent_sdk.Builder.with_model_input_projection project builder
  in
  let builder =
    match body_timeout_s with
    | None -> builder
    | Some timeout_s -> Agent_sdk.Builder.with_body_timeout timeout_s builder
  in
  let builder =
    match pre_dispatch_serialization_observer with
    | None -> builder
    | Some observer ->
      Agent_sdk.Builder.with_pre_dispatch_serialization_observer observer builder
  in
  builder
  |> Agent_sdk.Builder.build_safe
  |> function
  | Ok agent -> agent
  | Error error -> fail (Agent_sdk.Error.to_string error)
;;

let completion_request config : Llm_transport.completion_request =
  { config
  ; messages
  ; tools = [ tool ]
  ; capture_id = Some "request-count-fixture"
  ; observe_http_status = None
  ; observe_wire_chunk = None
  ; request_wire_observer = None
  ; stream_idle_timeout_s = None
  ; first_event_timeout_s = None
  ; body_timeout_s = None
  }
;;

let assoc body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> fields
  | _ -> fail "request body must be an object"
;;

let field_json name fields =
  match List.assoc_opt name fields with
  | Some json -> Yojson.Safe.to_string json
  | None -> fail ("missing request field: " ^ name)
;;

let test_shared_projection () =
  let cfg = config "https://api.anthropic.com" in
  let completion =
    Backend_anthropic.build_request ~config:cfg ~messages ~tools:[ tool ] () |> assoc
  in
  let count =
    Backend_anthropic.build_count_tokens_request ~config:cfg ~messages ~tools:[ tool ] ()
    |> assoc
  in
  List.iter
    (fun name ->
       check
         string
         ("shared field " ^ name)
         (field_json name completion)
         (field_json name count))
    [ "model"; "messages"; "system"; "tools"; "tool_choice"; "output_config" ];
  List.iter
    (fun name -> check bool ("count omits " ^ name) false (List.mem_assoc name count))
    [ "max_tokens"; "stream"; "temperature"; "top_p"; "top_k" ]
;;

let test_kimi_shared_projection () =
  let cfg = kimi_config "https://api.kimi.com/coding" in
  let completion =
    Backend_anthropic.build_request ~config:cfg ~messages ~tools:[ tool ] () |> assoc
  in
  let count =
    Backend_anthropic.build_count_tokens_request ~config:cfg ~messages ~tools:[ tool ] ()
    |> assoc
  in
  List.iter
    (fun name ->
       check
         string
         ("Kimi shared field " ^ name)
         (field_json name completion)
         (field_json name count))
    [ "model"; "messages"; "system"; "tools"; "tool_choice" ];
  List.iter
    (fun name ->
       check bool ("Kimi count omits " ^ name) false (List.mem_assoc name count))
    [ "max_tokens"; "stream"; "temperature"; "top_p"; "top_k" ]
;;

let fresh_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt socket Unix.SO_REUSEADDR true;
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | _ -> fail "loopback socket did not expose a TCP port"
  in
  Unix.close socket;
  port
;;

let with_mock_env ?response_delay_s ~status ~response f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let port = fresh_port () in
  let captured, resolve_captured = Eio.Promise.create () in
  let handler _conn request body =
    let body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    Eio.Promise.resolve
      resolve_captured
      (Cohttp.Request.uri request |> Uri.path, Cohttp.Request.headers request, body);
    Option.iter (Eio.Time.sleep clock) response_delay_s;
    Cohttp_eio.Server.respond_string ~status ~body:response ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:4
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
  let result = f ~sw ~net ~clock ~base_url in
  result, Eio.Promise.await captured
;;

let with_mock ~status ~response f =
  with_mock_env ~status ~response (fun ~sw ~net ~clock:_ ~base_url ->
    f ~sw ~net ~base_url)
;;

let admitted_anthropic_stream_response =
  "event: message_start\n\
   data: \
   {\"type\":\"message_start\",\"message\":{\"id\":\"msg-1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"input-count-fixture\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n\
   event: content_block_start\n\
   data: \
   {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n\
   event: content_block_delta\n\
   data: \
   {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"accepted\"}}\n\n\
   event: content_block_stop\n\
   data: {\"type\":\"content_block_stop\",\"index\":0}\n\n\
   event: message_delta\n\
   data: \
   {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n\
   event: message_stop\n\
   data: {\"type\":\"message_stop\"}\n\n"
;;

let admitted_anthropic_sync_response =
  {|{"id":"msg-1","type":"message","role":"assistant","model":"input-count-fixture","content":[{"type":"text","text":"accepted"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":1}}|}
;;

let with_admitted_http_mock ~stream f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let port = fresh_port () in
  let completion_body = ref None in
  let handler _conn request body =
    let body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let path = Cohttp.Request.uri request |> Uri.path in
    if String.ends_with ~suffix:"/count_tokens" path
    then Cohttp_eio.Server.respond_string ~status:`OK ~body:{|{"input_tokens":10}|} ()
    else (
      completion_body := Some body;
      let headers =
        if stream
        then Cohttp.Header.of_list [ "content-type", "text/event-stream" ]
        else Cohttp.Header.init ()
      in
      let response =
        if stream
        then admitted_anthropic_stream_response
        else admitted_anthropic_sync_response
      in
      Cohttp_eio.Server.respond_string ~status:`OK ~headers ~body:response ())
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:4
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
  let result = f ~sw ~net ~base_url in
  result, !completion_body
;;

let check_pre_dispatch_serialization ~label ~body observations =
  match List.rev observations with
  | [ observation ] ->
    check
      bool
      (label ^ " phase")
      true
      (observation.Request_wire_observer.phase
       = Request_wire_observer.Pre_dispatch_serialization);
    check int (label ^ " body bytes") (String.length body) observation.body_bytes;
    check
      string
      (label ^ " body digest")
      Digestif.SHA256.(to_hex (digest_string body))
      observation.body_sha256
  | observations -> failf "%s observer called %d times" label (List.length observations)
;;

let thinking_catalog anthropic_thinking_control =
  let contents =
    Printf.sprintf
      {|
[[models]]
id_prefix = "frozen-catalog-model"
base = "anthropic"
anthropic_thinking_control = "%s"
max_context_tokens = 512
max_output_tokens = 64
|}
      anthropic_thinking_control
  in
  match Model_catalog.of_toml_string ~source:"frozen admitted body test" contents with
  | Ok catalog -> catalog
  | Error detail -> fail detail
;;

let test_admitted_body_is_frozen_across_catalog_mutation () =
  let previous_catalog = Model_catalog.global () in
  Fun.protect
    ~finally:(fun () ->
      match previous_catalog with
      | Some catalog -> Model_catalog.set_global catalog
      | None -> Model_catalog.clear_global ())
    (fun () ->
       Model_catalog.set_global (thinking_catalog "manual_budget");
       let observations = ref [] in
       let (result, admitted_evidence, fresh_serialization), completion_body =
         with_admitted_http_mock ~stream:false
         @@ fun ~sw ~net ~base_url ->
         let cfg =
           { (config ~max_context:512 base_url) with
             model_id = "frozen-catalog-model"
           ; enable_thinking = Some true
           ; thinking_budget = Some 1024
           ; tool_choice = Some Auto
           ; response_format = Off
           }
         in
         let prepared = Complete.prepare_request ~config:cfg ~messages () in
         let admitted_evidence =
           match
             Complete.inspect_serialized_request ~stream:false ~config:cfg ~messages ()
           with
           | Ok evidence -> evidence
           | Error (Http_client.AcceptRejected { reason }) -> fail reason
           | Error _ -> fail "initial frozen-body serialization failed"
         in
         let serialized =
           match Complete.admit_request_body ~stream:false prepared with
           | Ok serialized -> serialized
           | Error (Http_client.AcceptRejected { reason }) -> fail reason
           | Error _ -> fail "initial frozen-body admission failed"
         in
         let measured = Complete.measure_request ~sw ~net serialized |> Result.get_ok in
         let admitted =
           Complete.admit_request ~now_unix_s:0 ~max_context_tokens:512 measured
           |> Result.get_ok
         in
         Model_catalog.set_global (thinking_catalog "always_adaptive");
         let fresh_serialization =
           Complete.inspect_serialized_request ~stream:false ~config:cfg ~messages ()
         in
         let result =
           Complete.complete_admitted
             ~sw
             ~net
             ~request_wire_observer:(fun observation ->
               observations := observation :: !observations;
               Ok ())
             admitted
             ()
         in
         result, admitted_evidence, fresh_serialization
       in
       (match fresh_serialization with
        | Error _ -> ()
        | Ok _ -> fail "catalog mutation did not invalidate fresh serialization");
       (match result with
        | Ok _ -> ()
        | Error _ -> fail "frozen admitted body was reserialized before dispatch");
       match completion_body with
       | None -> fail "frozen admitted body did not reach completion dispatch"
       | Some body ->
         check
           int
           "frozen admission bytes"
           admitted_evidence.Request_wire_observer.body_bytes
           (String.length body);
         check
           string
           "frozen admission digest"
           admitted_evidence.body_sha256
           Digestif.SHA256.(to_hex (digest_string body));
         check_pre_dispatch_serialization
           ~label:"frozen admitted body"
           ~body
           !observations)
;;

let test_transport_success () =
  let result, (path, headers, body) =
    with_mock ~status:`OK ~response:{|{"input_tokens":321}|}
    @@ fun ~sw ~net ~base_url ->
    Count_tokens_sync.measure_completion_request
      ~sw
      ~net
      (completion_request (config base_url))
  in
  (match result with
   | Ok measurement ->
     let count = measurement.input_count in
     check int "input tokens" 321 count.input_tokens;
     check string "model id" "input-count-fixture" count.model_id;
     check
       bool
       "protocol"
       true
       (Count.equal_protocol count.protocol Count.Anthropic_messages_count_tokens);
     check
       (option int)
       "exact requested output"
       (Some 64)
       (Types.output_token_receipt_requested measurement.output_token_receipt);
     check
       (option int)
       "exact effective output"
       (Some 64)
       (Types.output_token_receipt_effective measurement.output_token_receipt)
   | Error _ -> fail "expected native Anthropic count success");
  check string "custom proxy path" "/proxy/messages/count_tokens" path;
  let check_header name value =
    check (option string) name (Some value) (Cohttp.Header.get headers name)
  in
  check_header "x-api-key" "test-key";
  check_header "anthropic-version" "2023-06-01";
  check
    string
    "canonical request body"
    (Backend_anthropic.build_count_tokens_request
       ~config:(config "unused")
       ~messages
       ~tools:[ tool ]
       ())
    body
;;

let test_kimi_transport_success () =
  let result, (path, headers, body) =
    with_mock ~status:`OK ~response:{|{"input_tokens":321}|}
    @@ fun ~sw ~net ~base_url ->
    let cfg = kimi_config base_url in
    Count_tokens_sync.measure_completion_request ~sw ~net (completion_request cfg)
  in
  (match result with
   | Ok measurement ->
     check int "Kimi input tokens" 321 measurement.input_count.input_tokens
   | Error _ -> fail "expected native Kimi count success");
  check string "Kimi count path" "/proxy/messages/count_tokens" path;
  check
    (option string)
    "Kimi x-api-key"
    (Some "test-key")
    (Cohttp.Header.get headers "x-api-key");
  check
    string
    "Kimi canonical request body"
    (Backend_anthropic.build_count_tokens_request
       ~config:(kimi_config "unused")
       ~messages
       ~tools:[ tool ]
       ())
    body
;;

let test_prepared_measure_admit_dispatch () =
  let (result, fit, dispatched), _captured =
    with_mock ~status:`OK ~response:{|{"input_tokens":321}|}
    @@ fun ~sw ~net ~base_url ->
    let cfg = config ~max_context:512 base_url in
    let prepared =
      Complete.prepare_request
        ~config:cfg
        ~messages
        ~tools:[ tool ]
        ~trace_context:[ "x-oas-trace", "prepared-ssot" ]
        ()
    in
    let measured =
      match Complete.measure_request ~sw ~net (serialize_sync prepared) with
      | Ok measured -> measured
      | Error _ -> fail "expected prepared request measurement"
    in
    let max_context_tokens =
      match Complete.resolve_context_limit prepared with
      | Ok limit -> limit
      | Error _ -> fail "expected resolved context limit"
    in
    let admitted =
      match Complete.admit_request ~now_unix_s:0 ~max_context_tokens measured with
      | Ok admitted -> admitted
      | Error _ -> fail "expected prepared request admission"
    in
    let fit = Complete.admitted_fit admitted in
    let dispatched = ref None in
    let transport =
      { Llm_transport.complete_sync =
          (fun request ->
            dispatched := Some request;
            { Llm_transport.response = Ok response; latency_ms = Some 1 })
      ; complete_stream =
          (fun ?on_telemetry:_ ~on_event:_ _ -> fail "unexpected streaming dispatch")
      }
    in
    let result = Complete.complete_admitted ~sw ~net ~transport admitted () in
    result, fit, !dispatched
  in
  (match result with
   | Ok actual ->
     check string "response" "accepted" (Types.visible_text_of_response actual)
   | Error _ -> fail "expected admitted dispatch success");
  check int "measured input" 321 fit.Complete.input_tokens;
  check int "reserved output" 64 fit.reserved_output_tokens;
  check int "declared context" 512 fit.max_context_tokens;
  match dispatched with
  | None -> fail "admitted request was not dispatched"
  | Some request ->
    check string "same model" "input-count-fixture" request.config.model_id;
    check int "same messages" (List.length messages) (List.length request.messages);
    check int "same tools" 1 (List.length request.tools);
    check
      (option string)
      "same trace projection"
      (Some "prepared-ssot")
      (List.assoc_opt "x-oas-trace" request.config.headers)
;;

let test_prepared_context_overflow_is_typed () =
  let result, _captured =
    with_mock ~status:`OK ~response:{|{"input_tokens":500}|}
    @@ fun ~sw ~net ~base_url ->
    let prepared =
      Complete.prepare_request
        ~config:(config ~max_context:512 base_url)
        ~messages
        ~tools:[ tool ]
        ()
    in
    match Complete.measure_request ~sw ~net (serialize_sync prepared) with
    | Error _ -> fail "expected prepared request measurement"
    | Ok measured ->
      (match Complete.resolve_context_limit prepared with
       | Error _ -> fail "expected resolved context limit"
       | Ok max_context_tokens ->
         Complete.admit_request ~now_unix_s:0 ~max_context_tokens measured)
  in
  match result with
  | Error
      (Complete.Context_window_exceeded
         { input_tokens = 500; reserved_output_tokens = 64; max_context_tokens = 512 }) ->
    ()
  | Ok _ | Error _ -> fail "expected typed prepared context overflow"
;;

let test_prepared_admission_resolves_catalog_context_limit () =
  let result, _captured =
    with_mock ~status:`OK ~response:{|{"input_tokens":321}|}
    @@ fun ~sw ~net ~base_url ->
    let cfg = { (config base_url) with model_id = "claude-sonnet-4-5" } in
    let expected =
      Option.bind (Provider_config.capabilities_for_config_model cfg) (fun capabilities ->
        capabilities.Capabilities.max_context_tokens)
      |> Option.get
    in
    let prepared = Complete.prepare_request ~config:cfg ~messages ~tools:[ tool ] () in
    let measured =
      Complete.measure_request ~sw ~net (serialize_sync prepared) |> Result.get_ok
    in
    let max_context_tokens = Complete.resolve_context_limit prepared |> Result.get_ok in
    Complete.admit_request ~now_unix_s:0 ~max_context_tokens measured, expected
  in
  match result with
  | Error _, _ -> fail "catalog-backed context admission unexpectedly failed"
  | Ok admitted, expected ->
    check
      int
      "catalog context is the admission limit"
      expected
      (Complete.admitted_fit admitted).max_context_tokens
;;

(* Loopback server that counts every request it receives into [posts] and,
   unlike [with_mock], never awaits a captured promise. That makes it safe to
   drive code that is expected to issue no request at all: a zero-request run
   cannot block on an unresolved promise. In these fixtures the only server-bound
   request the code under test can make is the [/count_tokens] measurement (the
   completion itself uses the injected [transport], not the network), so [posts]
   observes the number of [/count_tokens] round-trips. *)
let with_post_counter f =
  let posts = Atomic.make 0 in
  let result =
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let port = fresh_port () in
    let handler _conn _request body =
      ignore (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) : string);
      Atomic.incr posts;
      Cohttp_eio.Server.respond_string ~status:`OK ~body:{|{"input_tokens":321}|} ()
    in
    let socket =
      Eio.Net.listen
        net
        ~sw
        ~backlog:4
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let server = Cohttp_eio.Server.make ~callback:handler () in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
    let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
    f ~sw ~net ~base_url
  in
  result, Atomic.get posts
;;

(* Transport that flips [dispatched] if the completion is ever dispatched. An
   unknown context limit must fail admission before either path runs. *)
let dispatch_tripwire dispatched =
  { Llm_transport.complete_sync =
      (fun _ ->
        dispatched := true;
        { Llm_transport.response = Ok response; latency_ms = None })
  ; complete_stream =
      (fun ?on_telemetry:_ ~on_event:_ _ ->
        dispatched := true;
        Ok response)
  }
;;

let serving_constraint ?expires_at_unix_s () =
  let source_kind =
    match expires_at_unix_s with
    | Some _ -> Serving_constraint.Probe
    | None -> Serving_constraint.Declaration
  in
  Serving_constraint.make
    ~source_kind
    ~source_ref:"probe://incident/2793"
    ~checked_at_unix_s:0
    ~confidence:Serving_constraint.High
    ?expires_at_unix_s
    ~accepted_through:524298
    ~rejected_from:524299
    ()
  |> Result.get_ok
;;

let constrained_capabilities base constraint_ =
  { base with Capabilities.serving_constraint = Some constraint_ }
;;

let run_constrained_anthropic_count input_tokens =
  let response = Printf.sprintf {|{"input_tokens":%d}|} input_tokens in
  with_mock ~status:`OK ~response
  @@ fun ~sw ~net ~base_url ->
  let provider_config =
    config
      ~max_context:1048576
      ~model_capabilities_override:
        (constrained_capabilities
           Capabilities.anthropic_capabilities
           (serving_constraint ()))
      base_url
  in
  let dispatched = ref false in
  let transport = dispatch_tripwire dispatched in
  let result =
    Agent_sdk.Agent.run
      ~sw
      (build_admission_agent ~net ~provider_config ~transport ())
      "same exact provider request"
  in
  result, !dispatched
;;

let test_serving_constraint_uses_exact_provider_count () =
  let (accepted, accepted_dispatched), (_, _, accepted_body) =
    run_constrained_anthropic_count 524298
  in
  let (rejected, rejected_dispatched), (_, _, rejected_body) =
    run_constrained_anthropic_count 524299
  in
  check
    string
    "the measured provider request is byte-identical"
    accepted_body
    rejected_body;
  (match accepted with
   | Ok _ -> check bool "accepted observation dispatches" true accepted_dispatched
   | Error error -> fail (Agent_sdk.Error.to_string error));
  match rejected with
  | Error
      (Agent_sdk.Error.Api
         (Retry.InputCapacity
            { reason =
                Retry.Serving_constraint_rejected
                  (Serving_constraint.Input_rejected
                     { input_tokens = 524299
                     ; accepted_through = 524298
                     ; rejected_from = 524299
                     })
            ; _
            })) ->
    check bool "rejected observation is zero-dispatch" false rejected_dispatched
  | Error error -> fail (Agent_sdk.Error.to_string error)
  | Ok _ -> fail "rejected exact token observation was dispatched"
;;

let test_stale_serving_constraint_fails_before_measurement () =
  let dispatched = ref false in
  let result, posts =
    with_post_counter
    @@ fun ~sw ~net ~base_url ->
    let provider_config =
      config
        ~max_context:1048576
        ~model_capabilities_override:
          (constrained_capabilities
             Capabilities.anthropic_capabilities
             (serving_constraint ~expires_at_unix_s:1 ()))
        base_url
    in
    Agent_sdk.Agent.run
      ~sw
      (build_admission_agent
         ~net
         ~provider_config
         ~transport:(dispatch_tripwire dispatched)
         ())
      "stale evidence"
  in
  (match result with
   | Error
       (Agent_sdk.Error.Api
          (Retry.InputCapacity
             { reason =
                 Retry.Serving_constraint_rejected (Serving_constraint.Evidence_expired _)
             ; _
             })) -> ()
   | Error error -> fail (Agent_sdk.Error.to_string error)
   | Ok _ -> fail "stale serving evidence was admitted");
  check int "stale evidence makes no count request" 0 posts;
  check bool "stale evidence makes no completion request" false !dispatched
;;

let test_unmeasurable_constraint_fails_typed_without_dispatch () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let dispatched = ref false in
  let provider_config =
    { (config
         ~kind:Provider_config.OpenAI_compat
         ~max_context:1048576
         ~model_capabilities_override:
           (constrained_capabilities
              Capabilities.openai_compat_chat_capabilities
              (serving_constraint ()))
         "not-used")
      with
      response_format = Off
    }
  in
  let result =
    Agent_sdk.Agent.run
      ~sw
      (build_admission_agent
         ~net:(Eio.Stdenv.net env)
         ~provider_config
         ~transport:(dispatch_tripwire dispatched)
         ())
      "provider-native measurement is unavailable"
  in
  (match result with
   | Error
       (Agent_sdk.Error.Api
          (Retry.InputCapacity { reason = Retry.Token_measurement_unavailable _; _ })) ->
     ()
   | Error error -> fail (Agent_sdk.Error.to_string error)
   | Ok _ -> fail "unmeasurable constrained request was dispatched");
  check bool "unmeasurable constraint is zero-dispatch" false !dispatched
;;

(* Regression for #2678: [Pipeline_stage_route.dispatch_sync] /
   [dispatch_stream] resolve the context limit (pure, no network) before they
   [measure_request] (the [/count_tokens] POST), so a pre-knowable
   [Context_limit_unknown] surfaces without a wasted round-trip.

   These two tests drive the REAL production dispatch path via
   [Agent_sdk.Agent.run] / [Agent_sdk.Agent.run_stream] (both route through
   [Pipeline_stage_route]); they do NOT reconstruct the resolve/measure/admit
   sequence inline. That is what makes them guard the production ordering: the
   model has no catalog row and the config carries no [~max_context], so resolve
   fails, and with the shipped order no request reaches the server ([posts] = 0)
   and the tripwire transport never dispatches.

   Counterfactual: revert the order in [Pipeline_stage_route] so [measure_request]
   runs before [resolve_context_limit]. The measurement then POSTs to
   [/count_tokens] before the (still failing) resolve, [posts] reaches 1, and the
   [posts = 0] assertion goes red. The typed error is identical in both orders
   (resolve fails either way), so [posts] is the discriminating observation for
   the reorder. The sync and stream cases guard the two independent call sites
   the production fix touched. *)
let expect_unknown_limit_failure label result =
  match result with
  | Error
      (Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field = "max_context"; _ }))
    -> ()
  | Error error -> fail (label ^ ": " ^ Agent_sdk.Error.to_string error)
  | Ok _ -> fail (label ^ ": expected unknown-context-limit failure before measurement")
;;

let test_resolve_before_measure_skips_count_roundtrip () =
  let dispatched = ref false in
  let result, posts =
    with_post_counter
    @@ fun ~sw ~net ~base_url ->
    let agent =
      build_admission_agent
        ~net
        ~provider_config:(config base_url)
        ~transport:(dispatch_tripwire dispatched)
        ()
    in
    Agent_sdk.Agent.run ~sw agent "resolve before measuring"
  in
  expect_unknown_limit_failure "sync" result;
  check bool "unknown limit must not dispatch (sync)" false !dispatched;
  check int "no /count_tokens round-trip for an unknown limit (sync)" 0 posts
;;

let test_resolve_before_measure_skips_count_roundtrip_stream () =
  let dispatched = ref false in
  let result, posts =
    with_post_counter
    @@ fun ~sw ~net ~base_url ->
    let agent =
      build_admission_agent
        ~net
        ~provider_config:(config base_url)
        ~transport:(dispatch_tripwire dispatched)
        ()
    in
    Agent_sdk.Agent.run_stream
      ~sw
      ~on_event:(fun _ -> ())
      agent
      "resolve before measuring"
  in
  expect_unknown_limit_failure "stream" result;
  check bool "unknown limit must not dispatch (stream)" false !dispatched;
  check int "no /count_tokens round-trip for an unknown limit (stream)" 0 posts
;;

let expect_request_body_rejection label = function
  | Error
      (Agent_sdk.Error.Api
         (Retry.InvalidRequest
            { reason = Retry.Request_body_too_large { actual_bytes; limit_bytes }; _ }))
    ->
    check int (label ^ " declared byte limit") 1 limit_bytes;
    check bool (label ^ " exact body exceeds limit") true (actual_bytes > limit_bytes)
  | Error error -> fail (label ^ ": " ^ Agent_sdk.Error.to_string error)
  | Ok _ -> fail (label ^ ": oversized completion body was admitted")
;;

let run_body_admission_before_measurement ~stream =
  let dispatched = ref false in
  let result, posts =
    with_post_counter
    @@ fun ~sw ~net ~base_url ->
    let agent =
      build_admission_agent
        ~net
        ~provider_config:(config ~max_context:1048576 ~max_request_body_bytes:1 base_url)
        ~transport:(dispatch_tripwire dispatched)
        ()
    in
    if stream
    then
      Agent_sdk.Agent.run_stream
        ~sw
        ~on_event:(fun _ -> ())
        agent
        "admit exact streaming body before measurement"
    else Agent_sdk.Agent.run ~sw agent "admit exact sync body before measurement"
  in
  result, posts, !dispatched
;;

let test_sync_body_admission_precedes_measurement () =
  let result, posts, dispatched = run_body_admission_before_measurement ~stream:false in
  expect_request_body_rejection "sync" result;
  check int "sync body rejection makes no count request" 0 posts;
  check bool "sync body rejection makes no completion request" false dispatched
;;

let test_stream_body_admission_precedes_measurement () =
  let result, posts, dispatched = run_body_admission_before_measurement ~stream:true in
  expect_request_body_rejection "stream" result;
  check int "stream body rejection makes no count request" 0 posts;
  check bool "stream body rejection makes no completion request" false dispatched
;;

let test_serialization_admission_validates_before_io () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let cfg =
    config ~request_path:"/v1/responses" ~max_concurrent_requests:0 "http://127.0.0.1:1"
  in
  let prepared = Complete.prepare_request ~config:cfg ~messages ~tools:[ tool ] () in
  match Complete.admit_request_body ~stream:false prepared with
  | Error (Http_client.AcceptRejected { reason = detail }) ->
    check bool "validation identifies local config" true (String.length detail > 0);
    check
      bool
      "invalid request never creates an admission lane"
      true
      (Option.is_none (Provider_admission.snapshot_for ~config:cfg))
  | Ok _ | Error _ -> fail "invalid prepared request must fail before provider I/O"
;;

let test_measurement_uses_provider_admission () =
  let result, _captured =
    with_mock ~status:`OK ~response:{|{"input_tokens":321}|}
    @@ fun ~sw ~net ~base_url ->
    let cfg = config ~max_context:512 ~max_concurrent_requests:1 base_url in
    let prepared = Complete.prepare_request ~config:cfg ~messages ~tools:[ tool ] () in
    let result = Complete.measure_request ~sw ~net (serialize_sync prepared) in
    result, Provider_admission.snapshot_for ~config:cfg
  in
  match result with
  | Error _, _ -> fail "admitted measurement unexpectedly failed"
  | Ok _, None -> fail "measurement bypassed provider admission"
  | Ok _, Some snapshot ->
    check int "declared measurement bound" 1 snapshot.Slot_scheduler.max_slots;
    check int "measurement permit returned" 0 snapshot.active
;;

let test_agent_route_uses_prepared_admission () =
  let result, _captured =
    with_mock ~status:`OK ~response:{|{"input_tokens":321}|}
    @@ fun ~sw ~net ~base_url ->
    let provider_config = config ~max_context:512 base_url in
    let dispatched = ref None in
    let transport =
      { Llm_transport.complete_sync =
          (fun request ->
            dispatched := Some request;
            { Llm_transport.response = Ok response; latency_ms = Some 1 })
      ; complete_stream =
          (fun ?on_telemetry:_ ~on_event:_ request ->
            dispatched := Some request;
            Ok response)
      }
    in
    let agent = build_admission_agent ~net ~provider_config ~transport () in
    let result = Agent_sdk.Agent.run ~sw agent "measure this exact turn" in
    result, !dispatched
  in
  match result with
  | Error error, _ -> fail (Agent_sdk.Error.to_string error)
  | Ok actual, None ->
    check string "response" "accepted" (Types.visible_text_of_response actual);
    fail "Agent route did not dispatch the admitted request"
  | Ok actual, Some request ->
    check string "response" "accepted" (Types.visible_text_of_response actual);
    check string "agent dispatch model" "input-count-fixture" request.config.model_id;
    check int "agent dispatch messages" 1 (List.length request.messages)
;;

let test_agent_stream_route_uses_prepared_admission () =
  let result, _captured =
    with_mock ~status:`OK ~response:{|{"input_tokens":321}|}
    @@ fun ~sw ~net ~base_url ->
    let provider_config = config ~max_context:512 base_url in
    let dispatched = ref None in
    let transport =
      { Llm_transport.complete_sync = (fun _ -> fail "unexpected sync dispatch")
      ; complete_stream =
          (fun ?on_telemetry:_ ~on_event:_ request ->
            dispatched := Some request;
            Ok response)
      }
    in
    let agent = build_admission_agent ~net ~provider_config ~transport () in
    let result = Agent_sdk.Agent.run_stream ~sw ~on_event:(fun _ -> ()) agent "stream" in
    result, !dispatched
  in
  match result with
  | Error error, _ -> fail (Agent_sdk.Error.to_string error)
  | Ok _, None -> fail "Agent stream route did not dispatch the admitted request"
  | Ok actual, Some request ->
    check string "stream response" "accepted" (Types.visible_text_of_response actual);
    check string "stream dispatch model" "input-count-fixture" request.config.model_id;
    check int "stream dispatch messages" 1 (List.length request.messages)
;;

let run_admitted_agent_observer ~stream =
  let observations = ref [] in
  let (result, observations), completion_body =
    with_admitted_http_mock ~stream
    @@ fun ~sw ~net ~base_url ->
    let provider_config = config ~max_context:512 base_url in
    let agent =
      build_admission_agent
        ~net
        ~provider_config
        ~pre_dispatch_serialization_observer:(fun observation ->
          observations := observation :: !observations;
          Ok ())
        ()
    in
    let result =
      if stream
      then
        Agent_sdk.Agent.run_stream
          ~sw
          ~on_event:(fun _ -> ())
          agent
          "observe admitted stream serialization"
      else Agent_sdk.Agent.run ~sw agent "observe admitted sync serialization"
    in
    result, !observations
  in
  (match result with
   | Ok _ -> ()
   | Error error -> fail (Agent_sdk.Error.to_string error));
  match completion_body with
  | None -> fail "admitted Agent path did not reach completion dispatch"
  | Some body -> body, observations
;;

let test_agent_admitted_sync_observer_sees_dispatched_body () =
  let body, observations = run_admitted_agent_observer ~stream:false in
  check_pre_dispatch_serialization ~label:"Agent.run admitted" ~body observations
;;

let test_agent_admitted_stream_observer_sees_dispatched_body () =
  let body, observations = run_admitted_agent_observer ~stream:true in
  check_pre_dispatch_serialization ~label:"Agent.run_stream admitted" ~body observations
;;

let test_agent_projection_is_shared_by_measurement_and_dispatch () =
  let projection_calls = ref 0 in
  let (result, dispatched), (_, _, measured_body) =
    with_mock ~status:`OK ~response:{|{"input_tokens":321}|}
    @@ fun ~sw ~net ~base_url ->
    let provider_config = config ~max_context:512 base_url in
    let dispatched = ref None in
    let transport =
      { Llm_transport.complete_sync =
          (fun request ->
            dispatched := Some request;
            { Llm_transport.response = Ok response; latency_ms = Some 1 })
      ; complete_stream =
          (fun ?on_telemetry:_ ~on_event:_ _ -> fail "unexpected streaming dispatch")
      }
    in
    let hydrated = msg User [ Text "hydrated artifact payload" ] in
    let agent =
      build_admission_agent
        ~net
        ~provider_config
        ~transport
        ~model_input_projection:(fun provider_messages ->
          incr projection_calls;
          Ok (provider_messages @ [ hydrated ]))
        ()
    in
    let result = Agent_sdk.Agent.run ~sw agent "canonical input" in
    result, !dispatched
  in
  match result, dispatched with
  | Error error, _ -> fail (Agent_sdk.Error.to_string error)
  | Ok _, None -> fail "projected request was not dispatched"
  | Ok _, Some request ->
    check int "projection is applied exactly once" 1 !projection_calls;
    check int "dispatch receives projected messages" 2 (List.length request.messages);
    check
      string
      "measurement and dispatch share exact request"
      (Backend_anthropic.build_count_tokens_request
         ~config:request.config
         ~messages:request.messages
         ~tools:request.tools
         ())
      measured_body
;;

let run_failing_projection projection =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let provider_config = config ~max_context:512 "http://127.0.0.1:1" in
  let transport =
    { Llm_transport.complete_sync = (fun _ -> fail "unexpected sync dispatch")
    ; complete_stream =
        (fun ?on_telemetry:_ ~on_event:_ _ -> fail "unexpected streaming dispatch")
    }
  in
  let agent =
    build_admission_agent
      ~net:(Eio.Stdenv.net env)
      ~provider_config
      ~transport
      ~model_input_projection:projection
      ()
  in
  Agent_sdk.Agent.run ~sw agent "canonical input"
;;

let check_projection_failure expected_detail = function
  | Error
      (Agent_sdk.Error.Agent
         (HookExecutionFailed
            { hook_name; stage; tool_name = None; tool_use_id = None; detail })) ->
    check string "projection hook name" "model_input_projection" hook_name;
    check string "projection stage" "turn:parse" stage;
    check string "projection detail" expected_detail detail
  | Error error -> fail (Agent_sdk.Error.to_string error)
  | Ok _ -> fail "failed projection must abort the turn"
;;

let test_agent_projection_failure_is_typed () =
  run_failing_projection (fun _ -> Error "artifact unavailable")
  |> check_projection_failure "artifact unavailable"
;;

let test_agent_projection_exception_is_typed () =
  let exception_ = Failure "projection exploded" in
  run_failing_projection (fun _ -> raise exception_)
  |> check_projection_failure (Printexc.to_string exception_)
;;

let test_agent_count_preflight_uses_completion_timeout () =
  let (result, dispatched), _captured =
    with_mock_env ~response_delay_s:1.0 ~status:`OK ~response:{|{"input_tokens":321}|}
    @@ fun ~sw ~net ~clock ~base_url ->
    let provider_config = config ~max_context:512 base_url in
    let dispatched = ref false in
    let transport =
      { Llm_transport.complete_sync =
          (fun _ ->
            dispatched := true;
            { Llm_transport.response = Ok response; latency_ms = Some 1 })
      ; complete_stream =
          (fun ?on_telemetry:_ ~on_event:_ _ -> fail "unexpected streaming dispatch")
      }
    in
    let agent =
      build_admission_agent ~body_timeout_s:0.02 ~net ~provider_config ~transport ()
    in
    let result = Agent_sdk.Agent.run ~sw ~clock agent "bounded count preflight" in
    result, !dispatched
  in
  match result, dispatched with
  (* The phase this pins is Wall_clock, not Http_operation. What the test is about is
     unchanged — the preflight is bounded by the completion timeout and no completion
     dispatch happens — but the label for a body_timeout_s breach moved, and the
     codebase's own definitions say the new one is the accurate label:
     http_client.mli:64-65 documents Wall_clock as the "whole operation wall-clock
     deadline", http_client.ml:895-897 documents Http_operation as the connect/headers
     phase and contrasts it explicitly with the body phase, and the breach reports
     "body_timeout_s total deadline exceeded". Http_operation for a body deadline was
     the older, contradictory labelling. *)
  | ( Error
        (Agent_sdk.Error.Provider
           (Llm_provider.Error.Timeout
              { timeout_phase = Some Llm_provider.Http_client.Wall_clock; _ }))
    , false ) -> ()
  | Error error, _ -> fail (Agent_sdk.Error.to_string error)
  | Ok _, _ -> fail "stalled count preflight must time out before completion dispatch"
;;

let test_agent_overflow_blocks_dispatch () =
  let result, _captured =
    with_mock ~status:`OK ~response:{|{"input_tokens":500}|}
    @@ fun ~sw ~net ~base_url ->
    let provider_config = config ~max_context:512 base_url in
    let dispatched = ref false in
    let transport =
      { Llm_transport.complete_sync =
          (fun _ ->
            dispatched := true;
            { Llm_transport.response = Ok response; latency_ms = None })
      ; complete_stream =
          (fun ?on_telemetry:_ ~on_event:_ _ -> fail "unexpected stream dispatch")
      }
    in
    let agent = build_admission_agent ~net ~provider_config ~transport () in
    let result = Agent_sdk.Agent.run ~sw agent "overflow" in
    result, !dispatched
  in
  match result with
  | Error (Agent_sdk.Error.Api (Retry.ContextOverflow { limit = Some 512; _ })), false ->
    ()
  | Error error, _ -> fail (Agent_sdk.Error.to_string error)
  | Ok _, _ -> fail "overflowed prepared request must not dispatch"
;;

let test_kimi_agent_overflow_blocks_dispatch () =
  let result, _captured =
    with_mock ~status:`OK ~response:{|{"input_tokens":500}|}
    @@ fun ~sw ~net ~base_url ->
    let provider_config = kimi_config ~max_context:512 base_url in
    let dispatched = ref false in
    let transport =
      { Llm_transport.complete_sync =
          (fun _ ->
            dispatched := true;
            { Llm_transport.response = Ok response; latency_ms = None })
      ; complete_stream =
          (fun ?on_telemetry:_ ~on_event:_ _ -> fail "unexpected stream dispatch")
      }
    in
    let agent = build_admission_agent ~net ~provider_config ~transport () in
    let result = Agent_sdk.Agent.run ~sw agent "overflow" in
    result, !dispatched
  in
  match result with
  | Error (Agent_sdk.Error.Api (Retry.ContextOverflow { limit = Some 512; _ })), false ->
    ()
  | Error error, _ -> fail (Agent_sdk.Error.to_string error)
  | Ok _, _ -> fail "overflowed Kimi request must not dispatch"
;;

let test_invalid_count_response_is_provider_parse_failure () =
  let result, _captured =
    with_mock ~status:`OK ~response:{|{"unexpected":true}|}
    @@ fun ~sw ~net ~base_url ->
    let provider_config = config ~max_context:512 base_url in
    let transport =
      { Llm_transport.complete_sync =
          (fun _ -> fail "malformed count response must block completion dispatch")
      ; complete_stream =
          (fun ?on_telemetry:_ ~on_event:_ _ ->
            fail "malformed count response must block streaming dispatch")
      }
    in
    let agent = build_admission_agent ~net ~provider_config ~transport () in
    Agent_sdk.Agent.run_detailed ~sw agent "malformed count response"
  in
  match result with
  | Error
      { Agent_sdk.Agent.error =
          Agent_sdk.Error.Api
            (Retry.InvalidRequest { reason = Retry.Json_parse_error; _ })
      ; provider_failure =
          Some { Agent_sdk.Provider_failure_attribution.evidence = Response_parse; _ }
      } -> ()
  | Error detailed -> fail (Agent_sdk.Error.to_string detailed.error)
  | Ok _ -> fail "malformed provider count response must fail"
;;

let test_unsupported_provider_preserves_compatibility () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let provider_config =
    { (config ~kind:Provider_config.OpenAI_compat ~max_context:512 "not-used") with
      response_format = Types.Off
    }
  in
  let dispatched = ref false in
  let transport =
    { Llm_transport.complete_sync =
        (fun _ ->
          dispatched := true;
          { Llm_transport.response = Ok response; latency_ms = None })
    ; complete_stream =
        (fun ?on_telemetry:_ ~on_event:_ _ -> fail "unexpected stream dispatch")
    }
  in
  let agent = build_admission_agent ~net ~provider_config ~transport () in
  match Agent_sdk.Agent.run ~sw agent "compatibility" with
  | Error error -> fail (Agent_sdk.Error.to_string error)
  | Ok _ -> check bool "compatibility dispatch" true !dispatched
;;

let test_transport_error () =
  let result, _captured =
    with_mock ~status:`Too_many_requests ~response:"rate limited"
    @@ fun ~sw ~net ~base_url ->
    Count_tokens_sync.count_anthropic ~sw ~net ~config:(config base_url) ~messages ()
  in
  match result with
  | Error (Count.Transport (Http_client.HttpError { code = 429; body; _ })) ->
    check string "provider body" "rate limited" body
  | Ok _ | Error _ -> fail "expected typed HTTP 429"
;;

let test_unsupported () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match
    Count_tokens_sync.measure_completion_request
      ~sw
      ~net:(Eio.Stdenv.net env)
      (completion_request (config ~kind:Provider_config.OpenAI_compat "not a URL"))
  with
  | Error
      (Count_tokens_sync.Input_count_failed
         (Count.Unsupported { protocol = Count.Anthropic_messages_count_tokens; model_id }))
    -> check string "model id" "input-count-fixture" model_id
  | Ok _ | Error _ -> fail "expected typed Unsupported before transport"
;;

let test_missing_output_ceiling_precedes_io () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let cfg =
    { (config "not a URL") with
      model_id = "request-measurement-missing-output-ceiling"
    ; max_tokens = None
    }
  in
  match
    Count_tokens_sync.measure_completion_request
      ~sw
      ~net:(Eio.Stdenv.net env)
      (completion_request cfg)
  with
  | Error
      (Count_tokens_sync.Output_token_resolution_failed
         Types.Required_output_token_ceiling_missing) -> ()
  | Ok _ | Error _ -> fail "expected typed output-token failure before count I/O"
;;

let test_count_tokens_url () =
  check
    string
    "plain path"
    "https://api.anthropic.com/proxy/messages/count_tokens"
    (Count_tokens_sync.count_tokens_url (config "https://api.anthropic.com"));
  check
    string
    "query string preserved after inserted segment"
    "https://proxy.example/proxy/messages/count_tokens?api-version=2024-06"
    (Count_tokens_sync.count_tokens_url
       (config
          ~request_path:"/proxy/messages?api-version=2024-06"
          "https://proxy.example"))
;;

let () =
  run
    "anthropic-input-token-count"
    [ ( "request"
      , [ test_case "shared canonical projection" `Quick test_shared_projection
        ; test_case "Kimi shared canonical projection" `Quick test_kimi_shared_projection
        ] )
    ; ( "transport"
      , [ test_case "native success" `Quick test_transport_success
        ; test_case "Kimi native success" `Quick test_kimi_transport_success
        ; test_case
            "prepared measure admit dispatch"
            `Quick
            test_prepared_measure_admit_dispatch
        ; test_case
            "prepared context overflow is typed"
            `Quick
            test_prepared_context_overflow_is_typed
        ; test_case
            "prepared admission resolves catalog context limit"
            `Quick
            test_prepared_admission_resolves_catalog_context_limit
        ; test_case
            "resolve before measure skips count round-trip"
            `Quick
            test_resolve_before_measure_skips_count_roundtrip
        ; test_case
            "resolve before measure skips count round-trip (stream)"
            `Quick
            test_resolve_before_measure_skips_count_roundtrip_stream
        ; test_case
            "serving boundary uses exact provider count"
            `Quick
            test_serving_constraint_uses_exact_provider_count
        ; test_case
            "stale serving evidence is zero-I/O"
            `Quick
            test_stale_serving_constraint_fails_before_measurement
        ; test_case
            "unmeasurable serving constraint is typed zero-dispatch"
            `Quick
            test_unmeasurable_constraint_fails_typed_without_dispatch
        ; test_case
            "serialization admission validates before I/O"
            `Quick
            test_serialization_admission_validates_before_io
        ; test_case
            "measurement uses provider admission"
            `Quick
            test_measurement_uses_provider_admission
        ; test_case
            "Agent route uses prepared admission"
            `Quick
            test_agent_route_uses_prepared_admission
        ; test_case
            "Agent stream route uses prepared admission"
            `Quick
            test_agent_stream_route_uses_prepared_admission
        ; test_case
            "Agent admitted sync observes dispatched serialization"
            `Quick
            test_agent_admitted_sync_observer_sees_dispatched_body
        ; test_case
            "Agent admitted stream observes dispatched serialization"
            `Quick
            test_agent_admitted_stream_observer_sees_dispatched_body
        ; test_case
            "admitted body is frozen across catalog mutation"
            `Quick
            test_admitted_body_is_frozen_across_catalog_mutation
        ; test_case
            "Agent projection is shared by measurement and dispatch"
            `Quick
            test_agent_projection_is_shared_by_measurement_and_dispatch
        ; test_case
            "Agent projection failure is typed"
            `Quick
            test_agent_projection_failure_is_typed
        ; test_case
            "Agent projection exception is typed"
            `Quick
            test_agent_projection_exception_is_typed
        ; test_case
            "Agent count preflight uses completion timeout"
            `Quick
            test_agent_count_preflight_uses_completion_timeout
        ; test_case
            "Agent overflow blocks dispatch"
            `Quick
            test_agent_overflow_blocks_dispatch
        ; test_case
            "Kimi Agent overflow blocks dispatch"
            `Quick
            test_kimi_agent_overflow_blocks_dispatch
        ; test_case
            "sync body admission precedes token measurement"
            `Quick
            test_sync_body_admission_precedes_measurement
        ; test_case
            "stream body admission precedes token measurement"
            `Quick
            test_stream_body_admission_precedes_measurement
        ; test_case
            "invalid count response is provider parse failure"
            `Quick
            test_invalid_count_response_is_provider_parse_failure
        ; test_case
            "unsupported provider preserves compatibility"
            `Quick
            test_unsupported_provider_preserves_compatibility
        ; test_case "typed HTTP error" `Quick test_transport_error
        ; test_case "non-Anthropic unsupported" `Quick test_unsupported
        ; test_case
            "missing output ceiling precedes I/O"
            `Quick
            test_missing_output_ceiling_precedes_io
        ; test_case "count-tokens URL insertion" `Quick test_count_tokens_url
        ] )
    ]
;;
