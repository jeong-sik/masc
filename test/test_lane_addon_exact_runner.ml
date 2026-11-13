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
  ; ui_category = None; contributions = [ Types.Observe ]; command = [ "unused" ]
  ; directory = "/nonexistent"; skills_directory = None; action_tool = None
  ; state_storage = Types.Ephemeral; tool_invocation = Types.Direct; tool_hooks = []; worker_service = Types.Mcp_tools; exported_tools = []; outputs = []
  ; refresh_policy = Types.Every_hint; model_access = Types.Model_disabled
  ; exact_outputs = [ { Types.name = "author"; schema; request_schema=Types.Package_schema_only } ]; operator_asks = false; web_search = false
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

let publish ?(lane_id = lane_id) ?(cli_slots = []) ?runtime_observations ~base_path targets =
  ignore
    (F.publish_registry ~lane_id ?runtime_observations
       ~slot_ids:(List.map (fun (target : F.target_fixture) -> target.id) targets)
       ~cli_slot_ids:cli_slots
       (F.resolver_snapshot ~source:base_path targets)
     : Runtime_exact_output_registry.t)

let publish_responses ?body_timeouts ~base_path targets =
  let module EO = Agent_core.Exact_output in
  let document=F.catalog_document ?body_timeouts ~source:base_path targets in
  let chat_path="request_path = \"/v1/chat/completions\"" in
  let lines=String.split_on_char '\n' document.contents in
  check bool "fixture has the expected chat path" true (List.mem chat_path lines);
  let document={document with contents=String.concat "\n" (List.map (fun line ->
    if String.equal line chat_path then "request_path = \"/v1/responses\"" else line) lines)} in
  let snapshot=match EO.load_resolver_snapshot ~catalog:(EO.Full_replacement document) () with
    | Ok snapshot -> snapshot | Error _ -> fail "Responses catalog fixture did not load" in
  ignore (F.publish_registry ~lane_id ~slot_ids:(List.map (fun (target : F.target_fixture) -> target.id) targets)
    ~cli_slot_ids:[] snapshot : Runtime_exact_output_registry.t)

let run_request ?(package=package) ?runner ?schema ?messages ~base_path ~store id =
  let runner = Option.value runner ~default:(Server_lane_addon_exact.runner ~base_path) in
  match Exact.run ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path) ~store ~declaration_id ~package ~runner (request ?schema ?messages id) with
  | Ok attempt -> attempt
  | Error detail -> fail detail

let original_receipt ~store id =
  match Eio_unix.run_in_systhread (fun () -> Exact.read_original_execution ~store
    ~declaration_id ~schema ~attempt_ordinal:1 (request id)) with
  | Ok (Exact.Completed_original result) -> result.receipt
  | Ok Exact.No_completed_original -> fail "actual original walk proof was not retained"
  | Error detail -> fail detail

let original_slot_observations ~store id = Eio_unix.run_in_systhread (fun () ->
  Exact.read_latest_slot_observations ~store ~declaration_id ~schema (request id))

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

let test_original_response_observations_are_bound_to_each_visit () =
  let response output = Yojson.Safe.to_string (`Assoc [
    "status",`String "completed";"error",`Null;"output",`List [`Assoc [
      "type",`String "message";"role",`String "assistant";"content",`List [`Assoc [
        "type",`String "output_text";"text",`String (Yojson.Safe.to_string output)]]]]]) in
  let wrong_body=response (`Assoc ["title",`String "x"]) and right_body=response question in
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let wrong=F.start_server ~sw ~net ~clock (F.Reply wrong_body) in
    let right=F.start_server ~sw ~net ~clock (F.Reply right_body) in
    publish_responses ~base_path [{F.id="first";base_url=wrong.base_url};{F.id="second";base_url=right.base_url}];
    check bool "second Responses visit answered" true
      (Option.is_some (answered_by (run_request ~base_path ~store "responses-v2")));
    let receipt=original_receipt ~store:(Lane_addon_store.create ~root:(Lane_addon_store.root store)) "responses-v2" in
    let observations=match original_slot_observations ~store "responses-v2" with
      | Ok (Some observations) -> observations | Ok None -> fail "original slot observations missing"
      | Error detail -> fail detail in
    check (list string) "passive capture retains both actual visited slots"
      ["first";"second"] (List.map (fun (visit:Exact_lane_slot_observation.t) -> visit.slot_id) observations);
    List.iter (fun (visit:Exact_lane_slot_observation.t) ->
      check (option string) "the physical Add-on output owns each visit" (Some lane_id) visit.lane_key;
      check bool "actual executor times were retained" true
        (visit.started_at<>None && visit.finished_at<>None)) observations;
    publish_responses ~base_path [{F.id="first";base_url=right.base_url};{F.id="second";base_url=right.base_url}];
    (match original_slot_observations ~store "responses-v2" with
     | Ok (Some ({binding=Exact_lane_slot_observation.Http binding;_}::_)) ->
       check string "republication cannot replace a historical endpoint"
         (wrong.base_url^"/v1/responses") binding.endpoint
     | Ok (None | Some _) -> fail "historical HTTP binding missing"
     | Error detail -> fail detail);
    let companion_dir=Filename.concat (Lane_addon_store.root store)
      (Lane_addon_exact_observation.directory ~declaration_id) in
    let companion=match Sys.readdir companion_dir with
      | [|name|] -> Filename.concat companion_dir name | _ -> fail "one original companion expected" in
    Fs_compat.save_file companion {|{"invalid":"diagnostic only"}|};
    check bool "damaged passive data is an explicit diagnostic read error" true
      (Result.is_error (original_slot_observations ~store "responses-v2"));
    check bool "authoritative original receipt survives diagnostic damage" true
      (Yojson.Safe.equal (Keeper_exact_walk_receipt.to_json receipt)
         (Keeper_exact_walk_receipt.to_json (original_receipt ~store "responses-v2")));
    check bool "retained answer still delivers without another provider call" true
      (Option.is_some (answered_by (run_request ~base_path ~store "responses-v2")));
    check (pair int int) "passive damage cannot replay either provider" (1,1)
      (F.post_count wrong,F.post_count right);
    let module Receipt=Keeper_exact_walk_receipt in
    let digest body=Agent_core_sha256.(to_hex (digest_string body)) in
    (match Receipt.response_observations receipt with
     | Some [first;second] ->
       check (list string) "original candidate order" ["first";"second"]
         [first.visit.candidate_id;second.visit.candidate_id];
       check (list int) "original visit ordinals" [1;2] [first.visit.ordinal;second.visit.ordinal];
       check bool "visits retain different call identities" true (first.call_id<>second.call_id);
       List.iter (fun (observed,body) ->
         check bool "Responses wire family" true (observed.Receipt.family=Receipt.Responses_codec);
         check (option int) "actual HTTP response" (Some 200) observed.http_status;
         check (option string) "digest of this visit's response body" (Some (digest body)) observed.body_sha256;
         check bool "same parse reports completed" true
           (observed.lifecycle=Some (Receipt.Observed_status Receipt.Completed)))
         [first,wrong_body;second,right_body]
     | None | Some _ -> fail "version 2 should retain both actual response observations");
    let wire=Receipt.to_json receipt in
    let legacy=match wire with
      | `Assoc fields -> `Assoc (List.filter_map (fun (key,value) ->
          if key="response_observations" then None
          else Some (key,if key="version" then `Int 1 else value)) fields)
      | _ -> fail "original receipt is not an object" in
    let old=match Receipt.of_json legacy with Ok old -> old | Error detail -> fail detail in
    check bool "v1 remains v1 and has no invented observations" true
      (Receipt.response_observations old=None && Yojson.Safe.equal (Receipt.to_json old) legacy);
    let change_observations f = match wire with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
          key,if key="response_observations" then f value else value) fields)
      | _ -> fail "original receipt is not an object" in
    let change_first field replacement = change_observations (function
      | `List (`Assoc first::rest) -> `List (`Assoc (List.map (fun (key,value) ->
          key,if key=field then replacement else value) first)::rest)
      | _ -> fail "actual observations are missing") in
    let remove_first_body=change_observations (function
      | `List (`Assoc first::rest) -> `List (`Assoc (List.map (fun (key,value) ->
          key,if key="body_sha256" || key="lifecycle" then `Null else value) first)::rest)
      | _ -> fail "actual observations are missing") in
    let reversed=change_observations (function `List observations -> `List (List.rev observations)
      | _ -> fail "actual observations are missing") in
    let missing=change_observations (function `List (_::rest) -> `List rest
      | _ -> fail "actual observations are missing") in
    List.iter (fun altered -> check bool "mismatched or missing visit evidence is refused" true
      (Result.is_error (Receipt.of_json altered)))
      [reversed;missing;remove_first_body;change_first "call_id" (`String "another-call");
       change_first "body_sha256" (`String (String.make 64 'a'));
       change_first "http_status" (`Int 429);
       change_first "lifecycle" (`List [`String "Observed_status";`List [`String "Queued"]]);
       change_first "lifecycle" (`List [`String "Unreadable_json"]);
       change_first "family" (`List [`String "Other_codec"])];
    let change_field field transform = function
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,if key=field then transform value else value) fields)
      | _ -> fail "expected an object in the original receipt" in
    let first_attempt transform = change_field "http" (change_field "attempts" (function
      | `List (first::rest) -> `List (transform first::rest)
      | _ -> fail "original attempts are missing")) in
    let float_version=change_field "version" (function `Int version -> `Float (float_of_int version)
      | _ -> fail "original version is missing") in
    let float_dispatch=first_attempt (change_field "dispatch_count" (fun _ -> `Float 1.0)) in
    let float_ordinal=first_attempt (change_field "visit" (change_field "ordinal" (fun _ -> `Float 1.0))) in
    List.iter (fun original -> List.iter (fun alter ->
      check bool "integer fields refuse integral JSON floats" true (Result.is_error (Receipt.of_json (alter original))))
      [float_version;float_dispatch;float_ordinal]) [legacy;wire];
    let float_observation=change_observations (function
      | `List (first::rest) -> `List (change_field "visit" (change_field "ordinal" (fun _ -> `Float 1.0)) first::rest)
      | _ -> fail "actual observations are missing") in
    check bool "v2 observation ordinal refuses an integral float" true
      (Result.is_error (Receipt.of_json float_observation));
    let erased_success = wire
      |> change_field "response_observations" (function
        | `List [first;second] -> `List [first;
          second |> change_field "http_status" (fun _ -> `Null)
                 |> change_field "body_sha256" (fun _ -> `Null)
                 |> change_field "lifecycle" (fun _ -> `Null)]
        | _ -> fail "actual observations are missing")
      |> change_field "http" (change_field "attempts" (function
        | `List [first;second] -> `List [first;change_field "phase" (fun _ -> `List [`String "Wire_started"]) second]
        | _ -> fail "original attempts are missing")) in
    check bool "an accepted visit cannot erase its complete response" true
      (Result.is_error (Receipt.of_json erased_success));
    check int "first provider called once" 1 (F.post_count wrong);
    check int "second provider called once" 1 (F.post_count right))

