open Alcotest
open Llm_provider
module EO = Agent_sdk.Exact_output

exception Advance_committed_before_successor

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
    ; "properties", `Assoc [ "name", `Assoc [ "type", `String "string" ] ]
    ; "required", `List [ `String "name" ]
    ; "additionalProperties", `Bool false
    ]
;;

type catalog_fixture =
  { id : string
  ; base_url : string
  ; kind : string
  ; request_path : string
  ; api_key_env : string
  ; native : bool
  ; json : bool
  ; body_timeout_s : float option
  ; serving_constraint : bool
  ; serving_accepted_through_tokens : int
  ; serving_rejected_from_tokens : int
  ; max_request_body_bytes : int option
  ; model_id : string
  ; anthropic_thinking_control : string option
  ; enable_thinking : bool option
  }

let catalog_entry
      ?body_timeout_s
      ?(serving_constraint = false)
      ?(serving_accepted_through_tokens = 524298)
      ?(serving_rejected_from_tokens = 524299)
      ?max_request_body_bytes
      ?(kind = "openai_compat")
      ?(request_path = "/v1/chat/completions")
      ?(api_key_env = "")
      ?model_id
      ?anthropic_thinking_control
      ?enable_thinking
      ~id
      ~base_url
      ~native
      ~json
      ()
  =
  { id
  ; base_url
  ; kind
  ; request_path
  ; api_key_env
  ; native
  ; json
  ; body_timeout_s
  ; serving_constraint
  ; serving_accepted_through_tokens
  ; serving_rejected_from_tokens
  ; max_request_body_bytes
  ; model_id = Option.value model_id ~default:(id ^ "-model")
  ; anthropic_thinking_control
  ; enable_thinking
  }
;;

let catalog_fixture_toml entry =
  (* The model row owns the Anthropic wire dialect. The target row owns the
     explicit request policy, so capability never implies enablement. *)
  let target_options =
    (match entry.body_timeout_s with
     | None -> ""
     | Some seconds -> Printf.sprintf "body_timeout_s = %.17g\n" seconds)
    ^ (match entry.max_request_body_bytes with
       | None -> ""
       | Some bytes -> Printf.sprintf "max_request_body_bytes = %d\n" bytes)
    ^
    match entry.enable_thinking with
    | None -> ""
    | Some enabled -> Printf.sprintf "enable_thinking = %b\n" enabled
  in
  let model_options =
    match entry.anthropic_thinking_control with
    | None -> ""
    | Some control -> Printf.sprintf "anthropic_thinking_control = %S\n" control
  in
  let serving_options =
    if entry.serving_constraint
    then
      Printf.sprintf
        "serving_constraint_source_kind = \"probe\"\n\
         serving_constraint_source = \"probe://incident/2793\"\n\
         serving_constraint_checked_at_unix_s = 0\n\
         serving_constraint_confidence = \"high\"\n\
         serving_constraint_expires_at_unix_s = 2000000000\n\
         serving_constraint_accepted_through_tokens = %d\n\
         serving_constraint_rejected_from_tokens = %d\n"
        entry.serving_accepted_through_tokens
        entry.serving_rejected_from_tokens
    else ""
  in
  Printf.sprintf
    "[[providers]]\n\
     id = %S\n\
     kind = %S\n\
     base_url = %S\n\
     request_path = %S\n\
     api_key_env = %S\n\n\
     [[models]]\n\
     id_prefix = %S\n\
     provider_name = %S\n\
     max_context_tokens = 8192\n\
     max_output_tokens = 1024\n\
     %ssupports_response_format_json = %b\n\
     supports_structured_output = %b\n\n\
     [[targets]]\n\
     id = %S\n\
     provider_ref = %S\n\
     model_id = %S\n\
     %s"
    entry.id
    entry.kind
    entry.base_url
    entry.request_path
    entry.api_key_env
    entry.model_id
    entry.id
    (serving_options ^ model_options)
    entry.json
    entry.native
    entry.id
    entry.id
    entry.model_id
    target_options
;;

let with_catalog ?(getenv = fun _ -> Ok None) entries f =
  let document : EO.catalog_document =
    { source = "exact-output outer-flow fixture"
    ; contents = String.concat "\n" (List.map catalog_fixture_toml entries)
    }
  in
  let io : EO.resolver_io = { getenv } in
  match EO.load_resolver_snapshot ~io ~catalog:(EO.Embedded_with_overlay document) () with
  (* Naming the rejected field beats "should load". Discarding the error made a
     catalog that the resolver refuses indistinguishable from any other load
     failure, so a fixture drift showed up only as an assertion label. *)
  | Error (EO.Target_catalog_invalid { detail; _ }) ->
    failf "outer-flow catalog rejected by the resolver: %s" detail
  | Error (EO.Catalog_parse_failed { detail; _ }) ->
    failf "outer-flow catalog did not parse: %s" detail
  | Error (EO.Target_binding_missing { target_ref; _ }) ->
    failf "outer-flow catalog target %s has an unbound component" target_ref
  | Error _ -> fail "outer-flow resolver snapshot should load"
  | Ok snapshot -> f snapshot
;;

let admitted_target snapshot selector =
  match EO.admit_target_ref snapshot selector with
  | Error _ -> failf "target ref %s was not admitted" selector
  | Ok admitted -> admitted
;;

let flow_candidate_as snapshot ~id ~target_ref =
  match
    EO.make_flow_candidate ~id ~admitted_target:(admitted_target snapshot target_ref)
  with
  | Ok candidate -> candidate
  | Error EO.Blank_flow_candidate_id -> fail "fixture candidate id was blank"
;;

let flow_candidate snapshot id = flow_candidate_as snapshot ~id ~target_ref:id

let credential_getenv = function
  | "MISSING_FLOW_KEY" -> Ok None
  | "INVALID_FLOW_KEY" -> Ok (Some "secret\r\nX-Leak: yes")
  | "READ_FAILED_FLOW_KEY" -> Error ()
  | _ -> Ok None
;;

let snapshot_candidates
      ?(messages = [ msg "return one exact object" ])
      ?(requirement =
        EO.make_output_requirement ~schema ~minimum_guarantee:EO.Json_syntax)
      candidates
  =
  match candidates with
  | [] -> fail "flow fixture must be nonempty"
  | first :: rest -> EO.snapshot_flow ~first ~rest ~messages requirement
;;

let frozen_candidates ?messages ?requirement candidates =
  match snapshot_candidates ?messages ?requirement candidates with
  | Ok ready -> ready
  | Error _ -> fail "flow fixture did not admit"
;;

let frozen_flow ?messages snapshot ids =
  List.map (flow_candidate snapshot) ids |> frozen_candidates ?messages
;;

let start_flow ready =
  match EO.start_flow ready with
  | Ok flow -> flow
  | Error (EO.Flow_id_generation_failed detail) ->
    failf "flow identity allocation failed: %s" detail
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

let openai_response content =
  let encoded_content = Yojson.Safe.to_string (`String content) in
  Printf.sprintf
    {|{"id":"resp-flow","model":"flow","choices":[{"index":0,"message":{"role":"assistant","content":%s},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
    encoded_content
;;

let tool_response =
  {|{"id":"resp-tool","model":"flow","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call-1","type":"function","function":{"name":"forbidden","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
;;

let with_server
      ?response_delay_s
      ?(status = `OK)
      ?first_response
      ?(abort_completion = false)
      ~response
      f
  =
  let completion_posts = Atomic.make 0 in
  let result =
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    let port = fresh_port () in
    let handler _conn _request body =
      ignore (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) : string);
      let post_index = Atomic.fetch_and_add completion_posts 1 in
      if abort_completion then raise Exit;
      Option.iter (Eio.Time.sleep clock) response_delay_s;
      let response_status, response_body =
        match first_response, post_index with
        | Some first, 0 -> first
        | Some _, _ | None, _ -> status, response
      in
      Cohttp_eio.Server.respond_string ~status:response_status ~body:response_body ()
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
  result, Atomic.get completion_posts
;;

type measurement_reply =
  | Measurement_tokens of int
  | Measurement_invalid_response
  | Measurement_transport_failure

type post_counts =
  { measurement_posts : int
  ; generation_posts : int
  ; journal_posts : int
  ; measurement_bodies : string list
  ; generation_bodies : string list
  }

let rec atomic_prepend target value =
  let current = Atomic.get target in
  if not (Atomic.compare_and_set target current (value :: current))
  then atomic_prepend target value
;;

let with_counted_server ?measurement_delay_s ~measurement_reply ~response f =
  let measurement_posts = Atomic.make 0 in
  let generation_posts = Atomic.make 0 in
  let journal_posts = Atomic.make 0 in
  let measurement_bodies = Atomic.make [] in
  let generation_bodies = Atomic.make [] in
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
      let path = Uri.path (Cohttp.Request.uri request) in
      match path with
      | path
        when String.equal path "/v1/messages/count_tokens"
             || String.ends_with ~suffix:":countTokens" path ->
        Atomic.incr measurement_posts;
        atomic_prepend measurement_bodies request_body;
        Option.iter (Eio.Time.sleep clock) measurement_delay_s;
        (match measurement_reply with
         | Measurement_tokens input_tokens ->
           let body =
             if String.ends_with ~suffix:":countTokens" path
             then Printf.sprintf {|{"totalTokens":%d}|} input_tokens
             else Printf.sprintf {|{"input_tokens":%d}|} input_tokens
           in
           Cohttp_eio.Server.respond_string ~status:`OK ~body ()
         | Measurement_invalid_response ->
           Cohttp_eio.Server.respond_string ~status:`OK ~body:{|{"wrong":true}|} ()
         | Measurement_transport_failure ->
           Cohttp_eio.Server.respond_string
             ~status:`Internal_server_error
             ~body:{|{"error":"measurement failed"}|}
             ())
      | "/journal" ->
        Atomic.incr journal_posts;
        Cohttp_eio.Server.respond_string ~status:`OK ~body:{|{"stored":true}|} ()
      | _ ->
        Atomic.incr generation_posts;
        atomic_prepend generation_bodies request_body;
        Cohttp_eio.Server.respond_string ~status:`OK ~body:response ()
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
  , { measurement_posts = Atomic.get measurement_posts
    ; generation_posts = Atomic.get generation_posts
    ; journal_posts = Atomic.get journal_posts
    ; measurement_bodies = List.rev (Atomic.get measurement_bodies)
    ; generation_bodies = List.rev (Atomic.get generation_bodies)
    } )
;;

let candidate_id (candidate : EO.flow_attempt_receipt) =
  candidate.visit.identity.candidate_id
;;

let flow_failure_id = function
  | EO.Flow_candidate_rejected rejection ->
    (EO.candidate_rejection_identity rejection).candidate_id
  | EO.Flow_candidate_execution_failed { candidate; _ } -> candidate_id candidate
;;

let flow_advance_failure_id = function
  | EO.Flow_advance_candidate_rejected rejection ->
    (EO.candidate_rejection_identity rejection).candidate_id
  | EO.Flow_advance_execution_failed { candidate; _ } ->
    candidate.visit.identity.candidate_id
;;

let flow_execution_failure = function
  | EO.Flow_candidate_execution_failed { candidate; cause; _ } -> candidate, cause
  | EO.Flow_candidate_rejected _ ->
    fail "expected an execution failure, got a candidate rejection"
;;

let attempt_for evidence id =
  match
    List.find_opt
      (fun (attempt : EO.flow_attempt_snapshot) ->
         String.equal attempt.visit.identity.candidate_id id)
      evidence.EO.attempts
  with
  | Some attempt -> attempt
  | None -> failf "missing attempt evidence for %s" id
;;

type no_semantic_rejection = |

let accepting_test_validator success
  : (EO.flow_success, no_semantic_rejection) EO.semantic_verdict
  =
  EO.Accept success
;;

let transport_test_result
      (result :
        ( (EO.flow_success, no_semantic_rejection) EO.validated_flow_success
          , ('callback_error, no_semantic_rejection) EO.validated_flow_error )
          result)
  : (EO.flow_success, 'callback_error EO.flow_execution_error) result
  =
  match result with
  | Ok success -> Ok success.transport_success
  | Error (EO.Flow_execution_terminal { cause; _ }) -> Error cause
  | Error (EO.Flow_semantic_candidates_exhausted _) -> .
;;

let execute_with_accepting_test_validator
      ~net
      ?clock
      ~before_measurement_dispatch
      ~on_measurement_terminal
      ~before_dispatch
      ~before_advance
      flow
  =
  EO.execute_flow_once
    ~net
    ?clock
    ~before_measurement_dispatch
    ~on_measurement_terminal
    ~before_dispatch
    ~before_advance
    ~validate:accepting_test_validator
    flow
  |> transport_test_result
;;

let execute_ok ~net flow =
  execute_with_accepting_test_validator
    ~net
    ~on_measurement_terminal:(fun _ -> Ok ())
    ~before_measurement_dispatch:(fun _ -> Ok ())
    ~before_dispatch:(fun _ -> Ok ())
    ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
    flow
;;

let execute_with_validator ~net ~before_advance ~validate flow =
  EO.execute_flow_once
    ~net
    ~on_measurement_terminal:(fun _ -> Ok ())
    ~before_measurement_dispatch:(fun _ -> Ok ())
    ~before_dispatch:(fun _ -> Ok ())
    ~before_advance
    ~validate
    flow
;;

let semantic_rejection_candidate_id (rejection : _ EO.semantic_rejection_receipt) =
  rejection.EO.transport_success |> EO.flow_success_candidate |> candidate_id
;;

let candidate_ids identities =
  List.map
    (fun (identity : EO.flow_candidate_identity) -> identity.candidate_id)
    identities
;;

let flow_snapshot_evidence ready = EO.flow_attempt_evidence (start_flow ready)

let flow_snapshot_ids ready =
  flow_snapshot_evidence ready
  |> fun evidence -> candidate_ids evidence.declared_candidate_snapshot
;;

let test_snapshot_defers_admission_and_allocates_nonshared_current_attempts () =
  let (before_a, before_b, result_a, result_b), posts =
    with_server ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    let entry id native json = catalog_entry ~id ~base_url ~native ~json () in
    with_catalog
      [ entry "flow-good-a" true true
      ; entry "flow-rejected" false false
      ; entry "flow-good-b" true true
      ]
    @@ fun snapshot ->
    let candidates =
      List.map (flow_candidate snapshot) [ "flow-good-a"; "flow-rejected"; "flow-good-b" ]
    in
    let ready =
      match candidates with
      | first :: rest ->
        (match
           EO.snapshot_flow
             ~first
             ~rest
             ~messages:[ msg "freeze all" ]
             (EO.make_output_requirement ~schema ~minimum_guarantee:EO.Json_syntax)
         with
         | Ok ready -> ready
         | Error _ -> fail "valid flow topology should freeze")
      | [] -> assert false
    in
    let flow_a = start_flow ready in
    let flow_b = start_flow ready in
    let before_a = EO.flow_attempt_evidence flow_a in
    let before_b = EO.flow_attempt_evidence flow_b in
    check
      string
      "flow A handle and evidence share one identity"
      (EO.flow_id_to_string before_a.flow_id)
      (EO.flow_id_to_string (EO.flow_attempt_id flow_a));
    check
      string
      "flow B handle and evidence share one identity"
      (EO.flow_id_to_string before_b.flow_id)
      (EO.flow_id_to_string (EO.flow_attempt_id flow_b));
    before_a, before_b, execute_ok ~net flow_a, execute_ok ~net flow_b
  in
  check int "two independent current attempts make two POSTs" 2 posts;
  check
    bool
    "independent flow starts do not share outer identity"
    true
    (not
       (String.equal
          (EO.flow_id_to_string before_a.flow_id)
          (EO.flow_id_to_string before_b.flow_id)));
  List.iter
    (fun evidence ->
       check
         int
         "candidate snapshot is complete"
         3
         (List.length evidence.EO.declared_candidate_snapshot);
       check int "no admission is speculative" 0 (List.length evidence.admissions);
       check int "no attempt is speculative" 0 (List.length evidence.attempts);
       check
         int
         "candidate visit count starts at zero"
         0
         (EO.candidate_visit_count_to_int evidence.candidate_visit_count))
    [ before_a; before_b ];
  match result_a, result_b with
  | Ok success_a, Ok success_b ->
    List.iter
      (fun success ->
         let evidence = EO.flow_success_evidence success in
         check
           int
           "only current candidate is admitted"
           1
           (List.length evidence.EO.admissions);
         check
           int
           "only current candidate gets an attempt"
           1
           (List.length evidence.attempts);
         check
           int
           "candidate visit count advances once"
           1
           (EO.candidate_visit_count_to_int evidence.candidate_visit_count))
      [ success_a; success_b ];
    check
      bool
      "separate flows do not share call identity"
      true
      (not
         (String.equal
            (EO.receipt_call_id (EO.flow_success_candidate success_a).receipt
             |> EO.call_id_to_string)
            (EO.receipt_call_id (EO.flow_success_candidate success_b).receipt
             |> EO.call_id_to_string)));
    List.iter
      (fun success ->
         let candidate = EO.flow_success_candidate success in
         let evidence = EO.flow_success_evidence success in
         check
           string
           "attempt visit remains bound to its outer flow"
           (EO.flow_id_to_string evidence.flow_id)
           (EO.flow_id_to_string candidate.visit.flow_id);
         check
           int
           "current candidate visit ordinal is one"
           1
           (EO.flow_visit_ordinal_to_int candidate.visit.ordinal))
      [ success_a; success_b ]
  | Ok _, Error _ | Error _, Ok _ | Error _, Error _ ->
    fail "independent current candidates did not both succeed"
;;

let test_later_missing_credential_does_not_block_current_success () =
  let (result, advances), posts =
    with_server ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      ~getenv:credential_getenv
      [ catalog_entry ~id:"current-good" ~base_url ~native:true ~json:true ()
      ; catalog_entry
          ~api_key_env:"MISSING_FLOW_KEY"
          ~id:"later-missing"
          ~base_url
          ~native:true
          ~json:true
          ()
      ]
    @@ fun snapshot ->
    let advances = ref 0 in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun _ -> Ok ())
        ~before_advance:(fun ~failed:_ ~next:_ ->
          incr advances;
          Ok ())
        (start_flow (frozen_flow snapshot [ "current-good"; "later-missing" ]))
    in
    result, !advances
  in
  check int "only the current candidate posts" 1 posts;
  check int "unvisited missing credential does not advance" 0 advances;
  match result with
  | Ok success ->
    check
      string
      "current candidate succeeds"
      "current-good"
      (candidate_id (EO.flow_success_candidate success));
    check
      int
      "full candidate snapshot remains frozen"
      2
      (List.length (EO.flow_success_evidence success).declared_candidate_snapshot);
    check
      int
      "only current admission is recorded"
      1
      (List.length (EO.flow_success_evidence success).admissions);
    check
      int
      "only current attempt is allocated"
      1
      (List.length (EO.flow_success_evidence success).attempts);
    check
      int
      "only current candidate is visited"
      1
      (EO.candidate_visit_count_to_int
         (EO.flow_success_evidence success).candidate_visit_count)
  | Error _ -> fail "later missing credential blocked the current candidate"
;;

let test_json_syntax_is_prompt_only_even_for_native_target () =
  let (result, advances), posts =
    with_counted_server
      ~measurement_reply:(Measurement_tokens 1)
      ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog [ catalog_entry ~id:"text-json" ~base_url ~native:true ~json:true () ]
    @@ fun snapshot ->
    let advances = ref 0 in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun _ -> Ok ())
        ~before_advance:(fun ~failed:_ ~next:_ ->
          incr advances;
          Ok ())
        (start_flow (frozen_flow snapshot [ "text-json" ]))
    in
    result, !advances
  in
  check int "prompt-only syntax skips measurement" 0 posts.measurement_posts;
  check int "prompt-only syntax posts exactly once" 1 posts.generation_posts;
  check int "successful prompt-only syntax does not advance" 0 advances;
  let request =
    match posts.generation_bodies with
    | [ body ] -> Yojson.Safe.from_string body
    | _ -> fail "prompt-only syntax did not retain its single generation body"
  in
  (match request with
   | `Assoc fields ->
     check
       bool
       "prompt-only syntax emits no response_format field for a native target"
       false
       (List.mem_assoc "response_format" fields)
   | _ -> fail "prompt-only syntax request body was not an object");
  let messages = Yojson.Safe.Util.(request |> member "messages" |> to_list) in
  check int "strict JSON instruction is appended last" 2 (List.length messages);
  let instruction =
    match List.rev messages with
    | final :: _ -> Yojson.Safe.Util.(final |> member "content" |> to_string)
    | [] -> fail "text fallback request lost all messages"
  in
  check
    bool
    "final instruction requires a bare JSON value"
    true
    (String.starts_with
       ~prefix:
         "Return exactly one JSON value matching this JSON Schema. Do not use Markdown \
          code fences or include any explanation. JSON Schema:"
       instruction);
  match result with
  | Ok success ->
    check
      string
      "prompt-only syntax candidate serves the request"
      "text-json"
      (candidate_id (EO.flow_success_candidate success));
    check
      bool
      "strict text fallback returns parsed JSON"
      true
      ((EO.flow_success_output success).output = `Assoc [ "name", `String "accepted" ])
  | Error _ -> fail "valid JSON text fallback did not succeed"
