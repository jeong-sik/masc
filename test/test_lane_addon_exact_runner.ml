(* A package's exact-output request runs through the real declared HTTP walk
   against a loopback provider, then through Lane_addon_exact.run. Only the
   official-client process edge is injected; no live provider is used. *)
open Alcotest
open Masc
module F = Exact_output_fixture
module Exact = Lane_addon_exact
module Types = Lane_addon_types

let () = Mirage_crypto_rng_unix.use_default ()

let declaration_id = "quiz"
let lane_id = "quiz/author"

let schema =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc [ "question", `Assoc [ "type", `String "string" ] ]
    ; "required", `List [ `String "question" ]
    ; "additionalProperties", `Bool false
    ]

let package : Types.package =
  { id = "operator-quiz"; revision = "1"; title = "Exact runner fixture"
  ; contributions = [ Types.Observe ]; command = [ "unused" ]
  ; directory = "/nonexistent"; skills_directory = None; action_tool = None
  ; state_storage = Types.Ephemeral; tool_invocation = Types.Direct; tool_hooks = []; worker_service = Types.Mcp_tools; exported_tools = []; outputs = []
  ; refresh_policy = Types.Every_hint; model_access = Types.Model_disabled
  ; exact_outputs = [ { Types.name = "author"; schema; request_schema=Types.Package_schema_only } ]; operator_asks = false
  ; binding_schema = None; presentation = Lane_addon_presentation.empty
  ; execution = Types.Container { runtime = Types.Docker; image = "unused"
      ; resources = { cpus = 0.5; memory_bytes = 134217728L; pids = Some 16; max_reply_bytes = 65536 } } }

let user text = `Assoc [ "role", `String "user"; "text", `String text ]
let assistant text = `Assoc [ "role", `String "assistant"; "text", `String text ]

let request ?schema ?(messages = [user "Write one question about the ledger."]) id =
  match
    Exact.request_of_json
      (`Assoc
         ([ "kind", `String "exact_output"; "request_id", `String id; "output", `String "author"
         ; "system", `String "You write quiz questions."
         ; "messages", `List messages ] @ (match schema with None -> [] | Some schema -> ["schema",schema])))
  with
  | Ok request -> request
  | Error detail -> fail detail

let question = `Assoc [ "question", `String "What does the ledger record?" ]
let refusal_body kind = Printf.sprintf {|{"error":{"message":"fixture refusal","type":%S}}|} kind

let with_case f =
  let base_path = Filename.temp_dir "lane-exact-runner-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
       Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path)
       @@ fun () ->
       Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path "config"))
       @@ fun () ->
       F.with_official_client_runtimes
       @@ fun () ->
       Eio_main.run
       @@ fun env ->
       Eio.Switch.run
       @@ fun sw ->
       let net = Eio.Stdenv.net env in
       let clock = Eio.Stdenv.clock env in
       Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
       @@ fun () ->
       let store = Lane_addon_store.create ~root:(Filename.concat base_path "lane-addons") in
       f ~sw ~net ~clock ~base_path ~store)

let publish ?(lane_id = lane_id) ?(cli_slots = []) ~base_path targets =
  ignore
    (F.publish_registry ~lane_id
       ~slot_ids:(List.map (fun (target : F.target_fixture) -> target.id) targets)
       ~cli_slot_ids:cli_slots
       (F.resolver_snapshot ~source:base_path targets)
     : Runtime_exact_output_registry.t)

let run_request ?(package=package) ?runner ?schema ?messages ~base_path ~store id =
  let runner = Option.value runner ~default:(Server_lane_addon_exact.runner ~base_path) in
  match Exact.run ~validate_request:(Server_lane_addon_exact.validate_request ~base_path) ~store ~declaration_id ~package ~runner (request ?schema ?messages id) with
  | Ok attempt -> attempt
  | Error detail -> fail detail

let answered_by = function
  | Exact.Final (Exact.Call_final (Exact.Answered { output; slot; usage })) -> Some (Exact.checked_json output, slot, usage)
  | Exact.Final _ | Exact.Not_final _ -> None

let test_an_answer_that_matches_the_schema_is_answered () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response question)) in
    publish ~base_path [ { F.id = "glm"; base_url = server.base_url } ];
    (match answered_by (run_request ~base_path ~store "a1") with
     | Some (output, slot, usage) ->
       check bool "the answer is delivered" true (output = question);
       check string "from the slot that gave it" "glm" slot;
       check bool "with the provider's usage" true (usage = Some { Exact.input_tokens = 1; output_tokens = 1 })
     | None -> fail "a matching answer must be answered");
    match F.request_bodies server with
    | [ body ] ->
      let contains text =
        let rec at i = i + String.length text <= String.length body
                       && (String.sub body i (String.length text) = text || at (i + 1)) in
        at 0
      in
      check bool "the package's system text is sent" true (contains "You write quiz questions.");
      check bool "and its message" true (contains "Write one question about the ledger.")
    | bodies -> failf "expected one request, got %d" (List.length bodies))

let test_an_answer_outside_the_schema_advances () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let wrong = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response (`Assoc [ "title", `String "x" ]))) in
    let right = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response question)) in
    publish ~base_path [ { F.id = "first"; base_url = wrong.base_url }; { F.id = "second"; base_url = right.base_url } ];
    (match answered_by (run_request ~base_path ~store "a2") with
     | Some (_, slot, _) -> check string "the next slot answers" "second" slot
     | None -> fail "the second slot's answer must be answered");
    check int "the first slot was asked once" 1 (F.post_count wrong))

let test_every_answer_outside_the_schema_is_invalid_output () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response (`Assoc [ "title", `String "x" ]))) in
    publish ~base_path [ { F.id = "only"; base_url = server.base_url } ];
    (match run_request ~base_path ~store "a3" with
     | Exact.Final (Exact.Call_final (Exact.Invalid_output _)) -> ()
     | _ -> fail "an answer no slot could give must be invalid_output");
    check bool "and it is final: the next run does not call again" true
      (match run_request ~base_path ~store "a3" with Exact.Final (Exact.Call_final (Exact.Invalid_output _)) -> true | _ -> false);
    check int "one call" 1 (F.post_count server))

let limited_response =
  {|{"id":"output-limit","model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":"{\"question\":\"partial\"}"},"finish_reason":"length"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}|}

let test_output_limit_retains_an_original_distinct_terminal () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server=F.start_server ~sw ~net ~clock (F.Reply limited_response) in
    publish ~base_path [{F.id="limited";base_url=server.base_url}];
    let original=run_request ~base_path ~store "original-output-limit" in
    let wire=match original with
      | Exact.Final (Exact.Call_final (Exact.Output_limit_reached _) as final) -> Exact.final_to_json final
      | Exact.Final _ | Exact.Not_final _ -> fail "an actual provider output limit must keep its typed terminal" in
    check bool "strict original result codec round trips the terminal" true
      (match Exact.final_of_json ~schema wire with
       | Ok (Exact.Call_final (Exact.Output_limit_reached _)) -> true
       | Ok _ | Error _ -> false);
    (match wire with
     | `Assoc fields -> check bool "unknown terminal fields are refused" true
         (Result.is_error (Exact.final_of_json ~schema (`Assoc (("permission",`Bool true)::fields))))
     | _ -> fail "terminal wire must be an object");
    check bool "blank output-limit detail is not a valid shared terminal" true
      (Result.is_error (Exact.final_of_json ~schema (`Assoc ["status",`String "output_limit_reached";"detail",`String " "])));
    let reopened=Lane_addon_store.create ~root:(Lane_addon_store.root store) in
    check bool "reopened original retains the terminal" true
      (original=run_request ~base_path ~store:reopened "original-output-limit");
    check int "recovery never redispatches that original request" 1 (F.post_count server))

let test_output_limit_still_advances_to_a_valid_http_candidate () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let limited=F.start_server ~sw ~net ~clock (F.Reply limited_response) in
    let valid=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response question)) in
    publish ~base_path [{F.id="limited";base_url=limited.base_url};{F.id="valid";base_url=valid.base_url}];
    (match answered_by (run_request ~base_path ~store "limit-then-valid") with
     | Some (_,slot,_) -> check string "the original walk advances" "valid" slot
     | None -> fail "a valid later candidate must still answer");
    check int "the limited candidate ran once" 1 (F.post_count limited))

type remaining_slot = Busy | Auth | Configuration | Input
let test_output_limit_does_not_override_another_refusal kind () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let limited=F.start_server ~sw ~net ~clock (F.Reply limited_response) in
    let status,body=match kind with
      | Busy -> `Too_many_requests,refusal_body "rate_limit_error"
      | Auth -> `Unauthorized,refusal_body "authentication_error"
      | Configuration -> `Not_found,refusal_body "not_found_error"
      | Input -> `Bad_request,refusal_body "invalid_request_error" in
    let other=F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ -> status,body)) in
    publish ~base_path [{F.id="limited";base_url=limited.base_url};{F.id="other";base_url=other.base_url}];
    let outcome=run_request ~base_path ~store "limit-priority" in
    let expected=match kind,outcome with
      | Busy,Exact.Not_final (Exact.Provider_refused (Exact.Provider_unavailable _))
      | Auth,Exact.Not_final (Exact.Provider_refused (Exact.Provider_auth_refused _))
      | Configuration,Exact.Not_final (Exact.Provider_refused (Exact.Provider_configuration_refused _))
      | Input,Exact.Final (Exact.Call_final (Exact.Input_refused Exact.Invalid_request)) -> true
      | (Busy|Auth|Configuration|Input),(Exact.Final _|Exact.Not_final _) -> false in
    check bool "the original refusal priority is preserved" true expected)

let test_measurement_failure_is_not_a_terminal_input_size_refusal () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server=F.start_server ~sw ~net ~clock (F.Reply "not-a-token-measurement") in
    ignore (F.publish_registry ~lane_id ~slot_ids:["measurement"]
      (F.resolver_snapshot ~requires_token_measurement:true ~source:base_path
        [{F.id="measurement";base_url=server.base_url}]) : Runtime_exact_output_registry.t);
    (match run_request ~base_path ~store "measurement-unavailable" with
     | Exact.Not_final (Exact.Provider_refused (Exact.Provider_unavailable _)) -> ()
     | Exact.Final _ | Exact.Not_final _ -> fail "missing measurement is not proof that input is too big");
    check (list string) "only token measurement was dispatched" ["/v1/messages/count_tokens"] (F.request_paths server))

let test_output_limit_keeps_the_original_cli_tail ~valid () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server=F.start_server ~sw ~net ~clock (F.Reply limited_response) in
    publish ~base_path ~cli_slots:[F.cli_primary_runtime] [{F.id="limited";base_url=server.base_url}];
    let calls=ref 0 in
    let cli_runner : Keeper_lane_cli_oneshot.runner = fun ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
      incr calls;Ok (if valid then Yojson.Safe.to_string question else "not JSON; output_limit_reached is only text here") in
    let runner=Server_lane_addon_exact.For_testing.runner ~base_path ~cli_runner in
    let outcome=run_request ~runner ~base_path ~store "output-limit-cli" in
    if valid then check bool "the later official client can still answer" true (Option.is_some (answered_by outcome))
    else check bool "an invalid later answer does not erase the actual output limit" true
      (match outcome with Exact.Final (Exact.Call_final (Exact.Output_limit_reached _)) -> true
       | Exact.Final _ | Exact.Not_final _ -> false);
    check int "the declared official-client candidate runs once" 1 !calls)

type capacity_evidence = Expired | Not_yet_valid | Boundary_unknown | Input_rejected
let test_original_capacity_evidence_keeps_its_retry_meaning kind () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let serving_constraint : F.serving_constraint = match kind with
      | Expired -> {checked_at_unix_s=0;expires_at_unix_s=1;accepted_through_tokens=1;rejected_from_tokens=3}
      | Not_yet_valid -> {checked_at_unix_s=1900000000;expires_at_unix_s=2000000000;accepted_through_tokens=1;rejected_from_tokens=3}
      | Boundary_unknown | Input_rejected ->
        {checked_at_unix_s=0;expires_at_unix_s=2000000000;accepted_through_tokens=1;rejected_from_tokens=3} in
    let measured=match kind with Input_rejected -> 3 | Expired | Not_yet_valid | Boundary_unknown -> 2 in
    let server=F.start_server ~sw ~net ~clock
      (F.Reply (Yojson.Safe.to_string (`Assoc ["input_tokens",`Int measured]))) in
    ignore (F.publish_registry ~lane_id ~slot_ids:["capacity-evidence"]
      (F.resolver_snapshot ~requires_token_measurement:true ~serving_constraint ~source:base_path
        [{F.id="capacity-evidence";base_url=server.base_url}]) : Runtime_exact_output_registry.t);
    let outcome=run_request ~base_path ~store "original-capacity-evidence" in
    let expected=match kind,outcome with
      | Input_rejected,Exact.Final (Exact.Call_final (Exact.Input_refused Exact.Input_capacity))
      | (Expired|Not_yet_valid|Boundary_unknown),Exact.Not_final (Exact.Provider_refused (Exact.Provider_unavailable _)) -> true
      | (Expired|Not_yet_valid|Boundary_unknown|Input_rejected),(Exact.Final _|Exact.Not_final _) -> false in
    check bool "only an actual input rejection is terminal" true expected;
    check (list string) "no generation was dispatched" ["/v1/messages/count_tokens"] (F.request_paths server))

let test_a_refused_input_is_final () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server =
      F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ -> `Bad_request, refusal_body "invalid_request_error"))
    in
    publish ~base_path [ { F.id = "only"; base_url = server.base_url } ];
    match run_request ~base_path ~store "a4" with
    | Exact.Final (Exact.Call_final (Exact.Input_refused Exact.Invalid_request)) -> ()
    | _ -> fail "a 400 refusal of the request must be input_refused")

let test_a_rate_limit_is_not_final_and_is_sent_again () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server =
      F.start_server ~sw ~net ~clock
        (F.Reply_with (fun index _ ->
           if index = 0 then `Too_many_requests, refusal_body "rate_limit_error"
           else `OK, F.openai_response question))
    in
    publish ~base_path [ { F.id = "only"; base_url = server.base_url } ];
    (match run_request ~base_path ~store "a5" with
     | Exact.Not_final (Exact.Provider_refused (Exact.Provider_unavailable _)) -> ()
     | _ -> fail "a rate limit must not end the request");
    check bool "the next trigger sends again and answers" true (answered_by (run_request ~base_path ~store "a5") <> None);
    check int "two calls" 2 (F.post_count server))

let test_an_auth_refusal_is_not_final () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server =
      F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ -> `Unauthorized, refusal_body "authentication_error"))
    in
    publish ~base_path [ { F.id = "only"; base_url = server.base_url } ];
    match run_request ~base_path ~store "a6" with
    | Exact.Not_final (Exact.Provider_refused (Exact.Provider_auth_refused _)) -> ()
    | _ -> fail "an authentication refusal must not end the request")

let test_a_slot_that_may_pass_keeps_the_request_open () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let busy = F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ -> `Too_many_requests, refusal_body "rate_limit_error")) in
    let refusing = F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ -> `Bad_request, refusal_body "invalid_request_error")) in
    publish ~base_path [ { F.id = "busy"; base_url = busy.base_url }; { F.id = "refusing"; base_url = refusing.base_url } ];
    match run_request ~base_path ~store "a7" with
    | Exact.Not_final (Exact.Provider_refused (Exact.Provider_unavailable _)) -> ()
    | _ -> fail "an input refusal must not end the request while another slot may still answer")

let test_an_unconfigured_lane_sends_nothing () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response question)) in
    ignore
      (F.publish_registry ~lane_id:"quiz/grade" ~slot_ids:[ "only" ]
         (F.resolver_snapshot ~source:base_path [ { F.id = "only"; base_url = server.base_url } ])
       : Runtime_exact_output_registry.t);
    check bool "a declared output without a lane table is unconfigured" true
      (run_request ~base_path ~store "a8" = Exact.Not_final (Exact.Lane_unavailable Exact.Lane_unconfigured));
    check int "and nothing was sent" 0 (F.post_count server))

let test_an_off_lane_sends_nothing () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response question)) in
    let owner = Option.get (Runtime_schema.exact_lane_owner_of_key lane_id) in
    let lane : Runtime_schema.exact_output_lane_decl =
      { owner; enabled = false; slot_ids = [ "only" ]; cli_slot_ids = []; max_output_tokens = None; thinking = None }
    in
    (match
       Runtime_exact_output_registry.publish ~lanes:[ lane ]
         (F.resolver_snapshot ~source:base_path [ { F.id = "only"; base_url = server.base_url } ])
     with
     | Ok _ -> ()
     | Error error -> fail (Runtime_exact_output_registry.publication_error_to_string error));
    check bool "an off lane is not final" true
      (run_request ~base_path ~store "a9" = Exact.Not_final (Exact.Lane_unavailable Exact.Lane_off));
    check int "and nothing was sent" 0 (F.post_count server))

let test_the_cli_tail_answers_after_the_http_slots () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response (`Assoc [ "title", `String "x" ]))) in
    publish ~base_path ~cli_slots:[ F.cli_primary_runtime ] [ { F.id = "http"; base_url = server.base_url } ];
    let prompts = ref [] in
    let cli_runner : Keeper_lane_cli_oneshot.runner =
      fun ~runtime_id:_ ~system_prompt ~output_schema:_ ~prompt ->
      prompts := (system_prompt, prompt) :: !prompts;
      Ok (Yojson.Safe.to_string question)
    in
    let runner = Server_lane_addon_exact.For_testing.runner ~base_path ~cli_runner in
    (match answered_by (run_request ~runner ~base_path ~store "a10") with
     | Some (_, slot, _) -> check string "the official client answers" F.cli_primary_runtime slot
     | None -> fail "the CLI tail's matching answer must be answered");
    match !prompts with
    | [ (system_prompt, prompt) ] ->
      check string "the client gets the package's system text" "You write quiz questions." system_prompt;
      check bool "and its message first" true
        (String.starts_with ~prefix:"Write one question about the ledger." prompt)
    | prompts -> failf "expected one client call, got %d" (List.length prompts))

let conversation = [user "Find the menu."; assistant "There are two menus."; user "Choose the account menu."]

let test_http_preserves_conversation_roles () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response question)) in
    publish ~base_path [{F.id="http";base_url=server.base_url}];
    check bool "the conversation answers" true
      (answered_by (run_request ~messages:conversation ~base_path ~store "roles") <> None);
    match F.request_bodies server with
    | [body] ->
        let open Yojson.Safe.Util in
        let messages = Yojson.Safe.from_string body |> member "messages" |> to_list in
        check (list string) "HTTP preserves original roles before the common schema instruction"
          ["system";"user";"assistant";"user";"user"]
          (List.map (fun message -> message |> member "role" |> to_string) messages);
        check (list string) "original conversation text is unchanged"
          ["You write quiz questions.";"Find the menu.";"There are two menus.";"Choose the account menu."]
          (List.take 4 messages |> List.map (fun message -> message |> member "content" |> to_string));
        let requirement=Agent_core.Exact_output.make_output_requirement ~schema
          ~minimum_guarantee:Agent_core.Exact_output.Json_syntax in
        check string "the only appended turn is the common schema instruction"
          (Agent_core.Exact_output.schema_instruction_text requirement)
          (List.nth messages 4 |> member "content" |> to_string);
        check string "the assistant's text belongs to the assistant turn" "There are two menus."
          (List.nth messages 2 |> member "content" |> to_string)
    | bodies -> failf "expected one HTTP request, got %d" (List.length bodies))

let test_cli_refuses_assistant_without_dispatch () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server = F.start_server ~sw ~net ~clock
      (F.Reply (F.openai_response (`Assoc ["wrong",`String "shape"]))) in
    publish ~base_path ~cli_slots:[F.cli_primary_runtime] [{F.id="http";base_url=server.base_url}];
    let cli_calls = ref 0 in
    let cli_runner : Keeper_lane_cli_oneshot.runner =
      fun ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
        incr cli_calls; Ok (Yojson.Safe.to_string question)
    in
    let runner = Server_lane_addon_exact.For_testing.runner ~base_path ~cli_runner in
    (match run_request ~runner ~messages:conversation ~base_path ~store "cli-history" with
     | Exact.Not_final (Exact.Provider_refused (Exact.Provider_configuration_refused _)) -> ()
     | _ -> fail "an incompatible CLI tail must preserve the unresolved conversation");
    check int "the HTTP path was attempted" 1 (F.post_count server);
    check int "the CLI process was never entered" 0 !cli_calls;
    (* A configuration event can select a capable HTTP slot. The same request
       then answers without rewriting its retained body or replaying input. *)
    let capable = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response question)) in
    publish ~base_path [{F.id="capable";base_url=capable.base_url}];
    check bool "the original request answers after configuration changes" true
      (answered_by (run_request ~runner ~messages:conversation ~base_path ~store "cli-history") <> None);
    check int "one capable call" 1 (F.post_count capable))

let test_requested_shape_advances_http_without_replacing_baseline () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let wrong = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response (`Assoc []))) in
    let right = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response question)) in
    publish ~base_path [{F.id="wrong";base_url=wrong.base_url};{F.id="right";base_url=right.base_url}];
    let baseline=`Assoc ["type",`String "object";"properties",`Assoc ["question",`Assoc ["type",`String "string"]];
      "additionalProperties",`Bool false] in
    let package={package with exact_outputs=[{Types.name="author";schema=baseline;request_schema=Types.Consumer_request_schema}]} in
    let requested=`Assoc ["$schema",`String "https://json-schema.org/draft/2020-12/schema";
      "type",`String "object";"required",`List [`String "question"];
      "properties",`Assoc ["question",`Assoc ["anyOf",`List [
        `Assoc ["type",`String "string"];`Assoc ["type",`String "null"]]]]] in
    (match answered_by (run_request ~package ~schema:requested ~base_path ~store "dynamic-shape") with
     | Some (_,slot,_) -> check string "partial request-shape rejection advances the HTTP walk" "right" slot
     | None -> fail "the valid second response must answer");
    check int "first candidate dispatched once" 1 (F.post_count wrong);
    check int "second candidate dispatched once" 1 (F.post_count right))