let test_original_responses_parse_failure_keeps_wire_status () =
  let body={|{"status":"in_progress","output":[{"type":"function_call"}]}|} in
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server=F.start_server ~sw ~net ~clock (F.Reply body) in
    publish_responses ~base_path [{F.id="responses";base_url=server.base_url}];
    ignore (run_request ~base_path ~store "responses-invalid-output");
    let module Receipt=Keeper_exact_walk_receipt in
    let receipt=original_receipt ~store:(Lane_addon_store.create ~root:(Lane_addon_store.root store))
      "responses-invalid-output" in
    (match Receipt.response_observations receipt with
     | Some [observation] ->
       check (option int) "the wire status remains 200" (Some 200) observation.http_status;
       check (option string) "the malformed output body is still bound"
         (Some Agent_core_sha256.(to_hex (digest_string body))) observation.body_sha256;
       check bool "the same parse observed in_progress" true
         (observation.lifecycle=Some (Receipt.Observed_status Receipt.In_progress))
     | None | Some _ -> fail "expected the original Responses observation");
    check int "observation read does not resend" 1 (F.post_count server))

let test_original_incomplete_responses_body_stays_unobserved () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server=F.start_server ~sw ~net ~clock (F.Incomplete_reply {|{"status":"queued"|}) in
    publish_responses ~body_timeouts:["responses",1.0] ~base_path [{F.id="responses";base_url=server.base_url}];
    ignore (run_request ~base_path ~store "responses-incomplete-body");
    let module Receipt=Keeper_exact_walk_receipt in
    let receipt=original_receipt ~store:(Lane_addon_store.create ~root:(Lane_addon_store.root store))
      "responses-incomplete-body" in
    (match Receipt.response_observations receipt with
     | Some [observation] ->
       check bool "the captured plan uses Responses" true (observation.family=Receipt.Responses_codec);
       check (option int) "actual response headers arrived" (Some 200) observation.http_status;
       check (option string) "an incomplete body has no complete digest" None observation.body_sha256;
       check bool "an incomplete body has no parsed lifecycle" true (observation.lifecycle=None)
     | None | Some _ -> fail "expected one incomplete response observation");
    let unregistered_header=match Receipt.to_json receipt with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,
        if key="response_observations" then (match value with
          | `List [`Assoc observation] -> `List [`Assoc (List.map (fun (key,value) ->
              key,if key="http_status" then `Int 600 else value) observation)]
          | _ -> fail "expected one response observation") else value) fields)
      | _ -> fail "expected original receipt" in
    check bool "a body deadline requires its successful response status" true
      (Result.is_error (Receipt.of_json unregistered_header));
    let terminal_body_deadline=match Receipt.to_json receipt with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,
        if key="http" then (match value with
          | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,
            if key="attempts" then (match value with
              | `List [`Assoc attempt] -> `List [`Assoc (List.map (fun (key,value) ->
                  key,if key="phase" then `List [`String "Terminal"] else value) attempt)]
              | _ -> fail "expected one response attempt") else value) fields)
          | _ -> fail "expected HTTP walk") else value) fields)
      | _ -> fail "expected original receipt" in
    check bool "a body deadline cannot be a terminal response" true
      (Result.is_error (Receipt.of_json terminal_body_deadline));
    let module EO=Agent_core.Exact_output in
    let module Http=Agent_core.Llm_provider.Http_client in
    let network_failure=Keeper_exact_walk_failure.(api_observation
      (EO.Completion_failed {dispatch=EO.Generation_dispatch_started;
        error=Http.NetworkError {message="synthetic connection reset";kind=Http.Connection_reset}})
      |> api_observation_to_yojson) in
    let replaced=ref false in
    let rec replace_deadline = function
      | `List [`String "Body_deadline"] -> replaced:=true;network_failure
      | `List values -> `List (List.map replace_deadline values)
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,replace_deadline value) fields)
      | value -> value in
    let network_with_unregistered_header=replace_deadline unregistered_header in
    check bool "fixture replaced the original body deadline" true !replaced;
    check bool "an unregistered header remains representable after a network failure" true
      (Result.is_ok (Receipt.of_json network_with_unregistered_header));
    check int "proof read did not resend" 1 (F.post_count server))

let test_an_answer_outside_the_schema_advances () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let wrong = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response (`Assoc [ "title", `String "x" ]))) in
    let right = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response question)) in
    publish ~base_path [ { F.id = "first"; base_url = wrong.base_url }; { F.id = "second"; base_url = right.base_url } ];
    (match answered_by (run_request ~base_path ~store "a2") with
     | Some (_, slot, _) -> check string "the next slot answers" "second" slot
     | None -> fail "the second slot's answer must be answered");
    check int "the first slot was asked once" 1 (F.post_count wrong);
    let original=original_receipt ~store "a2" |> Keeper_exact_walk_receipt.to_json in
    let unsent_accepted=match original with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,if key="http" then
          (match value with `Assoc fields -> `Assoc (List.map (fun (key,value) ->
            key,if key="attempts" then (match value with
              | `List [first;`Assoc accepted] -> `List [first;`Assoc
                  (List.map (fun (key,value) -> key,(match key with
                    | "generation_sent" -> `Bool false | "dispatch_count" -> `Int 0
                    | "phase" -> `List [`String "Before_wire"] | _ -> value)) accepted)]
              | _ -> fail "two actual HTTP attempts missing") else value) fields)
           | _ -> fail "HTTP receipt missing") else value) fields)
      | _ -> fail "original receipt missing" in
    check bool "earlier semantic generation cannot authorize an unsent accepted visit" true
      (Result.is_error (Keeper_exact_walk_receipt.of_json unsent_accepted)))

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
    let receipt=match Eio_unix.run_in_systhread (fun () -> Exact.read_original_execution ~store
      ~declaration_id ~schema ~attempt_ordinal:1 (request "measurement-unavailable")) with
      | Ok (Exact.Completed_original result) -> result.receipt
      | Ok Exact.No_completed_original -> fail "missing original measurement walk"
      | Error detail -> fail detail in
    check bool "measurement never grants a generation fact" true
      (Keeper_exact_walk_receipt.generation_dispatch receipt=Agent_core.Exact_output.No_generation_dispatch);
    check bool "measurement-only candidate rejection cannot authorize unread" true
      (Keeper_exact_walk_receipt.exhausted_input_refusals receipt=None);
    check (list string) "only token measurement was dispatched" ["/v1/messages/count_tokens"] (F.request_paths server))

let test_output_limit_keeps_the_original_cli_tail ~valid () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server=F.start_server ~sw ~net ~clock (F.Reply limited_response) in
    publish ~base_path ~cli_slots:[F.cli_primary_runtime] [{F.id="limited";base_url=server.base_url}];
    let calls=ref 0 in
    let cli_runner : Keeper_lane_cli_oneshot.runner = fun ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
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
    let expected_paths=match kind with
      | Expired | Not_yet_valid -> []
      | Boundary_unknown | Input_rejected -> ["/v1/messages/count_tokens"] in
    check (list string) "only valid evidence can reach measurement; generation never starts"
      expected_paths (F.request_paths server))

let test_a_refused_input_is_final () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server =
      F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ -> `Bad_request, refusal_body "invalid_request_error"))
    in
    publish ~base_path [ { F.id = "only"; base_url = server.base_url } ];
    match run_request ~base_path ~store "a4" with
    | Exact.Final (Exact.Call_final (Exact.Input_refused Exact.Invalid_request)) -> ()
    | _ -> fail "a 400 refusal of the request must be input_refused")

let test_a_slot_that_names_the_size_decides_the_refusal ~size_first () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let unnamed =
      F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ -> `Bad_request, refusal_body "invalid_request_error"))
    in
    let sized =
      F.start_server ~sw ~net ~clock
        (F.Reply_with (fun _ _ -> `Request_entity_too_large, refusal_body "invalid_request_error"))
    in
    let slots = [ { F.id = "unnamed"; base_url = unnamed.base_url }; { F.id = "sized"; base_url = sized.base_url } ] in
    publish ~base_path (if size_first then List.rev slots else slots);
    match run_request ~base_path ~store "size-named" with
    | Exact.Final (Exact.Call_final (Exact.Input_refused Exact.Request_body_refused)) -> ()
    | _ -> fail "a walk where one slot names the size must end on that refusal")

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

let test_provider_error_type_is_not_exposed_in_the_refusal_detail () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let credential = "sk-fixtureCredentialForExactOutput" in
    let body =
      Yojson.Safe.to_string
        (`Assoc
           [ "error", `Assoc [ "message", `String "provider error"; "type", `String credential ] ])
    in
    let server = F.start_server ~sw ~net ~clock (F.Reply body) in
    publish ~base_path [ { F.id = "only"; base_url = server.base_url } ];
    (match run_request ~base_path ~store "provider-error-type" with
     | Exact.Not_final (Exact.Provider_refused (Exact.Provider_unavailable { detail })) ->
       check bool "the typed failure remains visible" true
         (Astring.String.is_infix ~affix:"provider_reported_error" detail);
       check bool "the provider's credential-shaped type is absent" false
         (Astring.String.is_infix ~affix:credential detail)
     | Exact.Final _ | Exact.Not_final _ -> fail "expected the typed provider failure");
    let reopened = Lane_addon_store.create ~root:(Lane_addon_store.root store) in
    (match Eio_unix.run_in_systhread (fun () ->
       Exact.read_original_execution ~store:reopened ~declaration_id ~schema ~attempt_ordinal:1
         (request "provider-error-type")) with
     | Ok (Exact.Completed_original { outcome = Exact.Call_refused (Exact.Provider_unavailable { detail }); _ }) ->
       check bool "reopened refusal detail does not contain the credential" false
         (Astring.String.is_infix ~affix:credential detail)
     | Ok (Exact.Completed_original _) | Ok Exact.No_completed_original | Error _ ->
       fail "expected the retained provider failure");
    check int "only the original request was sent" 1 (F.post_count server))

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

let fixture_runtime runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | Some runtime -> runtime
  | None -> failf "fixture runtime %s must exist" runtime_id

(* What the host retained for one request: "started" for a started call,
   otherwise the not-final reason it recorded. *)
let attempt_labels ~store id =
  match Lane_addon_store.load_exact_request store ~declaration_id ~request_id:id with
  | Error detail -> fail detail
  | Ok None -> fail "the request must be recorded"
  | Ok (Some json) ->
    List.map
      (function
        | `Assoc fields when List.mem_assoc "started" fields -> "started"
        | `Assoc fields ->
          (match List.assoc_opt "reason" fields with
           | Some (`String reason) -> reason
           | Some _ | None -> "unlabelled")
        | _ -> "unlabelled")
      Yojson.Safe.Util.(json |> member "attempts" |> to_list)

(* RFC-exact-lane-waits-for-a-stated-reset R4: when the provider stated a
   reset for the account every slot runs on, the runner calls no slot and the
   host retains a deferral without a Started attempt. Before the rule every
   host event started a call the provider refused (85 on 2026-11-09). Both
   official-client fixture runtimes share one Claude Code account. *)
let test_a_lane_whose_every_slot_waits_starts_nothing () =
  with_case (fun ~sw:_ ~net:_ ~clock:_ ~base_path ~store ->
    publish ~base_path ~cli_slots:[ F.cli_primary_runtime; F.cli_secondary_runtime ] [];
    Runtime_quota_window.reset_for_testing ();
    Fun.protect ~finally:Runtime_quota_window.reset_for_testing (fun () ->
      let resets_at = Time_compat.now () +. 3600.0 in
      Runtime_quota_window.note_exhausted ~source:Runtime_quota_window.Provider_quota_refused
        ~scope:(Runtime_instance.quota_scope_of_runtime (fixture_runtime F.cli_primary_runtime)) ~resets_at;
      let calls = ref [] in
      let cli_runner : Keeper_lane_cli_oneshot.runner =
        fun ~runtime:{ Runtime_instance.id = runtime_id; _ } ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
        calls := runtime_id :: !calls;
        Ok (Yojson.Safe.to_string question)
      in
      let runner = Server_lane_addon_exact.For_testing.runner ~base_path ~cli_runner in
      (match run_request ~runner ~base_path ~store "h1" with
       | Exact.Not_final (Exact.Lane_unavailable (Exact.Every_slot_held { until })) ->
         check (float 0.0) "the lane waits for the reset the provider stated" resets_at until
       | _ -> fail "a lane whose every slot waits must end held, uncalled");
      check (list string) "no client was started" [] !calls;
      check (list string) "the host retains one deferral and no Started attempt"
        [ "every_slot_held" ] (attempt_labels ~store "h1")))

(* The Candle loop of 2026-11-09: each maintenance pulse read the retained
   appraisal, the read woke the Add-on host, and the host ran the same
   request again through Lane_addon_exact.run (lane_addon_runtime.ml, host
   cycle). Every run started a call the provider refused. Before the stated
   reset, no wake starts one now. The reset is a whole second, as Claude Code
   states it; the store writes that as an integer, which every later wake
   reads back with the retained record. *)
let test_no_wake_before_the_reset_starts_a_call () =
  with_case (fun ~sw:_ ~net:_ ~clock:_ ~base_path ~store ->
    publish ~base_path ~cli_slots:[ F.cli_primary_runtime; F.cli_secondary_runtime ] [];
    Runtime_quota_window.reset_for_testing ();
    Fun.protect ~finally:Runtime_quota_window.reset_for_testing (fun () ->
      let resets_at = Float.ceil (Time_compat.now () +. 3600.0) in
      Runtime_quota_window.note_exhausted ~source:Runtime_quota_window.Provider_quota_refused
        ~scope:(Runtime_instance.quota_scope_of_runtime (fixture_runtime F.cli_primary_runtime)) ~resets_at;
      let calls = ref [] in
      let cli_runner : Keeper_lane_cli_oneshot.runner =
        fun ~runtime:{ Runtime_instance.id = runtime_id; _ } ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
        calls := runtime_id :: !calls;
        Ok (Yojson.Safe.to_string question)
      in
      let runner = Server_lane_addon_exact.For_testing.runner ~base_path ~cli_runner in
      for wake = 1 to 3 do
        match run_request ~runner ~base_path ~store "h3" with
        | Exact.Not_final (Exact.Lane_unavailable (Exact.Every_slot_held { until })) ->
          check (float 0.0) (Printf.sprintf "wake %d waits for the stated reset" wake) resets_at until
        | _ -> failf "wake %d must end held, uncalled" wake
      done;
      check (list string) "no wake started a client" [] !calls;
      check (list string) "each wake retains one held deferral and no Started attempt"
        [ "every_slot_held"; "every_slot_held"; "every_slot_held" ]
        (attempt_labels ~store "h3")))

(* R5 when only some slots wait: a held slot ends the call as a slot that
   refused for its account's rest would, minus the call. A walked slot's input
   refusal then cannot end the request, as when the held slot was called and
   answered 429 (test_a_slot_that_may_pass_keeps_the_request_open). The
   receipt check compares walked candidates in order, so a wrong
   declared/excluded pair would raise instead of returning. *)
let test_a_held_slot_keeps_the_request_open_without_a_call () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let held = F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ -> `Too_many_requests, refusal_body "rate_limit_error")) in
    let refusing = F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ -> `Bad_request, refusal_body "invalid_request_error")) in
    let runtime = fixture_runtime "stub-http.stub-model" in
    let candidate = runtime.Runtime_instance.candidate_backpressure in
    publish ~base_path
      ~runtime_observations:
        [ ( "held"
          , { Runtime_exact_output_registry.candidate
            ; quota_scope = Runtime_instance.quota_scope_of_runtime runtime } ) ]
      [ { F.id = "held"; base_url = held.base_url }; { F.id = "refusing"; base_url = refusing.base_url } ];
    Fun.protect ~finally:(fun () -> Runtime_candidate_backpressure.note_candidate_success ~candidate) (fun () ->
      Runtime_candidate_backpressure.note_rate_limit ~candidate ~retry_after:(Some 3600.0);
      (match run_request ~base_path ~store "h2" with
       | Exact.Not_final (Exact.Provider_refused (Exact.Provider_unavailable _)) -> ()
       | _ -> fail "an input refusal must not end the request while a held slot may still answer");
      check int "the held slot is not called" 0 (F.post_count held);
      check int "the walked slot is called once" 1 (F.post_count refusing)))

(* RFC-exact-request-skips-a-slot-that-refused-its-input 3.2. Each case holds
   the slot "held" by its own Retry-After and puts one walked slot beside it.
   [body] gets [publish_beside], which publishes the lane with the given
   walked slots after "held", and [release], which ends the hold. *)
let too_large = F.Reply_with (fun _ _ -> `Request_entity_too_large, refusal_body "invalid_request_error")

let with_a_held_slot ~base_path ~held body =
  let runtime = fixture_runtime "stub-http.stub-model" in
  let candidate = runtime.Runtime_instance.candidate_backpressure in
  let publish_beside ?cli_slots (walked : F.target_fixture list) =
    publish ~base_path ?cli_slots
      ~runtime_observations:
        [ ( "held"
          , { Runtime_exact_output_registry.candidate
            ; quota_scope = Runtime_instance.quota_scope_of_runtime runtime } ) ]
      ({ F.id = "held"; base_url = held } :: walked)
  in
  let release () = Runtime_candidate_backpressure.note_candidate_success ~candidate in
  Fun.protect ~finally:release (fun () ->
    Runtime_candidate_backpressure.note_rate_limit ~candidate ~retry_after:(Some 3600.0);
    body ~publish_beside ~release)

let open_after_a_refusal label = function
  | Exact.Not_final (Exact.Provider_refused (Exact.Provider_unavailable _)) -> ()
  | _ -> fail label

(* A slot whose provider refused the request for its size is sent it once
   while another slot waits; the next wake calls nothing. Once nothing waits,
   the walk sends to every slot, so the walk that ends the request carries
   each slot's refusal. *)
let test_a_size_refusal_is_not_sent_again_while_a_slot_waits () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let held = F.start_server ~sw ~net ~clock too_large in
    let sized = F.start_server ~sw ~net ~clock too_large in
    with_a_held_slot ~base_path ~held:held.base_url (fun ~publish_beside ~release ->
      publish_beside [ { F.id = "sized"; base_url = sized.base_url } ];
      open_after_a_refusal "a size refusal beside a held slot must not end the request"
        (run_request ~base_path ~store "skip1");
      (match run_request ~base_path ~store "skip1" with
       | Exact.Not_final (Exact.Lane_unavailable (Exact.Every_slot_held _)) -> ()
       | _ -> fail "with the other slot refused for size, the lane has only the held slot left");
      check int "the slot that refused the size is sent the request once" 1 (F.post_count sized);
      check int "the held slot is not called" 0 (F.post_count held);
      check (list string) "the second wake retains a held deferral and no Started attempt"
        [ "provider_unavailable"; "every_slot_held" ] (attempt_labels ~store "skip1");
      release ();
      (match run_request ~base_path ~store "skip1" with
       | Exact.Final (Exact.Call_final (Exact.Input_refused Exact.Request_body_refused)) -> ()
       | _ -> fail "with no slot waiting, the walk must send to every slot and end on their refusals");
      check int "the slot that waited is sent the request" 1 (F.post_count held);
      check int "the slot that refused before is sent the request again" 2 (F.post_count sized)))

(* A 400 names no cause, so it does not say the size was refused. *)
let test_an_unnamed_refusal_is_sent_again_while_a_slot_waits () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let held = F.start_server ~sw ~net ~clock too_large in
    let unnamed =
      F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ -> `Bad_request, refusal_body "invalid_request_error"))
    in
    with_a_held_slot ~base_path ~held:held.base_url (fun ~publish_beside ~release:_ ->
      publish_beside [ { F.id = "unnamed"; base_url = unnamed.base_url } ];
      open_after_a_refusal "the first wake stays open" (run_request ~base_path ~store "skip2");
      open_after_a_refusal "the second wake calls the slot again" (run_request ~base_path ~store "skip2");
      check int "the slot is sent the request on each wake" 2 (F.post_count unnamed)))

(* The refusal belongs to the target that gave it. The same slot id naming
   another target is sent the request. *)
let test_a_slot_with_another_target_is_sent_the_request () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let held = F.start_server ~sw ~net ~clock too_large in
    let refusing = F.start_server ~sw ~net ~clock too_large in
    let answering = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response question)) in
    with_a_held_slot ~base_path ~held:held.base_url (fun ~publish_beside ~release:_ ->
      publish_beside [ { F.id = "moved"; base_url = refusing.base_url } ];
      open_after_a_refusal "the first target refuses the size" (run_request ~base_path ~store "skip3");
      publish_beside [ { F.id = "moved"; base_url = answering.base_url } ];
      check bool "the slot's new target answers" true
        (answered_by (run_request ~base_path ~store "skip3") <> None);
      check int "the first target was sent the request once" 1 (F.post_count refusing);
      check int "the new target was sent the request once" 1 (F.post_count answering)))

(* The refusal belongs to the schema that was sent. The package output's
   schema is what a request without its own schema sends, so another package
   schema is another request to the provider. *)
let test_a_slot_is_sent_the_request_under_another_schema () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let held = F.start_server ~sw ~net ~clock too_large in
    let sized = F.start_server ~sw ~net ~clock too_large in
    with_a_held_slot ~base_path ~held:held.base_url (fun ~publish_beside ~release:_ ->
      publish_beside [ { F.id = "sized"; base_url = sized.base_url } ];
      open_after_a_refusal "the first schema is refused for size" (run_request ~base_path ~store "skip5");
      let other_schema =
        `Assoc
          [ "type", `String "object"
          ; "properties",
            `Assoc [ "question", `Assoc [ "type", `String "string" ]; "hint", `Assoc [ "type", `String "string" ] ]
          ; "required", `List [ `String "question" ]
          ; "additionalProperties", `Bool false
          ]
      in
      let package =
        { package with
          exact_outputs =
            [ { Types.name = "author"; schema = other_schema; request_schema = Types.Package_schema_only } ] }
      in
      open_after_a_refusal "the slot is sent the request under the other schema"
        (run_request ~package ~base_path ~store "skip5");
      check int "the slot is sent the request once per schema" 2 (F.post_count sized)))

(* The newest proof that sent to a slot decides for it. A slot that refused
   the size and later failed another way is sent the request again. *)
let test_the_newest_answer_of_a_slot_decides () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let held =
      F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ -> `Too_many_requests, refusal_body "rate_limit_error"))
    in
    let changing =
      F.start_server ~sw ~net ~clock
        (F.Reply_with (fun index _ ->
           if index = 0 then `Request_entity_too_large, refusal_body "invalid_request_error"
           else `Internal_server_error, refusal_body "api_error"))
    in
    with_a_held_slot ~base_path ~held:held.base_url (fun ~publish_beside ~release ->
      publish_beside [ { F.id = "changing"; base_url = changing.base_url } ];
      open_after_a_refusal "the slot refuses the size beside the held slot"
        (run_request ~base_path ~store "skip6");
      release ();
      open_after_a_refusal "with nothing held both slots are called and neither ends the request"
        (run_request ~base_path ~store "skip6");
      check int "the slot was sent the request again once nothing was held" 2 (F.post_count changing);
      let runtime = fixture_runtime "stub-http.stub-model" in
      Runtime_candidate_backpressure.note_rate_limit
        ~candidate:runtime.Runtime_instance.candidate_backpressure ~retry_after:(Some 3600.0);
      open_after_a_refusal "the slot's newest answer is not a size refusal, so it is called"
        (run_request ~base_path ~store "skip6");
      check int "the slot is sent the request on the held wake" 3 (F.post_count changing)))