;;

let test_fenced_text_json_advances_to_frozen_successor () =
  let first_response =
    `OK, openai_response "```json\n{\"name\":\"must-not-be-cleaned\"}\n```"
  in
  let (result, observed_advance, advances), posts =
    with_server ~first_response ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry ~id:"fenced-text" ~base_url ~native:false ~json:false ()
      ; catalog_entry ~id:"bare-text" ~base_url ~native:false ~json:false ()
      ]
    @@ fun snapshot ->
    let observed_advance = ref None in
    let advances = ref 0 in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun _ -> Ok ())
        ~before_advance:(fun ~failed ~next ->
          let candidate, failure = flow_execution_failure failed in
          observed_advance
          := Some
               ( candidate_id candidate
               , next.identity.candidate_id
               , failure.EO.cause
               , EO.receipt_phase failure.receipt
               , EO.receipt_dispatch_count failure.receipt );
          incr advances;
          Ok ())
        (start_flow (frozen_flow snapshot [ "fenced-text"; "bare-text" ]))
    in
    result, !observed_advance, !advances
  in
  check int "invalid then valid fallback performs two POSTs" 2 posts;
  check int "invalid fallback advances once" 1 advances;
  (match observed_advance with
   | Some (failed, next, cause, phase, dispatch_count) ->
     check string "invalid fallback candidate" "fenced-text" failed;
     check string "frozen fallback successor" "bare-text" next;
     check bool "fenced text is invalid JSON" true (cause = EO.Invalid_json_output);
     check bool "invalid fallback receipt is terminal" true (phase = EO.Terminal);
     check int "invalid fallback preserves one POST" 1 dispatch_count
   | None -> fail "invalid fallback did not request its frozen successor");
  match result with
  | Ok success ->
    check
      string
      "bare JSON successor serves the request"
      "bare-text"
      (candidate_id (EO.flow_success_candidate success));
    (match (EO.flow_success_evidence success).advances with
     | [ advance ] ->
       check
         string
         "durable advance binds failed candidate"
         "fenced-text"
         (flow_advance_failure_id advance.failed);
       check
         string
         "durable advance binds declared successor"
         "bare-text"
         advance.next.identity.candidate_id
     | _ -> fail "successful fallback did not retain exactly one advance receipt");
    check
      bool
      "successor output is parsed without cleanup"
      true
      ((EO.flow_success_output success).output = `Assoc [ "name", `String "accepted" ])
  | Error _ -> fail "strict fallback did not advance to its frozen successor"
;;

let test_provider_schema_still_requires_native_capability () =
  let requirement =
    EO.make_output_requirement ~schema ~minimum_guarantee:EO.Provider_schema
  in
  let (result, evidence), posts =
    with_counted_server ~measurement_reply:(Measurement_tokens 1) ~response:"unused"
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry ~id:"no-native-schema" ~base_url ~native:false ~json:false () ]
    @@ fun snapshot ->
    let flow =
      start_flow
        (frozen_candidates ~requirement [ flow_candidate snapshot "no-native-schema" ])
    in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ ->
          fail "provider-schema rejection reached measurement terminal")
        ~before_measurement_dispatch:(fun _ ->
          fail "provider-schema rejection reached measurement dispatch")
        ~before_dispatch:(fun _ ->
          fail "provider-schema rejection reached generation dispatch")
        ~before_advance:(fun ~failed:_ ~next:_ ->
          fail "single provider-schema rejection requested a successor")
        flow
    in
    result, EO.flow_attempt_evidence flow
  in
  check
    int
    "provider-schema rejection performs no measurement POST"
    0
    posts.measurement_posts;
  check
    int
    "provider-schema rejection performs no generation POST"
    0
    posts.generation_posts;
  check
    int
    "provider-schema rejection allocates no attempt"
    0
    (List.length evidence.attempts);
  match result with
  | Error (EO.Flow_candidates_exhausted { rejection; _ } as error) ->
    check
      bool
      "provider-schema rejection starts no outward dispatch"
      true
      (EO.flow_execution_error_generation_dispatch error = EO.No_generation_dispatch);
    (match EO.candidate_rejection_disposition rejection with
     | EO.Output_requirement_rejected -> ()
     | _ -> fail "provider-schema rejection lost its typed disposition")
  | Ok _ | Error _ -> fail "missing native schema support was not rejected pre-dispatch"
;;

let test_missing_current_credential_advances_after_durable_settlement () =
  let (result, transitions, bound, next_visit), posts =
    with_server ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      ~getenv:credential_getenv
      [ catalog_entry
          ~api_key_env:"MISSING_FLOW_KEY"
          ~id:"current-missing"
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry ~id:"next-good" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    let transitions = ref [] in
    let bound = ref [] in
    let next_visit = ref None in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun candidate ->
          bound := candidate_id candidate :: !bound;
          Ok ())
        ~before_advance:(fun ~failed ~next ->
          match failed with
          | EO.Flow_candidate_rejected rejection ->
            let identity = EO.candidate_rejection_identity rejection in
            (match EO.candidate_rejection_disposition rejection with
             | EO.Runtime_slot_unavailable -> ()
             | _ -> fail "missing credential lost its neutral slot disposition");
            check
              string
              "rejected current identity"
              "current-missing"
              identity.candidate_id;
            check
              int
              "selection rejection is first visit"
              1
              (EO.flow_visit_ordinal_to_int
                 (EO.candidate_rejection_visit rejection).ordinal);
            check
              string
              "rejection and successor share one outer flow"
              (EO.flow_id_to_string (EO.candidate_rejection_visit rejection).flow_id)
              (EO.flow_id_to_string next.flow_id);
            check
              int
              "successor visit is second"
              2
              (EO.flow_visit_ordinal_to_int next.ordinal);
            next_visit := Some next;
            transitions
            := (identity.candidate_id, next.identity.candidate_id) :: !transitions;
            Ok ()
          | EO.Flow_candidate_execution_failed _ ->
            fail "missing credential became an execution failure")
        (start_flow (frozen_flow snapshot [ "current-missing"; "next-good" ]))
    in
    result, List.rev !transitions, List.rev !bound, !next_visit
  in
  check int "only resolved successor posts" 1 posts;
  check
    (list (pair string string))
    "selection rejection advances to predetermined successor"
    [ "current-missing", "next-good" ]
    transitions;
  check (list string) "only successor reaches before_dispatch" [ "next-good" ] bound;
  match result with
  | Ok success ->
    check
      string
      "resolved successor succeeds"
      "next-good"
      (candidate_id (EO.flow_success_candidate success));
    check
      int
      "both candidate outcomes remain ordered"
      2
      (List.length (EO.flow_success_evidence success).admissions);
    check
      int
      "only successor gets an attempt"
      1
      (List.length (EO.flow_success_evidence success).attempts);
    (match next_visit with
     | Some next ->
       check
         string
         "settled successor visit becomes the successful attempt visit"
         (EO.flow_id_to_string next.flow_id)
         (EO.flow_id_to_string (EO.flow_success_candidate success).visit.flow_id);
       check
         int
         "settled successor ordinal is retained by the attempt"
         (EO.flow_visit_ordinal_to_int next.ordinal)
         (EO.flow_visit_ordinal_to_int (EO.flow_success_candidate success).visit.ordinal);
       check
         string
         "settled successor identity is retained by the attempt"
         next.identity.candidate_id
         (EO.flow_success_candidate success).visit.identity.candidate_id
     | None -> fail "successful successor had no settled visit");
    check
      int
      "both candidates are visited"
      2
      (EO.candidate_visit_count_to_int
         (EO.flow_success_evidence success).candidate_visit_count)
  | Error _ -> fail "durably settled selection rejection did not reach successor"
;;

let test_read_failed_current_credential_advances_to_good_successor () =
  let (result, advances), posts =
    with_server ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      ~getenv:credential_getenv
      [ catalog_entry
          ~api_key_env:"READ_FAILED_FLOW_KEY"
          ~id:"read-failed-current"
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry ~id:"read-failed-successor" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    let advances = ref [] in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun _ -> Ok ())
        ~before_advance:(fun ~failed ~next ->
          match failed with
          | EO.Flow_candidate_rejected rejection ->
            (match EO.candidate_rejection_disposition rejection with
             | EO.Runtime_slot_unavailable -> ()
             | _ -> fail "read-failed credential lost its neutral slot disposition");
            advances
            := ( (EO.candidate_rejection_identity rejection).candidate_id
               , next.identity.candidate_id )
               :: !advances;
            Ok ()
          | EO.Flow_candidate_execution_failed _ ->
            fail "read-failed credential became an execution attempt")
        (start_flow
           (frozen_flow snapshot [ "read-failed-current"; "read-failed-successor" ]))
    in
    result, List.rev !advances
  in
  check int "only the read-failed successor posts" 1 posts;
  check
    (list (pair string string))
    "read-failed credential advances in frozen order"
    [ "read-failed-current", "read-failed-successor" ]
    advances;
  match result with
  | Ok success ->
    check
      string
      "read-failed successor succeeds"
      "read-failed-successor"
      (candidate_id (EO.flow_success_candidate success))
  | Error _ -> fail "read-failed current candidate blocked its good successor"
;;