module Capture = Workspace_memory_execution_capture
module Curator = Server_workspace_memory_addon_validation
module Ledger = Workspace_memory_ledger
module Request = Workspace_memory_request
module Briefing = Workspace_memory_briefing
module Owner = Lane_addon_tool_request_owner
let get = function Ok value -> value | Error detail -> fail detail
let captured_prompt effective : Prompt_registry.prompt_resolution =
  { effective; source=Prompt_registry.Override; file_value=None; override_value=Some effective;
    file_path=None; file_exists=false; has_override=true }
let destination : Capture.destination =
  { installation_id=Owner.installation_id (Owner.Configuration declaration_id);
    package_id=Curator.package_id; tool=Curator.tool;
    source_revision="original-source"; configuration_revision="original-selection" }
let curator_package = {package with id=Curator.package_id; exact_outputs=List.map
  (fun (name,schema) -> {Types.name; schema;
    request_schema=Types.Consumer_request_schema})
  ["classification",Workspace_memory_decision.output_schema;"briefing",Briefing.output_schema]}
let retain_capture ~store capture =
  Owner.retain ~store ~scope:Capture.scope
    ~request_id:(Capture.Request_id.to_string (Capture.request_id capture))
    ~installation_id:destination.installation_id ~package_id:destination.package_id
    ~tool:destination.tool ~request:(Capture.to_json capture)
  |> Result.map_error Owner.error_to_string |> get
