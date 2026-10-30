open Alcotest

(* The Runtime message floor reads one message at a time. These cases pin the
   rules its machine applies, through the production inference path: only the
   HTTP provider is a fixture. A request body names the message it carries, so a
   fixture reply can refuse or accept one message without counting calls. *)

module Librarian = Masc.Keeper_librarian
module Floor = Masc.Keeper_librarian_message_floor
module Unread = Masc.Keeper_librarian_unread
module Program = Masc.Keeper_memory_os_program
module Refusal = Masc.Keeper_librarian_input_refusal
module Runtime = Masc.Keeper_librarian_runtime
module Plan = Masc.Keeper_librarian_memory_plan
module Machine = Floor.Machine
module Memory = Masc.Keeper_memory_os_types
module Memory_program = Masc.Keeper_librarian_memory_program
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

let ok = function Ok value -> value | Error detail -> fail detail

type outcome =
  | Answered of Runtime.served_slot * Runtime.memory_step
  | Unreadable of Refusal.t list * Unread.t

let machine_of ?(tools = []) messages =
  let source = input ~tools messages in
  let read =
    Machine.read ~keeper_name:keeper ~sources:(sources_of messages) ~unread_messages:[]
      ~previous_state:None source |> ok in
  let plan =
    Plan.create ~keeper_id:source.keeper_id ~turn_ref:source.turn_ref ~snapshot:None
    |> Result.map_error Plan.error_to_string |> ok in
  Machine.start ~transaction_id:"floor-machine-test" ~plan read |> ok

let ask machine = match Machine.next machine |> ok with
  | Machine.Ask question -> question
  | Machine.Finished _ -> fail "the machine finished where a question was expected"

let finished machine = match Machine.next machine |> ok with
  | Machine.Finished finished -> finished
  | Machine.Ask _ -> fail "the machine asked where it should have finished"

(* Drive a machine with real Runtime calls and keep what it asked and what it
   was told, in order. *)
let drive_recording ~base_path ~keepers_dir messages machine =
  let rec go machine questions outcomes =
    match Machine.next machine |> ok with
    | Machine.Finished _ -> machine, List.rev questions, List.rev outcomes
    | Machine.Ask question ->
      (match Runtime.infer_memory_step ~base_path ~keepers_dir ~keeper_id:keeper
         ~previous_state:question.previous_state ~unread_messages:question.unread_messages
         question.input with
       | Runtime.Memory_inferred { step; served_by } ->
         go (Machine.answered machine ~served_by step |> ok) (question :: questions)
           (Answered (served_by, step) :: outcomes)
       | Runtime.Memory_not_inferred { exhausted_input_refusals = Some (_ :: _ as reasons); _ } ->
         let source = List.hd question.sources in
         let hole = unread_message messages source ~reasons |> ok in
         go (Machine.unreadable machine ~reasons ~hole |> ok) (question :: questions)
           (Unreadable (reasons, hole) :: outcomes)
       | Runtime.Memory_not_inferred _ -> fail "a recorded run needs every message answered or exhausted")
  in
  go machine [] []

let apply machine = function
  | Answered (served_by, step) -> Machine.answered machine ~served_by step |> ok
  | Unreadable (reasons, hole) -> Machine.unreadable machine ~reasons ~hole |> ok

let test_a_machine_rebuilt_from_its_outcomes_asks_the_same_questions () =
  with_floor ~refuse:[ "oversized message" ] @@ fun ~base_path ~keepers_dir ~server:_ ->
  let messages = [ message "first message"; message "oversized message"; message "third message" ] in
  let done_machine, questions, outcomes =
    drive_recording ~base_path ~keepers_dir messages (machine_of ~tools:[ tool "tool-once" ] messages)
  in
  check int "three questions, three outcomes" 3 (List.length outcomes);
  check bool "asking twice without an outcome gives the same question" true
    (let fresh = machine_of messages in ask fresh = ask fresh);
  (* A restart keeps only the outcomes. Replay them on a machine built from
     nothing else and require it to ask what the first machine asked. *)
  let replayed =
    List.fold_left2
      (fun machine question outcome ->
         check bool "the rebuilt machine asks the question the first one asked" true
           (ask machine = question);
         apply machine outcome)
      (machine_of ~tools:[ tool "tool-once" ] messages) questions outcomes
  in
  let original = finished done_machine and rebuilt = finished replayed in
  check bool "and finishes the same program" true
    (Yojson.Safe.equal (Program.to_json original.program) (Program.to_json rebuilt.program));
  check (option string) "with the same working state" original.working_state rebuilt.working_state;
  check int "the refused message stays unread" 1 (List.length rebuilt.program.unread)