let test_credential_rejections_are_ordered_zero_dispatch_terminal () =
  let (result, transitions, evidence), posts =
    with_server ~response:(openai_response {|{"name":"unused"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      ~getenv:credential_getenv
      [ catalog_entry
          ~api_key_env:"MISSING_FLOW_KEY"
          ~id:"credential-missing"
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry
          ~api_key_env:"INVALID_FLOW_KEY"
          ~id:"credential-invalid"
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry
          ~api_key_env:"READ_FAILED_FLOW_KEY"
          ~id:"credential-read-failed"
          ~base_url
          ~native:true
          ~json:true
          ()
      ]
    @@ fun snapshot ->
    let transitions = ref [] in
    let flow =
      start_flow
        (frozen_flow
           snapshot
           [ "credential-missing"; "credential-invalid"; "credential-read-failed" ])
    in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun candidate ->
          failf "credential rejection %s reached before_dispatch" (candidate_id candidate))
        ~before_advance:(fun ~failed ~next ->
          transitions
          := (flow_failure_id failed, next.identity.candidate_id) :: !transitions;
          Ok ())
        flow
    in
    result, List.rev !transitions, EO.flow_attempt_evidence flow
  in
  check int "credential rejections perform zero completion POSTs" 0 posts;
  check
    (list (pair string string))
    "credential rejection transitions remain ordered"
    [ "credential-missing", "credential-invalid"
    ; "credential-invalid", "credential-read-failed"
    ]
    transitions;
  check
    int
    "credential rejections fabricate no attempts"
    0
    (List.length evidence.attempts);
  check int "all credential outcomes remain ordered" 3 (List.length evidence.admissions);
  let check_rejection ~id ~visit rejection =
    check
      string
      "credential rejection identity"
      id
      (EO.candidate_rejection_identity rejection).candidate_id;
    check
      int
      "credential rejection visit is exact"
      visit
      (EO.flow_visit_ordinal_to_int (EO.candidate_rejection_visit rejection).ordinal);
    match EO.candidate_rejection_disposition rejection with
    | EO.Runtime_slot_unavailable -> ()
    | _ -> fail "credential rejection leaked a non-neutral disposition"
  in
  (match evidence.admissions with
   | [ EO.Candidate_rejected missing
     ; EO.Candidate_rejected invalid
     ; EO.Candidate_rejected read_failed
     ] ->
     check_rejection ~id:"credential-missing" ~visit:1 missing;
     check_rejection ~id:"credential-invalid" ~visit:2 invalid;
     check_rejection ~id:"credential-read-failed" ~visit:3 read_failed
   | _ -> fail "credential evidence did not retain three typed rejections");
  match result with
  | Error
      (EO.Flow_candidates_exhausted { rejection; evidence = terminal_evidence } as error)
    ->
    check
      bool
      "candidate exhaustion starts no outward dispatch"
      true
      (EO.flow_execution_error_generation_dispatch error = EO.No_generation_dispatch);
    check
      string
      "last rejected candidate is terminal"
      "credential-read-failed"
      (EO.candidate_rejection_identity rejection).candidate_id;
    check int "terminal retains zero attempts" 0 (List.length terminal_evidence.attempts);
    check
      int
      "terminal candidate visit count is exact"
      3
      (EO.candidate_visit_count_to_int terminal_evidence.candidate_visit_count)
  | Ok _ | Error _ -> fail "credential exhaustion lost its typed terminal rejection"
;;

let test_unmeasured_constraint_advances_only_after_durable_settlement () =
  let (result, transitions, bound), posts =
    with_server ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry
          ~id:"constrained-exact"
          ~base_url
          ~native:true
          ~json:true
          ~serving_constraint:true
          ()
      ; catalog_entry ~id:"unconstrained-exact" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    let ready = frozen_flow snapshot [ "constrained-exact"; "unconstrained-exact" ] in
    let transitions = ref [] in
    let bound = ref [] in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun candidate ->
          bound := candidate_id candidate :: !bound;
          Ok ())
        ~before_advance:(fun ~failed ~next ->
          match failed with
          | EO.Flow_candidate_rejected rejection ->
            let identity = EO.candidate_rejection_identity rejection in
            let accepted_through_tokens, rejected_from_tokens =
              match EO.candidate_rejection_disposition rejection with
              | EO.Input_capacity
                  (EO.Token_measurement_required
                     { accepted_through_tokens; rejected_from_tokens }) ->
                accepted_through_tokens, rejected_from_tokens
              | _ -> fail "capacity rejection lost its neutral disposition"
            in
            check
              string
              "settled rejected identity"
              "constrained-exact"
              identity.candidate_id;
            check int "settled constraint remains exact" 524298 accepted_through_tokens;
            check
              (option int)
              "settled rejected boundary remains exact"
              (Some 524299)
              rejected_from_tokens;
            check
              string
              "candidate rejection and successor share one flow"
              (EO.flow_id_to_string (EO.candidate_rejection_visit rejection).flow_id)
              (EO.flow_id_to_string next.flow_id);
            check
              bool
              "unsupported measurement starts no measurement wire"
              true
              (EO.candidate_rejection_measurement_dispatch_fact rejection
               = EO.No_measurement_dispatch);
            check
              bool
              "unsupported measurement remains typed"
              true
              (EO.candidate_rejection_measurement_outcome rejection
               = EO.Measurement_unsupported);
            transitions
            := (identity.candidate_id, next.identity.candidate_id) :: !transitions;
            Ok ()
          | _ -> fail "capacity rejection lost its typed durable transition")
        (start_flow ready)
    in
    result, List.rev !transitions, List.rev !bound
  in
  check int "only the admitted successor posts" 1 posts;
  check
    (list (pair string string))
    "capacity transition is explicit"
    [ "constrained-exact", "unconstrained-exact" ]
    transitions;
  check
    (list string)
    "only the admitted successor reaches before_dispatch"
    [ "unconstrained-exact" ]
    bound;
  match result with
  | Ok success ->
    check
      string
      "admitted successor succeeds"
      "unconstrained-exact"
      (candidate_id (EO.flow_success_candidate success));
    let evidence = EO.flow_success_evidence success in
    check int "only reached candidates are admitted" 2 (List.length evidence.admissions);
    check
      int
      "candidate visit count preserves ordered progress"
      2
      (EO.candidate_visit_count_to_int evidence.candidate_visit_count)
  | Error _ -> fail "durably settled admission rejection did not reach its successor"
;;

let test_request_body_capacity_advances_only_after_durable_settlement () =
  let (result, transition), posts =
    with_counted_server
      ~measurement_reply:(Measurement_tokens 1)
      ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry
          ~max_request_body_bytes:1
          ~id:"body-capped"
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry ~id:"body-successor" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    let transition = ref None in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun _ -> Ok ())
        ~before_advance:(fun ~failed ~next ->
          match failed with
          | EO.Flow_candidate_rejected rejection ->
            let actual_bytes, limit_bytes =
              match EO.candidate_rejection_disposition rejection with
              | EO.Input_capacity
                  (EO.Serialized_request_body_too_large { actual_bytes; limit_bytes }) ->
                actual_bytes, limit_bytes
              | _ -> fail "request-body rejection lost its neutral disposition"
            in
            check bool "serialized body exceeds the exact cap" true (actual_bytes > 1);
            check int "declared cap remains exact" 1 limit_bytes;
            check
              bool
              "body cap starts no measurement wire"
              true
              (EO.candidate_rejection_measurement_dispatch_fact rejection
               = EO.No_measurement_dispatch);
            check
              bool
              "body cap remains a typed local rejection"
              true
              (EO.candidate_rejection_measurement_outcome rejection
               = EO.Measurement_local_invalid);
            transition
            := Some
                 ( (EO.candidate_rejection_identity rejection).candidate_id
                 , next.identity.candidate_id );
            Ok ()
          | _ -> fail "request-body rejection lost its typed durable transition")
        (start_flow (frozen_flow snapshot [ "body-capped"; "body-successor" ]))
    in
    result, !transition
  in
  check int "body cap starts no measurement wire" 0 posts.measurement_posts;
  check int "only body-cap successor generates" 1 posts.generation_posts;
  check
    (option (pair string string))
    "request-body transition is explicit"
    (Some ("body-capped", "body-successor"))
    transition;
  match result with
  | Ok success ->
    check
      string
      "body-cap successor succeeds"
      "body-successor"
      (candidate_id (EO.flow_success_candidate success))
  | Error _ -> fail "durably settled body-cap rejection did not reach its successor"
;;

let test_request_body_projection_is_exact_and_credential_free () =
  let id = "body-projection" in
  let base_url = "https://projection.invalid" in
  let api_key_env = "MISSING_FLOW_KEY" in
  let requirement =
    EO.make_output_requirement ~schema ~minimum_guarantee:EO.Provider_schema
  in
  let messages = [ msg "measure the exact provider request body" ] in
  let project ?max_request_body_bytes () =
    with_catalog
      ~getenv:credential_getenv
      [ catalog_entry
          ?max_request_body_bytes
          ~api_key_env
          ~id
          ~base_url
          ~native:true
          ~json:true
          ()
      ]
    @@ fun snapshot ->
    let target = admitted_target snapshot id in
    let projection =
      match EO.project_request_body ~target ~messages requirement with
      | Ok projection -> projection
      | Error _ -> fail "credential-free body projection was rejected"
    in
    (match EO.resolve_target target with
     | Error _ -> ()
     | Ok _ -> fail "fixture did not retain its missing credential");
    projection
  in
  let uncapped = project () in
  check bool "uncapped body projection is finite" true (uncapped.actual_bytes > 0);
  check (option int) "uncapped target preserves no limit" None uncapped.limit_bytes;
  check bool "uncapped projection fits" true uncapped.within_limit;
  let exact = project ~max_request_body_bytes:uncapped.actual_bytes () in
  check
    int
    "declared cap does not change body bytes"
    uncapped.actual_bytes
    exact.actual_bytes;
  check
    (option int)
    "exact cap is preserved"
    (Some uncapped.actual_bytes)
    exact.limit_bytes;
  check bool "exact boundary fits" true exact.within_limit;
  let rejected = project ~max_request_body_bytes:(uncapped.actual_bytes - 1) () in
  check
    int
    "over-limit projection returns the same exact body bytes"
    uncapped.actual_bytes
    rejected.actual_bytes;
  check
    (option int)
    "over-limit projection preserves the exact cap"
    (Some (uncapped.actual_bytes - 1))
    rejected.limit_bytes;
  check bool "limit minus one is rejected" false rejected.within_limit
;;