let classification_capture ~base_path =
  let workspace = get (Capture.observe_workspace ~base_path) in
  let claim="An original source fact" in
  let fact : Ledger.pending_fact =
    {fact=Ledger.Ordinary {keeper_id="writer";claim_sha256=Lane_addon_store.digest claim};claim} in
  let prompt=captured_prompt "Classify the original facts: {{workspace_memory_changes}}" in
  let render input=Prompt_registry.render_resolved_prompt_template Prompt_names.workspace_memory_curator
    prompt ["workspace_memory_changes",Yojson.Safe.to_string input] in
  let batch=match Request.prepare ~neighbor_limit:0 ~render ~ledger:Ledger.empty ~current:[fact] ~pending:[fact]
    |> Result.map_error Request.error_to_string |> get with
    | Some batch -> batch | None -> fail "one original fact needs classification" in
  let capture=Capture.classification ~request_id:(Capture.Request_id.fresh ()) ~workspace ~destination
    ~prompt ~ledger:Ledger.empty ~batch |> get in
  let good=`Assoc ["decisions",`List [`Assoc ["fact_id",`String (Request.fact_id fact.fact);
    "kind",`String "create_claim";"value",`String "A host-validated claim"]]] in
  capture,good,`Assoc ["decisions",`List []]
let run_curator ?runner ~base_path ~store request =
  let runner=Option.value runner ~default:(Server_lane_addon_exact.runner ~base_path) in
  Exact.run ~store ~declaration_id ~package:curator_package ~runner
    ~validate_request:(Server_lane_addon_exact.validate_request ~base_path) request