let excluded_http ~store ~attempt_ordinal id =
  match Eio_unix.run_in_systhread (fun () -> Exact.read_original_execution ~store
    ~declaration_id ~schema ~attempt_ordinal (request id)) with
  | Ok (Exact.Completed_original result) ->
    Yojson.Safe.Util.(
      Keeper_exact_walk_receipt.to_json result.receipt |> member "excluded_http" |> to_list
      |> List.map to_string)
  | Ok Exact.No_completed_original -> fail "the walk left no proof"
  | Error detail -> fail detail

(* A walk that leaves a slot out still runs when a CLI slot can be called. Its
   receipt records the held slot and the left-out slot as exclusions. *)
let test_a_left_out_slot_is_an_exclusion_in_the_receipt () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let held = F.start_server ~sw ~net ~clock too_large in
    let sized = F.start_server ~sw ~net ~clock too_large in
    with_a_held_slot ~base_path ~held:held.base_url (fun ~publish_beside ~release:_ ->
      publish_beside ~cli_slots:[ F.cli_primary_runtime ] [ { F.id = "sized"; base_url = sized.base_url } ];
      let calls = ref 0 in
      let cli_runner : Keeper_lane_cli_oneshot.runner =
        fun ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
        incr calls;
        if !calls = 1 then Ok "not json" else Ok (Yojson.Safe.to_string question)
      in
      let runner = Server_lane_addon_exact.For_testing.runner ~base_path ~cli_runner in
      open_after_a_refusal "the first wake stays open beside the held slot"
        (run_request ~runner ~base_path ~store "skip4");
      check bool "the CLI slot answers on the second wake" true
        (answered_by (run_request ~runner ~base_path ~store "skip4") <> None);
      check int "the slot that refused the size is sent the request once" 1 (F.post_count sized);
      check (list string) "the first walk excludes only the held slot" [ "held" ]
        (excluded_http ~store ~attempt_ordinal:1 "skip4");
      check (list string) "the second walk excludes the held slot and the left-out slot" [ "held"; "sized" ]
        (excluded_http ~store ~attempt_ordinal:2 "skip4")))