let test_measured_token_and_body_capacity_are_independent () =
  let large_input = String.make 65536 'x' in
  let response =
    {|{"id":"msg-flow","type":"message","role":"assistant","model":"flow","content":[{"type":"text","text":"{\"name\":\"accepted\"}"}],"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1}}|}
  in
  let cases =
    [ "low-token large-byte success", 2, 100000, `Success
    ; "token boundary rejection", 3, 100000, `Token_rejected
    ; "serialized byte rejection", 2, 1, `Body_rejected
    ]
  in
  List.iter
    (fun (label, measured_tokens, max_request_body_bytes, expected) ->
       let (result, evidence), posts =
         with_counted_server
           ~measurement_reply:(Measurement_tokens measured_tokens)
           ~response
         @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
         with_catalog
           [ catalog_entry
               ~kind:"anthropic"
               ~request_path:"/v1/messages"
               ~serving_constraint:true
               ~serving_accepted_through_tokens:2
               ~serving_rejected_from_tokens:3
               ~max_request_body_bytes
               ~id:"measured-capacity"
               ~base_url
               ~native:true
               ~json:true
               ()
           ]
         @@ fun snapshot ->
         let flow =
           start_flow
             (frozen_flow ~messages:[ msg large_input ] snapshot [ "measured-capacity" ])
         in
         let result =
           execute_with_accepting_test_validator
             ~net
             ~on_measurement_terminal:(fun _ -> Ok ())
             ~before_measurement_dispatch:(fun _ -> Ok ())
             ~before_dispatch:(fun _ -> Ok ())
             ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
             flow
         in
         result, EO.flow_attempt_evidence flow
       in
       match expected, result with
       | `Success, Ok _ ->
         check int (label ^ " measurement dispatches") 1 posts.measurement_posts;
         check int (label ^ " generation dispatches") 1 posts.generation_posts;
         check int (label ^ " owns one attempt") 1 (List.length evidence.attempts);
         (match evidence.admissions with
          | [ EO.Candidate_admitted candidate ] ->
            check
              bool
              (label ^ " records measurement dispatch")
              true
              (candidate.measurement.dispatch = EO.Measurement_dispatch_started);
            check
              bool
              (label ^ " records successful measurement")
              true
              (candidate.measurement.outcome = EO.Measurement_succeeded)
          | _ -> fail (label ^ " lost admitted measurement evidence"))
       | `Token_rejected, Error (EO.Flow_candidates_exhausted { rejection; _ }) ->
         (match EO.candidate_rejection_disposition rejection with
          | EO.Input_capacity
              (EO.Token_capacity_rejected
                 (EO.Capacity_input_rejected
                    { input_tokens = 3
                    ; accepted_through_tokens = 2
                    ; rejected_from_tokens = 3
                    })) -> ()
          | _ -> fail (label ^ " lost its typed token-capacity rejection"));
         check int (label ^ " measurement dispatches") 1 posts.measurement_posts;
         check int (label ^ " generation dispatches") 0 posts.generation_posts;
         check
           bool
           (label ^ " records measurement dispatch")
           true
           (EO.candidate_rejection_measurement_dispatch_fact rejection
            = EO.Measurement_dispatch_started);
         check
           bool
           (label ^ " records successful measurement")
           true
           (EO.candidate_rejection_measurement_outcome rejection
            = EO.Measurement_succeeded);
         check int (label ^ " fabricates no attempt") 0 (List.length evidence.attempts)
       | `Body_rejected, Error (EO.Flow_candidates_exhausted { rejection; _ }) ->
         (match EO.candidate_rejection_disposition rejection with
          | EO.Input_capacity
              (EO.Serialized_request_body_too_large { actual_bytes; limit_bytes = 1 }) ->
            check bool (label ^ " measures final bytes") true (actual_bytes > 1)
          | _ -> fail (label ^ " lost its typed byte-capacity rejection"));
         check int (label ^ " measurement dispatches") 0 posts.measurement_posts;
         check int (label ^ " generation dispatches") 0 posts.generation_posts;
         check
           bool
           (label ^ " records local preflight rejection")
           true
           (EO.candidate_rejection_measurement_outcome rejection
            = EO.Measurement_local_invalid);
         check int (label ^ " fabricates no attempt") 0 (List.length evidence.attempts)
       | `Success, Error _ -> fail (label ^ " did not admit")
       | (`Token_rejected | `Body_rejected), Ok _ -> fail (label ^ " dispatched")
       | (`Token_rejected | `Body_rejected), Error _ ->
         fail (label ^ " returned the wrong terminal error"))
    cases
;;

let test_measurement_receipt_codec_and_transition () =
  let response =
    {|{"id":"msg-flow","type":"message","role":"assistant","model":"flow","content":[{"type":"text","text":"{\"name\":\"accepted\"}"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}|}
  in
  let (intent, terminal), posts =
    with_counted_server ~measurement_reply:(Measurement_tokens 1) ~response
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~serving_constraint:true
          ~id:"measurement-receipt-codec"
          ~base_url
          ~native:true
          ~json:true
          ()
      ]
    @@ fun snapshot ->
    let flow = start_flow (frozen_flow snapshot [ "measurement-receipt-codec" ]) in
    let intent = ref None in
    let terminal = ref None in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~before_measurement_dispatch:(fun measurement ->
          intent := Some (EO.flow_measurement_receipt_snapshot measurement);
          Ok ())
        ~on_measurement_terminal:(fun measurement ->
          terminal := Some (EO.flow_measurement_receipt_snapshot measurement);
          Ok ())
        ~before_dispatch:(fun _ -> Ok ())
        ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
        flow
    in
    (match result with
     | Ok _ -> ()
     | Error _ -> fail "measurement receipt codec fixture did not complete");
    let require_snapshot label = function
      | Some snapshot -> snapshot
      | None -> fail (label ^ " snapshot was not published")
    in
    require_snapshot "intent" !intent, require_snapshot "terminal" !terminal
  in
  check int "codec fixture measures once" 1 posts.measurement_posts;
  check int "codec fixture generates once" 1 posts.generation_posts;
  let decode label encoded =
    match EO.measurement_receipt_snapshot_of_string encoded with
    | Ok snapshot -> snapshot
    | Error error ->
      failf
        "%s decode failed: %s"
        label
        (EO.measurement_receipt_snapshot_decode_error_to_string error)
  in
  let intent_encoded = EO.measurement_receipt_snapshot_to_string intent in
  let terminal_encoded = EO.measurement_receipt_snapshot_to_string terminal in
  let decoded_intent = decode "intent" intent_encoded in
  let decoded_terminal = decode "terminal" terminal_encoded in
  check
    string
    "intent codec is canonical"
    intent_encoded
    (EO.measurement_receipt_snapshot_to_string decoded_intent);
  check
    string
    "terminal codec is canonical"
    terminal_encoded
    (EO.measurement_receipt_snapshot_to_string decoded_terminal);
  check
    string
    "operation identity survives durable round trip"
    (EO.measurement_operation_id_to_string (EO.measurement_receipt_operation_id intent))
    (EO.measurement_operation_id_to_string
       (EO.measurement_receipt_operation_id decoded_terminal));
  check
    string
    "catalog generation survives durable round trip"
    (EO.measurement_receipt_catalog_generation_fingerprint intent)
    (EO.measurement_receipt_catalog_generation_fingerprint decoded_terminal);
  check
    string
    "catalog evidence survives durable round trip"
    (EO.measurement_receipt_catalog_evidence_sha256 intent)
    (EO.measurement_receipt_catalog_evidence_sha256 decoded_terminal);
  check
    bool
    "first callback is dispatch intent"
    true
    (match EO.classify_measurement_receipt_transition ~previous:None ~incoming:intent with
     | EO.Measurement_dispatch_intent -> true
     | _ -> false);
  check
    bool
    "same dispatch intent is idempotent"
    true
    (match
       EO.classify_measurement_receipt_transition
         ~previous:(Some intent)
         ~incoming:decoded_intent
     with
     | EO.Measurement_idempotent_replay -> true
     | _ -> false);
  check
    bool
    "terminal callback advances the same operation"
    true
    (match
       EO.classify_measurement_receipt_transition
         ~previous:(Some decoded_intent)
         ~incoming:decoded_terminal
     with
     | EO.Measurement_terminal_advance -> true
     | _ -> false);
  check
    bool
    "same terminal evidence is idempotent"
    true
    (match
       EO.classify_measurement_receipt_transition
         ~previous:(Some terminal)
         ~incoming:decoded_terminal
     with
     | EO.Measurement_idempotent_replay -> true
     | _ -> false);
  check
    bool
    "terminal to intent is a typed monotonicity conflict"
    true
    (match
       EO.classify_measurement_receipt_transition
         ~previous:(Some terminal)
         ~incoming:intent
     with
     | EO.Measurement_transition_conflict
         (EO.Measurement_phase_regression
            { previous_phase = EO.Measurement_terminal
            ; incoming_phase = EO.Measurement_fence_committed
            }) -> true
     | _ -> false);
  let rewrite_field encoded name replacement =
    match Yojson.Safe.from_string encoded with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (field, value) ->
              if String.equal field name then field, replacement else field, value)
           fields)
      |> Yojson.Safe.to_string
    | _ -> fail "encoded measurement receipt was not an object"
  in
  let remove_field encoded name =
    match Yojson.Safe.from_string encoded with
    | `Assoc fields ->
      `Assoc (List.filter (fun (field, _) -> not (String.equal field name)) fields)
      |> Yojson.Safe.to_string
    | _ -> fail "encoded measurement receipt was not an object"
  in
  let add_field encoded name value =
    match Yojson.Safe.from_string encoded with
    | `Assoc fields -> `Assoc (fields @ [ name, value ]) |> Yojson.Safe.to_string
    | _ -> fail "encoded measurement receipt was not an object"
  in
  (match EO.measurement_receipt_snapshot_of_string "{" with
   | Error (EO.Measurement_receipt_snapshot_malformed_json _) -> ()
   | Ok _ | Error _ -> fail "malformed receipt did not fail typed decode");
  (match
     remove_field intent_encoded "catalog_evidence_sha256"
     |> EO.measurement_receipt_snapshot_of_string
   with
   | Error EO.Measurement_receipt_snapshot_invalid_fields -> ()
   | Ok _ | Error _ -> fail "missing receipt field did not fail exact schema");
  (match
     add_field intent_encoded "unexpected" (`Bool true)
     |> EO.measurement_receipt_snapshot_of_string
   with
   | Error EO.Measurement_receipt_snapshot_invalid_fields -> ()
   | Ok _ | Error _ -> fail "extra receipt field did not fail exact schema");
  let tampered = rewrite_field terminal_encoded "outcome" (`String "cancelled") in
  (match EO.measurement_receipt_snapshot_of_string tampered with
   | Error EO.Measurement_receipt_snapshot_integrity_mismatch -> ()
   | Ok _ | Error _ -> fail "tampered receipt did not fail integrity");
  let future = rewrite_field terminal_encoded "version" (`Int 2) in
  (match EO.measurement_receipt_snapshot_of_string future with
   | Error (EO.Measurement_receipt_snapshot_unsupported_version 2) -> ()
   | Ok _ | Error _ -> fail "future receipt version did not fail closed");
  check
    bool
    "terminal evidence cannot initialize a dispatch journal"
    true
    (match
       EO.classify_measurement_receipt_transition
         ~previous:None
         ~incoming:decoded_terminal
     with
     | EO.Measurement_transition_conflict
         (EO.Measurement_invalid_commit_phase EO.Measurement_terminal) -> true
     | _ -> false);
  let rewrite_with_integrity encoded name replacement =
    match Yojson.Safe.from_string encoded with
    | `Assoc fields ->
      let payload =
        fields
        |> List.filter (fun (field, _) -> not (String.equal field "integrity_sha256"))
        |> List.map (fun (field, value) ->
          if String.equal field name then field, replacement else field, value)
      in
      let integrity_sha256 =
        `Assoc payload
        |> Yojson.Safe.to_string
        |> Digestif.SHA256.digest_string
        |> Digestif.SHA256.to_hex
      in
      `Assoc (payload @ [ "integrity_sha256", `String integrity_sha256 ])
      |> Yojson.Safe.to_string
    | _ -> fail "encoded measurement receipt was not an object"
  in
  let inconsistent =
    rewrite_with_integrity terminal_encoded "phase" (`String "fence_committed")
  in
  (match EO.measurement_receipt_snapshot_of_string inconsistent with
   | Error (EO.Measurement_receipt_snapshot_invalid_field "receipt_state") -> ()
   | Ok _ | Error _ -> fail "internally inconsistent receipt did not fail closed");
  let other_operation =
    rewrite_with_integrity intent_encoded "operation_id" (`String "other-operation")
    |> decode "other operation"
  in
  check
    bool
    "operation mismatch is typed"
    true
    (match
       EO.classify_measurement_receipt_transition
         ~previous:(Some intent)
         ~incoming:other_operation
     with
     | EO.Measurement_transition_conflict EO.Measurement_operation_mismatch -> true
     | _ -> false);
  let other_binding =
    rewrite_with_integrity
      intent_encoded
      "candidate_binding_sha256"
      (`String (String.make 64 'a'))
    |> decode "other binding"
  in
  check
    bool
    "operation binding mismatch is typed"
    true
    (match
       EO.classify_measurement_receipt_transition
         ~previous:(Some intent)
         ~incoming:other_binding
     with
     | EO.Measurement_transition_conflict EO.Measurement_operation_binding_mismatch ->
       true
     | _ -> false);
  let check_catalog_binding_conflict label field replacement =
    let incoming =
      rewrite_with_integrity intent_encoded field (`String replacement) |> decode label
    in
    check
      bool
      label
      true
      (match
         EO.classify_measurement_receipt_transition ~previous:(Some intent) ~incoming
       with
       | EO.Measurement_transition_conflict EO.Measurement_operation_binding_mismatch ->
         true
       | _ -> false)
  in
  check_catalog_binding_conflict
    "catalog generation mismatch is binding conflict"
    "catalog_generation_fingerprint"
    (String.make 64 'b');
  check_catalog_binding_conflict
    "catalog evidence mismatch is binding conflict"
    "catalog_evidence_sha256"
    (String.make 64 'c');
  let wire_started =
    intent_encoded
    |> fun encoded ->
    rewrite_with_integrity encoded "phase" (`String "wire_started")
    |> fun encoded ->
    rewrite_with_integrity encoded "dispatch" (`String "dispatch_started")
    |> decode "wire started"
  in
  let no_dispatch_intent =
    rewrite_with_integrity intent_encoded "dispatch" (`String "no_dispatch")
    |> decode "no-dispatch fence"
  in
  let check_invalid_previous label previous expected_phase expected_dispatch =
    check
      bool
      label
      true
      (match
         EO.classify_measurement_receipt_transition
           ~previous:(Some previous)
           ~incoming:terminal
       with
       | EO.Measurement_transition_conflict
           (EO.Measurement_invalid_previous_boundary { phase; dispatch; outcome = None })
         -> phase = expected_phase && dispatch = expected_dispatch
       | _ -> false)
  in
  check_invalid_previous
    "wire-started previous boundary fails closed"
    wire_started
    EO.Measurement_wire_started
    EO.Measurement_dispatch_started;
  check_invalid_previous
    "no-dispatch fence previous boundary fails closed"
    no_dispatch_intent
    EO.Measurement_fence_committed
    EO.No_measurement_dispatch;
  check
    bool
    "wire-started incoming snapshot is not a durable commit"
    true
    (match
       EO.classify_measurement_receipt_transition
         ~previous:(Some intent)
         ~incoming:wire_started
     with
     | EO.Measurement_transition_conflict
         (EO.Measurement_invalid_commit_phase EO.Measurement_wire_started) -> true
     | _ -> false);
  let conflicting_terminal =
    rewrite_with_integrity terminal_encoded "outcome" (`String "cancelled")
    |> decode "conflicting terminal"
  in
  check
    bool
    "terminal evidence conflict fails closed"
    true
    (match
       EO.classify_measurement_receipt_transition
         ~previous:(Some terminal)
         ~incoming:conflicting_terminal
     with
     | EO.Measurement_transition_conflict EO.Measurement_evidence_conflict -> true
     | _ -> false);
  let conflicting_intent =
    rewrite_with_integrity intent_encoded "dispatch" (`String "no_dispatch")
    |> decode "conflicting intent"
  in
  match
    EO.classify_measurement_receipt_transition
      ~previous:(Some intent)
      ~incoming:conflicting_intent
  with
  | EO.Measurement_transition_conflict EO.Measurement_evidence_conflict -> ()
  | _ -> fail "same-phase conflicting evidence was not typed"
;;

let test_measurement_fence_rejection_is_terminal_without_wire () =
  let response =
    {|{"id":"msg-flow","type":"message","role":"assistant","model":"flow","content":[{"type":"text","text":"{\"name\":\"unused\"}"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}|}
  in
  let (result, replay, evidence, intent_callbacks, terminal_callbacks, advances), posts =
    with_counted_server ~measurement_reply:(Measurement_tokens 1) ~response
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~serving_constraint:true
          ~id:"measurement-fence-rejected"
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry
          ~id:"measurement-fence-withheld"
          ~base_url
          ~native:true
          ~json:true
          ()
      ]
    @@ fun snapshot ->
    let flow =
      start_flow
        (frozen_flow
           snapshot
           [ "measurement-fence-rejected"; "measurement-fence-withheld" ])
    in
    let intent_callbacks = ref 0 in
    let terminal_callbacks = ref 0 in
    let advances = ref 0 in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun measurement ->
          incr terminal_callbacks;
          let snapshot = EO.flow_measurement_receipt_snapshot measurement in
          check
            bool
            "terminal callback observes terminal receipt"
            true
            (snapshot.phase = EO.Measurement_terminal);
          Ok ())
        ~before_measurement_dispatch:(fun measurement ->
          incr intent_callbacks;
          let live = EO.flow_attempt_evidence flow in
          check
            int
            "measurement receipt is registered before fence"
            1
            (List.length live.measurements);
          let snapshot = EO.flow_measurement_receipt_snapshot measurement in
          check
            bool
            "callback observes committed intent"
            true
            (snapshot.phase = EO.Measurement_fence_committed);
          check
            bool
            "callback never receives a no-dispatch claim"
            true
            (snapshot.dispatch = EO.Measurement_dispatch_unknown);
          Error "measurement-fence-not-durable")
        ~before_dispatch:(fun _ -> fail "fence rejection reached generation dispatch")
        ~before_advance:(fun ~failed:_ ~next:_ ->
          incr advances;
          Ok ())
        flow
    in
    ( result
    , execute_ok ~net flow
    , EO.flow_attempt_evidence flow
    , !intent_callbacks
    , !terminal_callbacks
    , !advances )
  in
  check int "fence rejection starts no measurement POST" 0 posts.measurement_posts;
  check int "fence rejection starts no generation POST" 0 posts.generation_posts;
  check
    int
    "fence rejection creates no generation attempt"
    0
    (List.length evidence.attempts);
  check int "intent callback runs once" 1 intent_callbacks;
  check int "terminal callback runs once" 1 terminal_callbacks;
  check int "fence callback failure cannot advance" 0 advances;
  let measurement =
    match evidence.measurements with
    | [ measurement ] -> measurement
    | _ -> fail "fence rejection lost its sole measurement receipt"
  in
  let snapshot = measurement in
  check
    bool
    "fence rejection terminalizes receipt"
    true
    (snapshot.phase = EO.Measurement_terminal);
  check
    bool
    "fence rejection records definitive zero dispatch"
    true
    (snapshot.dispatch = EO.No_measurement_dispatch);
  check
    (option bool)
    "fence rejection preserves typed outcome"
    (Some true)
    (Option.map (fun outcome -> outcome = EO.Measurement_fence_rejected) snapshot.outcome);
  check
    bool
    "measurement operation identity is nonempty"
    true
    (not (String.equal "" (EO.measurement_operation_id_to_string snapshot.operation_id)));
  (match replay with
   | Error (EO.Flow_attempt_already_started _) -> ()
   | Ok _ | Error _ -> fail "fence-rejected flow replayed");
  match result with
  | Error
      (EO.Flow_before_measurement_dispatch_callback_failed
         { measurement = failed; cause = "measurement-fence-not-durable"; _ } as error) ->
    check
      string
      "terminal error retains the same operation"
      (EO.measurement_operation_id_to_string snapshot.operation_id)
      (EO.measurement_operation_id_to_string
         (EO.flow_measurement_receipt_snapshot failed).operation_id);
    check
      bool
      "fence rejection starts no generation dispatch"
      true
      (EO.flow_execution_error_generation_dispatch error = EO.No_generation_dispatch)
  | Ok _ | Error _ -> fail "fence rejection lost its typed terminal error"
;;

let test_measurement_fence_nested_http_does_not_mark_outer_dispatch () =
  let response =
    {|{"id":"msg-flow","type":"message","role":"assistant","model":"flow","content":[{"type":"text","text":"{\"name\":\"accepted\"}"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}|}
  in
  let (result, evidence), posts =
    with_counted_server ~measurement_reply:(Measurement_tokens 1) ~response
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~serving_constraint:true
          ~id:"measurement-nested-journal"
          ~base_url
          ~native:true
          ~json:true
          ()
      ]
    @@ fun snapshot ->
    let flow = start_flow (frozen_flow snapshot [ "measurement-nested-journal" ]) in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~before_measurement_dispatch:(fun measurement ->
          let before = EO.flow_measurement_receipt_snapshot measurement in
          check
            bool
            "durable callback starts from committed ambiguity"
            true
            (before.phase = EO.Measurement_fence_committed
             && before.dispatch = EO.Measurement_dispatch_unknown);
          (match
             Http_client.post_sync_once
               ~net
               ~url:(base_url ^ "/journal")
               ~headers:[ "content-type", "application/json" ]
               ~body:{|{"operation":"measurement-intent"}|}
               ()
           with
           | Error _ -> fail "nested journal HTTP failed"
           | Ok _ -> ());
          let during =
            match (EO.flow_attempt_evidence flow).measurements with
            | [ receipt ] -> receipt
            | _ -> fail "nested journal lost the outer measurement receipt"
          in
          check
            bool
            "nested journal HTTP cannot mark outer measurement dispatch"
            true
            (during.phase = EO.Measurement_fence_committed
             && during.dispatch = EO.Measurement_dispatch_unknown);
          Ok ())
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_dispatch:(fun _ -> Ok ())
        ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
        flow
    in
    result, EO.flow_attempt_evidence flow
  in
  check int "nested journal dispatches once" 1 posts.journal_posts;
  check int "outer measurement dispatches once" 1 posts.measurement_posts;
  check int "generation dispatches once" 1 posts.generation_posts;
  (match result with
   | Ok _ -> ()
   | Error _ -> fail "nested journal fixture did not complete");
  match evidence.measurements with
  | [ receipt ] ->
    check
      bool
      "outer measurement terminal records its own dispatch"
      true
      (receipt.phase = EO.Measurement_terminal
       && receipt.dispatch = EO.Measurement_dispatch_started
       && receipt.outcome = Some EO.Measurement_succeeded)
  | _ -> fail "nested journal fixture lost terminal measurement evidence"
;;

let test_measurement_terminal_callback_failure_blocks_generation () =
  let response =
    {|{"id":"msg-flow","type":"message","role":"assistant","model":"flow","content":[{"type":"text","text":"{\"name\":\"unused\"}"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}|}
  in
  let (result, replay, evidence, terminal_callbacks, advances), posts =
    with_counted_server ~measurement_reply:(Measurement_tokens 1) ~response
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~serving_constraint:true
          ~id:"measurement-terminal-rejected"
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry
          ~id:"measurement-terminal-withheld"
          ~base_url
          ~native:true
          ~json:true
          ()
      ]
    @@ fun snapshot ->
    let flow =
      start_flow
        (frozen_flow
           snapshot
           [ "measurement-terminal-rejected"; "measurement-terminal-withheld" ])
    in
    let terminal_callbacks = ref 0 in
    let advances = ref 0 in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~before_measurement_dispatch:(fun measurement ->
          let snapshot = EO.flow_measurement_receipt_snapshot measurement in
          check
            bool
            "intent callback receives committed ambiguity"
            true
            (snapshot.dispatch = EO.Measurement_dispatch_unknown);
          Ok ())
        ~on_measurement_terminal:(fun measurement ->
          incr terminal_callbacks;
          let snapshot = EO.flow_measurement_receipt_snapshot measurement in
          check
            bool
            "terminal callback receives successful terminal outcome"
            true
            (snapshot.phase = EO.Measurement_terminal
             && snapshot.dispatch = EO.Measurement_dispatch_started
             && snapshot.outcome = Some EO.Measurement_succeeded);
          Error "measurement-terminal-not-durable")
        ~before_dispatch:(fun _ ->
          fail "terminal measurement callback failure allocated generation")
        ~before_advance:(fun ~failed:_ ~next:_ ->
          incr advances;
          Ok ())
        flow
    in
    ( result
    , execute_ok ~net flow
    , EO.flow_attempt_evidence flow
    , !terminal_callbacks
    , !advances )
  in
  check int "terminal callback failure still measures once" 1 posts.measurement_posts;
  check int "terminal callback failure generates nothing" 0 posts.generation_posts;
  check int "terminal callback runs once" 1 terminal_callbacks;
  check int "terminal callback failure cannot advance" 0 advances;
  check
    int
    "terminal callback failure creates no generation attempt"
    0
    (List.length evidence.attempts);
  (match replay with
   | Error (EO.Flow_attempt_already_started _) -> ()
   | Ok _ | Error _ -> fail "terminal callback failure left flow replayable");
  match result with
  | Error
      (EO.Flow_measurement_terminal_callback_failed
         { measurement; cause = "measurement-terminal-not-durable"; _ } as error) ->
    let snapshot = EO.flow_measurement_receipt_snapshot measurement in
    check
      bool
      "terminal callback error is generation-zero"
      true
      (EO.flow_execution_error_generation_dispatch error = EO.No_generation_dispatch);
    check
      bool
      "terminal callback error retains terminal receipt"
      true
      (snapshot.phase = EO.Measurement_terminal)
  | Ok _ | Error _ -> fail "terminal callback failure lost its typed terminal error"
;;

let test_measurement_predispatch_failure_records_zero_dispatch () =
  let result, replay, evidence, intent_callbacks, terminal_callbacks =
    Eio_main.run
    @@ fun env ->
    let net = Eio.Stdenv.net env in
    let dead_url = Printf.sprintf "http://127.0.0.1:%d" (fresh_port ()) in
    with_catalog
      [ catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~serving_constraint:true
          ~id:"measurement-predispatch-failure"
          ~base_url:dead_url
          ~native:true
          ~json:true
          ()
      ]
    @@ fun snapshot ->
    let flow = start_flow (frozen_flow snapshot [ "measurement-predispatch-failure" ]) in
    let intent_callbacks = ref 0 in
    let terminal_callbacks = ref 0 in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~before_measurement_dispatch:(fun measurement ->
          incr intent_callbacks;
          let snapshot = EO.flow_measurement_receipt_snapshot measurement in
          check
            bool
            "predispatch intent is committed"
            true
            (snapshot.phase = EO.Measurement_fence_committed);
          check
            bool
            "predispatch intent is ambiguous"
            true
            (snapshot.dispatch = EO.Measurement_dispatch_unknown);
          Ok ())
        ~on_measurement_terminal:(fun measurement ->
          incr terminal_callbacks;
          let snapshot = EO.flow_measurement_receipt_snapshot measurement in
          check
            bool
            "predispatch failure terminalizes definitive zero dispatch"
            true
            (snapshot.phase = EO.Measurement_terminal
             && snapshot.dispatch = EO.No_measurement_dispatch);
          Ok ())
        ~before_dispatch:(fun _ ->
          fail "predispatch measurement failure allocated generation")
        ~before_advance:(fun ~failed:_ ~next:_ ->
          fail "final predispatch measurement failure requested successor advance")
        flow
    in
    ( result
    , execute_ok ~net flow
    , EO.flow_attempt_evidence flow
    , !intent_callbacks
    , !terminal_callbacks )
  in
  check int "predispatch intent callback runs once" 1 intent_callbacks;
  check int "predispatch terminal callback runs once" 1 terminal_callbacks;
  check
    int
    "predispatch failure creates no generation attempt"
    0
    (List.length evidence.attempts);
  let snapshot =
    match evidence.measurements with
    | [ measurement ] -> measurement
    | _ -> fail "predispatch failure lost its sole measurement receipt"
  in
  check
    bool
    "predispatch failure records definitive zero dispatch"
    true
    (snapshot.dispatch = EO.No_measurement_dispatch);
  check
    bool
    "predispatch failure retains transport outcome"
    true
    (snapshot.outcome = Some EO.Measurement_transport_failed);
  (match replay with
   | Error (EO.Flow_attempt_already_started _) -> ()
   | Ok _ | Error _ -> fail "predispatch measurement failure replayed");
  match result with
  | Error (EO.Flow_candidates_exhausted _) -> ()
  | Ok _ | Error _ -> fail "predispatch measurement failure lost typed exhaustion"
;;

let test_measurement_cancellation_terminalizes_receipt () =
  let response =
    {|{"id":"msg-flow","type":"message","role":"assistant","model":"flow","content":[{"type":"text","text":"{\"name\":\"unused\"}"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}|}
  in
  let run
        ~label
        ?measurement_delay_s
        ?(after_measurement_terminal = fun _ -> Ok ())
        before_measurement_dispatch
    =
    with_counted_server
      ?measurement_delay_s
      ~measurement_reply:(Measurement_tokens 1)
      ~response
    @@ fun ~sw:_ ~net ~clock ~base_url ->
    with_catalog
      [ catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~serving_constraint:true
          ~id:label
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~id:(label ^ "-successor")
          ~base_url
          ~native:true
          ~json:true
          ()
      ]
    @@ fun snapshot ->
    let successor = label ^ "-successor" in
    let flow = start_flow (frozen_flow snapshot [ label; successor ]) in
    let terminal_callbacks = ref 0 in
    let advances = ref 0 in
    let timed_out =
      try
        ignore
          (Eio.Time.with_timeout_exn clock 0.01 (fun () ->
             execute_with_accepting_test_validator
               ~net
               ~on_measurement_terminal:(fun measurement ->
                 incr terminal_callbacks;
                 let snapshot = EO.flow_measurement_receipt_snapshot measurement in
                 check
                   bool
                   "cancellation callback observes terminal receipt"
                   true
                   (snapshot.phase = EO.Measurement_terminal
                    && snapshot.outcome = Some EO.Measurement_cancelled);
                 after_measurement_terminal measurement)
               ~before_measurement_dispatch:(before_measurement_dispatch ~clock)
               ~before_dispatch:(fun _ ->
                 fail "measurement cancellation reached generation dispatch")
               ~before_advance:(fun ~failed:_ ~next:_ ->
                 incr advances;
                 Ok ())
               flow)
           : (EO.flow_success, _ EO.flow_execution_error) result);
        false
      with
      | Eio.Time.Timeout -> true
    in
    let replay = execute_ok ~net flow in
    timed_out, replay, EO.flow_attempt_evidence flow, !terminal_callbacks, !advances
  in
  let ( ( before_timed_out
        , before_replay
        , before_evidence
        , before_terminal_callbacks
        , before_advances )
      , before_posts )
    =
    run ~label:"measurement-cancel-before-fence" (fun ~clock _ ->
      Eio.Time.sleep clock 0.1;
      Ok ())
  in
  check bool "cancellation inside fence callback escapes" true before_timed_out;
  check int "pre-fence terminal callback runs once" 1 before_terminal_callbacks;
  check int "pre-fence cancellation does not advance" 0 before_advances;
  check
    int
    "pre-fence cancellation starts no measurement POST"
    0
    before_posts.measurement_posts;
  check
    int
    "pre-fence cancellation starts no generation POST"
    0
    before_posts.generation_posts;
  let before_snapshot =
    match before_evidence.measurements with
    | [ measurement ] -> measurement
    | _ -> fail "pre-fence cancellation lost its measurement receipt"
  in
  check
    bool
    "intent-callback cancellation terminalizes"
    true
    (before_snapshot.phase = EO.Measurement_terminal);
  check
    bool
    "intent-callback cancellation remains ambiguous"
    true
    (before_snapshot.dispatch = EO.Measurement_dispatch_unknown);
  check
    (option bool)
    "pre-fence cancellation records terminal outcome"
    (Some true)
    (Option.map
       (fun outcome -> outcome = EO.Measurement_cancelled)
       before_snapshot.outcome);
  (match before_replay with
   | Error (EO.Flow_attempt_already_started _) -> ()
   | Ok _ | Error _ -> fail "pre-fence cancelled flow replayed");
  let ( ( callback_error_timed_out
        , _
        , callback_error_evidence
        , callback_error_terminal_callbacks
        , _ )
      , callback_error_posts )
    =
    run
      ~label:"measurement-cancel-callback-error"
      ~after_measurement_terminal:(fun _ -> failwith "terminal callback ordinary failure")
      (fun ~clock _ ->
         Eio.Time.sleep clock 0.1;
         Ok ())
  in
  check
    bool
    "terminal callback exception cannot replace cancellation"
    true
    callback_error_timed_out;
  check
    int
    "failing terminal callback is attempted once"
    1
    callback_error_terminal_callbacks;
  check
    int
    "callback-error cancellation starts no measurement POST"
    0
    callback_error_posts.measurement_posts;
  (match callback_error_evidence.measurements with
   | [ { phase = EO.Measurement_terminal; outcome = Some EO.Measurement_cancelled; _ } ]
     -> ()
   | _ -> fail "callback-error cancellation lost terminal receipt evidence");
  let ( ( after_timed_out
        , after_replay
        , after_evidence
        , after_terminal_callbacks
        , after_advances )
      , after_posts )
    =
    run
      ~label:"measurement-cancel-after-fence"
      ~measurement_delay_s:0.1
      (fun ~clock:_ _ -> Ok ())
  in
  check bool "cancellation after fence escapes" true after_timed_out;
  check int "post-fence terminal callback runs once" 1 after_terminal_callbacks;
  check int "post-dispatch cancellation forbids successor" 0 after_advances;
  check
    int
    "post-fence cancellation reaches one measurement POST"
    1
    after_posts.measurement_posts;
  check
    int
    "post-fence cancellation starts no generation POST"
    0
    after_posts.generation_posts;
  check
    int
    "measurement cancellation creates no generation attempt"
    0
    (List.length after_evidence.attempts);
  let after_snapshot =
    match after_evidence.measurements with
    | [ measurement ] -> measurement
    | _ -> fail "post-fence cancellation lost its measurement receipt"
  in
  check
    bool
    "post-fence cancellation terminalizes"
    true
    (after_snapshot.phase = EO.Measurement_terminal);
  check
    bool
    "post-fence cancellation never claims zero dispatch"
    true
    (after_snapshot.dispatch = EO.Measurement_dispatch_started);
  check
    (option bool)
    "post-fence cancellation records terminal outcome"
    (Some true)
    (Option.map
       (fun outcome -> outcome = EO.Measurement_cancelled)
       after_snapshot.outcome);
  match after_replay with
  | Error (EO.Flow_attempt_already_started _) -> ()
  | Ok _ | Error _ -> fail "post-fence cancelled flow replayed"
;;

let test_predispatch_measurement_failure_advances_without_wire () =
  let response =
    {|{"id":"msg-flow","type":"message","role":"assistant","model":"flow","content":[{"type":"text","text":"{\"name\":\"accepted\"}"}],"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1}}|}
  in
  let (result, advances, evidence), posts =
    with_counted_server ~measurement_reply:(Measurement_tokens 1) ~response
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    let dead_url = Printf.sprintf "http://127.0.0.1:%d" (fresh_port ()) in
    with_catalog
      [ catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~serving_constraint:true
          ~id:"predispatch-measurement-failure"
          ~base_url:dead_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~id:"predispatch-measurement-successor"
          ~base_url
          ~native:true
          ~json:true
          ()
      ]
    @@ fun snapshot ->
    let flow =
      start_flow
        (frozen_flow
           snapshot
           [ "predispatch-measurement-failure"; "predispatch-measurement-successor" ])
    in
    let advances = ref 0 in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun candidate ->
          check
            string
            "only the zero-dispatch successor reaches generation"
            "predispatch-measurement-successor"
            (candidate_id candidate);
          Ok ())
        ~before_advance:(fun ~failed ~next:_ ->
          incr advances;
          match failed with
          | EO.Flow_candidate_rejected rejection ->
            check
              bool
              "predispatch rejection records zero measurement dispatch"
              true
              (EO.candidate_rejection_measurement_dispatch_fact rejection
               = EO.No_measurement_dispatch);
            check
              bool
              "predispatch rejection preserves typed transport outcome"
              true
              (EO.candidate_rejection_measurement_outcome rejection
               = EO.Measurement_transport_failed);
            Ok ()
          | EO.Flow_candidate_execution_failed _ ->
            fail "predispatch measurement rejection became a generation failure")
        flow
    in
    result, !advances, EO.flow_attempt_evidence flow
  in
  check int "predispatch failure performs no measurement POST" 0 posts.measurement_posts;
  check int "predispatch failure advances once" 1 advances;
  check int "only successor generates" 1 posts.generation_posts;
  check int "only successor owns an attempt" 1 (List.length evidence.attempts);
  match result with
  | Ok success ->
    check
      string
      "predispatch failure reaches successor"
      "predispatch-measurement-successor"
      (candidate_id (EO.flow_success_candidate success))
  | Error _ -> fail "predispatch zero-dispatch failure did not advance"
;;

let test_postdispatch_measurement_failures_do_not_advance () =
  let response =
    {|{"id":"msg-flow","type":"message","role":"assistant","model":"flow","content":[{"type":"text","text":"{\"name\":\"accepted\"}"}],"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1}}|}
  in
  let cases =
    [ ( "measurement transport failure"
      , Measurement_transport_failure
      , EO.Measurement_transport_failed )
    ; ( "measurement invalid response"
      , Measurement_invalid_response
      , EO.Measurement_invalid_response )
    ]
  in
  List.iter
    (fun (label, measurement_reply, expected_outcome) ->
       let (result, replay, evidence, advances, terminal_callbacks), posts =
         with_counted_server ~measurement_reply ~response
         @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
         with_catalog
           [ catalog_entry
               ~kind:"anthropic"
               ~request_path:"/v1/messages"
               ~serving_constraint:true
               ~id:"measured-failure"
               ~base_url
               ~native:true
               ~json:true
               ()
           ; catalog_entry
               ~kind:"anthropic"
               ~request_path:"/v1/messages"
               ~id:"measured-successor"
               ~base_url
               ~native:true
               ~json:true
               ()
           ]
         @@ fun snapshot ->
         let flow =
           start_flow (frozen_flow snapshot [ "measured-failure"; "measured-successor" ])
         in
         let advances = ref 0 in
         let terminal_callbacks = ref 0 in
         let result =
           execute_with_accepting_test_validator
             ~net
             ~on_measurement_terminal:(fun measurement ->
               incr terminal_callbacks;
               let snapshot = EO.flow_measurement_receipt_snapshot measurement in
               check
                 bool
                 (label ^ " terminal callback observes settled receipt")
                 true
                 (snapshot.phase = EO.Measurement_terminal
                  && snapshot.outcome = Some expected_outcome);
               Ok ())
             ~before_measurement_dispatch:(fun _ -> Ok ())
             ~before_dispatch:(fun candidate ->
               failf "%s reached generation for %s" label (candidate_id candidate))
             ~before_advance:(fun ~failed:_ ~next:_ ->
               incr advances;
               Ok ())
             flow
         in
         let replay = execute_ok ~net flow in
         result, replay, EO.flow_attempt_evidence flow, !advances, !terminal_callbacks
       in
       check int (label ^ " measurement posts") 1 posts.measurement_posts;
       check int (label ^ " successor advances") 0 advances;
       check int (label ^ " generation posts") 0 posts.generation_posts;
       check int (label ^ " terminal callback count") 1 terminal_callbacks;
       check
         int
         (label ^ " creates no generation attempt")
         0
         (List.length evidence.attempts);
       (match result with
        | Error (EO.Flow_candidates_exhausted { rejection; _ }) ->
          check
            bool
            (label ^ " records measurement wire")
            true
            (EO.candidate_rejection_measurement_dispatch_fact rejection
             = EO.Measurement_dispatch_started);
          check
            bool
            (label ^ " preserves typed outcome")
            true
            (EO.candidate_rejection_measurement_outcome rejection = expected_outcome)
        | Ok _ | Error _ -> fail (label ^ " did not stop at dispatched measurement"));
       match replay with
       | Error (EO.Flow_attempt_already_started _) -> ()
       | Ok _ | Error _ -> fail (label ^ " replayed after terminal measurement failure"))
    cases
;;

let test_exact_anthropic_frozen_artifact_parity () =
  let response =
    {|{"id":"msg-flow","type":"message","role":"assistant","model":"thinking-parity-model","content":[{"type":"text","text":"{\"name\":\"accepted\"}"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}|}
  in
  let successes, posts =
    with_counted_server ~measurement_reply:(Measurement_tokens 1) ~response
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~model_id:"thinking-parity-model"
          ~anthropic_thinking_control:"adaptive_preferred"
          ~enable_thinking:true
          ~id:"thinking-unmeasured"
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~model_id:"thinking-parity-model"
          ~anthropic_thinking_control:"adaptive_preferred"
          ~enable_thinking:true
          ~serving_constraint:true
          ~serving_accepted_through_tokens:10
          ~serving_rejected_from_tokens:11
          ~id:"thinking-measured"
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~model_id:"thinking-default-implicit-model"
          ~anthropic_thinking_control:"adaptive_default"
          ~id:"thinking-default-implicit"
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~model_id:"thinking-default-disabled-model"
          ~anthropic_thinking_control:"adaptive_default"
          ~enable_thinking:false
          ~id:"thinking-default-disabled"
          ~base_url
          ~native:true
          ~json:true
          ()
      ]
    @@ fun snapshot ->
    let execute id =
      let flow = start_flow (frozen_flow snapshot [ id ]) in
      match execute_ok ~net flow with
      | Error _ -> failf "%s did not execute" id
      | Ok success -> EO.flow_success_output success
    in
    let unmeasured = execute "thinking-unmeasured" in
    let measured = execute "thinking-measured" in
    let implicit = execute "thinking-default-implicit" in
    let disabled = execute "thinking-default-disabled" in
    [ unmeasured; measured; implicit; disabled ]
  in
  check int "exact artifact measures only constrained request" 1 posts.measurement_posts;
  check int "exact artifact generates all four requests" 4 posts.generation_posts;
  List.iter
    (fun (success : EO.success) ->
       match
         EO.receipt_phase success.receipt, EO.receipt_provider_trace success.receipt
       with
       | EO.Terminal, Some _ -> ()
       | _ -> fail "terminal generation receipt lost its late provider trace")
    successes;
  let unmeasured_body, measured_body, implicit_body, disabled_body =
    match posts.generation_bodies with
    | [ unmeasured; measured; implicit; disabled ] ->
      unmeasured, measured, implicit, disabled
    | _ -> fail "frozen artifact fixture lost generation request bodies"
  in
  let measurement_body =
    match posts.measurement_bodies with
    | [ body ] -> body
    | _ -> fail "frozen artifact fixture lost measurement request body"
  in
  let measured_success : EO.success =
    match successes with
    | [ _; measured; _; _ ] -> measured
    | _ -> fail "frozen artifact fixture lost measured success"
  in
  check
    string
    "measured generation receipt binds the actual wire bytes"
    Digestif.SHA256.(to_hex (digest_string measured_body))
    (EO.receipt_request_body_sha256 measured_success.receipt);
  let unmeasured_json = Yojson.Safe.from_string unmeasured_body in
  let measured_json = Yojson.Safe.from_string measured_body in
  let implicit_json = Yojson.Safe.from_string implicit_body in
  let disabled_json = Yojson.Safe.from_string disabled_body in
  let measurement_json = Yojson.Safe.from_string measurement_body in
  let thinking json = Yojson.Safe.Util.member "thinking" json in
  check
    bool
    "catalog thinking control reaches actual generation bytes"
    true
    (thinking measured_json = `Assoc [ "type", `String "adaptive" ]);
  check
    bool
    "measured and unmeasured generation use the same frozen thinking control"
    true
    (thinking unmeasured_json = thinking measured_json);
  check
    bool
    "count request derives thinking from the frozen generation artifact"
    true
    (thinking measurement_json = thinking measured_json);
  check
    bool
    "unset target thinking policy emits no thinking control"
    true
    (thinking implicit_json = `Null);
  check
    bool
    "explicit false target thinking policy emits disabled control"
    true
    (thinking disabled_json = `Assoc [ "type", `String "disabled" ]);
  check
    int
    "frozen output-token receipt reaches actual generation bytes"
    1024
    Yojson.Safe.Util.(measured_json |> member "max_tokens" |> to_int);
  let count_projection =
    match measured_json with
    | `Assoc fields ->
      `Assoc
        (List.filter
           (fun (name, _) ->
              not
                (List.mem
                   name
                   [ "max_tokens"; "stream"; "temperature"; "top_p"; "top_k" ]))
           fields)
    | _ -> fail "Anthropic generation request must be a JSON object"
  in
  check
    bool
    "count body is the exact frozen generation projection"
    true
    (measurement_json = count_projection);
  check
    string
    "count body bytes are the exact frozen generation projection bytes"
    (Yojson.Safe.to_string count_projection)
    measurement_body
