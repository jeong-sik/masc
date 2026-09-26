(* The Stagehand extension's llm.generate answered through the
   browser_stagehand_exact lane (RFC-browser-lane-stagehand §3.7, §6.1).

   The three requests are the ones the extension really sent on 2026-09-24
   (docs/evidence/browser-stagehand-cdp-20260924/extension-to-host-requests.json):
   an extract schema, the extract progress schema, and an act schema over an
   accessibility tree. The provider is a local HTTP server that answers with a
   recorded OpenAI-compatible body. *)

open Masc
module Model = Browser_stagehand_model
module EO = Agent_core.Exact_output
module F = Exact_output_fixture
module U = Yojson.Safe.Util

let recorded_params =
  lazy
    (match Yojson.Safe.from_file "fixtures/stagehand/llm-generate-params.json" with
     | `List [ extract; progress; act ] -> extract, progress, act
     | _ -> Alcotest.fail "the fixture holds the three recorded llm.generate params")
;;

let lane_id = Standalone_lane.to_id Standalone_lane.Browser_stagehand
let slot_id = "stagehand-fixture.model"
let second_slot_id = "stagehand-fixture.model-second"
let answer = `Assoc [ "action", `Null; "twoStep", `Bool false ]

(* One catalog target on the fixture server. [system_prompt] is the model's
   declared support for a system prompt. *)
let resolver_snapshot ~base_url ~system_prompt =
  let contents =
    Printf.sprintf
      "[[providers]]\n\
       id = \"stagehand-fixture\"\n\
       kind = \"openai_compat\"\n\
       base_url = %S\n\
       request_path = \"/v1/chat/completions\"\n\
       api_key_env = \"\"\n\n\
       [[models]]\n\
       id_prefix = \"model\"\n\
       provider_name = \"stagehand-fixture\"\n\
       max_context_tokens = 65536\n\
       max_output_tokens = 4096\n\
       supports_response_format_json = true\n\
       supports_structured_output = true\n\
       supports_system_prompt = %b\n\n\
       [[targets]]\n\
       id = %S\n\
       provider_ref = \"stagehand-fixture\"\n\
       model_id = \"model\"\n\
       connect_timeout_s = %g\n\
       body_timeout_s = %g\n\n\
       [[targets]]\n\
       id = %S\n\
       provider_ref = \"stagehand-fixture\"\n\
       model_id = \"model\"\n\
       connect_timeout_s = %g\n\
       body_timeout_s = %g\n"
      base_url
      system_prompt
      slot_id
      F.fixture_post_connect_timeout_seconds
      F.fixture_wait_seconds
      second_slot_id
      F.fixture_post_connect_timeout_seconds
      F.fixture_wait_seconds
  in
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  match
    EO.load_resolver_snapshot
      ~io
      ~catalog:(EO.Full_replacement { source = "stagehand model test"; contents })
      ()
  with
  | Ok snapshot -> snapshot
  | Error _ -> Alcotest.fail "the stagehand catalog fixture did not load"
;;

let resolved_lane ?(cli_slot_ids = []) ?(slot_ids = [ slot_id ]) ~base_url ~system_prompt () =
  let registry =
    F.publish_registry
      ~cli_slot_ids
      ~lane_id
      ~slot_ids
      (resolver_snapshot ~base_url ~system_prompt)
  in
  match Runtime_exact_output_registry.resolve_lane registry ~lane_id with
  | Ok resolved -> resolved
  | Error error ->
    Alcotest.failf
      "the fixture lane did not resolve: %s"
      (Runtime_exact_output_registry.lane_resolution_error_to_string error)
;;

let openai_body_for ~output ~usage =
  Printf.sprintf
    {|{"id":"stagehand-fixture","model":"model","choices":[{"index":0,"message":{"role":"assistant","content":%s},"finish_reason":"stop"}]%s}|}
    (Yojson.Safe.to_string (`String (Yojson.Safe.to_string output)))
    usage
;;

let openai_body ~usage = openai_body_for ~output:answer ~usage

let with_provider behavior f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let server = F.start_server ~sw ~net ~clock behavior in
  f ~net ~clock server
;;

let generate ?cli_runner ~net ~clock resolved params =
  Model.create
    ?cli_runner
    ~net
    ~clock
    ~base_path:(Sys.getcwd ())
    ~resolve_lane:(fun () -> Ok resolved)
    params
;;

let test_recorded_params_parse () =
  let extract, progress, act = Lazy.force recorded_params in
  let check_one label ~name params =
    match Model.parse_params params with
    | Error detail -> Alcotest.failf "%s did not parse: %s" label detail
    | Ok request ->
      (match request.Model.generation with
       | Model.Structured { name = parsed; schema = `Assoc _ } ->
         Alcotest.(check string) (label ^ " schema name") name parsed
       | Model.Structured _ | Model.Text_generation | Model.Tool_generation _ ->
         Alcotest.failf "%s is not a structured request" label);
      (match request.Model.messages with
       | [ { Model.role = Model.User; content = [ Model.Text text ] } ] ->
         Alcotest.(check bool) (label ^ " carries its prompt") true (String.length text > 0)
       | _ -> Alcotest.failf "%s is not one user text message" label);
      Alcotest.(check bool)
        (label ^ " carries a system prompt")
        true
        (Option.is_some request.Model.system_prompt);
      Alcotest.(check (option (float 0.))) (label ^ " temperature") None request.Model.temperature
  in
  check_one "extract" ~name:"Extraction" extract;
  check_one "progress" ~name:"Metadata" progress;
  check_one "act" ~name:"Act" act
;;

let test_answer_carries_reported_usage () =
  let _, _, act = Lazy.force recorded_params in
  let usage =
    {|,"usage":{"prompt_tokens":1200,"completion_tokens":30,"total_tokens":1230,"prompt_tokens_details":{"cached_tokens":1024}}|}
  in
  with_provider (F.Reply (openai_body ~usage))
  @@ fun ~net ~clock server ->
  let resolved = resolved_lane ~base_url:server.base_url ~system_prompt:true () in
  match generate ~net ~clock resolved act with
  | Error { Browser_stagehand_wire.message; _ } ->
    Alcotest.failf "the act request was refused: %s" message
  | Ok result ->
    Alcotest.(check int) "one provider call" 1 (F.post_count server);
    Alcotest.(check string) "role" "assistant" U.(result |> member "role" |> to_string);
    Alcotest.(check string)
      "output format"
      "json_schema"
      U.(result |> member "output_format" |> to_string);
    Alcotest.(check bool)
      "structured content is the model's JSON"
      true
      (Yojson.Safe.equal answer (U.member "structured_content" result));
    Alcotest.(check string)
      "text content is the same JSON"
      (Yojson.Safe.to_string answer)
      U.(result |> member "content" |> member "text" |> to_string);
    Alcotest.(check bool)
      "usage has exactly the reported counts"
      true
      (Yojson.Safe.equal
         (`Assoc
             [ "input_tokens", `Int 1200
             ; "output_tokens", `Int 30
             ; "total_tokens", `Int 1230
             ; "cached_input_tokens", `Int 1024
             ])
         (U.member "usage" result));
    (* Stagehand's system_prompt reaches the provider as the system message,
       and the user's text follows it. AGENT_CORE appends its own schema
       instruction after them, which is its business, not this lane's. *)
    let sent =
      match F.request_bodies server with
      | [ body ] -> Yojson.Safe.from_string body
      | _ -> Alcotest.fail "expected one request body"
    in
    let message position field =
      U.(sent |> member "messages" |> index position |> member field |> to_string)
    in
    Alcotest.(check string) "first role" "system" (message 0 "role");
    Alcotest.(check string)
      "the system message is Stagehand's system_prompt"
      U.(act |> member "system_prompt" |> to_string)
      (message 0 "content");
    Alcotest.(check string) "second role" "user" (message 1 "role");
    Alcotest.(check string)
      "the user message is Stagehand's text"
      U.(act |> member "messages" |> index 0 |> member "content" |> member "text" |> to_string)
      (message 1 "content")
;;

let test_unreported_usage_is_left_out () =
  let extract, _, _ = Lazy.force recorded_params in
  List.iter
    (fun (name, usage) ->
       with_provider (F.Reply (openai_body ~usage))
       @@ fun ~net ~clock server ->
       let resolved = resolved_lane ~base_url:server.base_url ~system_prompt:true () in
       match generate ~net ~clock resolved extract with
       | Error { Browser_stagehand_wire.message; _ } ->
         Alcotest.failf "%s: the extract request was refused: %s" name message
       | Ok (`Assoc fields) ->
         Alcotest.(check bool) (name ^ ": no usage key") false (List.mem_assoc "usage" fields);
         Alcotest.(check bool) (name ^ ": an answer") true (List.mem_assoc "structured_content" fields)
       | Ok _ -> Alcotest.failf "%s: the answer is not an object" name)
    [ "absent", ""
    ; "empty object", {|,"usage":{}|}
    ; "missing output count", {|,"usage":{"prompt_tokens":12}|}
    ]
;;

let contains ~affix text =
  let affix_length = String.length affix in
  let rec from index =
    index + affix_length <= String.length text
    && (String.equal (String.sub text index affix_length) affix || from (index + 1))
  in
  from 0
;;

let set key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> Alcotest.fail "params must be an object"
;;

let remove key = function
  | `Assoc fields -> `Assoc (List.remove_assoc key fields)
  | _ -> Alcotest.fail "params must be an object"
;;

(* Refused before the lane is even resolved, so no provider is called. *)
let test_unserved_requests_are_refused () =
  let extract, _, _ = Lazy.force recorded_params in
  let never_resolved () = Alcotest.fail "a refused request must not resolve the lane" in
  let refuse label params expected =
    Eio_main.run
    @@ fun env ->
    match
      Model.create
        ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env)
        ~base_path:(Sys.getcwd ())
        ~resolve_lane:never_resolved
        params
    with
    | Ok _ -> Alcotest.failf "%s was answered" label
    | Error { Browser_stagehand_wire.code; message } ->
      Alcotest.(check int) (label ^ " code") Browser_stagehand_wire.host_refused code;
      Alcotest.(check string) (label ^ " reason") (Model.refusal_to_string expected) message
  in
  refuse "text generation" (remove "response_format" extract)
    (Model.Generation_not_served Model.Text_generation_requested);
  refuse
    "tool generation"
    (extract
     |> set "response_format" (`Assoc [ "type", `String "text" ])
     |> set "tools" (`List [ `Assoc [ "name", `String "click" ] ]))
    (Model.Generation_not_served (Model.Tool_generation_requested { tool_names = [ "click" ] }));
  refuse
    "image block"
    (set
       "messages"
       (`List
           [ `Assoc
               [ "role", `String "user"
               ; ( "content"
                 , `List
                     [ `Assoc [ "type", `String "text"; "text", `String "what is this" ]
                     ; `Assoc
                         [ "type", `String "image"
                         ; "data", `String ""
                         ; "mime_type", `String "image/png"
                         ]
                     ] )
               ]
           ])
       extract)
    (Model.Content_not_served Model.Image_block)
