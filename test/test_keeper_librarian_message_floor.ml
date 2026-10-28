open Alcotest

(* The Runtime message floor reads one message at a time. These cases pin the
   rules its fold applies, through the production inference path: only the HTTP
   provider is a fixture. A request body names the message it carries, so a
   fixture reply can refuse or accept one message without counting calls. *)

module Librarian = Masc.Keeper_librarian
module Floor = Masc.Keeper_librarian_message_floor
module Unread = Masc.Keeper_librarian_unread
module Program = Masc.Keeper_memory_os_program
module Refusal = Masc.Keeper_librarian_input_refusal
module Fixture = Exact_output_fixture

let () = Masc.Prompt_defaults.init ()

let keeper = "message-floor-keeper"
let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-message-floor" ~absolute_turn:3
let boundary_line = 1

let message text = Agent_core.Types.make_message ~role:Agent_core.Types.User [ Agent_core.Types.Text text ]

let source_of index message =
  Unread.Official_turn
    { turn_ref; boundary_line; message_in_turn = index; message_sha256 = Unread.message_digest message }

let sources_of messages = List.mapi source_of messages

let unread_message messages source ~reasons =
  match source with
  | Unread.Official_turn { turn_ref; boundary_line; message_in_turn; _ } ->
    Unread.for_official_turn ~turn_ref ~boundary_line ~message_in_turn ~messages ~reasons
  | Unread.Atom _ -> Error "the floor fixture reads official turns only"

let input ?(tools = []) messages : Librarian.input =
  { turn_ref
  ; historical_task_contexts = []
  ; goal_context = Librarian.No_task
  ; keeper_id = Masc_test_deps.keeper_id_fixture keeper
  ; keeper_instructions = "You are the message-floor keeper."
  ; current = None
  ; messages
  ; tool_observations = tools
  ; working_context = Masc.Keeper_librarian_context.empty
  ; counterpart_observations = []
  }

let tool name : Librarian.tool_observation = { tool_name = name; outcome = Librarian.Succeeded }

let contains haystack needle = Astring.String.is_infix ~affix:needle haystack

(* The provider refuses a body that carries [refuse] with a named size refusal,
   fails one that carries [fail] with an unnamed server error, and answers any
   other request with a Memory decision whose working state counts the answers
   so far. *)
let answer_for ~claim ~state =
  `Assoc
    [ "new_claims", `List [ `Assoc [ "claim", `String claim; "category", `String "fact" ] ]
    ; "dropped", `List []
    ; "working_contexts", `List []
    ; "working_state", `String state
    ]