;;

let test_all_candidate_rejections_return_typed_zero_dispatch_terminal () =
  let (result, transitions, evidence), posts =
    with_server ~response:(openai_response {|{"name":"unused"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry
          ~serving_constraint:true
          ~id:"rejected-a"
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry
          ~max_request_body_bytes:1
          ~id:"rejected-b"
          ~base_url
          ~native:true
          ~json:true
          ()
      ]
    @@ fun snapshot ->
    let transitions = ref [] in
    let flow = start_flow (frozen_flow snapshot [ "rejected-a"; "rejected-b" ]) in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun candidate ->
          failf "rejected candidate %s reached before_dispatch" (candidate_id candidate))
        ~before_advance:(fun ~failed ~next ->
          transitions
          := (flow_failure_id failed, next.identity.candidate_id) :: !transitions;
          Ok ())
        flow
    in
    result, List.rev !transitions, EO.flow_attempt_evidence flow
  in
  check int "all-rejected flow performs zero completion POSTs" 0 posts;
  check
    (list (pair string string))
    "all-rejected flow settles the ordered transition"
    [ "rejected-a", "rejected-b" ]
    transitions;
  check int "all-rejected flow fabricates no attempts" 0 (List.length evidence.attempts);
  check int "all rejection evidence remains ordered" 2 (List.length evidence.admissions);
  (match evidence.admissions with
   | [ EO.Candidate_rejected first; EO.Candidate_rejected second ] ->
     check
       string
       "first retained rejection"
       "rejected-a"
       (EO.candidate_rejection_identity first).candidate_id;
     check
       int
       "first retained candidate count"
       1
       (EO.flow_visit_ordinal_to_int (EO.candidate_rejection_visit first).ordinal);
     check
       string
       "second retained rejection"
       "rejected-b"
       (EO.candidate_rejection_identity second).candidate_id;
     check
       int
       "second retained candidate count"
       2
       (EO.flow_visit_ordinal_to_int (EO.candidate_rejection_visit second).ordinal);
     List.iter
       (fun rejection ->
          check
            bool
            "retained rejection has no measurement wire"
            true
            (EO.candidate_rejection_measurement_dispatch_fact rejection
             = EO.No_measurement_dispatch))
       [ first; second ]
   | _ -> fail "flow evidence did not retain typed admission receipts");
  match result with
  | Error (EO.Flow_candidates_exhausted { rejection; evidence = terminal_evidence }) ->
    check
      string
      "terminal rejected candidate"
      "rejected-b"
      (EO.candidate_rejection_identity rejection).candidate_id;
    (match EO.candidate_rejection_disposition rejection with
     | EO.Input_capacity
         (EO.Serialized_request_body_too_large { actual_bytes; limit_bytes }) ->
       check bool "terminal body remains over cap" true (actual_bytes > limit_bytes)
     | _ -> fail "terminal admission receipt lost its neutral body-cap disposition");
    check int "terminal retains zero attempts" 0 (List.length terminal_evidence.attempts);
    check
      int
      "terminal candidate count is exact"
      2
      (EO.candidate_visit_count_to_int terminal_evidence.candidate_visit_count)
  | Ok _ | Error _ -> fail "all-rejected flow lost its typed terminal admission failure"
;;

exception Rejection_advance_committed_before_successor

let test_exception_after_durable_rejection_stops_before_successor () =
  let durable_path = Filename.temp_file "oas-rejection-advance-" ".json" in
  Fun.protect
    ~finally:(fun () -> Sys.remove durable_path)
    (fun () ->
       let (raised, replay, evidence, observed), posts =
         with_server ~response:(openai_response {|{"name":"must-not-dispatch"}|})
         @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
         with_catalog
           ~getenv:credential_getenv
           [ catalog_entry
               ~api_key_env:"MISSING_FLOW_KEY"
               ~id:"rejection-committed"
               ~base_url
               ~native:true
               ~json:true
               ()
           ; catalog_entry
               ~id:"rejection-withheld-successor"
               ~base_url
               ~native:true
               ~json:true
               ()
           ]
         @@ fun snapshot ->
         let flow =
           start_flow
             (frozen_flow
                snapshot
                [ "rejection-committed"; "rejection-withheld-successor" ])
         in
         let observed = ref None in
         let raised =
           try
             ignore
               (execute_with_accepting_test_validator
                  ~net
                  ~on_measurement_terminal:(fun _ -> Ok ())
                  ~before_measurement_dispatch:(fun _ -> Ok ())
                  ~before_dispatch:(fun candidate ->
                    failf
                      "zero-dispatch rejection unexpectedly prepared %s"
                      (candidate_id candidate))
                  ~before_advance:(fun ~failed ~next ->
                    match failed with
                    | EO.Flow_candidate_rejected rejection ->
                      let failed_visit = EO.candidate_rejection_visit rejection in
                      let payload =
                        `Assoc
                          [ "flow_id", `String (EO.flow_id_to_string failed_visit.flow_id)
                          ; ( "failed_ordinal"
                            , `Int (EO.flow_visit_ordinal_to_int failed_visit.ordinal) )
                          ; ( "next_ordinal"
                            , `Int (EO.flow_visit_ordinal_to_int next.ordinal) )
                          ; ( "failed_candidate_id"
                            , `String failed_visit.identity.candidate_id )
                          ; "next_candidate_id", `String next.identity.candidate_id
                          ]
                      in
                      Out_channel.with_open_bin durable_path (fun channel ->
                        output_string channel (Yojson.Safe.to_string payload);
                        flush channel;
                        Unix.fsync (Unix.descr_of_out_channel channel));
                      observed := Some (failed_visit, next);
                      raise Rejection_advance_committed_before_successor
                    | EO.Flow_candidate_execution_failed _ ->
                      fail "credential rejection allocated an execution attempt")
                  flow
                : (EO.flow_success, unit EO.flow_execution_error) result);
             false
           with
           | Rejection_advance_committed_before_successor -> true
         in
         raised, execute_ok ~net flow, EO.flow_attempt_evidence flow, !observed
       in
       check bool "exception escaped after durable rejection settlement" true raised;
       check int "rejection and withheld successor dispatch nothing" 0 posts;
       check int "only rejected admission is recorded" 1 (List.length evidence.admissions);
       check int "rejection fabricates no attempt" 0 (List.length evidence.attempts);
       check
         int
         "only rejected candidate is visited"
         1
         (EO.candidate_visit_count_to_int evidence.candidate_visit_count);
       (match replay with
        | Error (EO.Flow_attempt_already_started _) -> ()
        | Ok _ | Error _ -> fail "rejection callback exception left flow replayable");
       (match observed with
        | Some (failed_visit, next) ->
          check
            string
            "rejection and withheld successor share a flow"
            (EO.flow_id_to_string failed_visit.flow_id)
            (EO.flow_id_to_string next.flow_id);
          check
            int
            "rejected visit ordinal"
            1
            (EO.flow_visit_ordinal_to_int failed_visit.ordinal);
          check int "withheld visit ordinal" 2 (EO.flow_visit_ordinal_to_int next.ordinal)
        | None -> fail "durable rejection visit was not observed");
       check
         bool
         "durable visit settlement was written"
         true
         (In_channel.with_open_bin durable_path In_channel.input_all <> ""))
;;

let test_predispatch_transport_failure_advances_after_durable_callback () =
  let (result, bound, advanced, events), posts =
    with_server ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    let dead_url = Printf.sprintf "http://127.0.0.1:%d" (fresh_port ()) in
    with_catalog
      [ catalog_entry ~id:"flow-dead" ~base_url:dead_url ~native:true ~json:true ()
      ; catalog_entry ~id:"flow-live" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    let flow = start_flow (frozen_flow snapshot [ "flow-dead"; "flow-live" ]) in
    let bound = ref [] in
    let advanced = ref [] in
    let events = ref [] in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun candidate ->
          events := ("bind:" ^ candidate_id candidate) :: !events;
          bound := candidate_id candidate :: !bound;
          Ok ())
        ~before_advance:(fun ~failed ~next ->
          let failed_candidate, failure = flow_execution_failure failed in
          check
            bool
            "advance failure is pre-dispatch"
            true
            (EO.receipt_phase failure.EO.receipt = EO.Before_dispatch);
          check
            int
            "advance failure has zero dispatch"
            0
            (EO.receipt_dispatch_count failure.receipt);
          events
          := Printf.sprintf
               "advance:%s->%s"
               (candidate_id failed_candidate)
               next.identity.candidate_id
             :: !events;
          advanced
          := (candidate_id failed_candidate, next.identity.candidate_id) :: !advanced;
          Ok ())
        flow
    in
    result, List.rev !bound, List.rev !advanced, List.rev !events
  in
  check int "only live successor posts" 1 posts;
  check (list string) "bind order" [ "flow-dead"; "flow-live" ] bound;
  check
    (list (pair string string))
    "predetermined successor"
    [ "flow-dead", "flow-live" ]
    advanced;
  check
    (list string)
    "durable advance precedes successor bind"
    [ "bind:flow-dead"; "advance:flow-dead->flow-live"; "bind:flow-live" ]
    events;
  match result with
  | Ok success ->
    check
      string
      "successor succeeds"
      "flow-live"
      (candidate_id (EO.flow_success_candidate success));
    let failed = attempt_for (EO.flow_success_evidence success) "flow-dead" in
    check
      bool
      "failed receipt remains before dispatch"
      true
      (EO.generation_receipt_snapshot_phase failed.receipt = EO.Before_dispatch);
    check
      int
      "failed receipt remains zero dispatch"
      0
      (EO.generation_receipt_snapshot_dispatch_count failed.receipt)
  | Error _ -> fail "eligible pre-dispatch failure did not advance"
;;

let test_exception_after_durable_advance_stops_before_successor () =
  let durable_path = Filename.temp_file "oas-exact-flow-advance-" ".json" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove durable_path with
      | Sys_error _ -> ())
    (fun () ->
       let persist_advance json =
         let channel = open_out_bin durable_path in
         Fun.protect
           ~finally:(fun () -> close_out_noerr channel)
           (fun () ->
              output_string channel (Yojson.Safe.to_string json);
              flush channel;
              Unix.fsync (Unix.descr_of_out_channel channel))
       in
       let (raised, replay, evidence, bound, committed), posts =
         with_server ~response:(openai_response {|{"name":"unused"}|})
         @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
         let dead_url = Printf.sprintf "http://127.0.0.1:%d" (fresh_port ()) in
         with_catalog
           [ catalog_entry
               ~id:"advance-committed-dead"
               ~base_url:dead_url
               ~native:true
               ~json:true
               ()
           ; catalog_entry
               ~id:"advance-withheld-live"
               ~base_url
               ~native:true
               ~json:true
               ()
           ]
         @@ fun snapshot ->
         let flow =
           start_flow
             (frozen_flow snapshot [ "advance-committed-dead"; "advance-withheld-live" ])
         in
         let bound = ref [] in
         let raised =
           try
             ignore
               (execute_with_accepting_test_validator
                  ~net
                  ~on_measurement_terminal:(fun _ -> Ok ())
                  ~before_measurement_dispatch:(fun _ -> Ok ())
                  ~before_dispatch:(fun candidate ->
                    bound := candidate_id candidate :: !bound;
                    Ok ())
                  ~before_advance:(fun ~failed ~next ->
                    let failed, failure = flow_execution_failure failed in
                    (match failure.EO.cause with
                     | EO.Completion_failed -> ()
                     | _ ->
                       fail
                         "advance callback did not receive the typed completion failure");
                    check
                      bool
                      "committed failure is before dispatch"
                      true
                      (EO.receipt_phase failure.receipt = EO.Before_dispatch);
                    check
                      int
                      "committed failure has zero dispatch"
                      0
                      (EO.receipt_dispatch_count failure.receipt);
                    persist_advance
                      (`Assoc
                          [ "failed_candidate_id", `String (candidate_id failed)
                          ; "next_candidate_id", `String next.identity.candidate_id
                          ; ( "failed_call_id"
                            , `String
                                (EO.receipt_call_id failed.receipt |> EO.call_id_to_string)
                            )
                          ; ( "failed_plan_fingerprint"
                            , `String (EO.receipt_plan_fingerprint failed.receipt) )
                          ; "failure_cause", `String "completion_failed"
                          ; "failure_phase", `String "before_dispatch"
                          ; "failure_dispatch_count", `Int 0
                          ]);
                    raise Advance_committed_before_successor)
                  flow
                : (EO.flow_success, unit EO.flow_execution_error) result);
             false
           with
           | Advance_committed_before_successor -> true
         in
         let replay = execute_ok ~net flow in
         let evidence = EO.flow_attempt_evidence flow in
         let committed =
           In_channel.with_open_bin durable_path In_channel.input_all
           |> Yojson.Safe.from_string
         in
         raised, replay, evidence, List.rev !bound, committed
       in
       check bool "exception escaped after durable advance" true raised;
       check int "successor POST count remains zero" 0 posts;
       check
         (list string)
         "successor before_dispatch never runs"
         [ "advance-committed-dead" ]
         bound;
       (match replay with
        | Error (EO.Flow_attempt_already_started replay_evidence) ->
          check
            int
            "replay evidence keeps successor unprepared"
            1
            (List.length replay_evidence.attempts)
        | Ok _ | Error _ -> fail "flow was replayable after committed advance exception");
       let failed = attempt_for evidence "advance-committed-dead" in
       check
         bool
         "failed attempt evidence remains before dispatch"
         true
         (EO.generation_receipt_snapshot_phase failed.receipt = EO.Before_dispatch);
       check
         int
         "failed attempt evidence remains zero dispatch"
         0
         (EO.generation_receipt_snapshot_dispatch_count failed.receipt);
       check int "successor has no speculative attempt" 1 (List.length evidence.attempts);
       check
         int
         "only the failed candidate was attempted"
         1
         (EO.candidate_visit_count_to_int evidence.candidate_visit_count);
       let open Yojson.Safe.Util in
       let committed_string field = committed |> member field |> to_string in
       let committed_int field = committed |> member field |> to_int in
       check
         string
         "committed failed candidate joins retained evidence"
         (* [failed] is a flow_attempt_snapshot from [attempt_for], not the
            flow_attempt_receipt [candidate_id] reads. The path is inlined here the
            same way attempt_for itself reads it (:390-391): the two records are
            distinct nominal types, so one accessor cannot serve both without a
            functor, and a near-duplicate helper would say less than the path does. *)
         failed.visit.identity.candidate_id
         (committed_string "failed_candidate_id");
       check
         string
         "committed successor joins retained evidence"
         "advance-withheld-live"
         (committed_string "next_candidate_id");
       check
         string
         "committed failed call joins retained evidence"
         (EO.generation_receipt_snapshot_call_id failed.receipt |> EO.call_id_to_string)
         (committed_string "failed_call_id");
       check
         string
         "committed failed plan joins retained evidence"
         (EO.generation_receipt_snapshot_plan_fingerprint failed.receipt)
         (committed_string "failed_plan_fingerprint");
       check
         string
         "caller reconciliation retains typed cause"
         "completion_failed"
         (committed_string "failure_cause");
       check
         string
         "caller reconciliation retains exact phase"
         "before_dispatch"
         (committed_string "failure_phase");
       check
         int
         "caller reconciliation retains exact dispatch count"
         0
         (committed_int "failure_dispatch_count"))