(* R4 on a lane that declares HTTP slots only: a slot held by its own
   Retry-After is not called, and with no other slot the lane ends held. *)
let test_an_http_lane_whose_every_slot_waits_starts_nothing () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let held = F.start_server ~sw ~net ~clock (F.Reply (F.openai_response question)) in
    let runtime = fixture_runtime "stub-http.stub-model" in
    let candidate = runtime.Runtime_instance.candidate_backpressure in
    publish ~base_path
      ~runtime_observations:
        [ ( "held"
          , { Runtime_exact_output_registry.candidate
            ; quota_scope = Runtime_instance.quota_scope_of_runtime runtime } ) ]
      [ { F.id = "held"; base_url = held.base_url } ];
    Fun.protect ~finally:(fun () -> Runtime_candidate_backpressure.note_candidate_success ~candidate) (fun () ->
      Runtime_candidate_backpressure.note_rate_limit ~candidate ~retry_after:(Some 3600.0);
      (match run_request ~base_path ~store "h5" with
       | Exact.Not_final (Exact.Lane_unavailable (Exact.Every_slot_held _)) -> ()
       | _ -> fail "an HTTP lane whose every slot waits must end held, uncalled");
      check int "the held slot is not called" 0 (F.post_count held);
      check (list string) "the host retains one deferral and no Started attempt"
        [ "every_slot_held" ] (attempt_labels ~store "h5")))

