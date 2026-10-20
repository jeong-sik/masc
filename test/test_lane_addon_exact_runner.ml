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
  ; contributions = [ Types.Observe ]; worker_service=Types.Mcp_tools; command = [ "unused" ]
  ; directory = "/nonexistent"; skills_directory = None; action_tool = None
  ; state_storage = Types.Ephemeral; tool_invocation = Types.Direct; tool_hooks=[]; exported_tools = []; outputs = []
  ; refresh_policy = Types.Every_hint; model_access = Types.Model_disabled
  ; exact_outputs = [ { Types.name = "author"; schema } ]
  ; binding_schema = None; presentation = Lane_addon_presentation.empty
  ; execution=Types.Host_process {max_reply_bytes=65536} }

let user text = `Assoc [ "role", `String "user"; "text", `String text ]
let assistant text = `Assoc [ "role", `String "assistant"; "text", `String text ]

let request ?(messages = [user "Write one question about the ledger."]) id =
  match
    Exact.request_of_json
      (`Assoc
         [ "kind", `String "exact_output"; "request_id", `String id; "output", `String "author"
         ; "system", `String "You write quiz questions."
         ; "messages", `List messages ])
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

let publish ?(cli_slots = []) ~base_path targets =
  ignore
    (F.publish_registry ~lane_id
       ~slot_ids:(List.map (fun (target : F.target_fixture) -> target.id) targets)
       ~cli_slot_ids:cli_slots
       (F.resolver_snapshot ~source:base_path targets)
     : Runtime_exact_output_registry.t)

let run_request ?runner ?messages ~base_path ~store id =
  let runner = Option.value runner ~default:(Server_lane_addon_exact.runner ~base_path) in
  match Exact.run ~store ~declaration_id ~package ~runner (request ?messages id) with
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
        check (list string) "HTTP roles remain in their original order"
          ["system";"user";"assistant";"user"]
          (List.map (fun message -> message |> member "role" |> to_string) messages);
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

let () =
  run "lane add-on exact runner"
    [ ( "runner"
      , [ test_case "an answer that matches the schema is answered" `Quick test_an_answer_that_matches_the_schema_is_answered
        ; test_case "an answer outside the schema advances" `Quick test_an_answer_outside_the_schema_advances
        ; test_case "every answer outside the schema is invalid_output" `Quick
            test_every_answer_outside_the_schema_is_invalid_output
        ; test_case "a refused input is final" `Quick test_a_refused_input_is_final
        ; test_case "a rate limit is not final and is sent again" `Quick test_a_rate_limit_is_not_final_and_is_sent_again
        ; test_case "an auth refusal is not final" `Quick test_an_auth_refusal_is_not_final
        ; test_case "a slot that may pass keeps the request open" `Quick test_a_slot_that_may_pass_keeps_the_request_open
        ; test_case "an unconfigured lane sends nothing" `Quick test_an_unconfigured_lane_sends_nothing
        ; test_case "an off lane sends nothing" `Quick test_an_off_lane_sends_nothing
        ; test_case "the cli tail answers after the http slots" `Quick test_the_cli_tail_answers_after_the_http_slots
        ; test_case "HTTP preserves conversation roles" `Quick test_http_preserves_conversation_roles
        ; test_case "CLI refuses assistant history before dispatch" `Quick test_cli_refuses_assistant_without_dispatch ] ) ]