let test_an_outcome_that_does_not_fit_the_question_is_refused () =
  with_floor ~refuse:[ "oversized message" ] @@ fun ~base_path ~keepers_dir ~server:_ ->
  let messages = [ message "oversized message"; message "second message" ] in
  let sources = sources_of messages in
  let machine = machine_of messages in
  let reasons = [ Refusal.Request_body_refused ] in
  let hole_for index ~reasons =
    unread_message messages (List.nth sources index) ~reasons |> ok in
  let refused label = function
    | Ok _ -> failf "%s was accepted" label
    | Error (_ : string) -> () in
  refused "a hole for another message"
    (Machine.unreadable machine ~reasons ~hole:(hole_for 1 ~reasons));
  refused "a hole naming other causes than the refusal"
    (Machine.unreadable machine ~reasons ~hole:(hole_for 0 ~reasons:[ Refusal.Input_capacity ]));
  (* Run to the end, then the machine has no question left to answer. *)
  let final_machine, _, outcomes = drive_recording ~base_path ~keepers_dir messages machine in
  let step = List.find_map (function Answered (served_by, step) -> Some (served_by, step) | Unreadable _ -> None)
    outcomes |> Option.get in
  refused "an answer after the last question"
    (Machine.answered final_machine ~served_by:(fst step) (snd step));
  refused "a hole after the last question"
    (Machine.unreadable final_machine ~reasons ~hole:(hole_for 0 ~reasons));
  (* Host observations asked alone cannot be unread. *)
  let alone = machine_of ~tools:[ tool "tool-with-no-message-left" ] [ message "oversized message" ] in
  let after_hole =
    Machine.unreadable alone ~reasons
      ~hole:(unread_message [ message "oversized message" ] (List.hd (sources_of [ message "oversized message" ]))
               ~reasons |> ok)
    |> ok in
  let question = ask after_hole in
  check bool "the observations are asked alone" true (question.sources = []);
  refused "a hole for the observation-only question"
    (Machine.unreadable after_hole ~reasons
       ~hole:(hole_for 0 ~reasons));
  (* A plan that already staged a decision cannot start a floor. *)
  let staged_plan =
    let source = input [ message "second message" ] in
    let plan = Plan.create ~keeper_id:source.keeper_id ~turn_ref:source.turn_ref ~snapshot:None |> Result.map_error Plan.error_to_string |> ok in
    let _, _, outcomes = drive_recording ~base_path ~keepers_dir [ message "second message" ]
      (machine_of [ message "second message" ]) in
    match outcomes with
    | [ Answered (_, step) ] -> Plan.append plan step |> Result.map_error Plan.error_to_string |> ok
    | _ -> fail "expected one answered step" in
  let read =
    Machine.read ~keeper_name:keeper ~sources:(sources_of messages) ~unread_messages:[]
      ~previous_state:None (input messages) |> ok in
  refused "a floor started from a staged plan"
    (Machine.start ~transaction_id:"floor-machine-test" ~plan:staged_plan read)

(* {1 Durable steps}

   A durable floor step must ask the question the Runtime floor asks and give
   the plan the decision the Runtime floor would. The Runtime side of each
   comparison is the production inference path against the fixture provider. *)

let current_fact = Memory.observed ~claim:"a fact already in Memory" ~category:Memory.Fact ~now:1_000_000.
  ~origin:{ Memory.kind = Memory.Authored; trace_id = "" }

let earlier_hole () =
  let earlier = message "an earlier message nobody could read" in
  unread_message [ earlier; message "the message in question" ] (source_of 0 earlier)
    ~reasons:[ Refusal.Request_body_refused ] |> ok

(* What the fixture provider answers to its first request. *)
let first_answer = answer_for ~claim:"claim number 1" ~state:"state number 1"

let step_context () : Runtime.durable_step_context =
  { previous_state = Some "carried-in state"; unread_messages = [ earlier_hole () ] }

let question_input ?(current = None) () =
  { (input ~tools:[ tool "tool-in-the-question" ] [ message "the message in question" ]) with current }

let runtime_step ~base_path ~keepers_dir (context : Runtime.durable_step_context) question =
  match Runtime.infer_memory_step ~base_path ~keepers_dir ~keeper_id:keeper
          ~previous_state:context.previous_state ~unread_messages:context.unread_messages question with
  | Runtime.Memory_inferred { step; _ } -> step
  | Runtime.Memory_not_inferred _ -> fail "the Runtime floor refused the question"