let test_original_curator_semantics_advance_http_and_survive_reopen () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let capture,good,bad=classification_capture ~base_path in
    retain_capture ~store capture;
    let request=get (Curator.request capture) in
    let wrong=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response bad)) in
    let right=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response good)) in
    publish ~lane_id:"quiz/classification" ~base_path
      [{F.id="wrong-facts";base_url=wrong.base_url};{F.id="original-facts";base_url=right.base_url}];
    (match answered_by (get (run_curator ~base_path ~store request)) with
     | Some (answer,slot,_) ->
       check bool "only a complete original fact decision is accepted" true (answer=good);
       check string "domain rejection advances inside the same HTTP walk" "original-facts" slot
     | None -> fail "valid original fact decision must answer");
    let reopened=Lane_addon_store.create ~root:(Lane_addon_store.root store) in
    check bool "reopened original capture and final answer are reused" true
      (answered_by (get (run_curator ~base_path ~store:reopened request)) <> None);
    check int "invalid candidate was sent once" 1 (F.post_count wrong);
    check int "accepted candidate is not dispatched again" 1 (F.post_count right);
    let owner=Owner.load ~store:reopened ~scope:Capture.scope ~request_id:request.request_id
      |> Result.map_error Owner.error_to_string |> get in
    match owner with
    | Some retained ->
      check bool "validation has no host commit authority" true
        (Lane_addon_request_progress.phase retained.progress=Lane_addon_request_progress.Captured)
    | None -> fail "original host capture disappeared")