;;

let test_lane_admits_only_system_prompt_slots () =
  let _, _, act = Lazy.force recorded_params in
  with_provider (F.Reply (openai_body ~usage:""))
  @@ fun ~net ~clock server ->
  let resolved = resolved_lane ~base_url:server.base_url ~system_prompt:false () in
  let refused_slots =
    match Model.admit_lane resolved with
    | Error
        (Model.No_slot_admitted
           ([ { slot_id = refused; refusal = Model.System_prompt_not_accepted } ] as refused_slots))
      ->
      Alcotest.(check string) "the refused slot" slot_id refused;
      refused_slots
    | Error _ | Ok _ -> Alcotest.fail "a slot that takes no system prompt must be refused"
  in
  (match generate ~net ~clock resolved act with
   | Ok _ -> Alcotest.fail "a lane with no admitted slot answered"
   | Error { Browser_stagehand_wire.message; _ } ->
     Alcotest.(check string)
       "the refusal names the lane admission"
       (Model.refusal_to_string (Model.Lane_refused (Model.No_slot_admitted refused_slots)))
       message);
  Alcotest.(check int) "no provider call" 0 (F.post_count server);
  let with_cli =
    resolved_lane
      ~cli_slot_ids:[ F.cli_primary_runtime ]
      ~base_url:"http://127.0.0.1:9"
      ~system_prompt:true
      ()
  in
  match Model.admit_lane with_cli with
  | Ok { Model.cli_slots = [ cli ]; http_slots = [ _ ]; refused_slots = [] } ->
    Alcotest.(check string) "the declared cli slot is kept" F.cli_primary_runtime cli
  | Ok _ -> Alcotest.fail "the lane keeps its HTTP slot and its one cli slot"
  | Error refusal ->
    Alcotest.failf
      "a lane that declares cli_slots was refused: %s"
      (Model.refusal_to_string (Model.Lane_refused refusal))