let cli_trace receipt field =
  Yojson.Safe.Util.(
    Keeper_exact_walk_receipt.to_json receipt |> member "cli" |> member field |> to_list
    |> List.map to_string)

(* R5 with a held CLI slot behind a walked HTTP slot: the CLI slot is visited
   as Held and never started, and the receipt the host retains keeps that
   observation. Its reset is a whole second, which the store writes as an
   integer; reading the receipt back, and the next wake reading the record,
   must accept that form. *)
let test_a_held_cli_slot_survives_the_retained_receipt () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let server =
      F.start_server ~sw ~net ~clock
        (F.Reply_with (fun index _ ->
           if index = 0 then `Too_many_requests, refusal_body "rate_limit_error"
           else `OK, F.openai_response question))
    in
    publish ~base_path ~cli_slots:[ F.cli_primary_runtime ] [ { F.id = "only"; base_url = server.base_url } ];
    Runtime_quota_window.reset_for_testing ();
    Fun.protect ~finally:Runtime_quota_window.reset_for_testing (fun () ->
      let resets_at = Float.ceil (Time_compat.now () +. 3600.0) in
      Runtime_quota_window.note_exhausted ~source:Runtime_quota_window.Provider_quota_refused
        ~scope:(Runtime_instance.quota_scope_of_runtime (fixture_runtime F.cli_primary_runtime)) ~resets_at;
      let calls = ref [] in
      let cli_runner : Keeper_lane_cli_oneshot.runner =
        fun ~runtime:{ Runtime_instance.id = runtime_id; _ } ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
        calls := runtime_id :: !calls;
        Ok (Yojson.Safe.to_string question)
      in
      let runner = Server_lane_addon_exact.For_testing.runner ~base_path ~cli_runner in
      (match run_request ~runner ~base_path ~store "h4" with
       | Exact.Not_final (Exact.Provider_refused (Exact.Provider_unavailable _)) -> ()
       | _ -> fail "a rate-limited HTTP slot beside a held CLI slot must not end the request");
      let receipt = original_receipt ~store "h4" in
      check (list string) "the held CLI slot is visited" [ F.cli_primary_runtime ] (cli_trace receipt "visited");
      check (list string) "the held CLI slot is not dispatched" [] (cli_trace receipt "dispatched");
      check bool "the next wake reads the retained record and answers" true
        (answered_by (run_request ~runner ~base_path ~store "h4") <> None);
      check (list string) "the held CLI slot is never started" [] !calls;
      check int "the HTTP slot is called on each wake" 2 (F.post_count server)))

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
      fun ~runtime:_ ~system_prompt ~output_schema:_ ~prompt ->
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
      fun ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
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

(* An act answer with an object-or-null child, rather than the scalar
   nullable child covered by the quiz fixture above. Exercise the actual HTTP
   walk and host proof codec together. *)
type act_action = Object_action | Null_action