let test_original_curator_semantics_advance_the_cli_tail () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let capture,good,_=classification_capture ~base_path in
    let bad=match good with
      | `Assoc [("decisions",`List [`Assoc fields])] ->
        `Assoc ["decisions",`List [`Assoc (("kind",`String "join_claim")::
          ("value",`String "absent-original-claim")::
          List.remove_assoc "value" (List.remove_assoc "kind" fields))]]
      | _ -> fail "one original classification row expected" in
    retain_capture ~store capture;
    let wrong=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response bad)) in
    publish ~lane_id:"quiz/classification" ~base_path
      ~cli_slots:[F.cli_primary_runtime;F.cli_secondary_runtime] [{F.id="http";base_url=wrong.base_url}];
    let prompts=ref [] in
    let cli_runner : Keeper_lane_cli_oneshot.runner = fun ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt ->
      prompts := (runtime_id,prompt)::!prompts;
      Ok (Yojson.Safe.to_string (if runtime_id=F.cli_primary_runtime then bad else good)) in
    let runner=Server_lane_addon_exact.For_testing.runner ~base_path ~cli_runner in
    let request=get (Curator.request capture) in
    (match answered_by (get (run_curator ~runner ~base_path ~store request)) with
     | Some (_,slot,_) -> check string "CLI semantic rejection reaches the next admitted client"
         F.cli_secondary_runtime slot
     | None -> fail "the next CLI's complete original decision must answer");
    check (list string) "original CLI order remains within one request"
      [F.cli_primary_runtime;F.cli_secondary_runtime] (List.rev_map fst !prompts);
    let requirement=Agent_core.Exact_output.make_output_requirement ~schema:(Capture.output_schema capture)
      ~minimum_guarantee:Agent_core.Exact_output.Json_syntax in
    let original_prompt=Capture.rendered_prompt capture ^ "\n\n"
      ^ Agent_core.Exact_output.schema_instruction_text requirement in
    check bool "both clients receive the complete captured prompt and common schema instruction" true
      (List.for_all (fun (_,prompt) -> prompt=original_prompt) !prompts);
    check int "the HTTP candidate was attempted once" 1 (F.post_count wrong))

