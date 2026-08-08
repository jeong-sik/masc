open Alcotest
open Llm_provider
module EO = Agent_sdk.Exact_output

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

let catalog_entry ~id ~base_url ~api_key_env =
  Printf.sprintf
    "[[providers]]\n\
     id = %S\n\
     kind = \"openai_compat\"\n\
     base_url = %S\n\
     request_path = \"/v1/chat/completions\"\n\
     api_key_env = %S\n\n\
     [[models]]\n\
     id_prefix = %S\n\
     provider_name = %S\n\
     max_context_tokens = 8192\n\
     max_output_tokens = 1024\n\
     supports_response_format_json = true\n\
     supports_structured_output = true\n\n\
     [[targets]]\n\
     id = %S\n\
     provider_ref = %S\n\
     model_id = %S\n"
    id
    base_url
    api_key_env
    (id ^ "-model")
    id
    id
    id
    (id ^ "-model")
;;

let with_catalog ~base_url f =
  let ids = [ "evidence-a"; "evidence-b"; "evidence-c"; "evidence-d" ] in
  let contents =
    ids
    |> List.map (fun id ->
      catalog_entry
        ~id
        ~base_url
        ~api_key_env:(if String.equal id "evidence-a" then "MISSING_EVIDENCE_KEY" else ""))
    |> String.concat "\n"
  in
  let document : EO.catalog_document =
    { source = "validated-flow-evidence-test"; contents }
  in
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  match EO.load_resolver_snapshot ~io ~catalog:(EO.Embedded_with_overlay document) () with
  | Ok snapshot -> f snapshot
  | Error _ -> fail "evidence catalog did not load"
;;

let admitted_target snapshot id =
  match EO.admit_target_ref snapshot id with
  | Ok target -> target
  | Error _ -> failf "target %s was not admitted" id
;;

let candidate snapshot id =
  match EO.make_flow_candidate ~id ~admitted_target:(admitted_target snapshot id) with
  | Ok candidate -> candidate
  | Error EO.Blank_flow_candidate_id -> fail "fixture candidate id was blank"
;;