let provider ?(refuse = []) ?(fail = []) () =
  let answered = ref 0 in
  Fixture.Reply_with
    (fun _index body ->
       let refusal status =
         status, {|{"error":{"message":"fixture refusal","type":"invalid_request_error"}}|}
       in
       if List.exists (contains body) refuse then refusal `Request_entity_too_large
       else if List.exists (contains body) fail then refusal `Internal_server_error
       else begin
         incr answered;
         ( `OK
         , Fixture.openai_response
             (answer_for
                ~claim:(Printf.sprintf "claim number %d" !answered)
                ~state:(Printf.sprintf "state number %d" !answered)) )
       end)

let with_floor ?refuse ?fail f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
  @@ fun () ->
  let base_path = Filename.temp_dir "librarian-message-floor" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path)
  @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key
    (Some (Filename.concat base_path "config"))
  @@ fun () ->
  Fixture.with_official_client_runtimes
  @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    { Runtime_schema.default_typesafeai with lane_enabled = false; absorb_gate = false }
  @@ fun () ->
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  let server =
    Fixture.start_server ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      (provider ?refuse ?fail ())
  in
  let slot = "message-floor-slot" in
  ignore
    (Fixture.publish_registry ~lane_id:"librarian_exact" ~slot_ids:[ slot ]
       (Fixture.resolver_snapshot ~source:"message floor"
          [ { Fixture.id = slot; base_url = server.base_url } ])
     : Runtime_exact_output_registry.t);
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  f ~base_path ~keepers_dir ~server

let infer ~base_path ~keepers_dir ?(previous_state = None) ?(unread_messages = [])
    ?sources input =
  let sources = Option.value sources ~default:(sources_of input.Librarian.messages) in
  Floor.infer ~base_path ~keepers_dir ~keeper_name:keeper ~sources
    ~unread_message:(unread_message input.Librarian.messages)
    ~previous_state ~unread_messages input

let prepared = function
  | Ok value -> value
  | Error (error : Floor.error) -> failf "the floor refused: %s" error.detail

(* Request bodies in the order the provider received them. *)
let requests (server : Fixture.test_server) = List.rev (Atomic.get server.requests)

let stage_sources (program : Program.t) =
  List.map (fun (stage : Program.stage) -> stage.decision.sources) program.stages

let check_sources label expected actual =
  check (list (list string)) label
    (List.map (List.map (fun source -> Yojson.Safe.to_string (Unread.source_to_json source))) expected)
    (List.map (List.map (fun source -> Yojson.Safe.to_string (Unread.source_to_json source))) actual)

let test_every_message_is_read_in_order () =
  with_floor @@ fun ~base_path ~keepers_dir ~server ->
  let messages = [ message "first message"; message "second message" ] in
  let result =
    infer ~base_path ~keepers_dir ~previous_state:(Some "carried-in state") (input messages)
    |> prepared
  in
  check_sources "one stage per message, in order" (List.map (fun s -> [ s ]) (sources_of messages))
    (stage_sources result.program);
  check (list string) "the stages' working states follow the answers"
    [ "state number 1"; "state number 2" ]
    (List.map (fun (stage : Program.stage) -> stage.decision.working_state) result.program.stages);
  check (option string) "the last accepted working state is returned" (Some "state number 2")
    result.working_state;
  check int "no message is unread" 0 (List.length result.program.unread);
  (match result.program.stages with
   | [ first; second ] ->
     check bool "the first message sees no staged facts" true (first.decision.input_current = None);
     check bool "the second message sees what the first one staged" true
       (match second.decision.input_current with
        | Some facts -> List.length facts = 1
        | None -> false)
   | _ -> fail "expected exactly two stages");
  (match requests server with
   | [ first; second ] ->
     check bool "the first request carries the caller's working state" true
       (contains first "carried-in state");
     check bool "the second request carries the first answer's working state" true
       (contains second "state number 1");
     check bool "each request carries only its own message" true
       (contains first "first message" && not (contains first "second message")
        && contains second "second message" && not (contains second "first message"))
   | other -> failf "expected two provider requests, saw %d" (List.length other))

let test_an_exhausted_message_becomes_an_unread_hole () =
  with_floor ~refuse:[ "oversized message" ] @@ fun ~base_path ~keepers_dir ~server ->
  let messages = [ message "first message"; message "oversized message"; message "third message" ] in
  let result = infer ~base_path ~keepers_dir (input messages) |> prepared in
  let sources = sources_of messages in
  check_sources "the unread message is in no stage"
    [ [ List.nth sources 0 ]; [ List.nth sources 2 ] ]
    (stage_sources result.program);
  (match result.program.unread with
   | [ hole ] ->
     check string "the hole names the refused message"
       (Yojson.Safe.to_string (Unread.source_to_json (List.nth sources 1)))
       (Yojson.Safe.to_string (Unread.source_to_json hole.source));
     check bool "the hole keeps the named provider cause" true
       (hole.reasons = [ Refusal.Request_body_refused ])
   | other -> failf "expected one unread hole, saw %d" (List.length other));
  check int "the refused message was asked once" 3 (Fixture.post_count server);
  (match requests server with
   | [ _; _; third ] ->
     check bool "the message after a hole is told about the hole" true
       (contains third (Unread.message_digest (List.nth messages 1)));
     check bool "and continues from the last accepted working state" true
       (contains third "state number 1")
   | other -> failf "expected three provider requests, saw %d" (List.length other));
  (match result.program.stages with
   | [ _; third ] ->
     check bool "the message after a hole sees the staged facts of the one before it" true
       (match third.decision.input_current with Some facts -> List.length facts = 1 | None -> false)
   | _ -> fail "expected exactly two stages")

let test_an_unnamed_failure_stops_the_floor () =
  with_floor ~fail:[ "failing message" ] @@ fun ~base_path ~keepers_dir ~server ->
  let messages = [ message "first message"; message "failing message"; message "third message" ] in
  (match infer ~base_path ~keepers_dir (input messages) with
   | Ok _ -> fail "a failure with no named input refusal was read past"
   | Error (error : Floor.error) ->
     check string "the error says which message was not read" "message 1 was not read" error.detail;
     check bool "the actual provider reports are kept" true (error.reports <> []));
  check int "the message after the failure was never asked" 2 (Fixture.post_count server)

let test_host_observations_ride_on_the_first_accepted_message () =
  with_floor ~refuse:[ "oversized message" ] @@ fun ~base_path ~keepers_dir ~server ->
  let messages = [ message "oversized message"; message "second message"; message "third message" ] in
  let result =
    infer ~base_path ~keepers_dir (input ~tools:[ tool "tool-observed-once" ] messages) |> prepared
  in
  check int "one hole, two stages" 2 (List.length result.program.stages);
  (match requests server with
   | [ refused; accepted; later ] ->
     check bool "the refused message carried the observation" true (contains refused "tool-observed-once");
     check bool "the next message carries it too, because none accepted it yet" true
       (contains accepted "tool-observed-once");
     check bool "a message after an accepted step does not" false (contains later "tool-observed-once")
   | other -> failf "expected three provider requests, saw %d" (List.length other))

let test_observations_without_a_message_get_their_own_step () =
  with_floor ~refuse:[ "oversized message" ] @@ fun ~base_path ~keepers_dir ~server ->
  let messages = [ message "oversized message" ] in
  let result =
    infer ~base_path ~keepers_dir (input ~tools:[ tool "tool-with-no-message-left" ] messages)
    |> prepared
  in
  check_sources "the only stage reads no conversation message" [ [] ] (stage_sources result.program);
  check int "the refused message stays unread" 1 (List.length result.program.unread);
  (match requests server with
   | [ _refused; observation_only ] ->
     check bool "the observation-only request carries the observation" true
       (contains observation_only "tool-with-no-message-left");
     check bool "and not the refused message" false (contains observation_only "oversized message")
   | other -> failf "expected two provider requests, saw %d" (List.length other))

let test_a_source_manifest_that_disagrees_is_refused_before_any_call () =
  with_floor @@ fun ~base_path ~keepers_dir ~server ->
  let messages = [ message "first message"; message "second message" ] in
  let swapped = List.rev (sources_of messages) in
  (match infer ~base_path ~keepers_dir ~sources:swapped (input messages) with
   | Ok _ -> fail "a manifest in another order was accepted"
   | Error (error : Floor.error) ->
     check bool "the error names the hash disagreement" true
       (contains error.detail "source hash differs"));
  check int "no provider was called" 0 (Fixture.post_count server);
  (match infer ~base_path ~keepers_dir ~sources:[] (input messages) with
   | Ok _ -> fail "an empty manifest was accepted"
   | Error (error : Floor.error) ->
     check bool "an empty manifest is refused" true (contains error.detail "nonempty"));
  check int "still no provider call" 0 (Fixture.post_count server)

let () =
  run "keeper_librarian_message_floor"
    [ ( "message floor"
      , [ test_case "every message is read in order, threading state and staged facts" `Quick
            test_every_message_is_read_in_order
        ; test_case "a message every slot refused for size becomes an unread hole" `Quick
            test_an_exhausted_message_becomes_an_unread_hole
        ; test_case "a failure with no named input refusal stops the floor" `Quick
            test_an_unnamed_failure_stops_the_floor
        ; test_case "host observations ride on the first accepted message" `Quick
            test_host_observations_ride_on_the_first_accepted_message
        ; test_case "observations with no message left get their own step" `Quick
            test_observations_without_a_message_get_their_own_step
        ; test_case "a source manifest that disagrees is refused before any call" `Quick
            test_a_source_manifest_that_disagrees_is_refused_before_any_call
        ] )
    ]