let test_curator_authority_is_required_before_dispatch_and_replay () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let capture,good,_=classification_capture ~base_path in
    let request=get (Curator.request capture) in
    let server=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response good)) in
    publish ~lane_id:"quiz/classification" ~base_path [{F.id="only";base_url=server.base_url}];
    check bool "a package name cannot grant missing host authority" true
      (Result.is_error (run_curator ~base_path ~store request));
    check int "missing capture sends nothing" 0 (F.post_count server);
    retain_capture ~store capture;
    let changed=Exact.request_to_json request |> function
      | `Assoc fields -> get (Exact.request_of_json (`Assoc
          (("messages",`List [user "A replacement prompt"])::List.remove_assoc "messages" fields)))
      | _ -> fail "original request must be an object" in
    check bool "worker cannot replace captured prompt bytes" true
      (Result.is_error (run_curator ~base_path ~store changed));
    check bool "worker cannot transfer this capture to another installation" true
      (Result.is_error (Exact.run ~store ~declaration_id:"another" ~package:curator_package
        ~runner:(Server_lane_addon_exact.runner ~base_path)
        ~validate_request:(Server_lane_addon_exact.validate_request ~base_path) request));
    check bool "relabeling the package does not bypass an original Curator capture" true
      (Result.is_error (Exact.run ~store ~declaration_id
        ~package:{curator_package with id="another-package"}
        ~runner:(Server_lane_addon_exact.runner ~base_path)
        ~validate_request:(Server_lane_addon_exact.validate_request ~base_path) request));
    check int "refusals do not enter the provider" 0 (F.post_count server);
    ignore (get (run_curator ~base_path ~store request) : Exact.attempt);
    let other=Filename.concat base_path "other-workspace" in Unix.mkdir other 0o700;
    check bool "retained answers require the original physical workspace too" true
      (Result.is_error (run_curator ~base_path:other ~store request));
    check bool "authority restoration reuses the original terminal" true
      (answered_by (get (run_curator ~base_path ~store request)) <> None);
    check int "no provider replay follows authority refusal" 1 (F.post_count server))

let test_retained_schema_only_curator_answer_is_not_a_domain_judgment () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let capture,_,bad=classification_capture ~base_path in
    retain_capture ~store capture;
    let request=get (Curator.request capture) in
    let server=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response bad)) in
    publish ~lane_id:"quiz/classification" ~base_path [{F.id="only";base_url=server.base_url}];
    let runner=Server_lane_addon_exact.runner ~base_path in
    (* Seed a real retained schema-only result as produced without the host
       semantic port. It must not gain domain authority when read later. *)
    (match get (Exact.run ~store ~declaration_id ~package:curator_package ~runner
      ~validate_request:(fun ~store:_ ~declaration_id:_ ~package:_ _ -> Ok (fun _ -> Ok ())) request) with
     | Exact.Final (Exact.Call_final (Exact.Answered {output;_})) ->
       check bool "schema-only seed really retained the domain-invalid answer" true
         (Exact.checked_json output=bad)
     | Exact.Final _ | Exact.Not_final _ -> fail "seed must be answered before semantic replay rejection");
    (match get (run_curator ~base_path ~store request) with
     | Exact.Final (Exact.Call_final (Exact.Invalid_output _)) -> ()
     | _ -> fail "schema-only terminal is not a complete captured decision");
    check int "invalid retained terminal is not retried" 1 (F.post_count server))

let test_curator_briefing_semantics_reject_blank_before_acceptance () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let prompt=captured_prompt "Summarize the original pass: {{workspace_memory_briefing}}" in
    let render input=Prompt_registry.render_resolved_prompt_template Prompt_names.workspace_memory_briefing
      prompt ["workspace_memory_briefing",Yojson.Safe.to_string input] in
    let sources=[{Briefing.id="claim-a";kind=Briefing.Claim;text="Original complete source"}] in
    let batch=match get (Briefing.prepare ~sources ~contract:(Briefing.contract ~template:prompt.effective)
      ~render Briefing.empty) with
      | Briefing.Prepared batch -> batch
      | Briefing.Unchanged | Briefing.Cleanup _ -> fail "original briefing pass expected" in
    let capture=Capture.briefing ~request_id:(Capture.Request_id.fresh ())
      ~workspace:(get (Capture.observe_workspace ~base_path)) ~destination ~prompt ~batch |> get in
    retain_capture ~store capture;
    let wrong=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response (`Assoc ["briefing",`String " "]))) in
    let right=F.start_server ~sw ~net ~clock
      (F.Reply (F.openai_response (`Assoc ["briefing",`String "The original completed summary"]))) in
    publish ~lane_id:"quiz/briefing" ~base_path
      [{F.id="blank";base_url=wrong.base_url};{F.id="original-summary";base_url=right.base_url}];
    match answered_by (get (run_curator ~base_path ~store (get (Curator.request capture)))) with
    | Some (_,slot,_) -> check string "briefing full-domain validation advances" "original-summary" slot
    | None -> fail "nonblank original summary must answer")

let () =
  run "lane add-on exact runner"
    [ ( "runner"
      , [ test_case "an answer that matches the schema is answered" `Quick test_an_answer_that_matches_the_schema_is_answered
        ; test_case "an answer outside the schema advances" `Quick test_an_answer_outside_the_schema_advances
        ; test_case "every answer outside the schema is invalid_output" `Quick
            test_every_answer_outside_the_schema_is_invalid_output
        ; test_case "output limit retains its original strict terminal" `Quick test_output_limit_retains_an_original_distinct_terminal
        ; test_case "output limit advances to the later HTTP candidate" `Quick test_output_limit_still_advances_to_a_valid_http_candidate
        ; test_case "transient outranks output limit" `Quick (test_output_limit_does_not_override_another_refusal Busy)
        ; test_case "authentication outranks output limit" `Quick (test_output_limit_does_not_override_another_refusal Auth)
        ; test_case "configuration outranks output limit" `Quick (test_output_limit_does_not_override_another_refusal Configuration)
        ; test_case "input refusal outranks output limit" `Quick (test_output_limit_does_not_override_another_refusal Input)
        ; test_case "missing measurement does not prove oversized input" `Quick test_measurement_failure_is_not_a_terminal_input_size_refusal
        ; test_case "output limit still allows the original CLI answer" `Quick (test_output_limit_keeps_the_original_cli_tail ~valid:true)
        ; test_case "an unusable CLI answer retains original output-limit evidence" `Quick (test_output_limit_keeps_the_original_cli_tail ~valid:false)
        ; test_case "expired evidence is not a terminal input refusal" `Quick (test_original_capacity_evidence_keeps_its_retry_meaning Expired)
        ; test_case "future evidence is not a terminal input refusal" `Quick (test_original_capacity_evidence_keeps_its_retry_meaning Not_yet_valid)
        ; test_case "unknown capacity boundary is not a terminal input refusal" `Quick (test_original_capacity_evidence_keeps_its_retry_meaning Boundary_unknown)
        ; test_case "measured input rejection stays terminal" `Quick (test_original_capacity_evidence_keeps_its_retry_meaning Input_rejected)
        ; test_case "a refused input is final" `Quick test_a_refused_input_is_final
        ; test_case "a rate limit is not final and is sent again" `Quick test_a_rate_limit_is_not_final_and_is_sent_again
        ; test_case "an auth refusal is not final" `Quick test_an_auth_refusal_is_not_final
        ; test_case "a slot that may pass keeps the request open" `Quick test_a_slot_that_may_pass_keeps_the_request_open
        ; test_case "an unconfigured lane sends nothing" `Quick test_an_unconfigured_lane_sends_nothing
        ; test_case "an off lane sends nothing" `Quick test_an_off_lane_sends_nothing
        ; test_case "the cli tail answers after the http slots" `Quick test_the_cli_tail_answers_after_the_http_slots
        ; test_case "HTTP preserves conversation roles" `Quick test_http_preserves_conversation_roles
        ; test_case "CLI refuses assistant history before dispatch" `Quick test_cli_refuses_assistant_without_dispatch
        ; test_case "request shape advances HTTP without replacing baseline" `Quick test_requested_shape_advances_http_without_replacing_baseline
        ; test_case "original Curator facts advance HTTP and survive reopen" `Quick test_original_curator_semantics_advance_http_and_survive_reopen
        ; test_case "original Curator semantics advance CLI tail" `Quick test_original_curator_semantics_advance_the_cli_tail
        ; test_case "Curator authority precedes dispatch and replay" `Quick test_curator_authority_is_required_before_dispatch_and_replay
        ; test_case "schema-only retained Curator answer has no domain authority" `Quick test_retained_schema_only_curator_answer_is_not_a_domain_judgment
        ; test_case "Curator briefing rejects blank before acceptance" `Quick test_curator_briefing_semantics_reject_blank_before_acceptance ] ) ]