let test_a_durable_step_asks_the_runtime_floors_question () =
  with_floor @@ fun ~base_path ~keepers_dir ~server:_ ->
  let context = step_context () in
  let question = question_input ~current:(Some { Librarian.facts = [ current_fact ] }) () in
  let prepared = Runtime.prepare_durable_step ~now:1_000_000. ~context question |> ok in
  let runtime = runtime_step ~base_path ~keepers_dir context question in
  check string "the rendered prompt is the Runtime floor's" runtime.rendered_prompt
    prepared.preparation.rendered_prompt;
  check bool "so are its variables and the input they were rendered from" true
    (runtime.prompt_variables = prepared.preparation.variables
     && runtime.source_input = prepared.preparation.source_input);
  check bool "the continuity slot carries the working state and the unread message" true
    (contains prepared.preparation.rendered_prompt "carried-in state"
     && contains prepared.preparation.rendered_prompt
          (Unread.message_digest (message "an earlier message nobody could read")));
  check bool "the schema asks for a working state" true
    (Yojson.Safe.equal prepared.preparation.output_schema
       Masc.Keeper_structured_output_schema.librarian_continuity_output_schema)

let test_a_retained_step_makes_the_decision_the_runtime_floor_makes () =
  with_floor @@ fun ~base_path ~keepers_dir ~server:_ ->
  let context = step_context () in
  let question = question_input () in
  let prepared = Runtime.prepare_durable_step ~now:1_000_000. ~context question |> ok in
  let runtime = runtime_step ~base_path ~keepers_dir context question in
  let proposal =
    Runtime.validate_durable_step_proposal prepared first_answer
    |> Result.map_error (fun _ -> "the step proposal was refused") |> ok in
  let retained =
    Runtime.durable_memory_step ~run_id:"retained-step-1" prepared proposal
      ~absorb_gate:runtime.absorb_gate |> ok in
  let claims (step : Runtime.memory_step) =
    List.map (fun (fact : Memory.fact) -> fact.claim, fact.category) step.new_claims in
  check bool "the gated decision carries the same input, prompt and judgment" true
    (retained.source_input = runtime.source_input && retained.prompt_variables = runtime.prompt_variables
     && retained.rendered_prompt = runtime.rendered_prompt && retained.absorb_gate = runtime.absorb_gate);
  check bool "and the same Memory change" true
    (claims retained = claims runtime && retained.dropped = runtime.dropped
     && retained.absorbed = runtime.absorbed && retained.revisions = runtime.revisions
     && retained.working_state = runtime.working_state);
  (* The plan and the program take it exactly as they take the Runtime's. *)
  let plan =
    Plan.create ~keeper_id:retained.source_input.keeper_id ~turn_ref:retained.source_input.turn_ref
      ~snapshot:None |> Result.map_error Plan.error_to_string |> ok in
  let staged = Plan.append plan retained |> Result.map_error Plan.error_to_string |> ok in
  check bool "the plan stages its facts" true
    (match Plan.current staged with Some current -> List.length current.facts = 1 | None -> false);
  let sources = sources_of retained.source_input.messages in
  check bool "the program binds it to the message it judged" true
    (match Memory_program.decision ~sources retained with Ok _ -> true | Error _ -> false);
  check bool "a blank run identity is no decision" true
    (match Runtime.durable_memory_step ~run_id:"  " prepared proposal ~absorb_gate:runtime.absorb_gate with
     | Error _ -> true | Ok _ -> false)

let test_a_restored_omitted_step_cannot_become_a_live_program_decision () =
  with_floor @@ fun ~base_path ~keepers_dir ~server:_ ->
  let context=step_context () and question=question_input () in
  let prepared=Runtime.prepare_durable_step ~now:1_000_000. ~context question |> ok in
  let runtime=runtime_step ~base_path ~keepers_dir context question in
  let key=Masc.Prompt_names.librarian in
  let previous=(Masc.Prompt_registry.resolve_prompt key).override_value in
  Fun.protect ~finally:(fun () -> match previous with
    | None -> Masc.Prompt_registry.clear_prompt_override key
    | Some value -> Masc.Prompt_registry.set_override key value |> ok) (fun () ->
    Masc.Prompt_registry.set_override key "Legacy question omitting counterpart observations" |> ok;
    let counterpart : Masc.Keeper_counterpart_observation.t =
      {origin=Durable_chat;channel="direct";workspace_id=None;user_id=None;user_name=None;
       authority=External;content="Retained observation not sent by the legacy question"} in
    let p=prepared.preparation in
    let legacy=Runtime.restore_durable_step_preparation ~context
      ~source_input:{p.source_input with counterpart_observations=[counterpart]} ~parsing_now:p.parsing_now
      ~policy:p.policy ~rule_prompt:p.rule_prompt ~prompt:(Masc.Prompt_registry.resolve_prompt key)
      ~output_schema:p.output_schema |> ok in
    Runtime.validate_durable_step_preparation legacy |> ok;
    let proposal=Runtime.validate_durable_step_proposal legacy first_answer
      |> Result.map_error (fun _ -> "the structurally restored legacy answer was refused") |> ok in
    match Runtime.durable_memory_step ~run_id:"legacy-unpublished-step" legacy proposal
        ~absorb_gate:runtime.absorb_gate with
    | Error detail -> check bool "a retained gate result cannot hide omitted observations" true
        (contains detail "counterpart_observations")
    | Ok _ -> fail "an omitted legacy question became a new program decision")

let test_a_step_preparation_restores_and_refuses_tampering () =
  with_floor @@ fun ~base_path:_ ~keepers_dir:_ ~server:_ ->
  let context = step_context () in
  let prepared = Runtime.prepare_durable_step ~now:1_000_000. ~context (question_input ()) |> ok in
  let restored =
    Runtime.restore_durable_step_preparation ~context ~source_input:prepared.preparation.source_input
      ~parsing_now:prepared.preparation.parsing_now ~policy:prepared.preparation.policy
      ~rule_prompt:prepared.preparation.rule_prompt ~prompt:prepared.preparation.prompt
      ~output_schema:prepared.preparation.output_schema |> ok in
  check bool "restoring from the frozen parts renders the same step" true (restored = prepared);
  let refused label step =
    match Runtime.validate_durable_step_preparation step with
    | Ok () -> failf "%s was accepted" label
    | Error (_ : string) -> () in
  refused "another working state than the prompt was rendered with"
    { prepared with context = { context with previous_state = Some "another state" } };
  refused "another unread list than the prompt was rendered with"
    { prepared with context = { context with unread_messages = [] } };
  refused "the schema of a pass that asks for no working state"
    { prepared with preparation =
        { prepared.preparation with
          output_schema = Masc.Keeper_structured_output_schema.librarian_current_output_schema } };
  refused "an input that still holds a working context"
    { prepared with preparation =
        { prepared.preparation with
          source_input =
            { prepared.preparation.source_input with
              working_context = { Masc.Keeper_librarian_context.empty with unavailable = [ "pending" ] } } } };
  refused "a rendered prompt that is not the substitution of its input"
    { prepared with preparation = { prepared.preparation with rendered_prompt = "tampered" } };
  (* The substitutions can agree with an input that still holds a working
     context: restoring from one re-renders consistently, so only the rule that
     a floor question carries none refuses it. *)
  check bool "a restore from an input that still holds a working context is refused" true
    (match
       Runtime.restore_durable_step_preparation ~context
         ~source_input:
           { prepared.preparation.source_input with
             working_context = { Masc.Keeper_librarian_context.empty with unavailable = [ "pending" ] } }
         ~parsing_now:prepared.preparation.parsing_now ~policy:prepared.preparation.policy
         ~rule_prompt:prepared.preparation.rule_prompt ~prompt:prepared.preparation.prompt
         ~output_schema:prepared.preparation.output_schema
     with
     | Error (_ : string) -> true
     | Ok _ -> false)

let test_a_step_answer_needs_a_working_state () =
  with_floor @@ fun ~base_path:_ ~keepers_dir:_ ~server:_ ->
  let prepared = Runtime.prepare_durable_step ~now:1_000_000. ~context:(step_context ()) (question_input ()) |> ok in
  let with_state state = `Assoc
    [ "new_claims", `List []; "dropped", `List []; "working_contexts", `List []; "working_state", state ] in
  let verdict answer = match Runtime.validate_durable_step_proposal prepared answer with
    | Ok proposal -> Ok proposal.working_state
    | Error (_ : Runtime.durable_proposal_error) -> Error () in
  check bool "a nonblank working state is read" true (verdict (with_state (`String "kept")) = Ok "kept");
  check bool "a null working state is refused" true (verdict (with_state `Null) = Error ());
  check bool "a blank working state is refused" true (verdict (with_state (`String "  ")) = Error ());
  check bool "an answer with no working state is refused" true
    (verdict (`Assoc [ "new_claims", `List []; "dropped", `List []; "working_contexts", `List [] ]) = Error ())

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
    ; ( "durable step"
      , [ test_case "a durable step asks the question the Runtime floor asks" `Quick
            test_a_durable_step_asks_the_runtime_floors_question
        ; test_case "a retained step makes the decision the Runtime floor makes" `Quick
            test_a_retained_step_makes_the_decision_the_runtime_floor_makes
        ; test_case "a step preparation restores from its frozen parts and refuses tampering" `Quick
            test_a_step_preparation_restores_and_refuses_tampering
        ; test_case "a restored omitted question cannot become a live program decision" `Quick
            test_a_restored_omitted_step_cannot_become_a_live_program_decision
        ; test_case "a step answer needs a nonblank working state" `Quick
            test_a_step_answer_needs_a_working_state
        ] )
    ; ( "machine"
      , [ test_case "a machine rebuilt from its outcomes asks the same questions" `Quick
            test_a_machine_rebuilt_from_its_outcomes_asks_the_same_questions
        ; test_case "an outcome that does not fit the pending question is refused" `Quick
            test_an_outcome_that_does_not_fit_the_question_is_refused
        ] )
    ]