;;

(* A subscription CLI slot answers when no HTTP slot can: the lane's only HTTP
   slot takes no system prompt, so the request goes straight to the CLI tail.
   The one-shot gets Stagehand's system prompt as its own argument and the
   user text as its prompt; its answer carries no usage. *)
let test_cli_slot_answers () =
  let _, _, act = Lazy.force recorded_params in
  let expected_system = U.(act |> member "system_prompt" |> to_string) in
  let expected_user =
    U.(act |> member "messages" |> index 0 |> member "content" |> member "text" |> to_string)
  in
  let calls = ref [] in
  let cli_runner : Keeper_lane_cli_oneshot.runner =
    fun ~runtime_id ~system_prompt ~output_schema:_ ~prompt ->
    calls := (runtime_id, system_prompt, prompt) :: !calls;
    Ok (Yojson.Safe.to_string answer)
  in
  F.with_official_client_runtimes
  @@ fun () ->
  with_provider (F.Reply (openai_body ~usage:""))
  @@ fun ~net ~clock server ->
  let resolved =
    resolved_lane
      ~cli_slot_ids:[ F.cli_primary_runtime ]
      ~base_url:server.base_url
      ~system_prompt:false
      ()
  in
  (match generate ~cli_runner ~net ~clock resolved act with
   | Error { Browser_stagehand_wire.message; _ } ->
     Alcotest.failf "a lane with a cli slot refused the act request: %s" message
   | Ok (`Assoc fields) ->
     Alcotest.(check bool)
       "structured content is the cli answer"
       true
       (match List.assoc_opt "structured_content" fields with
        | Some content -> Yojson.Safe.equal answer content
        | None -> false);
     Alcotest.(check bool) "no usage key" false (List.mem_assoc "usage" fields)
   | Ok _ -> Alcotest.fail "the answer is not an object");
  Alcotest.(check int) "no HTTP provider call" 0 (F.post_count server);
  match !calls with
  | [ (runtime_id, system_prompt, prompt) ] ->
    Alcotest.(check string) "the cli slot ran" F.cli_primary_runtime runtime_id;
    Alcotest.(check string) "Stagehand's system prompt" expected_system system_prompt;
    Alcotest.(check bool)
      "the prompt starts with the user text"
      true
      (String.length prompt >= String.length expected_user
       && String.equal expected_user (String.sub prompt 0 (String.length expected_user)))
  | calls -> Alcotest.failf "expected one cli call, got %d" (List.length calls)
;;

(* A failed HTTP slot hands the request to the CLI tail. *)
let test_cli_slot_follows_failed_http_slot () =
  let _, progress, _ = Lazy.force recorded_params in
  let cli_runner : Keeper_lane_cli_oneshot.runner =
    fun ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
    Ok (Yojson.Safe.to_string answer)
  in
  F.with_official_client_runtimes
  @@ fun () ->
  with_provider (F.Reply_with (fun _ _ -> `Internal_server_error, {|{"error":"down"}|}))
  @@ fun ~net ~clock server ->
  let resolved =
    resolved_lane
      ~cli_slot_ids:[ F.cli_primary_runtime ]
      ~base_url:server.base_url
      ~system_prompt:true
      ()
  in
  match generate ~cli_runner ~net ~clock resolved progress with
  | Error { Browser_stagehand_wire.message; _ } ->
    Alcotest.failf "the cli tail did not answer after the HTTP slot failed: %s" message
  | Ok result ->
    Alcotest.(check int) "the HTTP slot was tried once" 1 (F.post_count server);
    Alcotest.(check bool)
      "structured content is the cli answer"
      true
      (Yojson.Safe.equal answer (U.member "structured_content" result))
