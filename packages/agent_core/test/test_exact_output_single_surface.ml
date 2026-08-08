open Alcotest
open Llm_provider
module EO = Agent_sdk.Exact_output

let _preserve_public_raw_sync_response_surface
      ({ status = _; body = _; retry_after_header = _ } : Http_client.raw_sync_response)
  =
  ()
;;

let _preserve_public_success_surface
      ({ call_id = _; receipt = _; output = _; provenance = _; raw_response = _ } :
        EO.success)
  =
  ()
;;

let msg text : Types.message =
  { role = Types.User
  ; content = [ Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ "name", `Assoc [ "type", `String "string" ]
          ; "schema", `Assoc [ "type", `String "string" ]
          ] )
    ; "required", `List [ `String "name" ]
    ; "additionalProperties", `Bool false
    ]
;;

let capabilities_with_supported_models ~supported_models ~native ~json =
  { Capabilities.default_capabilities with
    max_context_tokens = Some 8192
  ; max_output_tokens = Some 1024
  ; supports_response_format_json = json
  ; supports_structured_output = native
  ; supported_models
  }
;;

let capabilities ~native ~json =
  capabilities_with_supported_models ~supported_models:None ~native ~json
;;

type catalog_fixture =
  { id : string
  ; kind : Provider_config.provider_kind
  ; base_url : string
  ; base_url_env : string option
  ; request_path : string
  ; api_key_env : string
  ; capabilities : Capabilities.capabilities
  ; max_request_body_bytes : int option
  ; body_timeout_s : float option
  }

let catalog_entry
      ?base_url_env
      ?(api_key_env = "")
      ?max_request_body_bytes
      ?body_timeout_s
      ~id
      ~kind
      ~base_url
      ~request_path
      ~capabilities
      ()
  =
  { id
  ; kind
  ; base_url
  ; base_url_env
  ; request_path
  ; api_key_env
  ; capabilities
  ; max_request_body_bytes
  ; body_timeout_s
  }
;;

let catalog_fixture_toml entry =
  Printf.sprintf
    "[[providers]]\n\
     id = %S\n\
     kind = %S\n\
     base_url = %S\n\
     %srequest_path = %S\n\
     api_key_env = %S\n\n\
     [[models]]\n\
     id_prefix = %S\n\
     provider_name = %S\n\
     max_context_tokens = 8192\n\
     max_output_tokens = 1024\n\
     supports_response_format_json = %b\n\
     supports_structured_output = %b\n\
     %s\n\
     [[targets]]\n\
     id = %S\n\
     provider_ref = %S\n\
     model_id = %S\n\
     %s%s"
    entry.id
    (Provider_config.string_of_provider_kind entry.kind)
    entry.base_url
    (match entry.base_url_env with
     | None -> ""
     | Some name -> Printf.sprintf "base_url_env = %S\n" name)
    entry.request_path
    entry.api_key_env
    (entry.id ^ "-model")
    entry.id
    entry.capabilities.supports_response_format_json
    entry.capabilities.supports_structured_output
    (match entry.capabilities.supported_models with
     | None -> ""
     | Some models ->
       Printf.sprintf
         "supported_models = [%s]\n"
         (String.concat ", " (List.map (Printf.sprintf "%S") models)))
    entry.id
    entry.id
    (entry.id ^ "-model")
    (match entry.max_request_body_bytes with
     | None -> ""
     | Some bytes -> Printf.sprintf "max_request_body_bytes = %d\n" bytes)
    (match entry.body_timeout_s with
     | None -> ""
     | Some seconds -> Printf.sprintf "body_timeout_s = %.17g\n" seconds)
;;

let with_catalog ?(getenv = fun _ -> Ok None) entries f =
  let overlay : EO.catalog_document =
    { source = "exact-output single-surface fixture"
    ; contents = String.concat "\n" (List.map catalog_fixture_toml entries)
    }
  in
  let io : EO.resolver_io = { getenv } in
  match EO.load_resolver_snapshot ~io ~catalog:(EO.Embedded_with_overlay overlay) () with
  | Error _ -> fail "resolver snapshot should load"
  | Ok snapshot -> f snapshot
;;

let target snapshot selector =
  let admitted =
    match EO.admit_target_ref snapshot selector with
    | Ok admitted -> admitted
    | Error _ -> failf "target ref %s was not admitted" selector
  in
  match EO.resolve_target admitted with
  | Ok target -> target
  | Error _ -> failf "target %s did not resolve" selector
;;

let requirement_for domain_schema minimum_guarantee =
  EO.make_output_requirement ~schema:domain_schema ~minimum_guarantee
;;

let requirement minimum_guarantee = requirement_for schema minimum_guarantee

let plan_for_schema snapshot selector domain_schema minimum_guarantee =
  match
    EO.admit
      ~target:(target snapshot selector)
      ~messages:[ msg "return one object" ]
      (requirement_for domain_schema minimum_guarantee)
  with
  | Ok plan -> plan
  | Error _ -> failf "target %s did not admit" selector
;;

let plan snapshot selector minimum_guarantee =
  plan_for_schema snapshot selector schema minimum_guarantee
;;

let flow_from_admitted_target ~id ~messages requirement admitted_target =
  let candidate =
    match EO.make_flow_candidate ~id ~admitted_target with
    | Ok candidate -> candidate
    | Error EO.Blank_flow_candidate_id ->
      failf "target ref %s produced a blank flow candidate" id
  in
  match EO.snapshot_flow ~first:candidate ~rest:[] ~messages requirement with
  | Ok flow -> flow
  | Error _ -> failf "target ref %s did not produce a single-candidate flow" id
;;

let flow_for_schema snapshot selector domain_schema minimum_guarantee =
  let admitted_target =
    match EO.admit_target_ref snapshot selector with
    | Ok admitted -> admitted
    | Error _ -> failf "target ref %s was not admitted for a flow" selector
  in
  flow_from_admitted_target
    ~id:selector
    ~messages:[ msg "return one object" ]
    (requirement_for domain_schema minimum_guarantee)
    admitted_target
;;

let flow snapshot selector minimum_guarantee =
  flow_for_schema snapshot selector schema minimum_guarantee
;;

type single_execution =
  { flow : EO.flow_attempt
  ; receipt : EO.receipt option Atomic.t
  }

let attempt ready =
  match EO.start_flow ready with
  | Ok flow -> { flow; receipt = Atomic.make None }
  | Error (EO.Flow_id_generation_failed detail) ->
    failf "exact flow identity allocation failed: %s" detail
;;

type no_semantic_rejection = |

let accept_transport success
  : (EO.flow_success, no_semantic_rejection) EO.semantic_verdict
  =
  EO.Accept success
;;

let execution_receipt execution =
  match Atomic.get execution.receipt with
  | Some receipt -> receipt
  | None -> fail "single-candidate flow did not allocate an execution receipt"
;;

let execute_once ~net ?clock execution =
  let before_dispatch (candidate : EO.flow_attempt_receipt) =
    Atomic.set execution.receipt (Some candidate.EO.receipt);
    Ok ()
  in
  match
    EO.execute_flow_once
      ~net
      ?clock
      ~before_measurement_dispatch:(fun _ -> Ok ())
      ~on_measurement_terminal:(fun _ -> Ok ())
      ~before_dispatch
      ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
      ~validate:accept_transport
      execution.flow
  with
  | Ok success -> Ok (EO.flow_success_output success.accepted)
  | Error
      (EO.Flow_execution_terminal
         { cause = EO.Flow_exact_execution_failed { cause; _ }; _ }) -> Error cause
  | Error (EO.Flow_execution_terminal { cause = EO.Flow_attempt_already_started _; _ }) ->
    let receipt = execution_receipt execution in
    Error
      { EO.call_id = EO.receipt_call_id receipt
      ; receipt
      ; cause = EO.Attempt_already_started
      ; raw_response = None
      }
  | Error (EO.Flow_semantic_candidates_exhausted _) -> .
  | Error (EO.Flow_execution_terminal _) ->
    fail "single-candidate flow failed outside exact execution"
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

type capture =
  { path : string
  ; body : string
  ; headers : (string * string) list
  }

let openai_response content =
  let encoded_content = Yojson.Safe.to_string (`String content) in
  Printf.sprintf
    {|{"id":"resp-surface","model":"surface","choices":[{"index":0,"message":{"role":"assistant","content":%s},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
    encoded_content
;;

let ollama_response content =
  let encoded_content = Yojson.Safe.to_string (`String content) in
  Printf.sprintf
    {|{"model":"surface","created_at":"2026-07-22T00:00:00Z","message":{"role":"assistant","content":%s},"done":true,"done_reason":"stop","prompt_eval_count":1,"eval_count":1}|}
    encoded_content
;;

let anthropic_response ?(stop_reason = "end_turn") content =
  Printf.sprintf
    {|{"id":"msg-surface","type":"message","role":"assistant","model":"surface","content":%s,"stop_reason":"%s","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}|}
    content
    stop_reason
;;

let gemini_response content =
  let encoded_content = Yojson.Safe.to_string (`String content) in
  Printf.sprintf
    {|{"candidates":[{"content":{"role":"model","parts":[{"text":%s}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1,"totalTokenCount":2}}|}
    encoded_content
;;

let with_server
      ?response_delay_s
      ?(status = `OK)
      ?(abort_completion = false)
      ?(response_headers = [])
      ?(on_completion_request = fun () -> ())
      ~response
      f
  =
  let completion_posts = Atomic.make 0 in
  let token_posts = Atomic.make 0 in
  let captures = Atomic.make [] in
  let result =
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    let port = fresh_port () in
    let handler _conn request body =
      let request_body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
      let path = Cohttp.Request.uri request |> Uri.path in
      if String.equal (Filename.basename path) "count_tokens"
      then (
        Atomic.incr token_posts;
        Cohttp_eio.Server.respond_string ~status:`OK ~body:{|{"input_tokens":1}|} ())
      else (
        Atomic.incr completion_posts;
        on_completion_request ();
        Atomic.set
          captures
          ({ path
           ; body = request_body
           ; headers = Cohttp.Request.headers request |> Cohttp.Header.to_list
           }
           :: Atomic.get captures);
        if abort_completion then raise Exit;
        Option.iter (Eio.Time.sleep clock) response_delay_s;
        Cohttp_eio.Server.respond_string
          ~headers:(Cohttp.Header.of_list response_headers)
          ~status
          ~body:response
          ())
    in
    let socket =
      Eio.Net.listen
        net
        ~sw
        ~backlog:8
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let server = Cohttp_eio.Server.make ~callback:handler () in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
    f ~sw ~net ~clock ~base_url:(Printf.sprintf "http://127.0.0.1:%d" port)
  in
  ( result
  , Atomic.get completion_posts
  , Atomic.get token_posts
  , List.rev (Atomic.get captures) )
;;

let cancel_execute_once_after_dispatch ~sw ~net ~clock ~request_seen execution =
  let exception Caller_cancelled in
  let cancel_context, notify_cancel_context = Eio.Promise.create () in
  let client_outcome, notify_client_outcome = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let cancelled =
      try
        ignore
          (Eio.Cancel.sub (fun context ->
             Eio.Promise.resolve notify_cancel_context context;
             execute_once ~net execution));
        false
      with
      | Eio.Cancel.Cancelled Caller_cancelled -> true
    in
    Eio.Promise.resolve notify_client_outcome cancelled);
  let await label promise =
    try Eio.Time.with_timeout_exn clock 1.0 (fun () -> Eio.Promise.await promise) with
    | Eio.Time.Timeout -> failf "%s was not observed" label
  in
  let cancel_context = await "client cancellation context" cancel_context in
  await "completion request dispatch" request_seen;
  Eio.Cancel.cancel cancel_context Caller_cancelled;
  await "client cancellation" client_outcome
;;

let test_tier_table_and_provider_schema_rejection () =
  let entry id native json =
    catalog_entry
      ~id
      ~kind:Provider_config.OpenAI_compat
      ~base_url:"https://surface.invalid"
      ~request_path:"/v1/chat/completions"
      ~capabilities:(capabilities ~native ~json)
      ()
  in
  with_catalog
    [ entry "native" true true; entry "json-only" false true; entry "none" false false ]
  @@ fun snapshot ->
  let native_json = plan snapshot "native" EO.Json_syntax |> EO.plan_provenance in
  let native_schema = plan snapshot "native" EO.Provider_schema |> EO.plan_provenance in
  let json_only = plan snapshot "json-only" EO.Json_syntax |> EO.plan_provenance in
  let text_only = plan snapshot "none" EO.Json_syntax |> EO.plan_provenance in
  check
    bool
    "syntax minimum does not request a provider schema"
    true
    (EO.plan_provenance_actual_assurance native_json = EO.Json_syntax_only);
  check
    bool
    "syntax minimum has no effective schema"
    true
    (Option.is_none (EO.plan_provenance_effective_schema_fingerprint native_json));
  check
    bool
    "native satisfies provider schema"
    true
    (EO.plan_provenance_actual_assurance native_schema = EO.Provider_schema_requested);
  check
    bool
    "native has effective schema fingerprint"
    true
    (Option.is_some (EO.plan_provenance_effective_schema_fingerprint native_schema));
  check
    bool
    "json-only records syntax assurance"
    true
    (EO.plan_provenance_actual_assurance json_only = EO.Json_syntax_only);
  check
    bool
    "json-only has no effective schema"
    true
    (Option.is_none (EO.plan_provenance_effective_schema_fingerprint json_only));
  check
    bool
    "text fallback records syntax assurance"
    true
    (EO.plan_provenance_actual_assurance text_only = EO.Json_syntax_only);
  check
    bool
    "text fallback has no effective provider schema"
    true
    (Option.is_none (EO.plan_provenance_effective_schema_fingerprint text_only));
  match
    EO.admit
      ~target:(target snapshot "json-only")
      ~messages:[ msg "json" ]
      (requirement EO.Provider_schema)
  with
  | Error error ->
    (match EO.admission_error_disposition error with
     | EO.Output_requirement_rejected -> ()
     | _ -> fail "provider-schema rejection lost its neutral disposition")
  | Ok _ -> fail "provider-schema minimum must fail on JSON-only target"
;;

let test_deepseek_catalog_is_json_only_before_dispatch () =
  let target_id = "deepseek-json-only-surface" in
  let overlay : EO.catalog_document =
    { source = "DeepSeek exact-output capability fixture"
    ; contents =
        Printf.sprintf
          "[[targets]]\n\
           id = %S\n\
           provider_ref = \"deepseek\"\n\
           model_id = \"deepseek-v4-pro\"\n"
          target_id
    }
  in
  let getenv name =
    Ok
      (if String.equal name "DEEPSEEK_API_KEY" then Some "deepseek-fixture-key" else None)
  in
  let io : EO.resolver_io = { getenv } in
  match EO.load_resolver_snapshot ~io ~catalog:(EO.Embedded_with_overlay overlay) () with
  | Error _ -> fail "DeepSeek exact-output target should resolve"
  | Ok snapshot ->
    let selected = target snapshot target_id in
    (match
       EO.admit ~target:selected ~messages:[ msg "json" ] (requirement EO.Json_syntax)
     with
     | Ok ready ->
       check
         bool
         "DeepSeek JSON mode remains syntax-only"
         true
         (EO.plan_provenance_actual_assurance (EO.plan_provenance ready)
          = EO.Json_syntax_only)
     | Error _ -> fail "DeepSeek JSON syntax requirement should admit");
    (match
       EO.admit
         ~target:selected
         ~messages:[ msg "schema" ]
         (requirement EO.Provider_schema)
     with
     | Error error ->
       (match EO.admission_error_disposition error with
        | EO.Output_requirement_rejected -> ()
        | _ -> fail "DeepSeek schema rejection lost its neutral disposition")
     | Ok _ -> fail "DeepSeek provider schema must reject before dispatch")
;;

let test_request_body_limit_is_typed_and_pre_dispatch () =
  let id = "request-body-limit" in
  let admission, completion_posts, token_posts, captures =
    with_server ~response:(openai_response {|{"name":"must not arrive"}|})
    @@ fun ~sw:_ ~net:_ ~clock:_ ~base_url ->
    let entry =
      catalog_entry
        ~id
        ~kind:Provider_config.OpenAI_compat
        ~base_url
        ~request_path:"/v1/chat/completions"
        ~max_request_body_bytes:1
        ~capabilities:(capabilities ~native:true ~json:true)
        ()
    in
    with_catalog [ entry ]
    @@ fun snapshot ->
    EO.admit
      ~target:(target snapshot id)
      ~messages:[ msg "this serialized request is larger than one byte" ]
      (requirement EO.Json_syntax)
  in
  (match admission with
   | Error error ->
     (match EO.admission_error_disposition error with
      | EO.Input_capacity
          (EO.Serialized_request_body_too_large { actual_bytes; limit_bytes }) ->
        check int "resolved exact-target byte limit" 1 limit_bytes;
        check
          bool
          "actual serialized request bytes measured"
          true
          (actual_bytes > limit_bytes)
      | _ -> fail "oversized request lost its neutral byte-cap disposition")
   | Ok _ -> fail "oversized exact-output request unexpectedly admitted");
  check int "completion POST count" 0 completion_posts;
  check int "token measurement POST count" 0 token_posts;
  check int "captured request count" 0 (List.length captures)
;;

let test_supported_models_membership_is_exact_and_pre_dispatch () =
  let allowed_id = "membership-allowed" in
  let rejected_id = "membership-rejected" in
  let (allowed, rejected), completion_posts, token_posts, captures =
    with_server ~response:(openai_response {|{"name":"unused"}|})
    @@ fun ~sw:_ ~net:_ ~clock:_ ~base_url ->
    let entry id supported_models =
      catalog_entry
        ~id
        ~kind:Provider_config.OpenAI_compat
        ~base_url
        ~request_path:"/v1/chat/completions"
        ~capabilities:
          (capabilities_with_supported_models
             ~native:true
             ~json:true
             ~supported_models:(Some supported_models))
        ()
    in
    with_catalog
      [ entry allowed_id [ allowed_id ^ "-model" ]
      ; entry rejected_id [ "MEMBERSHIP-REJECTED-MODEL" ]
      ]
    @@ fun snapshot ->
    let admit id =
      EO.admit
        ~target:(target snapshot id)
        ~messages:[ msg "membership" ]
        (requirement EO.Json_syntax)
    in
    admit allowed_id, admit rejected_id
  in
  (match allowed with
   | Ok _ -> ()
   | Error _ -> fail "exact supported model must admit");
  (match rejected with
   | Error error ->
     (match EO.admission_error_disposition error with
      | EO.Runtime_contract_rejected -> ()
      | _ -> fail "model membership rejection lost its neutral disposition")
   | Ok _ -> fail "case-only non-member must return the typed rejection");
  check int "membership rejection completion posts" 0 completion_posts;
  check int "membership rejection token posts" 0 token_posts;
  check int "membership rejection captures" 0 (List.length captures)
;;

let test_wire_envelope_and_cross_feature_injection_rejected () =
  let smuggled =
    `Assoc [ "name", `String "attacker"; "schema", schema; "strict", `Bool false ]
  in
  let entry =
    catalog_entry
      ~id:"cross-feature"
      ~kind:Provider_config.OpenAI_compat
      ~base_url:"https://surface.invalid"
      ~request_path:"/v1/chat/completions"
      ~capabilities:(capabilities ~native:true ~json:true)
      ()
  in
  with_catalog [ entry ]
  @@ fun snapshot ->
  (match
     EO.admit
       ~target:(target snapshot "cross-feature")
       ~messages:[ msg "domain schema" ]
       (EO.make_output_requirement ~schema:smuggled ~minimum_guarantee:EO.Json_syntax)
   with
   | Ok _ -> ()
   | Error _ -> fail "domain schema keys must remain opaque to wire admission");
  let benign_metadata_message =
    { (msg "domain metadata") with metadata = [ "domain.note", `String "preserved" ] }
  in
  (match
     EO.admit
       ~target:(target snapshot "cross-feature")
       ~messages:[ benign_metadata_message ]
       (requirement EO.Json_syntax)
   with
   | Ok _ -> ()
   | Error _ -> fail "unrelated domain metadata must remain admissible");
  let wire_phase_message =
    { (msg "reserved wire metadata") with
      role = Types.Assistant
    ; metadata = [ "openai.responses.phase", `String "commentary" ]
    }
  in
  (match
     EO.admit
       ~target:(target snapshot "cross-feature")
       ~messages:[ wire_phase_message ]
       (requirement EO.Json_syntax)
   with
   | Error error ->
     (match EO.admission_error_disposition error with
      | EO.Input_contract_rejected -> ()
      | _ -> fail "reserved wire metadata lost its neutral disposition")
   | Ok _ -> fail "reserved wire metadata must reject before dispatch");
  let tool_role_message = { (msg "tool role") with role = Types.Tool } in
  (match
     EO.admit
       ~target:(target snapshot "cross-feature")
       ~messages:[ tool_role_message ]
       (requirement EO.Json_syntax)
   with
   | Error error ->
     (match EO.admission_error_disposition error with
      | EO.Input_contract_rejected -> ()
      | _ -> fail "tool role rejection lost its neutral disposition")
   | Ok _ -> fail "tool role must reject before exact dispatch");
  let tool_message : Types.message =
    { role = Types.Assistant
    ; content = [ Types.ToolUse { id = "tool-1"; name = "forbidden"; input = `Assoc [] } ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  match
    EO.admit
      ~target:(target snapshot "cross-feature")
      ~messages:[ tool_message ]
      (requirement EO.Json_syntax)
  with
  | Error error ->
    (match EO.admission_error_disposition error with
     | EO.Input_contract_rejected -> ()
     | _ -> fail "tool history rejection lost its neutral disposition")
  | Ok _ -> fail "tool history must reject before exact dispatch"
;;

let test_anthropic_schema_prefill_rejected_before_dispatch () =
  let admission, completion_posts, token_posts, captures =
    with_server ~response:(anthropic_response {|[{"type":"text","text":"{}"}]|})
    @@ fun ~sw:_ ~net:_ ~clock:_ ~base_url ->
    let entry =
      catalog_entry
        ~id:"anthropic-prefill"
        ~kind:Provider_config.Anthropic
        ~base_url
        ~request_path:"/v1/messages"
        ~capabilities:(capabilities ~native:true ~json:false)
        ()
    in
    with_catalog [ entry ]
    @@ fun snapshot ->
    let prefill = { (msg "prefill") with role = Types.Assistant } in
    EO.admit
      ~target:(target snapshot "anthropic-prefill")
      ~messages:[ msg "return JSON"; prefill ]
      (requirement EO.Provider_schema)
  in
  (match admission with
   | Error error ->
     (match EO.admission_error_disposition error with
      | EO.Input_contract_rejected -> ()
      | _ -> fail "Anthropic prefill rejection lost its neutral disposition")
   | Ok _ -> fail "Anthropic schema prefill must reject during admission");
  check int "Anthropic prefill completion posts" 0 completion_posts;
  check int "Anthropic prefill token posts" 0 token_posts;
  check int "Anthropic prefill captures" 0 (List.length captures)
;;

let assert_absent json field =
  match json with
  | `Assoc fields -> check bool (field ^ " absent") false (List.mem_assoc field fields)
  | _ -> fail "captured request body must be a JSON object"
;;

let test_no_measure_one_post_and_wire_authority () =
  let run ?(domain_schema = schema) ~id ~kind ~path ~response inspect =
    let (provenance, plan_fingerprint, result), completion_posts, token_posts, captures =
      with_server ~response
      @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
      let entry =
        catalog_entry
          ~id
          ~kind
          ~base_url
          ~request_path:path
          ~capabilities:(capabilities ~native:true ~json:true)
          ()
      in
      with_catalog [ entry ]
      @@ fun snapshot ->
      let ready = plan_for_schema snapshot id domain_schema EO.Provider_schema in
      let execution =
        flow_for_schema snapshot id domain_schema EO.Provider_schema |> attempt
      in
      EO.plan_provenance ready, EO.plan_fingerprint ready, execute_once ~net execution
    in
    check int (id ^ " completion posts") 1 completion_posts;
    check int (id ^ " token posts") 0 token_posts;
    let capture =
      match captures with
      | [ capture ] -> capture
      | _ -> fail "expected one completion capture"
    in
    check string (id ^ " path") path capture.path;
    let body = Yojson.Safe.from_string capture.body in
    List.iter
      (assert_absent body)
      [ "tools"
      ; "tool_choice"
      ; "parallel_tool_calls"
      ; "reasoning_effort"
      ; "thinking"
      ; "pricing"
      ; "retry"
      ; "retries"
      ; "max_retries"
      ; "fallbacks"
      ; "internal_model_rotation_count"
      ];
    check
      bool
      (id ^ " server-side fallback header absent")
      false
      (List.exists
         (fun (name, value) ->
            String.equal (String.lowercase_ascii name) "anthropic-beta"
            && value
               |> String.split_on_char ','
               |> List.exists (fun beta ->
                 String.equal (String.trim beta) "server-side-fallback-2026-06-01"))
         capture.headers);
    inspect provenance body;
    match result with
    | Ok (success : EO.success) ->
      check
        bool
        (id ^ " output")
        true
        (success.output = `Assoc [ "name", `String "accepted" ]);
      check string (id ^ " raw body") response success.raw_response.body;
      check int (id ^ " receipt dispatch") 1 (EO.receipt_dispatch_count success.receipt);
      check
        string
        (id ^ " stable call identity")
        (EO.call_id_to_string success.call_id)
        (EO.receipt_call_id success.receipt |> EO.call_id_to_string);
      check
        string
        (id ^ " receipt plan fingerprint")
        plan_fingerprint
        (EO.receipt_plan_fingerprint success.receipt);
      check
        string
        (id ^ " frozen body digest")
        Digestif.SHA256.(to_hex (digest_string capture.body))
        (EO.receipt_request_body_sha256 success.receipt)
    | Error _ -> fail (id ^ " exact execution failed")
  in
  let content = {|{"name":"accepted"}|} in
  run
    ~domain_schema:
      (`Assoc
          [ "name", `String "caller-controlled"; "schema", schema; "strict", `Bool false ])
    ~id:"openai-surface"
    ~kind:Provider_config.OpenAI_compat
    ~path:"/v1/chat/completions"
    ~response:(openai_response content)
    (fun provenance body ->
       let envelope =
         Yojson.Safe.Util.(body |> member "response_format" |> member "json_schema")
       in
       check
         bool
         "OAS forces strict OpenAI schema"
         true
         Yojson.Safe.Util.(envelope |> member "strict" |> to_bool);
       let nested = Yojson.Safe.Util.member "schema" envelope in
       check
         string
         "caller name remains nested domain data"
         "caller-controlled"
         Yojson.Safe.Util.(nested |> member "name" |> to_string);
       check
         bool
         "caller strict remains nested domain data"
         false
         Yojson.Safe.Util.(nested |> member "strict" |> to_bool);
       match EO.plan_provenance_effective_schema_fingerprint provenance with
       | Some effective ->
         check
           bool
           "source and actual wire fingerprints differ"
           true
           (not
              (String.equal
                 (EO.plan_provenance_source_schema_fingerprint provenance
                  |> EO.schema_fingerprint_to_string)
                 (EO.schema_fingerprint_to_string effective)))
       | None -> fail "OpenAI native schema must expose its wire fingerprint");
  run
    ~id:"ollama-surface"
    ~kind:Provider_config.Ollama
    ~path:"/api/chat"
    ~response:(ollama_response content)
    (fun _provenance body ->
       check
         bool
         "Ollama receives raw schema"
         true
         Yojson.Safe.Util.(
           body |> member "format" |> member "type" |> to_string = "object"));
  run
    ~id:"anthropic-surface"
    ~kind:Provider_config.Anthropic
    ~path:"/v1/messages"
    ~response:(anthropic_response {|[{"type":"text","text":"{\"name\":\"accepted\"}"}]|})
    (fun _provenance _body -> ())
;;

let test_provider_trace_fingerprint_anchors_normalized_headers_and_body () =
  let run ~response_headers response =
    let result, posts, _, _ =
      with_server ~response_headers ~response
      @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
      let entry =
        catalog_entry
          ~id:"provider-trace-surface"
          ~kind:Provider_config.OpenAI_compat
          ~base_url
          ~request_path:"/v1/chat/completions"
          ~capabilities:(capabilities ~native:true ~json:true)
          ()
      in
      with_catalog [ entry ]
      @@ fun snapshot ->
      execute_once ~net (attempt (flow snapshot "provider-trace-surface" EO.Json_syntax))
    in
    check int "provider trace uses one POST" 1 posts;
    match result with
    | Error _ -> fail "provider trace fixture failed"
    | Ok success ->
      (match EO.receipt_provider_trace success.receipt with
       | None -> fail "success receipt lost provider trace"
       | Some trace -> EO.provider_trace_fingerprint trace)
  in
  let response = openai_response {|{"name":"accepted"}|} in
  let first =
    run ~response_headers:[ "X-Trace-B", " beta "; "X-Trace-A", "alpha" ] response
  in
  let reordered =
    run ~response_headers:[ "x-trace-a", "alpha"; "x-trace-b", "beta" ] response
  in
  check string "header normalization is deterministic" first reordered;
  let changed_header =
    run ~response_headers:[ "x-trace-a", "changed"; "x-trace-b", "beta" ] response
  in
  check
    bool
    "provider trace is header-sensitive"
    true
    (not (String.equal first changed_header));
  let changed_body =
    run
      ~response_headers:[ "x-trace-a", "alpha"; "x-trace-b", "beta" ]
      (openai_response {|{"name":"different"}|})
  in
  check
    bool
    "provider trace is body-sensitive"
    true
    (not (String.equal first changed_body))
;;

let test_response_received_error_evidence_matrix () =
  let run label response matches_cause =
    let result, posts, _, _ =
      with_server ~response
      @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
      let entry =
        catalog_entry
          ~id:"error-surface"
          ~kind:Provider_config.OpenAI_compat
          ~base_url
          ~request_path:"/v1/chat/completions"
          ~capabilities:(capabilities ~native:true ~json:true)
          ()
      in
      with_catalog [ entry ]
      @@ fun snapshot ->
      execute_once ~net (attempt (flow snapshot "error-surface" EO.Json_syntax))
    in
    check int (label ^ " dispatches once") 1 posts;
    match result with
    | Error { EO.call_id; receipt; cause; raw_response = Some raw } ->
      check bool (label ^ " typed cause") true (matches_cause cause);
      check
        string
        (label ^ " stable call identity")
        (EO.call_id_to_string call_id)
        (EO.receipt_call_id receipt |> EO.call_id_to_string);
      check string (label ^ " lossless body") response raw.body;
      check
        string
        (label ^ " exact body digest")
        Digestif.SHA256.(to_hex (digest_string response))
        raw.body_sha256;
      check
        (option int)
        (label ^ " response status")
        (Some 200)
        (EO.receipt_http_status receipt);
      check
        bool
        (label ^ " typed error receipt trace")
        true
        (Option.is_some (EO.receipt_provider_trace receipt))
    | Ok _ | Error _ -> fail (label ^ " lost response-received evidence")
  in
  let completion_failed = function
    | EO.Completion_failed -> true
    | _ -> false
  in
  let invalid_json = function
    | EO.Invalid_json_output -> true
    | _ -> false
  in
  run "provider parser" "not-provider-json" completion_failed;
  [ "fenced JSON", "```json\n{\"name\":\"accepted\"}\n```"
  ; "valid JSON with trailing text", "{\"name\":\"accepted\"} trailing"
  ; "consecutive JSON values", "{\"name\":\"first\"}{\"name\":\"second\"}"
  ]
  |> List.iter (fun (label, content) -> run label (openai_response content) invalid_json)
;;

let check_receipt label ~phase ~dispatch_count ~http_status receipt =
  check bool (label ^ " phase") true (EO.receipt_phase receipt = phase);
  check int (label ^ " dispatch count") dispatch_count (EO.receipt_dispatch_count receipt);
  check (option int) (label ^ " HTTP status") http_status (EO.receipt_http_status receipt)
;;

let test_public_receipt_phase_matrix () =
  let pre_result, pre_posts, _, _ =
    with_server ~response:"unused"
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    let entry =
      catalog_entry
        ~id:"pre-dispatch-surface"
        ~kind:Provider_config.OpenAI_compat
        ~base_url
        ~request_path:"/v1/chat/completions"
        ~capabilities:(capabilities ~native:true ~json:true)
        ~body_timeout_s:1.0
        ()
    in
    with_catalog [ entry ]
    @@ fun snapshot ->
    execute_once ~net (attempt (flow snapshot "pre-dispatch-surface" EO.Json_syntax))
  in
  check int "pre-dispatch has zero POSTs" 0 pre_posts;
  (match pre_result with
   | Error { EO.receipt; cause = EO.Clock_required_for_timeout; raw_response = None; _ }
     ->
     check_receipt
       "pre-dispatch"
       ~phase:EO.Before_dispatch
       ~dispatch_count:0
       ~http_status:None
       receipt
   | Ok _ | Error _ -> fail "pre-dispatch failure was not typed conservatively");
  let abort_result, abort_posts, _, _ =
    with_server ~abort_completion:true ~response:"unused"
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    let entry =
      catalog_entry
        ~id:"abort-surface"
        ~kind:Provider_config.OpenAI_compat
        ~base_url
        ~request_path:"/v1/chat/completions"
        ~capabilities:(capabilities ~native:true ~json:true)
        ()
    in
    with_catalog [ entry ]
    @@ fun snapshot ->
    execute_once ~net (attempt (flow snapshot "abort-surface" EO.Json_syntax))
  in
  check int "abort observes one POST" 1 abort_posts;
  (match abort_result with
   | Error { EO.receipt; cause = EO.Completion_failed; raw_response = None; _ } ->
     check_receipt
       "abort"
       ~phase:EO.Dispatch_started
       ~dispatch_count:1
       ~http_status:None
       receipt
   | Ok _ | Error _ -> fail "post-abort failure lost dispatch evidence");
  let rate_result, rate_posts, _, _ =
    with_server ~status:`Too_many_requests ~response:"rate limited"
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    let entry =
      catalog_entry
        ~id:"rate-surface"
        ~kind:Provider_config.OpenAI_compat
        ~base_url
        ~request_path:"/v1/chat/completions"
        ~capabilities:(capabilities ~native:true ~json:true)
        ()
    in
    with_catalog [ entry ]
    @@ fun snapshot ->
    execute_once ~net (attempt (flow snapshot "rate-surface" EO.Json_syntax))
  in
  check int "429 observes one POST" 1 rate_posts;
  (match rate_result with
   | Error
       { EO.receipt
       ; cause = EO.Completion_failed
       ; raw_response = Some { body = "rate limited"; _ }
       ; _
       } ->
     check_receipt
       "429"
       ~phase:EO.Response_received
       ~dispatch_count:1
       ~http_status:(Some 429)
       receipt
   | Ok _ | Error _ -> fail "429 lost status or raw body");
  let terminal_result, terminal_posts, _, _ =
    with_server ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    let entry =
      catalog_entry
        ~id:"terminal-surface"
        ~kind:Provider_config.OpenAI_compat
        ~base_url
        ~request_path:"/v1/chat/completions"
        ~capabilities:(capabilities ~native:true ~json:true)
        ()
    in
    with_catalog [ entry ]
    @@ fun snapshot ->
    let execution = flow snapshot "terminal-surface" EO.Json_syntax |> attempt in
    check
      int
      "flow starts without an allocated attempt"
      0
      (List.length (EO.flow_attempt_evidence execution.flow).attempts);
    execute_once ~net execution
  in
  check int "terminal observes one POST" 1 terminal_posts;
  match terminal_result with
  | Ok success ->
    check_receipt
      "terminal"
      ~phase:EO.Terminal
      ~dispatch_count:1
      ~http_status:(Some 200)
      success.receipt
  | Error _ -> fail "terminal success did not reach Terminal"
;;

let test_reasoning_response_bytes_do_not_enter_json_output () =
  let response =
    anthropic_response
      {|[{"type":"thinking","thinking":"{\"must_not_mix\":true}","signature":"sig-surface"},{"type":"text","text":"{\"name\":\"accepted\"}"}]|}
  in
  let result, posts, _, _ =
    with_server ~response
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    let entry =
      catalog_entry
        ~id:"reasoning-response-surface"
        ~kind:Provider_config.Anthropic
        ~base_url
        ~request_path:"/v1/messages"
        ~capabilities:(capabilities ~native:true ~json:true)
        ()
    in
    with_catalog [ entry ]
    @@ fun snapshot ->
    execute_once
      ~net
      (attempt (flow snapshot "reasoning-response-surface" EO.Json_syntax))
  in
  check int "reasoning response dispatches once" 1 posts;
  match result with
  | Ok success ->
    check
      bool
      "only text JSON is normalized"
      true
      (success.output = `Assoc [ "name", `String "accepted" ]);
    check string "raw reasoning response is preserved" response success.raw_response.body
  | Error _ -> fail "reasoning plus text should normalize successfully"
;;

let test_public_unmeasured_plan_fingerprint_contract () =
  let entry id ~native ~json =
    catalog_entry
      ~id
      ~kind:Provider_config.OpenAI_compat
      ~base_url:"https://surface.invalid"
      ~request_path:"/v1/chat/completions"
      ~capabilities:(capabilities ~native ~json)
      ()
  in
  with_catalog
    [ entry "golden-target" ~native:false ~json:true
    ; entry "sensitivity-a" ~native:true ~json:true
    ; entry "sensitivity-b" ~native:true ~json:true
    ]
  @@ fun snapshot ->
  let select selector _model = target snapshot selector in
  let admit target messages schema =
    match
      EO.admit
        ~target
        ~messages
        (EO.make_output_requirement ~schema ~minimum_guarantee:EO.Json_syntax)
    with
    | Ok ready -> ready
    | Error _ -> fail "fingerprint fixture did not admit"
  in
  let golden =
    admit
      (select "golden-target" "golden-model")
      [ msg "fingerprint" ]
      (`Assoc [ "type", `String "object" ])
  in
  check
    string
    "same exact binding is deterministic"
    (EO.plan_fingerprint golden)
    (EO.plan_fingerprint
       (admit
          (select "golden-target" "ignored-by-exact-target")
          [ msg "fingerprint" ]
          (`Assoc [ "type", `String "object" ])));
  let schema_a =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "name", `Assoc [ "type", `String "string" ] ]
      ]
  in
  let schema_a_reordered =
    `Assoc
      [ "properties", `Assoc [ "name", `Assoc [ "type", `String "string" ] ]
      ; "type", `String "object"
      ]
  in
  let schema_b =
    `Assoc [ "type", `String "array"; "items", `Assoc [ "type", `String "string" ] ]
  in
  let target_a = select "sensitivity-a" "sensitivity-model" in
  let target_b = select "sensitivity-b" "sensitivity-model" in
  let base = admit target_a [ msg "same" ] schema_a in
  let same = admit target_a [ msg "same" ] schema_a in
  let canonical = admit target_a [ msg "same" ] schema_a_reordered in
  let different_message = admit target_a [ msg "different" ] schema_a in
  let different_schema = admit target_a [ msg "same" ] schema_b in
  let different_target = admit target_b [ msg "same" ] schema_a in
  check
    string
    "deterministic plan fingerprint"
    (EO.plan_fingerprint base)
    (EO.plan_fingerprint same);
  check
    string
    "canonical schema equivalence"
    (EO.plan_fingerprint base)
    (EO.plan_fingerprint canonical);
  check
    bool
    "message sensitivity"
    true
    (EO.plan_fingerprint base <> EO.plan_fingerprint different_message);
  check
    bool
    "schema sensitivity"
    true
    (EO.plan_fingerprint base <> EO.plan_fingerprint different_schema);
  check
    bool
    "target sensitivity"
    true
    (EO.plan_fingerprint base <> EO.plan_fingerprint different_target);
  ()
;;

let test_normalization_error_classes () =
  let run label response matches =
    let result, posts, _, _ =
      with_server ~response
      @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
      let entry =
        catalog_entry
          ~id:"normalization-surface"
          ~kind:Provider_config.Anthropic
          ~base_url
          ~request_path:"/v1/messages"
          ~capabilities:(capabilities ~native:true ~json:true)
          ()
      in
      with_catalog [ entry ]
      @@ fun snapshot ->
      execute_once ~net (attempt (flow snapshot "normalization-surface" EO.Json_syntax))
    in
    check int (label ^ " dispatches once") 1 posts;
    match result with
    | Error { EO.receipt; cause; raw_response = Some _; _ } ->
      check bool (label ^ " typed cause") true (matches cause);
      check
        (option int)
        (label ^ " response status")
        (Some 200)
        (EO.receipt_http_status receipt)
    | Ok _ | Error _ -> fail (label ^ " lost response-received evidence")
  in
  run
    "incomplete"
    (anthropic_response
       ~stop_reason:"max_tokens"
       {|[{"type":"text","text":"{\"name\":\"accepted\"}"}]|})
    (function
    | EO.Incomplete_output -> true
    | _ -> false);
  run "missing" (anthropic_response "[]") (function
    | EO.Missing_output -> true
    | _ -> false);
  run
    "ambiguous"
    (anthropic_response {|[{"type":"text","text":"{}"},{"type":"text","text":"{}"}]|})
    (function
    | EO.Ambiguous_output 2 -> true
    | _ -> false);
  run
    "unexpected"
    (anthropic_response
       {|[{"type":"text","text":"{}"},{"type":"tool_use","id":"tool-1","name":"lookup","input":{}}]|})
    (function
    | EO.Unexpected_output_content -> true
    | _ -> false)
;;

let test_attempt_rejects_concurrent_duplicate_before_second_dispatch () =
  let response = openai_response {|{"name":"accepted"}|} in
  let (first, second), posts, _, _ =
    with_server ~response
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    let entry =
      catalog_entry
        ~id:"concurrent-surface"
        ~kind:Provider_config.OpenAI_compat
        ~base_url
        ~request_path:"/v1/chat/completions"
        ~capabilities:(capabilities ~native:true ~json:true)
        ()
    in
    with_catalog [ entry ]
    @@ fun snapshot ->
    let execution = flow snapshot "concurrent-surface" EO.Json_syntax |> attempt in
    let first_promise, first_resolver = Eio.Promise.create () in
    let second_promise, second_resolver = Eio.Promise.create () in
    Eio.Fiber.both
      (fun () -> execute_once ~net execution |> Eio.Promise.resolve first_resolver)
      (fun () -> execute_once ~net execution |> Eio.Promise.resolve second_resolver);
    Eio.Promise.await first_promise, Eio.Promise.await second_promise
  in
  check int "one concurrent completion post" 1 posts;
  let successes, duplicates =
    List.fold_left
      (fun (successes, duplicates) -> function
         | Ok _ -> successes + 1, duplicates
         | Error { EO.cause = EO.Attempt_already_started; _ } -> successes, duplicates + 1
         | Error _ -> fail "concurrent exact invocation returned wrong error")
      (0, 0)
      [ first; second ]
  in
  check int "one concurrent success" 1 successes;
  check int "one concurrent duplicate" 1 duplicates
;;

let test_parallel_attempts_from_one_plan_do_not_share_identity_or_state () =
  let response = openai_response {|{"name":"accepted"}|} in
  let (first_id, first, second_id, second), posts, _, _ =
    with_server ~response
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    let entry =
      catalog_entry
        ~id:"parallel-attempt-surface"
        ~kind:Provider_config.OpenAI_compat
        ~base_url
        ~request_path:"/v1/chat/completions"
        ~capabilities:(capabilities ~native:true ~json:true)
        ()
    in
    with_catalog [ entry ]
    @@ fun snapshot ->
    let ready = flow snapshot "parallel-attempt-surface" EO.Json_syntax in
    let first_attempt = attempt ready in
    let second_attempt = attempt ready in
    let first_promise, first_resolver = Eio.Promise.create () in
    let second_promise, second_resolver = Eio.Promise.create () in
    Eio.Fiber.both
      (fun () -> execute_once ~net first_attempt |> Eio.Promise.resolve first_resolver)
      (fun () -> execute_once ~net second_attempt |> Eio.Promise.resolve second_resolver);
    let first = Eio.Promise.await first_promise in
    let second = Eio.Promise.await second_promise in
    let first_id =
      execution_receipt first_attempt |> EO.receipt_call_id |> EO.call_id_to_string
    in
    let second_id =
      execution_receipt second_attempt |> EO.receipt_call_id |> EO.call_id_to_string
    in
    check
      bool
      "parallel call identities differ"
      true
      (not (String.equal first_id second_id));
    first_id, first, second_id, second
  in
  check int "parallel attempts dispatch independently" 2 posts;
  let check_success label expected_id = function
    | Ok (success : EO.success) ->
      check string label expected_id (EO.call_id_to_string success.call_id);
      check
        string
        (label ^ " receipt")
        expected_id
        (EO.receipt_call_id success.receipt |> EO.call_id_to_string)
    | Error _ -> fail (label ^ " should succeed independently")
  in
  check_success "first parallel identity" first_id first;
  check_success "second parallel identity" second_id second
;;

let test_cancellation_leaves_queryable_monotonic_receipt () =
  let request_seen, notify_request_seen = Eio.Promise.create () in
  let response = openai_response {|{"name":"accepted"}|} in
  let (cancelled, phase, duplicate), posts, _, _ =
    with_server
      ~response_delay_s:0.1
      ~on_completion_request:(fun () -> Eio.Promise.resolve notify_request_seen ())
      ~response
    @@ fun ~sw ~net ~clock ~base_url ->
    let entry =
      catalog_entry
        ~id:"cancel-surface"
        ~kind:Provider_config.OpenAI_compat
        ~base_url
        ~request_path:"/v1/chat/completions"
        ~capabilities:(capabilities ~native:true ~json:true)
        ()
    in
    with_catalog [ entry ]
    @@ fun snapshot ->
    let execution = flow snapshot "cancel-surface" EO.Json_syntax |> attempt in
    let cancelled =
      cancel_execute_once_after_dispatch ~sw ~net ~clock ~request_seen execution
    in
    let receipt = execution_receipt execution in
    let phase = EO.receipt_phase receipt in
    let duplicate = execute_once ~net execution in
    cancelled, phase, duplicate
  in
  check bool "caller cancellation observed" true cancelled;
  check int "cancelled attempt dispatched once" 1 posts;
  check
    bool
    "cancelled receipt remains dispatch-started"
    true
    (phase = EO.Dispatch_started);
  match duplicate with
  | Error { EO.cause = EO.Attempt_already_started; _ } -> ()
  | Ok _ | Error _ -> fail "cancelled attempt must remain consumed"
;;

let with_stale_server ?response_body_delay_s f =
  let posts = Atomic.make 0 in
  let result =
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    let port = fresh_port () in
    let socket =
      Eio.Net.listen
        net
        ~sw
        ~backlog:8
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let response = openai_response {|{"name":"accepted"}|} in
    let handle flow _addr =
      let reader = Eio.Buf_read.of_flow ~max_size:max_int flow in
      ignore (Eio.Buf_read.line reader : string);
      let rec headers content_length =
        let line = Eio.Buf_read.line reader |> String.trim in
        if line = ""
        then content_length
        else (
          let content_length =
            match String.split_on_char ':' line with
            | name :: value :: _ when String.lowercase_ascii name = "content-length" ->
              int_of_string (String.trim value)
            | _ -> content_length
          in
          headers content_length)
      in
      ignore (Eio.Buf_read.take (headers 0) reader : string);
      Atomic.incr posts;
      Eio.Flow.copy_string
        (Printf.sprintf
           "HTTP/1.1 200 OK\r\n\
            Content-Type: application/json\r\n\
            Content-Length: %d\r\n\
            \r\n"
           (String.length response))
        flow;
      Option.iter (Eio.Time.sleep clock) response_body_delay_s;
      Eio.Flow.copy_string response flow
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      while true do
        Eio.Net.accept_fork socket ~sw ~on_error:(fun _ -> ()) handle
      done);
    f ~sw ~net ~clock ~base_url:(Printf.sprintf "http://127.0.0.1:%d" port)
  in
  result, Atomic.get posts
;;

let test_body_cancellation_retains_response_status () =
  let (timed_out, phase, status), posts =
    with_stale_server ~response_body_delay_s:0.2
    @@ fun ~sw:_ ~net ~clock ~base_url ->
    let entry =
      catalog_entry
        ~id:"body-cancel-surface"
        ~kind:Provider_config.OpenAI_compat
        ~base_url
        ~request_path:"/v1/chat/completions"
        ~capabilities:(capabilities ~native:true ~json:true)
        ()
    in
    with_catalog [ entry ]
    @@ fun snapshot ->
    let execution = flow snapshot "body-cancel-surface" EO.Json_syntax |> attempt in
    let timed_out =
      try
        match
          Eio.Time.with_timeout_exn clock 0.05 (fun () -> execute_once ~net execution)
        with
        | Ok _ | Error _ -> false
      with
      | Eio.Time.Timeout -> true
    in
    let receipt = execution_receipt execution in
    timed_out, EO.receipt_phase receipt, EO.receipt_http_status receipt
  in
  check bool "body cancellation observed" true timed_out;
  check int "body cancellation dispatches once" 1 posts;
  check bool "headers advance receipt" true (phase = EO.Response_received);
  check (option int) "received status survives cancellation" (Some 200) status
;;

let check_receipt_provenance label (provenance : EO.plan_provenance) receipt =
  check
    string
    (label ^ " target identity")
    (EO.plan_provenance_target_identity provenance |> EO.target_identity_fingerprint)
    (EO.receipt_target_identity receipt |> EO.target_identity_fingerprint);
  check
    string
    (label ^ " catalog generation")
    (EO.plan_provenance_catalog_generation provenance |> EO.catalog_generation_fingerprint)
    (EO.receipt_catalog_generation receipt |> EO.catalog_generation_fingerprint);
  check
    string
    (label ^ " catalog evidence")
    (EO.plan_provenance_catalog_evidence provenance |> EO.catalog_evidence_sha256)
    (EO.receipt_catalog_evidence receipt |> EO.catalog_evidence_sha256)
;;

let header_value name headers =
  List.find_map
    (fun (header_name, value) ->
       if String.equal (String.lowercase_ascii header_name) (String.lowercase_ascii name)
       then Some value
       else None)
    headers
;;

let header_values name headers =
  List.filter_map
    (fun (header_name, value) ->
       if String.equal (String.lowercase_ascii header_name) (String.lowercase_ascii name)
       then Some value
       else None)
    headers
;;

let test_overlay_endpoint_and_credential_are_materialized () =
  let response = openai_response {|{"name":"accepted"}|} in
  let result, posts, _, captures =
    with_server ~response
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    let entry =
      catalog_entry
        ~id:"environment-surface"
        ~kind:Provider_config.OpenAI_compat
        ~base_url:"https://fallback.invalid"
        ~base_url_env:"EXACT_SURFACE_BASE_URL"
        ~api_key_env:"EXACT_SURFACE_API_KEY"
        ~request_path:"/v1/chat/completions"
        ~capabilities:(capabilities ~native:true ~json:true)
        ()
    in
    let frozen_base_url = ref base_url in
    let frozen_credential = ref "  frozen-surface-secret  " in
    let getenv name =
      Ok
        (if String.equal name "EXACT_SURFACE_BASE_URL"
         then Some !frozen_base_url
         else if String.equal name "EXACT_SURFACE_API_KEY"
         then Some !frozen_credential
         else None)
    in
    with_catalog ~getenv [ entry ]
    @@ fun snapshot ->
    frozen_base_url := "https://rotated.invalid";
    frozen_credential := "rotated-surface-secret";
    flow snapshot "environment-surface" EO.Json_syntax |> attempt |> execute_once ~net
  in
  check int "environment target dispatches once" 1 posts;
  (match result with
   | Ok _ -> ()
   | Error _ -> fail "environment target should execute");
  let capture =
    match captures with
    | [ capture ] -> capture
    | _ -> fail "environment target should produce one capture"
  in
  check
    (option string)
    "frozen credential reaches Authorization header"
    (Some "Bearer frozen-surface-secret")
    (header_value "authorization" capture.headers);
  check
    (list string)
    "exact request owns exactly one JSON content type"
    [ "application/json" ]
    (header_values "content-type" capture.headers)
;;

let test_credential_rotation_keeps_snapshot_bound_wire_authority () =
  let response = openai_response {|{"name":"accepted"}|} in
  let (result_a, result_b), posts, token_posts, captures =
    with_server ~response
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    let entry =
      catalog_entry
        ~id:"credential-rotation-surface"
        ~kind:Provider_config.OpenAI_compat
        ~base_url
        ~api_key_env:"ROTATING_SURFACE_API_KEY"
        ~request_path:"/v1/chat/completions"
        ~capabilities:(capabilities ~native:true ~json:true)
        ()
    in
    let credential = ref "snapshot-secret-a" in
    let getenv name =
      Ok (if String.equal name "ROTATING_SURFACE_API_KEY" then Some !credential else None)
    in
    let snapshot_a = with_catalog ~getenv [ entry ] Fun.id in
    let handle_a =
      match EO.admit_target_ref snapshot_a "credential-rotation-surface" with
      | Ok admitted -> admitted
      | Error _ -> fail "snapshot A target should admit"
    in
    credential := "snapshot-secret-b";
    let snapshot_b = with_catalog ~getenv [ entry ] Fun.id in
    let handle_b =
      match EO.admit_target_ref snapshot_b "credential-rotation-surface" with
      | Ok admitted -> admitted
      | Error _ -> fail "snapshot B target should admit"
    in
    check
      string
      "credential rotation leaves catalog generation unchanged"
      (EO.resolver_catalog_generation snapshot_a |> EO.catalog_generation_fingerprint)
      (EO.resolver_catalog_generation snapshot_b |> EO.catalog_generation_fingerprint);
    check
      string
      "credential rotation leaves catalog evidence unchanged"
      (EO.resolver_catalog_evidence snapshot_a |> EO.catalog_evidence_sha256)
      (EO.resolver_catalog_evidence snapshot_b |> EO.catalog_evidence_sha256);
    let domain_a = Domain.spawn (fun () -> EO.resolve_target handle_a) in
    let domain_b = Domain.spawn (fun () -> EO.resolve_target handle_b) in
    let target_a =
      match Domain.join domain_a with
      | Ok target -> target
      | Error _ -> fail "snapshot A handle should resolve across a Domain"
    in
    let target_b =
      match Domain.join domain_b with
      | Ok target -> target
      | Error _ -> fail "snapshot B handle should resolve across a Domain"
    in
    check
      string
      "credential rotation leaves target identity unchanged"
      (EO.selected_target_identity target_a |> EO.target_identity_fingerprint)
      (EO.selected_target_identity target_b |> EO.target_identity_fingerprint);
    let ready target =
      match
        EO.admit
          ~target
          ~messages:[ msg "credential rotation" ]
          (requirement EO.Json_syntax)
      with
      | Ok ready -> ready
      | Error _ -> fail "credential rotation target should admit a request"
    in
    ignore (ready target_a : EO.ready_plan);
    ignore (ready target_b : EO.ready_plan);
    let execute id admitted_target =
      flow_from_admitted_target
        ~id
        ~messages:[ msg "credential rotation" ]
        (requirement EO.Json_syntax)
        admitted_target
      |> attempt
      |> execute_once ~net
    in
    let result_a = execute "credential-rotation-a" handle_a in
    let result_b = execute "credential-rotation-b" handle_b in
    result_a, result_b
  in
  check int "two frozen credential plans dispatch once each" 2 posts;
  check int "credential rotation performs no token measurement" 0 token_posts;
  List.iter
    (function
      | Ok _ -> ()
      | Error _ -> fail "both frozen credential plans should execute")
    [ result_a; result_b ];
  match captures with
  | [ capture_a; capture_b ] ->
    check
      (option string)
      "snapshot A retains credential A after snapshot B exists"
      (Some "Bearer snapshot-secret-a")
      (header_value "authorization" capture_a.headers);
    check
      (option string)
      "snapshot B retains credential B"
      (Some "Bearer snapshot-secret-b")
      (header_value "authorization" capture_b.headers)
  | _ -> fail "credential rotation should produce exactly two ordered captures"
;;

let test_identity_survives_success_error_and_cancellation () =
  let run ?(status = `OK) response =
    let (provenance, result), posts, _, _ =
      with_server ~status ~response
      @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
      let entry =
        catalog_entry
          ~id:"identity-surface"
          ~kind:Provider_config.OpenAI_compat
          ~base_url
          ~request_path:"/v1/chat/completions"
          ~capabilities:(capabilities ~native:true ~json:true)
          ()
      in
      with_catalog [ entry ]
      @@ fun snapshot ->
      let ready = plan snapshot "identity-surface" EO.Json_syntax in
      let execution = flow snapshot "identity-surface" EO.Json_syntax |> attempt in
      EO.plan_provenance ready, execute_once ~net execution
    in
    check int "identity path dispatches once" 1 posts;
    provenance, result
  in
  let success_provenance, success = run (openai_response {|{"name":"accepted"}|}) in
  (match success with
   | Ok success ->
     check_receipt_provenance "success" success_provenance success.receipt;
     check
       string
       "success call identity"
       (EO.call_id_to_string success.call_id)
       (EO.receipt_call_id success.receipt |> EO.call_id_to_string);
     check
       string
       "success result provenance identity"
       (EO.plan_provenance_target_identity success_provenance
        |> EO.target_identity_fingerprint)
       (EO.plan_provenance_target_identity success.provenance
        |> EO.target_identity_fingerprint)
   | Error _ -> fail "identity success fixture should succeed");
  let error_provenance, error = run ~status:`Too_many_requests "rate limited" in
  (match error with
   | Error error ->
     check_receipt_provenance "error" error_provenance error.receipt;
     check
       string
       "error call identity"
       (EO.call_id_to_string error.call_id)
       (EO.receipt_call_id error.receipt |> EO.call_id_to_string)
   | Ok _ -> fail "identity error fixture should fail");
  let request_seen, notify_request_seen = Eio.Promise.create () in
  let (cancel_provenance, cancel_receipt, cancelled), posts, _, _ =
    with_server
      ~response_delay_s:0.1
      ~on_completion_request:(fun () -> Eio.Promise.resolve notify_request_seen ())
      ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw ~net ~clock ~base_url ->
    let entry =
      catalog_entry
        ~id:"identity-cancel-surface"
        ~kind:Provider_config.OpenAI_compat
        ~base_url
        ~request_path:"/v1/chat/completions"
        ~capabilities:(capabilities ~native:true ~json:true)
        ()
    in
    with_catalog [ entry ]
    @@ fun snapshot ->
    let ready = plan snapshot "identity-cancel-surface" EO.Json_syntax in
    let provenance = EO.plan_provenance ready in
    let execution = flow snapshot "identity-cancel-surface" EO.Json_syntax |> attempt in
    let cancelled =
      cancel_execute_once_after_dispatch ~sw ~net ~clock ~request_seen execution
    in
    let receipt = execution_receipt execution in
    provenance, receipt, cancelled
  in
  check bool "identity cancellation observed" true cancelled;
  check int "identity cancellation dispatches once" 1 posts;
  check_receipt_provenance "cancellation" cancel_provenance cancel_receipt
;;

let gemini_exact_entry
      ?(base_url = "https://surface.invalid/v1beta/models")
      ~id
      ~request_path
      ()
  =
  catalog_entry
    ~id
    ~kind:Provider_config.Gemini
    ~base_url
    ~request_path
    ~capabilities:(capabilities ~native:true ~json:true)
    ()
;;

let test_gemini_nullable_schema_admitted () =
  let id = "gemini-nullable-surface" in
  let nullable_schema =
    `Assoc
      [ "type", `String "object"
      ; ( "properties"
        , `Assoc
            [ "nickname", `Assoc [ "type", `List [ `String "null"; `String "string" ] ] ]
        )
      ; "required", `List [ `String "nickname" ]
      ]
  in
  with_catalog [ gemini_exact_entry ~id ~request_path:"" () ]
  @@ fun snapshot ->
  match
    EO.admit
      ~target:(target snapshot id)
      ~messages:[ msg "nullable" ]
      (EO.make_output_requirement
         ~schema:nullable_schema
         ~minimum_guarantee:EO.Provider_schema)
  with
  | Ok _ -> ()
  | Error _ -> fail "Gemini generateContent must admit nullable type arrays"
;;

let test_gemini_any_of_nullable_enum_admitted_unchanged () =
  let nullable_enum =
    `Assoc
      [ ( "anyOf"
        , `List
            [ `Assoc
                [ "type", `String "string"
                ; ( "enum"
                  , `List
                      [ `String "self_observation"
                      ; `String "external_state"
                      ; `String "durable_knowledge"
                      ] )
                ]
            ; `Assoc [ "type", `String "null" ]
            ] )
      ]
  in
  let top_level =
    `Assoc
      [ "title", `String "nullable observation kind"
      ; "description", `String "provider-neutral nullable enum"
      ; "anyOf", Yojson.Safe.Util.member "anyOf" nullable_enum
      ]
  in
  let nested =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "kind", nullable_enum ]
      ; "required", `List [ `String "kind" ]
      ; "additionalProperties", `Bool false
      ]
  in
  let run ~label ~domain_schema ~content =
    let id = "gemini-any-of-" ^ label in
    let (provenance, result), completion_posts, token_posts, captures =
      with_server ~response:(gemini_response content)
      @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
      let entry =
        gemini_exact_entry ~base_url:(base_url ^ "/v1beta/models") ~id ~request_path:"" ()
      in
      with_catalog [ entry ]
      @@ fun snapshot ->
      let ready =
        match
          EO.admit
            ~target:(target snapshot id)
            ~messages:[ msg label ]
            (EO.make_output_requirement
               ~schema:domain_schema
               ~minimum_guarantee:EO.Provider_schema)
        with
        | Error _ -> failf "%s Gemini anyOf schema must admit" label
        | Ok ready -> ready
      in
      let execution =
        flow_for_schema snapshot id domain_schema EO.Provider_schema |> attempt
      in
      EO.plan_provenance ready, execute_once ~net execution
    in
    check int (label ^ " Gemini generation POST") 1 completion_posts;
    check int (label ^ " Gemini token POST") 0 token_posts;
    let capture =
      match captures with
      | [ capture ] -> capture
      | _ -> failf "%s Gemini schema must produce one captured request" label
    in
    let captured_schema =
      Yojson.Safe.from_string capture.body
      |> Yojson.Safe.Util.member "generationConfig"
      |> Yojson.Safe.Util.member "responseJsonSchema"
    in
    check
      bool
      (label ^ " Gemini request preserves schema semantics")
      true
      (Yojson.Safe.equal captured_schema domain_schema);
    let source =
      EO.plan_provenance_source_schema_fingerprint provenance
      |> EO.schema_fingerprint_to_string
    in
    (match EO.plan_provenance_effective_schema_fingerprint provenance with
     | None -> failf "%s Gemini schema must expose its wire fingerprint" label
     | Some effective ->
       check
         string
         (label ^ " Gemini source and effective fingerprints match")
         source
         (EO.schema_fingerprint_to_string effective));
    match result with
    | Error _ -> failf "%s Gemini exact execution must succeed" label
    | Ok success ->
      check
        bool
        (label ^ " Gemini output")
        true
        (success.output = Yojson.Safe.from_string content)
  in
  run
    ~label:"top-level-nullable-enum"
    ~domain_schema:top_level
    ~content:{|"self_observation"|};
  run
    ~label:"nested-nullable-enum"
    ~domain_schema:nested
    ~content:{|{"kind":"self_observation"}|}
;;

let test_gemini_any_of_rejections_are_direct_admission () =
  let id = "gemini-any-of-rejection-surface" in
  let string_branch =
    `Assoc [ "type", `String "string"; "enum", `List [ `String "ready" ] ]
  in
  let null_branch = `Assoc [ "type", `String "null" ] in
  let rejected_schemas =
    [ "oneOf semantic loss", `Assoc [ "oneOf", `List [ string_branch; null_branch ] ]
    ; "empty anyOf", `Assoc [ "anyOf", `List [] ]
    ; "scalar anyOf", `Assoc [ "anyOf", `String "not-a-schema-list" ]
    ; ( "non-string title"
      , `Assoc [ "title", `Int 1; "anyOf", `List [ string_branch; null_branch ] ] )
    ; ( "non-string description"
      , `Assoc
          [ "description", `Bool false; "anyOf", `List [ string_branch; null_branch ] ] )
    ; ( "empty enum"
      , `Assoc
          [ ( "anyOf"
            , `List [ `Assoc [ "type", `String "string"; "enum", `List [] ]; null_branch ]
            )
          ] )
    ; ( "anyOf with oneOf"
      , `Assoc
          [ "anyOf", `List [ string_branch; null_branch ]
          ; "oneOf", `List [ string_branch; null_branch ]
          ] )
    ; ( "duplicate anyOf"
      , `Assoc
          [ "anyOf", `List [ string_branch; null_branch ]
          ; "anyOf", `List [ string_branch; null_branch ]
          ] )
    ; "malformed nested branch", `Assoc [ "anyOf", `List [ string_branch; `Bool true ] ]
    ; ( "nested unsupported keyword"
      , `Assoc
          [ ( "anyOf"
            , `List
                [ `Assoc [ "type", `String "string"; "pattern", `String ".+" ]
                ; null_branch
                ] )
          ] )
    ; ( "structural sibling"
      , `Assoc [ "anyOf", `List [ string_branch; null_branch ]; "type", `String "string" ]
      )
    ; ( "mixed-null scalar enum"
      , `Assoc
          [ ( "anyOf"
            , `List
                [ `Assoc
                    [ "type", `String "string"; "enum", `List [ `String "ready"; `Null ] ]
                ; null_branch
                ] )
          ] )
    ; ( "recursive required"
      , `Assoc
          [ ( "anyOf"
            , `List
                [ `Assoc
                    [ "type", `String "object"
                    ; "properties", `Assoc [ "name", string_branch ]
                    ; "required", `List [ `Int 1 ]
                    ]
                ; null_branch
                ] )
          ] )
    ; ( "recursive additionalProperties"
      , `Assoc
          [ ( "anyOf"
            , `List
                [ `Assoc
                    [ "type", `String "object"
                    ; "properties", `Assoc []
                    ; "additionalProperties", `String "closed"
                    ]
                ; null_branch
                ] )
          ] )
    ; ( "recursive bounds"
      , `Assoc
          [ ( "anyOf"
            , `List
                [ `Assoc
                    [ "type", `String "array"
                    ; "items", string_branch
                    ; "minItems", `Int (-1)
                    ]
                ; null_branch
                ] )
          ] )
    ]
  in
  with_catalog [ gemini_exact_entry ~id ~request_path:"" () ]
  @@ fun snapshot ->
  let selected = target snapshot id in
  List.iter
    (fun (label, domain_schema) ->
       match
         EO.admit
           ~target:selected
           ~messages:[ msg label ]
           (EO.make_output_requirement
              ~schema:domain_schema
              ~minimum_guarantee:EO.Provider_schema)
       with
       | Error error ->
         (match EO.admission_error_disposition error with
          | EO.Output_requirement_rejected -> ()
          | _ -> failf "%s lost its neutral rejection disposition" label)
       | Ok _ -> failf "%s must reject during Gemini admission" label)
    rejected_schemas
;;

let test_gemini_nonempty_request_path_rejected_before_resolution () =
  let id = "gemini-interactions-surface" in
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  let overlay : EO.catalog_document =
    { source = "Gemini endpoint surface fixture"
    ; contents =
        catalog_fixture_toml (gemini_exact_entry ~id ~request_path:"/interactions" ())
    }
  in
  match EO.load_resolver_snapshot ~io ~catalog:(EO.Embedded_with_overlay overlay) () with
  | Error
      (EO.Target_endpoint_invalid
         { target_ref; cause = EO.Unsupported_gemini_request_path }) ->
    check string "rejected Gemini target" id target_ref
  | Ok _ | Error _ -> fail "nonempty Gemini request_path must fail before resolution"
;;

let () =
  run
    "exact-output-single-surface"
    [ ( "surface"
      , [ test_case
            "capability tier table"
            `Quick
            test_tier_table_and_provider_schema_rejection
        ; test_case
            "DeepSeek catalog is JSON-only before dispatch"
            `Quick
            test_deepseek_catalog_is_json_only_before_dispatch
        ; test_case
            "request body limit is typed and pre-dispatch"
            `Quick
            test_request_body_limit_is_typed_and_pre_dispatch
        ; test_case
            "supported_models exact membership"
            `Quick
            test_supported_models_membership_is_exact_and_pre_dispatch
        ; test_case
            "injection rejected"
            `Quick
            test_wire_envelope_and_cross_feature_injection_rejected
        ; test_case
            "Anthropic schema prefill rejected before dispatch"
            `Quick
            test_anthropic_schema_prefill_rejected_before_dispatch
        ; test_case
            "Gemini nullable schema admitted"
            `Quick
            test_gemini_nullable_schema_admitted
        ; test_case
            "Gemini anyOf nullable enum is preserved"
            `Quick
            test_gemini_any_of_nullable_enum_admitted_unchanged
        ; test_case
            "Gemini anyOf rejections are direct admission"
            `Quick
            test_gemini_any_of_rejections_are_direct_admission
        ; test_case
            "Gemini nonempty request path rejected before resolution"
            `Quick
            test_gemini_nonempty_request_path_rejected_before_resolution
        ; test_case
            "no measure and one post"
            `Quick
            test_no_measure_one_post_and_wire_authority
        ; test_case
            "provider trace fingerprint"
            `Quick
            test_provider_trace_fingerprint_anchors_normalized_headers_and_body
        ; test_case
            "response-received error evidence"
            `Quick
            test_response_received_error_evidence_matrix
        ; test_case "receipt phase matrix" `Quick test_public_receipt_phase_matrix
        ; test_case
            "reasoning bytes stay out of JSON"
            `Quick
            test_reasoning_response_bytes_do_not_enter_json_output
        ; test_case
            "public unmeasured plan fingerprint contract"
            `Quick
            test_public_unmeasured_plan_fingerprint_contract
        ; test_case "normalization error classes" `Quick test_normalization_error_classes
        ; test_case
            "concurrent duplicate rejected"
            `Quick
            test_attempt_rejects_concurrent_duplicate_before_second_dispatch
        ; test_case
            "parallel attempts do not share identity or state"
            `Quick
            test_parallel_attempts_from_one_plan_do_not_share_identity_or_state
        ; test_case
            "cancellation receipt"
            `Quick
            test_cancellation_leaves_queryable_monotonic_receipt
        ; test_case
            "body cancellation keeps status"
            `Quick
            test_body_cancellation_retains_response_status
        ; test_case
            "identity survives all outcomes"
            `Quick
            test_identity_survives_success_error_and_cancellation
        ; test_case
            "overlay endpoint and credential"
            `Quick
            test_overlay_endpoint_and_credential_are_materialized
        ; test_case
            "credential rotation keeps snapshot-bound wire authority"
            `Quick
            test_credential_rotation_keeps_snapshot_bound_wire_authority
        ] )
    ]
;;