;;

let test_callback_failures_are_terminal () =
  let before_dispatch_result, before_dispatch_posts =
    with_server ~response:(openai_response {|{"name":"unused"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry ~id:"bind-a" ~base_url ~native:true ~json:true ()
      ; catalog_entry ~id:"bind-b" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    execute_with_accepting_test_validator
      ~net
      ~on_measurement_terminal:(fun _ -> Ok ())
      ~before_measurement_dispatch:(fun _ -> Ok ())
      ~before_dispatch:(fun _ -> Error "bind-not-durable")
      ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
      (start_flow (frozen_flow snapshot [ "bind-a"; "bind-b" ]))
  in
  check int "failed bind dispatches nothing" 0 before_dispatch_posts;
  (match before_dispatch_result with
   | Error
       (EO.Flow_before_dispatch_callback_failed
          { candidate; cause = "bind-not-durable"; evidence } as error) ->
     check
       bool
       "before-dispatch callback failure starts no outward dispatch"
       true
       (EO.flow_execution_error_generation_dispatch error = EO.No_generation_dispatch);
     check string "failed bind candidate" "bind-a" (candidate_id candidate);
     check
       bool
       "failed bind leaves receipt not started"
       true
       (EO.receipt_phase candidate.receipt = EO.Not_started);
     check int "successor remains unprepared" 1 (List.length evidence.attempts);
     let start_failed =
       EO.Flow_attempt_start_failed
         { candidate = candidate.visit
         ; cause = EO.Call_id_generation_failed "injected"
         ; evidence
         }
     in
     check
       bool
       "attempt-start failure starts no outward dispatch"
       true
       (EO.flow_execution_error_generation_dispatch start_failed
        = EO.No_generation_dispatch)
   | Ok _ | Error _ -> fail "failed bind did not return typed terminal evidence");
  let before_advance_result, before_advance_posts =
    with_server ~response:(openai_response {|{"name":"unused"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    let dead_url = Printf.sprintf "http://127.0.0.1:%d" (fresh_port ()) in
    with_catalog
      [ catalog_entry ~id:"advance-a" ~base_url:dead_url ~native:true ~json:true ()
      ; catalog_entry ~id:"advance-b" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    execute_with_accepting_test_validator
      ~net
      ~on_measurement_terminal:(fun _ -> Ok ())
      ~before_measurement_dispatch:(fun _ -> Ok ())
      ~before_dispatch:(fun _ -> Ok ())
      ~before_advance:(fun ~failed:_ ~next:_ -> Error "release-not-durable")
      (start_flow (frozen_flow snapshot [ "advance-a"; "advance-b" ]))
  in
  check int "failed advance dispatches no successor" 0 before_advance_posts;
  match before_advance_result with
  | Error
      (EO.Flow_before_advance_callback_failed
         { failed; next; cause = "release-not-durable"; evidence; _ } as error) ->
    check
      bool
      "before-advance callback failure starts no outward dispatch"
      true
      (EO.flow_execution_error_generation_dispatch error = EO.No_generation_dispatch);
    check string "failed attempt identity" "advance-a" (flow_failure_id failed);
    check string "withheld successor identity" "advance-b" next.identity.candidate_id;
    check int "withheld successor remains unprepared" 1 (List.length evidence.attempts);
    check
      int
      "failed callback publishes no advance receipt"
      0
      (List.length evidence.advances)
  | Ok _ | Error _ -> fail "failed advance did not return typed terminal evidence"
;;

let assert_typed_capacity_refusal_advances_once ~label ~first_response ~assert_cause =
  let refused_id = label ^ "-refused" in
  let successor_id = label ^ "-successor" in
  let ( (result, replay, advances, evidence, observed_advance, dispatches_before_replay)
      , posts )
    =
    with_server ~first_response ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry ~id:refused_id ~base_url ~native:true ~json:true ()
      ; catalog_entry ~id:successor_id ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    let flow = start_flow (frozen_flow snapshot [ refused_id; successor_id ]) in
    let advances = ref 0 in
    let observed_advance = ref None in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun _ -> Ok ())
        ~before_advance:(fun ~failed ~next ->
          let failed_candidate, failure = flow_execution_failure failed in
          observed_advance
          := Some
               ( candidate_id failed_candidate
               , next.identity.candidate_id
               , failure.EO.cause
               , EO.receipt_phase failure.receipt
               , EO.receipt_dispatch_count failure.receipt );
          incr advances;
          Ok ())
        flow
    in
    let evidence = EO.flow_attempt_evidence flow in
    let dispatches_before_replay =
      List.fold_left
        (fun total (attempt : EO.flow_attempt_snapshot) ->
           total + EO.generation_receipt_snapshot_dispatch_count attempt.receipt)
        0
        evidence.attempts
    in
    ( result
    , execute_ok ~net flow
    , !advances
    , evidence
    , !observed_advance
    , dispatches_before_replay )
  in
  (match observed_advance with
   | Some (failed, next, cause, phase, dispatch_count) ->
     check string (label ^ " typed capacity failure candidate") refused_id failed;
     check string (label ^ " typed capacity predetermined successor") successor_id next;
     assert_cause cause;
     check
       bool
       (label ^ " typed capacity refusal records response receipt")
       true
       (phase = EO.Response_received);
     check int (label ^ " typed capacity refusal records one dispatch") 1 dispatch_count
   | None -> fail (label ^ " capacity refusal did not request advance"));
  check int (label ^ " flow performs two total POSTs") 2 posts;
  check int (label ^ " typed capacity requests one successor advance") 1 advances;
  check
    int
    (label ^ " typed capacity retains one advance receipt")
    1
    (List.length evidence.advances);
  check
    int
    (label ^ " typed capacity retains two attempts")
    2
    (List.length evidence.attempts);
  let refused_attempt = attempt_for evidence refused_id in
  check
    int
    (refused_id ^ " dispatch count")
    1
    (EO.generation_receipt_snapshot_dispatch_count refused_attempt.receipt);
  let successor_attempt = attempt_for evidence successor_id in
  check
    int
    (successor_id ^ " dispatch count")
    1
    (EO.generation_receipt_snapshot_dispatch_count successor_attempt.receipt);
  check int (label ^ " replay adds zero POSTs") 0 (posts - dispatches_before_replay);
  (match replay with
   | Error (EO.Flow_attempt_already_started _) -> ()
   | Ok _ | Error _ -> fail (label ^ " capacity flow replay dispatched again"));
  match result with
  | Ok success ->
    check
      string
      (label ^ " typed capacity successor succeeds")
      successor_id
      (candidate_id (EO.flow_success_candidate success))
  | Error _ -> fail (label ^ " typed capacity refusal did not advance")
;;

let test_context_window_400_prose_remains_terminal () =
  let response =
    {|{"error":"The prompt is too long: 1400014, model maximum context length: 1048576 (ref: 8519ccf3-5d45-4686-9ac1-64d159f75ec1)"}|}
  in
  let (result, advances), posts =
    with_server ~status:`Bad_request ~response
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry ~id:"context-prose-a" ~base_url ~native:true ~json:true ()
      ; catalog_entry ~id:"context-prose-b" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    let advances = ref 0 in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun _ -> Ok ())
        ~before_advance:(fun ~failed:_ ~next:_ ->
          incr advances;
          Ok ())
        (start_flow (frozen_flow snapshot [ "context-prose-a"; "context-prose-b" ]))
    in
    result, !advances
  in
  check int "HTTP 400 prose dispatches once" 1 posts;
  check int "HTTP 400 prose requests no advance" 0 advances;
  match result with
  | Error (EO.Flow_exact_execution_failed failure) ->
    check
      bool
      "HTTP 400 prose remains unattributed completion failure"
      true
      (failure.cause.cause = EO.Completion_failed)
  | Ok _ | Error _ -> fail "HTTP 400 prose did not remain terminal"
;;

let test_serialized_request_413_refusal_advances_once_to_successor () =
  assert_typed_capacity_refusal_advances_once
    ~label:"serialized-request"
    ~first_response:
      (Cohttp.Code.status_of_code 413, {|{"error":"request body too large"}|})
    ~assert_cause:(function
      | EO.Serialized_request_refused { http_status = 413 } -> ()
      | _ -> fail "HTTP 413 lost its typed serialized-request cause")
;;

let test_generic_400_remains_terminal_without_advance () =
  let (result, advances, evidence), posts =
    with_server ~status:`Bad_request ~response:{|{"error":"generic request rejection"}|}
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry ~id:"generic-400-a" ~base_url ~native:true ~json:true ()
      ; catalog_entry ~id:"generic-400-b" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    let flow = start_flow (frozen_flow snapshot [ "generic-400-a"; "generic-400-b" ]) in
    let advances = ref 0 in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun _ -> Ok ())
        ~before_advance:(fun ~failed:_ ~next:_ ->
          incr advances;
          Ok ())
        flow
    in
    result, !advances, EO.flow_attempt_evidence flow
  in
  check int "generic 400 dispatches once" 1 posts;
  check int "generic 400 requests no advance" 0 advances;
  check int "generic 400 leaves successor unprepared" 1 (List.length evidence.attempts);
  match result with
  | Error
      (EO.Flow_exact_execution_failed
         { candidate; cause = { cause = EO.Completion_failed; _ }; _ }) ->
    check string "generic 400 terminal candidate" "generic-400-a" (candidate_id candidate)
  | Ok _ | Error _ -> fail "generic 400 did not remain a completion failure"
;;

let test_postdispatch_and_structural_outcomes_never_advance () =
  let run ?(status = `OK) ?(abort_completion = false) label response =
    let (result, advances), posts =
      with_server ~status ~abort_completion ~response
      @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
      with_catalog
        [ catalog_entry ~id:(label ^ "-a") ~base_url ~native:true ~json:true ()
        ; catalog_entry ~id:(label ^ "-b") ~base_url ~native:true ~json:true ()
        ]
      @@ fun snapshot ->
      let advances = ref 0 in
      let result =
        execute_with_accepting_test_validator
          ~net
          ~on_measurement_terminal:(fun _ -> Ok ())
          ~before_measurement_dispatch:(fun _ -> Ok ())
          ~before_dispatch:(fun _ -> Ok ())
          ~before_advance:(fun ~failed:_ ~next:_ ->
            incr advances;
            Ok ())
          (start_flow (frozen_flow snapshot [ label ^ "-a"; label ^ "-b" ]))
      in
      result, !advances
    in
    check int (label ^ " dispatches exactly once") 1 posts;
    check int (label ^ " does not request advance") 0 advances;
    match result with
    | Error (EO.Flow_exact_execution_failed { candidate; cause; evidence } as error) ->
      check
        bool
        (label ^ " records outward dispatch started")
        true
        (EO.flow_execution_error_generation_dispatch error
         = EO.Generation_dispatch_started);
      check string (label ^ " terminal candidate") (label ^ "-a") (candidate_id candidate);
      check
        int
        (label ^ " terminal dispatch count")
        1
        (EO.receipt_dispatch_count cause.receipt);
      check
        int
        (label ^ " successor remains unprepared")
        1
        (List.length evidence.attempts)
    | Ok _ | Error _ -> fail (label ^ " did not remain terminal")
  in
  run ~abort_completion:true "partial" "unused";
  run ~status:`Too_many_requests "response" "rate limited";
  run "tool" tool_response
;;

let test_snapshot_preserves_caller_declared_order () =
  with_catalog
    [ catalog_entry
        ~id:"catalog-a"
        ~base_url:"http://127.0.0.1:1"
        ~native:true
        ~json:true
        ()
    ; catalog_entry
        ~id:"catalog-b"
        ~base_url:"http://127.0.0.1:2"
        ~native:true
        ~json:true
        ()
    ]
  @@ fun snapshot ->
  let ready = frozen_flow snapshot [ "catalog-b"; "catalog-a" ] in
  check
    (list string)
    "snapshot preserves caller order"
    [ "catalog-b"; "catalog-a" ]
    (flow_snapshot_ids ready)
;;

let test_semantic_rejection_advances_to_declared_successor () =
  let (result, validated_ids, advances), posts =
    with_server ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry ~id:"semantic-a" ~base_url ~native:true ~json:true ()
      ; catalog_entry ~id:"semantic-b" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    let validated_ids = ref [] in
    let advances = ref 0 in
    let result =
      execute_with_validator
        ~net
        ~before_advance:(fun ~failed:_ ~next:_ ->
          incr advances;
          Ok ())
        ~validate:(fun success ->
          let id = candidate_id (EO.flow_success_candidate success) in
          validated_ids := id :: !validated_ids;
          if String.equal id "semantic-a"
          then EO.Reject_and_advance ("domain-invalid:" ^ id)
          else EO.Accept id)
        (start_flow (frozen_flow snapshot [ "semantic-a"; "semantic-b" ]))
    in
    result, List.rev !validated_ids, !advances
  in
  check int "one POST per visited candidate" 2 posts;
  check
    (list string)
    "validator follows declared order"
    [ "semantic-a"; "semantic-b" ]
    validated_ids;
  check int "semantic rejection bypasses before_advance" 0 advances;
  match result with
  | Ok success ->
    check string "accepted successor" "semantic-b" success.accepted;
    check
      string
      "transport success belongs to successor"
      "semantic-b"
      (candidate_id (EO.flow_success_candidate success.transport_success));
    check
      int
      "semantic rejection emits no transport advance receipt"
      0
      (List.length (EO.flow_success_evidence success.transport_success).advances);
    check
      (list string)
      "prior opaque rejection is preserved"
      [ "semantic-a" ]
      (List.map semantic_rejection_candidate_id success.prior_rejections)
  | Error _ -> fail "declared semantic successor did not succeed"
;;

let test_all_semantic_rejections_return_nonempty_ordered_exhaustion () =
  let (result, advances), posts =
    with_server ~response:(openai_response {|{"name":"rejected"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry ~id:"reject-a" ~base_url ~native:true ~json:true ()
      ; catalog_entry ~id:"reject-b" ~base_url ~native:true ~json:true ()
      ; catalog_entry ~id:"reject-c" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    let advances = ref 0 in
    let result =
      execute_with_validator
        ~net
        ~before_advance:(fun ~failed:_ ~next:_ ->
          incr advances;
          Ok ())
        ~validate:(fun success ->
          let id = candidate_id (EO.flow_success_candidate success) in
          EO.Reject_and_advance ("rejected:" ^ id))
        (start_flow (frozen_flow snapshot [ "reject-a"; "reject-b"; "reject-c" ]))
    in
    result, !advances
  in
  check int "each exhausted candidate posts once" 3 posts;
  check int "semantic exhaustion bypasses before_advance" 0 advances;
  match result with
  | Error (EO.Flow_semantic_candidates_exhausted { rejections; evidence }) ->
    let ordered = rejections.first :: rejections.rest in
    check
      (list string)
      "nonempty rejection trace preserves declared order"
      [ "reject-a"; "reject-b"; "reject-c" ]
      (List.map semantic_rejection_candidate_id ordered);
    List.iter
      (fun (rejection : _ EO.semantic_rejection_receipt) ->
         check
           int
           "semantic candidate dispatch count"
           1
           (EO.receipt_dispatch_count
              (EO.flow_success_candidate rejection.transport_success).receipt))
      ordered;
    check int "terminal evidence retains every attempt" 3 (List.length evidence.attempts)
  | Ok _ | Error _ -> fail "semantic exhaustion lost its typed nonempty trace"
;;

let test_admission_and_semantic_rejections_share_one_declared_walk () =
  let (result, transitions, validated_ids), posts =
    with_server ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      ~getenv:credential_getenv
      [ catalog_entry
          ~api_key_env:"MISSING_FLOW_KEY"
          ~id:"mixed-missing"
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry ~id:"mixed-semantic" ~base_url ~native:true ~json:true ()
      ; catalog_entry ~id:"mixed-accepted" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    let transitions = ref [] in
    let validated_ids = ref [] in
    let result =
      execute_with_validator
        ~net
        ~before_advance:(fun ~failed ~next ->
          transitions
          := (flow_failure_id failed, next.identity.candidate_id) :: !transitions;
          Ok ())
        ~validate:(fun success ->
          let id = candidate_id (EO.flow_success_candidate success) in
          validated_ids := id :: !validated_ids;
          if String.equal id "mixed-semantic"
          then EO.Reject_and_advance id
          else EO.Accept id)
        (start_flow
           (frozen_flow snapshot [ "mixed-missing"; "mixed-semantic"; "mixed-accepted" ]))
    in
    result, List.rev !transitions, List.rev !validated_ids
  in
  check int "only transport-admitted candidates post" 2 posts;
  check
    (list (pair string string))
    "admission rejection advances only to predetermined successor"
    [ "mixed-missing", "mixed-semantic" ]
    transitions;
  check
    (list string)
    "semantic validation retains declared suffix order"
    [ "mixed-semantic"; "mixed-accepted" ]
    validated_ids;
  match result with
  | Ok success ->
    check string "mixed walk accepted final candidate" "mixed-accepted" success.accepted;
    check
      (list string)
      "mixed walk preserves semantic evidence only"
      [ "mixed-semantic" ]
      (List.map semantic_rejection_candidate_id success.prior_rejections)
  | Error _ -> fail "mixed declared walk did not accept its final candidate"
;;

let test_prior_semantic_rejection_survives_later_transport_terminal () =
  let first_response = `OK, openai_response {|{"name":"first"}|} in
  let (result, advances), posts =
    with_server
      ~first_response
      ~status:`Bad_request
      ~response:{|{"error":"generic invalid request"}|}
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry ~id:"prior-semantic" ~base_url ~native:true ~json:true ()
      ; catalog_entry ~id:"later-terminal" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    let advances = ref 0 in
    let result =
      execute_with_validator
        ~net
        ~before_advance:(fun ~failed:_ ~next:_ ->
          incr advances;
          Ok ())
        ~validate:(fun success ->
          EO.Reject_and_advance (candidate_id (EO.flow_success_candidate success)))
        (start_flow (frozen_flow snapshot [ "prior-semantic"; "later-terminal" ]))
    in
    result, !advances
  in
  check int "semantic then transport terminal posts once each" 2 posts;
  check int "neither terminal path requests before_advance" 0 advances;
  match result with
  | Error
      (EO.Flow_execution_terminal
         { cause = EO.Flow_exact_execution_failed { candidate; evidence; _ }
         ; prior_rejections
         }) ->
    check string "later terminal candidate" "later-terminal" (candidate_id candidate);
    check
      (list string)
      "earlier opaque rejection survives"
      [ "prior-semantic" ]
      (List.map semantic_rejection_candidate_id prior_rejections);
    check int "terminal evidence retains both attempts" 2 (List.length evidence.attempts)
  | Ok _ | Error _ -> fail "later transport terminal lost prior semantic evidence"
;;

let test_gemini_structural_sibling_rejects_before_outer_dispatch () =
  let id = "gemini-structural-sibling-flow" in
  let string_branch =
    `Assoc [ "type", `String "string"; "enum", `List [ `String "ready" ] ]
  in
  let invalid_schema =
    `Assoc
      [ "anyOf", `List [ string_branch; `Assoc [ "type", `String "null" ] ]
      ; "type", `String "string"
      ]
  in
  let requirement =
    EO.make_output_requirement
      ~schema:invalid_schema
      ~minimum_guarantee:EO.Provider_schema
  in
  let (result, evidence), posts =
    with_counted_server ~measurement_reply:(Measurement_tokens 1) ~response:"unused"
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry
          ~kind:"gemini"
          ~request_path:""
          ~id
          ~base_url:(base_url ^ "/v1beta/models")
          ~native:true
          ~json:true
          ()
      ]
    @@ fun snapshot ->
    let flow =
      start_flow (frozen_candidates ~requirement [ flow_candidate snapshot id ])
    in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~before_measurement_dispatch:(fun _ ->
          fail "schema rejection reached measurement intent")
        ~on_measurement_terminal:(fun _ ->
          fail "schema rejection reached measurement terminal")
        ~before_dispatch:(fun _ -> fail "schema rejection allocated generation")
        ~before_advance:(fun ~failed:_ ~next:_ ->
          fail "single rejected schema requested successor advance")
        flow
    in
    result, EO.flow_attempt_evidence flow
  in
  check int "invalid Gemini schema performs no measurement POST" 0 posts.measurement_posts;
  check int "invalid Gemini schema performs no generation POST" 0 posts.generation_posts;
  check int "invalid Gemini schema allocates no attempt" 0 (List.length evidence.attempts);
  match result with
  | Error
      (EO.Flow_candidates_exhausted { rejection; evidence = terminal_evidence } as error)
    ->
    check
      bool
      "invalid Gemini schema starts no generation dispatch"
      true
      (EO.flow_execution_error_generation_dispatch error = EO.No_generation_dispatch);
    (match EO.candidate_rejection_disposition rejection with
     | EO.Output_requirement_rejected -> ()
     | _ -> fail "invalid Gemini schema lost its output-requirement disposition");
    check
      bool
      "invalid Gemini schema records no measurement dispatch"
      true
      (EO.candidate_rejection_measurement_dispatch_fact rejection
       = EO.No_measurement_dispatch);
    check
      bool
      "invalid Gemini schema records local invalid measurement outcome"
      true
      (EO.candidate_rejection_measurement_outcome rejection = EO.Measurement_local_invalid);
    check
      int
      "terminal invalid Gemini schema retains no attempt"
      0
      (List.length terminal_evidence.attempts)
  | Ok _ | Error _ -> fail "invalid Gemini schema lost typed candidate exhaustion"
;;

let test_structural_predispatch_failure_does_not_advance () =
  let response =
    {|{"id":"msg-flow","type":"message","role":"assistant","model":"flow","content":[{"type":"text","text":"{\"name\":\"unused\"}"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}|}
  in
  let (result, replay, evidence, intents, terminals, advances), posts =
    with_counted_server ~measurement_reply:(Measurement_tokens 1) ~response
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry
          ~kind:"anthropic"
          ~request_path:"/v1/messages"
          ~serving_constraint:true
          ~body_timeout_s:1.0
          ~id:"clock-a"
          ~base_url
          ~native:true
          ~json:true
          ()
      ; catalog_entry ~id:"clock-b" ~base_url ~native:true ~json:true ()
      ]
    @@ fun snapshot ->
    let flow = start_flow (frozen_flow snapshot [ "clock-a"; "clock-b" ]) in
    let intents = ref 0 in
    let terminals = ref 0 in
    let advances = ref 0 in
    let result =
      execute_with_accepting_test_validator
        ~net
        ~before_measurement_dispatch:(fun _ ->
          incr intents;
          Ok ())
        ~on_measurement_terminal:(fun _ ->
          incr terminals;
          Ok ())
        ~before_dispatch:(fun _ -> fail "missing measurement clock allocated generation")
        ~before_advance:(fun ~failed:_ ~next:_ ->
          incr advances;
          Ok ())
        flow
    in
    ( result
    , execute_ok ~net flow
    , EO.flow_attempt_evidence flow
    , !intents
    , !terminals
    , !advances )
  in
  check int "missing clock dispatches no measurement" 0 posts.measurement_posts;
  check int "missing clock dispatches no generation" 0 posts.generation_posts;
  check int "missing clock invokes no intent callback" 0 intents;
  check int "missing clock invokes no terminal callback" 0 terminals;
  check int "missing clock cannot advance" 0 advances;
  check
    int
    "missing clock records no measurement receipt"
    0
    (List.length evidence.measurements);
  check
    int
    "missing clock allocates no generation attempt"
    0
    (List.length evidence.attempts);
  (match replay with
   | Error (EO.Flow_attempt_already_started _) -> ()
   | Ok _ | Error _ -> fail "missing-clock flow replayed");
  match result with
  | Error
      (EO.Flow_measurement_start_failed
         { cause = EO.Measurement_clock_required_for_timeout; evidence; _ } as error) ->
    check
      bool
      "predispatch structural failure starts no outward dispatch"
      true
      (EO.flow_execution_error_generation_dispatch error = EO.No_generation_dispatch);
    check int "structural successor remains unprepared" 0 (List.length evidence.attempts)
  | Ok _ | Error _ -> fail "missing clock was not terminal"
;;

let test_concurrent_duplicate_flow_does_not_double_dispatch () =
  let (left, right), posts =
    with_server ~response_delay_s:0.1 ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock:_ ~base_url ->
    with_catalog
      [ catalog_entry ~id:"concurrent-flow" ~base_url ~native:true ~json:true () ]
    @@ fun snapshot ->
    let flow = start_flow (frozen_flow snapshot [ "concurrent-flow" ]) in
    let execute () : (EO.flow_success, string EO.flow_execution_error) result =
      execute_with_accepting_test_validator
        ~net
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~before_dispatch:(fun _ -> Ok ())
        ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
        flow
    in
    let left_promise, left_resolver = Eio.Promise.create () in
    let right_promise, right_resolver = Eio.Promise.create () in
    Eio.Fiber.both
      (fun () -> Eio.Promise.resolve left_resolver (execute ()))
      (fun () -> Eio.Promise.resolve right_resolver (execute ()));
    Eio.Promise.await left_promise, Eio.Promise.await right_promise
  in
  check int "concurrent duplicate makes one POST" 1 posts;
  let is_success = function
    | Ok _ -> true
    | Error _ -> false
  in
  let is_replay = function
    | Error (EO.Flow_attempt_already_started _) -> true
    | Ok _ | Error _ -> false
  in
  check
    bool
    "one concurrent invocation succeeds"
    true
    (is_success left <> is_success right);
  check
    bool
    "one concurrent invocation is rejected"
    true
    (is_replay left <> is_replay right)
;;

let test_cancellation_terminalizes_outer_attempt () =
  let (timed_out, replay, evidence), posts =
    with_server ~response_delay_s:0.1 ~response:(openai_response {|{"name":"accepted"}|})
    @@ fun ~sw:_ ~net ~clock ~base_url ->
    with_catalog [ catalog_entry ~id:"cancel-flow" ~base_url ~native:true ~json:true () ]
    @@ fun snapshot ->
    let flow = start_flow (frozen_flow snapshot [ "cancel-flow" ]) in
    let timed_out =
      try
        ignore
          (Eio.Time.with_timeout_exn clock 0.01 (fun () -> execute_ok ~net flow)
           : (EO.flow_success, _ EO.flow_execution_error) result);
        false
      with
      | Eio.Time.Timeout -> true
    in
    let replay = execute_ok ~net flow in
    timed_out, replay, EO.flow_attempt_evidence flow
  in
  check bool "cancellation escaped" true timed_out;
  check int "cancellation dispatched at most once" 1 posts;
  (match replay with
   | Error (EO.Flow_attempt_already_started _) -> ()
   | Ok _ | Error _ -> fail "cancelled flow was not terminal");
  let receipt = (attempt_for evidence "cancel-flow").receipt in
  check
    int
    "cancelled receipt records dispatch"
    1
    (EO.generation_receipt_snapshot_dispatch_count receipt)
;;

let () =
  run
    "exact-output-flow"
    [ ( "outer-flow"
      , [ test_case
            "snapshot defers admission and current attempts do not share"
            `Quick
            test_snapshot_defers_admission_and_allocates_nonshared_current_attempts
        ; test_case
            "later missing credential does not block current success"
            `Quick
            test_later_missing_credential_does_not_block_current_success
        ; test_case
            "JSON syntax is prompt-only even for a native target"
            `Quick
            test_json_syntax_is_prompt_only_even_for_native_target
        ; test_case
            "fenced JSON advances to frozen successor"
            `Quick
            test_fenced_text_json_advances_to_frozen_successor
        ; test_case
            "provider schema still requires native capability"
            `Quick
            test_provider_schema_still_requires_native_capability
        ; test_case
            "missing current credential advances after durable settlement"
            `Quick
            test_missing_current_credential_advances_after_durable_settlement
        ; test_case
            "read-failed current credential advances to good successor"
            `Quick
            test_read_failed_current_credential_advances_to_good_successor
        ; test_case
            "credential rejections remain ordered zero-dispatch terminal"
            `Quick
            test_credential_rejections_are_ordered_zero_dispatch_terminal
        ; test_case
            "unmeasured constraint advances after durable settlement"
            `Quick
            test_unmeasured_constraint_advances_only_after_durable_settlement
        ; test_case
            "request body cap advances after durable settlement"
            `Quick
            test_request_body_capacity_advances_only_after_durable_settlement
        ; test_case
            "request body projection is exact and credential-free"
            `Quick
            test_request_body_projection_is_exact_and_credential_free
        ; test_case
            "measured token and serialized body capacities are independent"
            `Quick
            test_measured_token_and_body_capacity_are_independent
        ; test_case
            "measurement receipt codec and monotonic transition"
            `Quick
            test_measurement_receipt_codec_and_transition
        ; test_case
            "measurement fence rejection is terminal without wire"
            `Quick
            test_measurement_fence_rejection_is_terminal_without_wire
        ; test_case
            "nested journal HTTP cannot mark measurement dispatch"
            `Quick
            test_measurement_fence_nested_http_does_not_mark_outer_dispatch
        ; test_case
            "measurement terminal callback blocks generation"
            `Quick
            test_measurement_terminal_callback_failure_blocks_generation
        ; test_case
            "measurement predispatch failure records zero dispatch"
            `Quick
            test_measurement_predispatch_failure_records_zero_dispatch
        ; test_case
            "measurement cancellation terminalizes receipt"
            `Quick
            test_measurement_cancellation_terminalizes_receipt
        ; test_case
            "predispatch measurement failure advances without wire"
            `Quick
            test_predispatch_measurement_failure_advances_without_wire
        ; test_case
            "postdispatch measurement failure forbids successor"
            `Quick
            test_postdispatch_measurement_failures_do_not_advance
        ; test_case
            "frozen Anthropic artifact parity"
            `Quick
            test_exact_anthropic_frozen_artifact_parity
        ; test_case
            "all candidate rejections return zero-dispatch terminal"
            `Quick
            test_all_candidate_rejections_return_typed_zero_dispatch_terminal
        ; test_case
            "predispatch transport failure advances durably"
            `Quick
            test_predispatch_transport_failure_advances_after_durable_callback
        ; test_case
            "exception after durable advance stops successor"
            `Quick
            test_exception_after_durable_advance_stops_before_successor
        ; test_case
            "exception after durable rejection stops successor"
            `Quick
            test_exception_after_durable_rejection_stops_before_successor
        ; test_case
            "callback failures are terminal"
            `Quick
            test_callback_failures_are_terminal
        ; test_case
            "context-window 400 prose remains terminal"
            `Quick
            test_context_window_400_prose_remains_terminal
        ; test_case
            "HTTP 413 serialized request advances with one dispatch per candidate"
            `Quick
            test_serialized_request_413_refusal_advances_once_to_successor
        ; test_case
            "generic 400 remains terminal"
            `Quick
            test_generic_400_remains_terminal_without_advance
        ; test_case
            "postdispatch and structural outcomes stop"
            `Quick
            test_postdispatch_and_structural_outcomes_never_advance
        ; test_case
            "snapshot preserves caller declared order"
            `Quick
            test_snapshot_preserves_caller_declared_order
        ; test_case
            "semantic rejection advances to declared successor"
            `Quick
            test_semantic_rejection_advances_to_declared_successor
        ; test_case
            "all semantic rejections return typed nonempty exhaustion"
            `Quick
            test_all_semantic_rejections_return_nonempty_ordered_exhaustion
        ; test_case
            "admission and semantic rejections share one declared walk"
            `Quick
            test_admission_and_semantic_rejections_share_one_declared_walk
        ; test_case
            "prior semantic rejection survives later transport terminal"
            `Quick
            test_prior_semantic_rejection_survives_later_transport_terminal
        ; test_case
            "Gemini structural sibling rejects before outer dispatch"
            `Quick
            test_gemini_structural_sibling_rejects_before_outer_dispatch
        ; test_case
            "predispatch structural failure stops"
            `Quick
            test_structural_predispatch_failure_does_not_advance
        ; test_case
            "concurrent duplicate makes one dispatch"
            `Quick
            test_concurrent_duplicate_flow_does_not_double_dispatch
        ; test_case
            "cancellation terminalizes outer attempt"
            `Quick
            test_cancellation_terminalizes_outer_attempt
        ] )
    ]
;;