let test_consumer_act_answer_survives_host_proof action_kind () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let baseline=`Assoc ["type",`String "object";
      "properties",`Assoc ["twoStep",`Assoc ["type",`String "boolean";"enum",`List [`Bool false]]];
      "required",`List [`String "twoStep"];"additionalProperties",`Bool true] in
    let action_schema=`Assoc ["type",`String "object";
      "properties",`Assoc ["elementId",`Assoc ["type",`String "string"];
        "method",`Assoc ["type",`String "string"];
        "arguments",`Assoc ["type",`String "array";"items",`Assoc ["type",`String "string"]]];
      "required",`List [`String "elementId";`String "method";`String "arguments"];
      "additionalProperties",`Bool false] in
    let requested=`Assoc ["type",`String "object";
      "properties",`Assoc ["action",`Assoc ["anyOf",`List [action_schema;`Assoc ["type",`String "null"]]];
        "twoStep",`Assoc ["type",`String "boolean"]];
      "required",`List [`String "action";`String "twoStep"];"additionalProperties",`Bool false] in
    let action=match action_kind with
      | Object_action -> `Assoc ["elementId",`String "0-320";"method",`String "click";"arguments",`List []]
      | Null_action -> `Null in
    let answer=match Lane_addon_action.canonical (`Assoc ["action",action;"twoStep",`Bool false]) with
      | Ok answer -> answer | Error detail -> fail detail in
    let output={Types.name="author";schema=baseline;request_schema=Types.Consumer_request_schema} in
    let package={package with exact_outputs=[output]} in
    let original=request ~schema:requested "object-or-null-act" in
    List.iter (fun malformed ->
      check bool "initial answer rejects nested shape and package baseline violations" true
        (Result.is_error (Exact.validate_answer ~output original malformed)))
      [`Assoc ["action",`Assoc ["elementId",`String "0-320";"arguments",`List []];"twoStep",`Bool false];
       `Assoc ["action",`Assoc ["elementId",`String "0-320";"method",`Int 7;"arguments",`List []];"twoStep",`Bool false];
       `Assoc ["action",action;"twoStep",`Bool true]];
    let server=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response answer)) in
    publish ~base_path [{F.id="act";base_url=server.base_url}];
    let run store=match Exact.run ~store ~declaration_id ~package
      ~runner:(Server_lane_addon_exact.runner ~base_path)
      ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path) original with
      | Ok attempt -> attempt | Error detail -> fail detail in
    let first=run store in
    let final=match first with
      | Exact.Final (Call_final (Answered {output;_}) as final) ->
          check bool "HTTP answer survives original proof publication" true (Exact.checked_json output=answer); final
      | Exact.Final _ | Exact.Not_final _ -> fail "the valid act response must answer" in
    let reopened=Lane_addon_store.create ~root:(Lane_addon_store.root store) in
    let read f=match Eio_unix.run_in_systhread f with Ok value -> value | Error detail -> fail detail in
    (match read (fun () -> Exact.read_original_execution ~store:reopened ~declaration_id
        ~schema:requested ~attempt_ordinal:1 original) with
     | Exact.Completed_original {outcome=Call_ended (Answered {output;_});_} ->
         check bool "reopened execution proof preserves the act answer" true (Exact.checked_json output=answer)
     | Exact.Completed_original _ | Exact.No_completed_original -> fail "completed original proof missing");
    check bool "retained observation uses the original consumer shape" true
      (read (fun () -> Exact.observe_retained ~store:reopened ~declaration_id ~schema:requested original)
        =Exact.Retained_terminal (Retained_call (match final with Call_final value -> value
          | Outcome_unknown | Not_allowed _ | Request_id_reused -> fail "answered final expected")));
    check bool "reopened host replay returns the original result" true (run reopened=first);
    check int "proof reads and replay never resend" 1 (F.post_count server))

module Capture = Workspace_memory_execution_capture
module Revision = Workspace_memory_revision
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
    ~tool:destination.tool ~summary:(Capture.Summary.to_json (get (Capture.summary capture)))
    ~request:(Capture.to_json capture)
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
      ~size:Request.Fill_frame ~frame:max_int ~measure:(fun _ -> Ok 0)
    |> Result.map_error Request.error_to_string |> get with
    | Some batch -> batch | None -> fail "one original fact needs classification" in
  let capture=Capture.classification ~request_id:(Capture.Request_id.fresh ()) ~workspace ~destination
    ~prompt ~ledger:Ledger.empty
    ~stored_ledger:(get (Revision.write_ledger ~base_path Ledger.empty |> Result.map_error Revision.write_error_to_string)) ~batch |> get in
  let local=match Request.selected_ids batch with [(id,_)] -> id | [] | _::_::_ -> fail "one original selection" in
  let good=`Assoc ["decisions",`List [`Assoc ["fact_id",`String local;
    "kind",`String "create_claim";"value",`String "A host-validated claim"]]] in
  capture,good,`Assoc ["decisions",`List []]
let run_curator ?runner ~base_path ~store request =
  let runner=Option.value runner ~default:(Server_lane_addon_exact.runner ~base_path) in
  Exact.run ~store ~declaration_id ~package:curator_package ~runner
    ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path) request

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
    let cli_runner : Keeper_lane_cli_oneshot.runner = fun ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt ->
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
    let unowned,_,_=classification_capture ~base_path in
    check bool "a package name cannot grant a request the host has no original for" true
      (match run_curator ~base_path ~store (get (Curator.request unowned)) with
       | Ok (Exact.Final (Exact.Not_allowed _)) -> true
       | Ok (Exact.Final _ | Exact.Not_final _) | Error _ -> false);
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
        ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path) request));
    check bool "relabeling the package does not bypass an original Curator capture" true
      (Result.is_error (Exact.run ~store ~declaration_id
        ~package:{curator_package with id="another-package"}
        ~runner:(Server_lane_addon_exact.runner ~base_path)
        ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path) request));
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
      ~authorize_request:(fun ~store:_ ~declaration_id:_ ~package:_ _ ->
                    Ok {Exact.admission_class=Agent_core.Llm_provider.Admission_class.Standard;
                        before_dispatch=(fun () -> Ok ()); with_execution=(fun run -> run ()); validate_output=(fun _ -> Ok ())}) request) with
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

let test_http_flow_preserves_host_admission_class ?(revoke_while_queued=false) admission_class () =
  with_case (fun ~sw ~net ~clock ~base_path ~store:_ ->
    let module Provider = Agent_core.Llm_provider in
    let module Admission = Provider.Provider_admission in
    let server=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response question)) in
    let binding=Provider.Provider_config.make
      ~kind:Provider.Provider_config.OpenAI_compat ~provider_id:"openai-responses"
      ~model_id:"gpt-5.6-luna" ~base_url:server.base_url ~request_path:"/v1/chat/completions"
      ~api_key:"synthetic-no-network"
      ~max_concurrent_requests:1 ~connect_timeout_s:F.fixture_post_connect_timeout_seconds () in
    let target : Agent_core.Exact_output.declared_target =
      {target_ref="openai-responses.admission"; binding;
       credential=Agent_core.Exact_output.Credential_resolved binding.api_key;
       body_timeout_s=Some F.fixture_post_body_timeout_seconds;
       model_declaration=Agent_core.Exact_output.No_model_declaration} in
    let snapshot=match Agent_core.Exact_output.load_resolver_snapshot
        ~catalog:(Agent_core.Exact_output.Embedded_with_targets [target]) () with
      | Ok snapshot -> snapshot | Error _ -> fail "actual admission fixture target did not load" in
    ignore (F.publish_registry ~lane_id ~slot_ids:[target.target_ref] snapshot);
    let observed=ref [] in
    let remove=Admission.install_wait_observer (fun wait -> observed:=wait::!observed) in
    Eio.Switch.on_release sw remove;
    let original=request "actual-host-admission" in
    let permitted=ref true and dispatch_checks=ref 0 and guarded=ref [] in
    let authorization : Exact.request_authorization =
      {admission_class; before_dispatch=(fun () -> incr dispatch_checks;
          if !permitted then Ok () else Error "original configuration changed while awaiting admission");
       with_execution=(fun run -> run ()); validate_output=(fun _ -> Ok ())} in
    let call=match Server_lane_addon_exact.runner ~base_path
        ~before_dispatch:(fun dispatch -> guarded:=dispatch::!guarded; authorization.before_dispatch ())
        ~admission_class:authorization.admission_class ~lane_key:lane_id ~schema ~size_refused:[] original with
      | Ok call -> call | Error _ -> fail "actual HTTP runner refused the fixture lane" in
    let validate raw=match Exact.validate_answer ~output:(List.hd package.exact_outputs) original raw with
      | Error detail -> Error detail
      | Ok checked ->
        Result.map (fun () -> checked) (authorization.validate_output (Exact.checked_json checked)) in
    let finished,resolve=Eio.Promise.create () in
    Admission.with_admission ~config:binding (fun () ->
      (* This fixture target requires no remote measurement. The real runner's
         first suspension is its full endpoint's permit wait. Eio.fork runs the
         child immediately; the snapshot confirms it actually queued before the
         holder releases, without a timer or a scheduling poll. *)
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve (call ~validate));
      match Admission.snapshot_for ~config:binding with
      | None -> fail "actual provider scheduler was not created"
      | Some state ->
        check int "one permit remains held" 1 state.active;
        check int "the real Exact flow queued before release" 1 state.queue_length;
        check int "a queued flow has not sent HTTP" 0 (F.post_count server);
        check int "a queued flow has not reached its generation guard" 0 (List.length !guarded);
        if revoke_while_queued then permitted:=false);
    let result=F.await_within_fixture_budget ~clock
      ~failure:"actual host-class HTTP flow did not finish" finished in
    check int "actual dispatch rechecks after the permit wait" 1 !dispatch_checks;
    check bool "the guard after the permit wait names the generation dispatch" true
      (!guarded=[Exact.Generation]);
    check (option string) "only a permitted original names an accepted transport"
      (if revoke_while_queued then None else Some target.target_ref)
      (Keeper_exact_walk_receipt.answered_slot result.receipt);
    (match result.outcome with
     | Exact.Call_ended (Exact.Answered {output;_}) ->
       check bool "a vetoed generation cannot answer" false revoke_while_queued;
       check bool "the real HTTP response is accepted" true (Exact.checked_json output=question)
     | Call_refused _ when revoke_while_queued -> ()
     | Call_ended (Invalid_output _ | Input_refused _ | Output_limit_reached _)
     | Call_refused _ -> fail "unexpected actual host-class HTTP outcome");
    (match !observed with
     | [wait] ->
       check bool "provider admission saw the host's actual class" true
         (wait.Admission.admission_class=admission_class);
       check string "the original bound model reached admission" binding.model_id wait.model_id;
       check bool "the queued request was granted" true (wait.outcome=Admission.Wait_granted)
     | [] | _::_ -> fail "expected one original provider admission wait");
    check int "only permitted original sends HTTP" (if revoke_while_queued then 0 else 1) (F.post_count server))

let test_returned_answer_survives_dispatch_authority_change () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let permitted=ref true in
    let server=F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ ->
      permitted:=false;
      `OK,F.openai_response question)) in
    publish ~base_path [{F.id="original";base_url=server.base_url}];
    let authorize_request ~store:_ ~declaration_id:_ ~package:_ _ =
      Ok {Exact.admission_class=Agent_core.Llm_provider.Admission_class.Background;
        before_dispatch=(fun () -> if !permitted then Ok () else Error "configuration changed");
        with_execution=(fun run -> run ()); validate_output=(fun _ -> Ok ())} in
    let original=request "returned-before-reconfiguration" in
    let execute ()=get (Exact.run ~store ~declaration_id ~package ~authorize_request
      ~runner:(Server_lane_addon_exact.runner ~base_path) original) in
    check bool "a result from the admitted original survives later config drift" true
      (Option.is_some (answered_by (execute ())));
    check bool "retained delivery does not run the execution guard" true
      (Option.is_some (answered_by (execute ())));
    check int "neither result validation nor replay resends" 1 (F.post_count server))

(* The guard runs once when the execution starts and once before each CLI
   dispatch. Its second answer here is the one before the first CLI slot. *)
let test_cli_dispatch_veto_never_advances () =
  with_case (fun ~sw:_ ~net:_ ~clock:_ ~base_path ~store ->
    publish ~base_path ~cli_slots:[F.cli_primary_runtime;F.cli_secondary_runtime] [];
    let checks=ref 0 and calls=ref 0 in
    let authorize_request ~store:_ ~declaration_id:_ ~package:_ _ =
      Ok {Exact.admission_class=Agent_core.Llm_provider.Admission_class.Background;
        before_dispatch=(fun () -> incr checks;
          if !checks=2 then Error "original configuration changed before CLI" else Ok ());
        with_execution=(fun run -> run ()); validate_output=(fun _ -> Ok ())} in
    let cli_runner : Keeper_lane_cli_oneshot.runner =
      fun ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
        incr calls;Ok (Yojson.Safe.to_string question) in
    let original=request "cli-authority-veto" in
    let execute ()=get (Exact.run ~store ~declaration_id ~package ~authorize_request
      ~runner:(Server_lane_addon_exact.For_testing.runner ~base_path ~cli_runner) original) in
    (match execute () with
     | Exact.Not_final (Exact.Provider_refused (Exact.Provider_unavailable _)) -> ()
     | Exact.Final _ | Exact.Not_final _ ->
       fail "a guard refusal before a CLI dispatch leaves the request open, as it does before HTTP");
    check int "neither the refused slot nor the later slot is sent to" 0 !calls;
    check (option string) "the retained walk names no answering slot" None
      (Keeper_exact_walk_receipt.answered_slot (original_receipt ~store "cli-authority-veto"));
    (match answered_by (execute ()) with
     | Some (_,slot,_) -> check string "the first declared slot answers once the guard allows" F.cli_primary_runtime slot
     | None -> fail "the same request must run again once the guard allows");
    check int "the allowed run sends once" 1 !calls;
    check bool "the retained answer is delivered" true (Option.is_some (answered_by (execute ())));
    check int "delivery does not send again" 1 !calls)

let test_cli_stop_before_dispatch_receipt () =
  let module Receipt = Keeper_exact_walk_receipt in
  let failed=Keeper_lane_cli_oneshot.Unknown_runtime {runtime_id="unresolved"} in
  let make ~visited ~dispatched ~stopped =
    Receipt.make ~declared_http:[] ~excluded_http:[] ~declared_cli:["unresolved";"stopped";"later"]
      ~http:(Receipt.http_not_started ~detail:"explicit synthetic CLI trace")
      ~cli:(Receipt.cli ~visited ~dispatched ~failures:[failed] ~result:(Receipt.Stopped_before_dispatch stopped)) in
  (match make ~visited:["unresolved";"stopped"] ~dispatched:[] ~stopped:"stopped" with
   | Error detail -> fail detail
   | Ok receipt ->
     check bool "a stop before dispatch survives its strict encoding" true
       (match Receipt.of_json (Receipt.to_json receipt) with
        | Ok decoded -> Yojson.Safe.equal (Receipt.to_json decoded) (Receipt.to_json receipt)
        | Error _ -> false);
     check (option string) "a stop names no answering slot" None (Receipt.answered_slot receipt));
  check bool "the stopped slot was not sent to" true
    (Result.is_error (make ~visited:["unresolved";"stopped"] ~dispatched:["stopped"] ~stopped:"stopped"));
  check bool "no slot is visited after the stop" true
    (Result.is_error (make ~visited:["unresolved";"stopped";"later"] ~dispatched:[] ~stopped:"stopped"));
  check bool "the stopped slot is itself a visit" true
    (Result.is_error (make ~visited:["unresolved"] ~dispatched:[] ~stopped:"stopped"))

let test_worker_names_do_not_grant_background () =
  with_case (fun ~sw:_ ~net:_ ~clock:_ ~base_path ~store ->
    let original=request "named-like-librarian" in
    let authorization=match Server_lane_addon_exact.authorize_request ~base_path ~store
        ~declaration_id:"librarian" ~package:{package with id="librarian"} original with
      | Ok authorization -> authorization
      | Error (Exact.Unowned {reason=detail} | Exact.Undecided {detail}) -> fail detail in
    check bool "worker package and installation names are no Background grant" true
      (authorization.admission_class=Agent_core.Llm_provider.Admission_class.Standard))

let test_original_mixed_failure_proof () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let size=F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ ->
      `Request_entity_too_large,refusal_body "invalid_request_error")) in
    let quota=F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ ->
      `Too_many_requests,refusal_body "rate_limit_error")) in
    publish ~base_path [{F.id="size";base_url=size.base_url};{F.id="quota";base_url=quota.base_url}];
    ignore (run_request ~base_path ~store "mixed-original");
    let reopened=Lane_addon_store.create ~root:(Lane_addon_store.root store) in
    let receipt=original_receipt ~store:reopened "mixed-original" in
    let evidence=Keeper_exact_walk_receipt.failure_evidence receipt in
    check bool "the original named capacity survives the quota" true evidence.named_input_capacity;
    check bool "quota still vetoes recursive whole-input partition" true evidence.size_independent_execution_failure;
    check bool "the separate actually exhausted API-only proof retains named causes" true
      (Keeper_exact_walk_receipt.exhausted_input_refusals receipt=Some [Keeper_librarian_input_refusal.Request_body_refused]);
    let wire=Keeper_exact_walk_receipt.to_json receipt in
    let missing_advance=match wire with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,if key="http" then
          (match value with `Assoc fields -> `Assoc (List.map (fun (key,value) ->
            key,if key="advances" then `List [] else value) fields) | _ -> fail "http object") else value) fields)
      | _ -> fail "receipt object" in
    check bool "a missing actual predecessor outcome cannot become exhaustion" true
      (Result.is_error (Keeper_exact_walk_receipt.of_json missing_advance));
    List.iter (fun (field,replacement) ->
      let contradictory=match wire with
        | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,if key="http" then
            (match value with `Assoc fields -> `Assoc (List.map (fun (key,value) ->
              key,if key="attempts" then (match value with
                | `List (`Assoc attempt::rest) -> `List (`Assoc
                    (List.map (fun (key,value) -> key,if key=field then replacement else value) attempt)::rest)
                | _ -> fail "missing real generation attempt") else value) fields)
             | _ -> fail "http object") else value) fields)
        | _ -> fail "receipt object" in
      check bool "a contradictory original generation state refuses" true
        (Result.is_error (Keeper_exact_walk_receipt.of_json contradictory)))
      ["dispatch_count",`Int 0;"phase",`List [`String "Fresh"];"generation_sent",`Bool false];
    check int "receipt consumption did not replay size provider" 1 (F.post_count size);
    check int "receipt consumption did not replay quota provider" 1 (F.post_count quota))

let test_semantic_failure_veto_survives_capacity () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let invalid=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response (`Assoc ["wrong",`String "value"]))) in
    let size=F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ ->
      `Request_entity_too_large,refusal_body "invalid_request_error")) in
    publish ~base_path [{F.id="semantic";base_url=invalid.base_url};{F.id="size";base_url=size.base_url}];
    ignore (run_request ~base_path ~store "semantic-size-original");
    let receipt=original_receipt ~store "semantic-size-original" in
    let evidence=Keeper_exact_walk_receipt.failure_evidence receipt in
    check bool "an earlier actual domain rejection remains an invalid-output veto" true evidence.invalid_output;
    check bool "that veto prevents partitioning despite later named capacity" false
      (Keeper_exact_walk_failure.refuses_input_capacity evidence);
    check bool "semantic moves outside advances still disqualify unread authority" true
      (Keeper_exact_walk_receipt.exhausted_input_refusals receipt=None))

let test_original_cli_prior_failure_proof () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let size=F.start_server ~sw ~net ~clock (F.Reply_with (fun _ _ ->
      `Request_entity_too_large,refusal_body "invalid_request_error")) in
    publish ~base_path ~cli_slots:[F.cli_primary_runtime;F.cli_secondary_runtime]
      [{F.id="size";base_url=size.base_url}];
    let calls=ref [] in
    let cli_runner : Keeper_lane_cli_oneshot.runner = fun ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
      calls:=runtime_id::!calls;
      Ok (if runtime_id=F.cli_primary_runtime then "not JSON" else Yojson.Safe.to_string question) in
    let runner=Server_lane_addon_exact.For_testing.runner ~base_path ~cli_runner in
    ignore (run_request ~runner ~base_path ~store "cli-original-proof");
    let receipt=original_receipt ~store "cli-original-proof" in
    check (option string) "the actual later official client answered" (Some F.cli_secondary_runtime)
      (Keeper_exact_walk_receipt.answered_slot receipt);
    check (list string) "actual official-client visits retain failed predecessor" [F.cli_primary_runtime;F.cli_secondary_runtime]
      (List.rev !calls);
    check bool "the failed earlier CLI JSON remains visible after success" true
      (Keeper_exact_walk_receipt.failure_evidence receipt).invalid_output;
    let wire=Keeper_exact_walk_receipt.to_json receipt in
    List.iter (fun field ->
      let reversed=match wire with
        | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,if key="cli" then
            (match value with `Assoc fields -> `Assoc (List.map (fun (key,value) ->
              key,if key=field then (match value with `List values -> `List (List.rev values)
                | _ -> fail "CLI ordered trace missing") else value) fields)
             | _ -> fail "CLI object missing") else value) fields)
        | _ -> fail "original receipt object missing" in
      check bool "reversed original CLI visit or dispatch prefix refuses" true
        (Result.is_error (Keeper_exact_walk_receipt.of_json reversed))) ["visited";"dispatched"];
    check bool "declared CLI participation never becomes API-only unread authority" true
      (Keeper_exact_walk_receipt.exhausted_input_refusals receipt=None))

let test_original_undispatched_cli_visit_order () =
  let module Receipt = Keeper_exact_walk_receipt in
  let failures=List.map (fun runtime_id -> Keeper_lane_cli_oneshot.Unknown_runtime {runtime_id})
    ["unresolved-b";"unresolved-a"] in
  let cli=Receipt.cli ~visited:["unresolved-b";"unresolved-a"] ~dispatched:[]
    ~failures ~result:Receipt.Exhausted in
  let original=match Receipt.make ~declared_http:[] ~excluded_http:[]
      ~declared_cli:["unresolved-a";"unresolved-b"]
      ~http:(Receipt.http_not_started ~detail:"explicit synthetic CLI trace") ~cli with
    | Ok receipt -> receipt | Error detail -> fail detail in
  check bool "actual visits may differ from configured order without inventing dispatch" true
    (Result.is_ok (Receipt.of_json (Receipt.to_json original)));
  let reversed=match Receipt.to_json original with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,if key="cli" then
        (match value with `Assoc fields -> `Assoc (List.map (fun (key,value) ->
          key,if key="failures" then (match value with `List values -> `List (List.rev values)
            | _ -> fail "CLI failures missing") else value) fields)
         | _ -> fail "CLI object missing") else value) fields)
    | _ -> fail "original receipt missing" in
  check bool "an exhausted declaration set cannot hide reordered original failures" true
    (Result.is_error (Receipt.of_json reversed))

(* RFC-0498 §4.4: once the Curator original is settled, nothing owns the
   Exact record and execution link its run left. The sweep deletes them, and
   a rerun gets the same refusal before and after. *)
module Sweep = Server_unowned_exact_sweep
let sweep ~store package =
  let declaration : Lane_addon_config.declaration =
    { id=declaration_id; enabled=true; run_id="sweep"; manifest_path="/nonexistent/lane.toml";
      package; binding=`Null; revision="1"; source_revision="1"; source_path="/nonexistent/quiz.toml";
      max_exact_in_flight=Lane_addon_config.one_exact_at_a_time } in
  Sweep.run ~store ~declarations:[declaration]

let test_a_settled_curator_original_leaves_its_exact_files_to_the_sweep () =
  with_case (fun ~sw ~net ~clock ~base_path ~store ->
    let swept package = match sweep ~store package with
      | Ok report -> report | Error error -> fail (Sweep.error_to_string error) in
    let files directory=
      Sys.readdir (Filename.concat (Lane_addon_store.root store) directory) |> Array.length in
    let records=Lane_addon_store.exact_request_directory ~declaration_id in
    let links=Exact.proof_directory ~declaration_id in
    let capture,good,_=classification_capture ~base_path in
    retain_capture ~store capture;
    let request=get (Curator.request capture) in
    let server=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response good)) in
    publish ~lane_id:"quiz/classification" ~base_path [{F.id="original-facts";base_url=server.base_url}];
    if answered_by (get (run_curator ~base_path ~store request)) = None then fail "the original must answer";
    let live=swept curator_package in
    check (pair int int) "the live original keeps its Exact record and execution link" (1,1)
      (live.kept_exact_records,live.kept_proofs);
    check int "live original also keeps its passive companion" 1 live.kept_observations;
    check (pair int int) "a live original loses nothing" (0,0) (live.removed_exact_records,live.removed_proofs);
    (match Owner.load ~store ~scope:Capture.scope ~request_id:request.request_id
           |> Result.map_error Owner.error_to_string |> get with
     | None -> fail "original host capture disappeared"
     | Some retained ->
       (match Owner.settle ~store ~date:"2026-11-06" (Owner.listed retained) with
        | Ok () -> () | Error error -> fail (Owner.settle_error_to_string error)));
    let not_allowed () = match run_curator ~base_path ~store request with
      | Ok (Exact.Final (Exact.Not_allowed _)) -> true
      | Ok (Exact.Final _ | Exact.Not_final _) | Error _ -> false in
    check bool "a rerun of the settled request is refused" true (not_allowed ());
    check int "a package that needs no original is not swept" 0 (swept package).declarations;
    let link_dir=Filename.concat (Lane_addon_store.root store) links in
    let link=match Sys.readdir link_dir with [|link|] -> link | _ -> fail "one execution link expected" in
    let misnamed=Filename.concat link_dir (String.make 64 '0' ^ ".json") in
    Out_channel.with_open_bin misnamed (fun channel ->
      Out_channel.output_string channel
        (In_channel.with_open_bin (Filename.concat link_dir link) In_channel.input_all));
    check bool "a link under another request's name refuses the sweep" true
      (Result.is_error (sweep ~store curator_package));
    check (pair int int) "a refused sweep deletes nothing" (1,2) (files records,files links);
    Sys.remove misnamed;
    let settled=swept curator_package in
    check (pair int int) "the sweep deletes the unowned link and record" (1,1)
      (settled.removed_proofs,settled.removed_exact_records);
    check int "settled original's passive companion follows its retention" 1 settled.removed_observations;
    check (pair int int) "no Exact file is left" (0,0) (files records,files links);
    check bool "a rerun after the sweep is still refused" true (not_allowed ());
    check int "no rerun reached the provider" 1 (F.post_count server))

let () =
  run "lane add-on exact runner"
    [ ( "runner"
      , [ test_case "undispatched CLI failures preserve actual order" `Quick test_original_undispatched_cli_visit_order
        ; test_case "actual mixed failure proof survives Store reopen" `Quick test_original_mixed_failure_proof
        ; test_case "actual semantic predecessor veto survives capacity" `Quick test_semantic_failure_veto_survives_capacity
        ; test_case "actual CLI success retains prior failure" `Quick test_original_cli_prior_failure_proof
        ; test_case "queued generation rechecks execution authority after permit" `Quick
            (test_http_flow_preserves_host_admission_class ~revoke_while_queued:true Agent_core.Llm_provider.Admission_class.Background)
        ; test_case "returned output survives later configuration changes" `Quick test_returned_answer_survives_dispatch_authority_change
        ; test_case "a CLI authority veto sends nothing and leaves the request open" `Quick test_cli_dispatch_veto_never_advances
        ; test_case "a CLI stop before dispatch keeps its visit order" `Quick test_cli_stop_before_dispatch_receipt
        ; test_case "an answer that matches the schema is answered" `Quick test_an_answer_that_matches_the_schema_is_answered
        ; test_case "original response observations follow each visit" `Quick test_original_response_observations_are_bound_to_each_visit
        ; test_case "original Responses parse failure keeps wire status" `Quick test_original_responses_parse_failure_keeps_wire_status
        ; test_case "original incomplete Responses body stays unobserved" `Quick test_original_incomplete_responses_body_stays_unobserved
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
        ; test_case "a size refusal after an unnamed one ends the walk" `Quick
            (test_a_slot_that_names_the_size_decides_the_refusal ~size_first:false)
        ; test_case "a size refusal before an unnamed one ends the walk" `Quick
            (test_a_slot_that_names_the_size_decides_the_refusal ~size_first:true)
        ; test_case "a rate limit is not final and is sent again" `Quick test_a_rate_limit_is_not_final_and_is_sent_again
        ; test_case "provider error type is not exposed" `Quick test_provider_error_type_is_not_exposed_in_the_refusal_detail
        ; test_case "an auth refusal is not final" `Quick test_an_auth_refusal_is_not_final
        ; test_case "a slot that may pass keeps the request open" `Quick test_a_slot_that_may_pass_keeps_the_request_open
        ; test_case "a lane whose every slot waits starts nothing" `Quick test_a_lane_whose_every_slot_waits_starts_nothing
        ; test_case "no wake before the reset starts a call" `Quick test_no_wake_before_the_reset_starts_a_call
        ; test_case "a held slot keeps the request open without a call" `Quick
            test_a_held_slot_keeps_the_request_open_without_a_call
        ; test_case "a size refusal is not sent again while a slot waits" `Quick
            test_a_size_refusal_is_not_sent_again_while_a_slot_waits
        ; test_case "an unnamed refusal is sent again while a slot waits" `Quick
            test_an_unnamed_refusal_is_sent_again_while_a_slot_waits
        ; test_case "a slot with another target is sent the request" `Quick
            test_a_slot_with_another_target_is_sent_the_request
        ; test_case "a slot is sent the request under another schema" `Quick
            test_a_slot_is_sent_the_request_under_another_schema
        ; test_case "the newest answer of a slot decides" `Quick test_the_newest_answer_of_a_slot_decides
        ; test_case "a left-out slot is an exclusion in the receipt" `Quick
            test_a_left_out_slot_is_an_exclusion_in_the_receipt
        ; test_case "an HTTP lane whose every slot waits starts nothing" `Quick
            test_an_http_lane_whose_every_slot_waits_starts_nothing
        ; test_case "a held CLI slot survives the retained receipt" `Quick
            test_a_held_cli_slot_survives_the_retained_receipt
        ; test_case "an unconfigured lane sends nothing" `Quick test_an_unconfigured_lane_sends_nothing
        ; test_case "an off lane sends nothing" `Quick test_an_off_lane_sends_nothing
        ; test_case "the cli tail answers after the http slots" `Quick test_the_cli_tail_answers_after_the_http_slots
        ; test_case "HTTP preserves conversation roles" `Quick test_http_preserves_conversation_roles
        ; test_case "CLI refuses assistant history before dispatch" `Quick test_cli_refuses_assistant_without_dispatch
        ; test_case "request shape advances HTTP without replacing baseline" `Quick test_requested_shape_advances_http_without_replacing_baseline
        ; test_case "act object survives HTTP proof reopen and Browser delivery" `Quick
            (test_consumer_act_answer_survives_host_proof Object_action)
        ; test_case "act null survives HTTP proof reopen and Browser delivery" `Quick
            (test_consumer_act_answer_survives_host_proof Null_action)
        ; test_case "original Curator facts advance HTTP and survive reopen" `Quick test_original_curator_semantics_advance_http_and_survive_reopen
        ; test_case "original Curator semantics advance CLI tail" `Quick test_original_curator_semantics_advance_the_cli_tail
        ; test_case "Curator authority precedes dispatch and replay" `Quick test_curator_authority_is_required_before_dispatch_and_replay
        ; test_case "schema-only retained Curator answer has no domain authority" `Quick test_retained_schema_only_curator_answer_is_not_a_domain_judgment
        ; test_case "Curator briefing rejects blank before acceptance" `Quick test_curator_briefing_semantics_reject_blank_before_acceptance
        ; test_case "real HTTP admission preserves trusted Background" `Quick
            (test_http_flow_preserves_host_admission_class Agent_core.Llm_provider.Admission_class.Background)
        ; test_case "real HTTP admission preserves trusted Standard" `Quick
            (test_http_flow_preserves_host_admission_class Agent_core.Llm_provider.Admission_class.Standard)
        ; test_case "worker names cannot select Background" `Quick test_worker_names_do_not_grant_background
        ; test_case "a settled Curator original leaves its Exact files to the sweep" `Quick
            test_a_settled_curator_original_leaves_its_exact_files_to_the_sweep ] ) ]