let start_flow snapshot =
  let candidates =
    List.map
      (candidate snapshot)
      [ "evidence-a"; "evidence-b"; "evidence-c"; "evidence-d" ]
  in
  let frozen =
    match candidates with
    | first :: rest ->
      EO.snapshot_flow
        ~first
        ~rest
        ~messages:[ msg "return one exact object" ]
        (EO.make_output_requirement ~schema ~minimum_guarantee:EO.Json_syntax)
    | [] -> fail "candidate fixture is empty"
  in
  match frozen with
  | Error _ -> fail "flow snapshot was rejected"
  | Ok frozen ->
    (match EO.start_flow frozen with
     | Ok flow -> flow
     | Error (EO.Flow_id_generation_failed detail) ->
       failf "flow identity allocation failed: %s" detail)
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
    {|{"id":"evidence-response","model":"evidence","choices":[{"index":0,"message":{"role":"assistant","content":%s},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
    encoded_content
;;

let sha256 value = Digestif.SHA256.(to_hex (digest_string value))

let recompute_integrity = function
  | `Assoc fields ->
    let payload_fields =
      List.filter (fun (name, _) -> not (String.equal name "integrity_sha256")) fields
    in
    let integrity_sha256 = `Assoc payload_fields |> Yojson.Safe.to_string |> sha256 in
    `Assoc (payload_fields @ [ "integrity_sha256", `String integrity_sha256 ])
  | _ -> fail "durable evidence was not an object"
;;

let break_first_step_ordinal = function
  | `Assoc fields ->
    let replace_steps = function
      | `List (`Assoc first_fields :: rest) ->
        let first_fields =
          List.map
            (fun (name, value) ->
               if String.equal name "ordinal" then name, `Int 2 else name, value)
            first_fields
        in
        `List (`Assoc first_fields :: rest)
      | _ -> fail "durable evidence steps were empty or malformed"
    in
    `Assoc
      (List.map
         (fun (name, value) ->
            if String.equal name "steps" then name, replace_steps value else name, value)
         fields)
  | _ -> fail "durable evidence was not an object"
;;

let with_server f =
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
      let index = Atomic.fetch_and_add posts 1 in
      let response =
        if index = 0
        then openai_response "not-json"
        else openai_response {|{"name":"accepted"}|}
      in
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
    f ~net ~base_url:(Printf.sprintf "http://127.0.0.1:%d" port)
  in
  result, Atomic.get posts
;;

let candidate_id (success : EO.flow_success) =
  (EO.flow_success_candidate success).visit.identity.candidate_id
;;

let run_mixed_flow () =
  with_server
  @@ fun ~net ~base_url ->
  with_catalog ~base_url
  @@ fun snapshot ->
  EO.execute_flow_once
    ~net
    ~before_measurement_dispatch:(fun _ -> Ok ())
    ~on_measurement_terminal:(fun _ -> Ok ())
    ~before_dispatch:(fun _ -> Ok ())
    ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
    ~validate:(fun success ->
      let id = candidate_id success in
      if String.equal id "evidence-c"
      then EO.Reject_and_advance ("rejected:" ^ id)
      else EO.Accept id)
    (start_flow snapshot)
;;

let snapshot success ~accepted_calls ~rejection_calls =
  EO.snapshot_validated_flow_evidence
    ~project_accepted:(fun value ->
      incr accepted_calls;
      Ok (`Assoc [ "accepted", `String value ]))
    ~project_rejection:(fun value ->
      incr rejection_calls;
      Ok (`Assoc [ "rejected", `String value ]))
    success
;;

let test_mixed_transcript_round_trip_and_projector_cardinality () =
  let result, posts = run_mixed_flow () in
  check int "only admitted candidates dispatch" 3 posts;
  match result with
  | Error _ -> fail "mixed flow did not reach its declared accepted candidate"
  | Ok success ->
    check string "accepted candidate" "evidence-d" success.accepted;
    let evidence = EO.flow_success_evidence success.transport_success in
    check int "four admissions retained" 4 (List.length evidence.admissions);
    check int "three attempts retained" 3 (List.length evidence.attempts);
    check int "two transport advances retained" 2 (List.length evidence.advances);
    check int "one semantic rejection retained" 1 (List.length success.prior_rejections);
    let accepted_calls = ref 0 in
    let rejection_calls = ref 0 in
    let durable =
      match snapshot success ~accepted_calls ~rejection_calls with
      | Ok durable -> durable
      | Error _ -> fail "valid typed flow did not produce durable evidence"
    in
    check int "accepted projector invoked once" 1 !accepted_calls;
    check int "rejection projector invoked once" 1 !rejection_calls;
    let encoded = EO.validated_flow_evidence_to_string durable in
    let decoded =
      match EO.validated_flow_evidence_of_string encoded with
      | Ok decoded -> decoded
      | Error error ->
        failf
          "durable evidence did not decode: %s"
          (EO.validated_flow_evidence_decode_error_to_string error)
    in
    check
      string
      "canonical encoding survives round trip"
      encoded
      (EO.validated_flow_evidence_to_string decoded);
    check
      string
      "transcript digest survives round trip"
      (EO.validated_flow_evidence_sha256 durable)
      (EO.validated_flow_evidence_sha256 decoded);
    check
      string
      "accepted domain digest survives round trip"
      (EO.validated_flow_evidence_accepted_domain_sha256 durable)
      (EO.validated_flow_evidence_accepted_domain_sha256 decoded);
    let tampered =
      match Yojson.Safe.from_string encoded with
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (name, value) ->
                if String.equal name "flow_id"
                then name, `String "different-flow"
                else name, value)
             fields)
        |> Yojson.Safe.to_string
      | _ -> fail "durable evidence was not an object"
    in
    (match EO.validated_flow_evidence_of_string tampered with
     | Error _ -> ()
     | Ok _ -> fail "tampered durable evidence decoded");
    let structurally_invalid =
      encoded
      |> Yojson.Safe.from_string
      |> break_first_step_ordinal
      |> recompute_integrity
      |> Yojson.Safe.to_string
    in
    (match EO.validated_flow_evidence_of_string structurally_invalid with
     | Error _ -> ()
     | Ok _ -> fail "re-hashed structurally invalid evidence decoded")
;;

let test_projection_failure_is_typed_and_short_circuits_acceptance () =
  let result, _posts = run_mixed_flow () in
  match result with
  | Error _ -> fail "mixed flow did not reach projection test"
  | Ok success ->
    let accepted_calls = ref 0 in
    let rejection_calls = ref 0 in
    let projected =
      EO.snapshot_validated_flow_evidence
        ~project_accepted:(fun _ ->
          incr accepted_calls;
          Ok (`Assoc []))
        ~project_rejection:(fun _ ->
          incr rejection_calls;
          Error "rejection projector failed")
        success
    in
    check int "failing rejection projector invoked once" 1 !rejection_calls;
    check int "accepted projector not invoked after rejection failure" 0 !accepted_calls;
    (match projected with
     | Error
         (EO.Rejection_evidence_projection_failed
            { ordinal = 3; cause = "rejection projector failed" }) -> ()
     | Ok _ | Error _ -> fail "projection failure lost its typed ordinal and cause")
;;

let () =
  run
    "exact-output validated flow evidence"
    [ ( "durable transcript"
      , [ test_case
            "mixed order round trip and projector cardinality"
            `Quick
            test_mixed_transcript_round_trip_and_projector_cardinality
        ; test_case
            "typed projection failure"
            `Quick
            test_projection_failure_is_typed_and_short_circuits_acceptance
        ] )
    ]
;;