;;

let test_provider_failure_is_a_refusal () =
  let _, progress, _ = Lazy.force recorded_params in
  with_provider (F.Reply_with (fun _ _ -> `Internal_server_error, {|{"error":"down"}|}))
  @@ fun ~net ~clock server ->
  let resolved = resolved_lane ~base_url:server.base_url ~system_prompt:true () in
  match generate ~net ~clock resolved progress with
  | Ok _ -> Alcotest.fail "a failed provider produced an answer"
  | Error { Browser_stagehand_wire.code; message } ->
    Alcotest.(check int) "code" Browser_stagehand_wire.host_refused code;
    Alcotest.(check int) "the provider was called once" 1 (F.post_count server);
    Alcotest.(check bool) "the reason names the slot" true (contains ~affix:slot_id message)
;;

let test_missing_nested_required_key_advances_to_second_http_slot () =
  let _, _, act = Lazy.force recorded_params in
  let incomplete =
    `Assoc
      [ "action", `Assoc [ "method", `String "click" ]
      ; "twoStep", `Bool false
      ]
  in
  with_provider
    (F.Replies
       [ openai_body_for ~output:incomplete ~usage:""
       ; openai_body_for ~output:answer ~usage:""
       ])
  @@ fun ~net ~clock server ->
  let resolved =
    resolved_lane ~slot_ids:[ slot_id; second_slot_id ]
      ~base_url:server.base_url ~system_prompt:true ()
  in
  match generate ~net ~clock resolved act with
  | Error { Browser_stagehand_wire.message; _ } ->
    Alcotest.failf "the second HTTP slot did not answer: %s" message
  | Ok result ->
    Alcotest.(check int) "the incomplete first answer advanced" 2 (F.post_count server);
    Alcotest.(check bool) "the accepted answer is the second slot's value" true
      (Yojson.Safe.equal answer (U.member "structured_content" result))
;;

let () =
  Alcotest.run
    "browser_stagehand_model"
    [ ( "llm.generate"
      , [ Alcotest.test_case "the recorded params parse" `Quick test_recorded_params_parse
        ; Alcotest.test_case
            "an answer carries the reported usage"
            `Quick
            test_answer_carries_reported_usage
        ; Alcotest.test_case
            "unreported usage is left out"
            `Quick
            test_unreported_usage_is_left_out
        ; Alcotest.test_case
            "text, tool and image requests are refused"
            `Quick
            test_unserved_requests_are_refused
        ; Alcotest.test_case
            "the lane admits only slots that take a system prompt"
            `Quick
            test_lane_admits_only_system_prompt_slots
        ; Alcotest.test_case
            "a provider failure is a refusal"
            `Quick
            test_provider_failure_is_a_refusal
        ; Alcotest.test_case
            "missing nested required key advances to second HTTP slot"
            `Quick
            test_missing_nested_required_key_advances_to_second_http_slot
        ; Alcotest.test_case "a cli slot answers" `Quick test_cli_slot_answers
        ; Alcotest.test_case
            "a cli slot follows a failed HTTP slot"
            `Quick
            test_cli_slot_follows_failed_http_slot
        ] )
    ]
;;
