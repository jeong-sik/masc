open Alcotest

(* A message-floor step is an original of its own: a scope, an ID format and a
   record kind that completed-history discovery never reads. These cases pin
   what makes a step that one question of one chain: it restores from its record
   alone with its own input, matches only the question the floor's machine asks
   after the same answers, names its range and previous step by ID and digest,
   and cannot be mistaken for a history original. *)

module Librarian = Masc.Keeper_librarian
module Machine = Masc.Keeper_librarian_message_floor.Machine
module Unread = Masc.Keeper_librarian_unread
module Refusal = Masc.Keeper_librarian_input_refusal
module Runtime = Masc.Keeper_librarian_runtime
module Plan = Masc.Keeper_librarian_memory_plan
module Durable = Masc.Keeper_librarian_durable_request
module Step = Masc.Keeper_librarian_floor_step_request
module Owner = Masc.Lane_addon_tool_request_owner
module Exact = Masc.Lane_addon_exact
module Memory = Masc.Keeper_memory_os_current

let () = Masc.Prompt_defaults.init ()

let keeper = "floor-step-keeper"
let other_keeper = "floor-step-other-keeper"
let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-floor-step" ~absolute_turn:5
let boundary_line = 1
let ok = function Ok value -> value | Error detail -> fail detail
let contains haystack needle = Astring.String.is_infix ~affix:needle haystack

let expect_error label ~mentioning = function
  | Ok _ -> failf "%s was accepted" label
  | Error (detail : string) ->
    check bool (Printf.sprintf "%s names its cause (%s)" label detail) true (contains detail mentioning)

let message text = Agent_core.Types.make_message ~role:Agent_core.Types.User [ Agent_core.Types.Text text ]

let source_of index message =
  Unread.Official_turn
    { turn_ref; boundary_line; message_in_turn = index; message_sha256 = Unread.message_digest message }

let sources_of messages = List.mapi source_of messages

let input ?(keeper_name = keeper) messages : Librarian.input =
  { turn_ref
  ; historical_task_contexts = []
  ; goal_context = Librarian.No_task
  ; keeper_id = Masc_test_deps.keeper_id_fixture keeper_name
  ; keeper_instructions = "You are the floor-step keeper."
  ; current = None
  ; messages
  ; tool_observations = []
  ; working_context = Masc.Keeper_librarian_context.empty
  ; counterpart_observations = []
  }

let first_message = message "the first message of the turn"
let second_message = message "the second message of the turn"
let messages = [ first_message; second_message ]

let machine_over ?(keeper_name = keeper) ?(previous_state = None) messages =
  let source = input ~keeper_name messages in
  let read =
    Machine.read ~keeper_name ~sources:(sources_of messages) ~unread_messages:[] ~previous_state
      source |> ok in
  let plan =
    Plan.create ~keeper_id:source.keeper_id ~turn_ref:source.turn_ref ~snapshot:None
    |> Result.map_error Plan.error_to_string |> ok in
  Machine.start ~transaction_id:"floor-step-request-test" ~plan read |> ok

let ask machine = match Machine.next machine |> ok with
  | Machine.Ask question -> question
  | Machine.Finished _ -> fail "the machine finished where a question was expected"

(* The first message could not be read: the floor records it as unread and asks
   about the second. *)
let skip machine messages =
  let question = ask machine in
  let reasons = [ Refusal.Request_body_refused ] in
  let hole =
    match List.hd question.sources with
    | Unread.Official_turn { turn_ref; boundary_line; message_in_turn; _ } ->
      Unread.for_official_turn ~turn_ref ~boundary_line ~message_in_turn ~messages ~reasons |> ok
    | Unread.Atom _ -> fail "the fixture reads official turns only" in
  Machine.unreadable machine ~reasons ~hole |> ok

(* The first question the floor asks about an input of the test's choosing. *)
let question_over (source : Librarian.input) =
  let read =
    Machine.read ~keeper_name:keeper ~sources:(sources_of source.messages) ~unread_messages:[]
      ~previous_state:None source |> ok in
  let plan =
    Plan.create ~keeper_id:source.keeper_id ~turn_ref:source.turn_ref ~snapshot:None
    |> Result.map_error Plan.error_to_string |> ok in
  ask (Machine.start ~transaction_id:"floor-step-test" ~plan read |> ok)

let prepare (question : Machine.question) =
  Runtime.prepare_durable_step ~now:1_000_000.
    ~context:{ Runtime.previous_state = question.previous_state; unread_messages = question.unread_messages }
    question.input |> ok

let sha_hex character = String.make 64 character

let canonical_installation = Owner.installation_id (Owner.Configuration "floor-step-declaration")

let destination : Durable.destination =
  { installation_id = canonical_installation
  ; package_id = Durable.package_id
  ; tool = Durable.tool
  ; source_revision = String.make 40 '1'
  ; configuration_revision = String.make 40 '2'
  }

let with_fixture f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Masc_test_deps.ensure_rng_initialized ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "librarian-floor-step" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) (fun () ->
      let config = Masc.Workspace.default_config base_path in
      ignore (Masc.Workspace.init config ~agent_name:(Some keeper));
      List.iter (fun name ->
        Masc_test_deps.declare_fixture_keeper ~sandbox_image:"base" ~base_path
          ~sandbox_profile:(Some Masc.Keeper_types_profile.Docker) name) [ keeper; other_keeper ];
      Masc.Keeper_types_profile.invalidate_keeper_profile_snapshots ();
      let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
      let owner_of name =
        (match Memory.ensure_epoch ~keepers_dir ~keeper_id:name with
         | Ok _ -> ()
         | Error detail -> fail ("the Memory epoch could not be created: " ^ detail));
        Durable.observe_owner ~base_path ~keepers_dir ~keeper_id:name |> ok in
      Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
      let stores = ref 0 in
      let fresh_store () =
        incr stores;
        Masc.Lane_addon_store.create ~root:(Filename.concat base_path (Printf.sprintf "store-%d" !stores)) in
      f ~owner:(owner_of keeper) ~other_owner:(owner_of other_keeper) ~fresh_store))

let digest_of step = Owner.request_digest (Step.to_json step) |> ok

(* The two-step chain the floor builds when its first message is unreadable. *)
type chain = {
  range : Step.link;
  first_question : Machine.question;
  first_step : Step.t;
  second_question : Machine.question;
  second_step : Step.t;
}

let chain ~owner =
  let range = { Step.request_id = Durable.fresh_request_id owner; request_digest = sha_hex 'a' } in
  let machine = machine_over messages in
  let first_question = ask machine in
  let first_step =
    Step.create ~request_id:(Step.fresh_request_id owner) ~owner ~destination ~range ~previous:None
      ~question:first_question ~step:(prepare first_question) () |> ok in
  let second_question = ask (skip machine messages) in
  let second_step =
    Step.create ~request_id:(Step.fresh_request_id owner) ~owner ~destination ~range
      ~previous:(Some { Step.request_id = Step.request_id first_step; request_digest = digest_of first_step })
      ~question:second_question ~step:(prepare second_question) () |> ok in
  { range; first_question; first_step; second_question; second_step }

let retain ?request_id ~store step json =
  let scope = Step.scope (Step.physical_owner step) in
  let request_id = Option.value request_id ~default:(Step.request_id step) in
  let destination = Step.destination step in
  (match Owner.retain ~store ~scope ~request_id ~installation_id:destination.installation_id
           ~package_id:destination.package_id ~tool:destination.tool ~summary:`Null ~request:json with
   | Ok () -> ()
   | Error error -> fail (Owner.error_to_string error));
  match Owner.load ~store ~scope ~request_id with
  | Ok (Some record) -> record
  | Ok None -> fail "the retained step was not observable"
  | Error error -> fail (Owner.error_to_string error)

let replace_field name replacement = function
  | `Assoc members ->
    `Assoc (List.map (fun (key, value) -> if key = name then key, replacement value else key, value) members)
  | _ -> fail "a step encodes as an object"

(* What the floor does with a retained step: restore it from its record, then
   ask whether it is the question the machine asks now. *)
let restore_for ~owner question record =
  match Step.restore ~owner record with
  | Error _ as error -> error
  | Ok step -> Result.map (fun () -> step) (Step.matches_question question step)

let test_a_step_restores_from_its_record_alone () =
  with_fixture @@ fun ~owner ~other_owner:_ ~fresh_store ->
  let chain = chain ~owner in
  let store = fresh_store () in
  let first_record = retain ~store chain.first_step (Step.to_json chain.first_step) in
  let second_record = retain ~store chain.second_step (Step.to_json chain.second_step) in
  let restored_first = Step.restore ~owner first_record |> ok in
  let restored_second = Step.restore ~owner second_record |> ok in
  check bool "the first step restores to what was created" true
    (Yojson.Safe.equal (Step.to_json restored_first) (Step.to_json chain.first_step));
  check bool "and so does the second" true
    (Yojson.Safe.equal (Step.to_json restored_second) (Step.to_json chain.second_step));
  Step.confirm_record restored_first first_record |> ok;
  Step.confirm_record restored_second second_record |> ok;
  Step.matches_question chain.first_question restored_first |> ok;
  Step.matches_question chain.second_question restored_second |> ok;
  check int "the first step is at position 0" 0 (Step.position restored_first);
  check int "the second at position 1" 1 (Step.position restored_second);
  check bool "the first has no previous step" true (Step.previous restored_first = None);
  check bool "the second names the first by ID and digest" true
    (Step.previous restored_second
     = Some { Step.request_id = Step.request_id restored_first; request_digest = first_record.request_digest });
  check bool "both name the range original" true
    (Step.range restored_first = chain.range && Step.range restored_second = chain.range);
  let input = (Step.step restored_second).preparation.source_input in
  check bool "the restored step holds its own input: the second message only" true
    (input.messages = [ second_message ]);
  let prompt = (Step.step restored_second).preparation.rendered_prompt in
  check bool "the second step's prompt carries the message the first left unread" true
    (contains prompt (Unread.message_digest first_message));
  let exact = Step.request restored_second |> ok in
  check string "the host request carries this step's ID" (Step.request_id restored_second) exact.Exact.request_id;
  check string "it asks for the durable output" "durable" exact.Exact.output;
  check bool "as one user message holding the rendered prompt" true
    (exact.Exact.messages = [ { Exact.role = Exact.User; text = prompt } ]);
  check bool "under the schema that requires a working state" true
    (match exact.Exact.schema with
     | Some schema ->
       Yojson.Safe.equal schema Masc.Keeper_structured_output_schema.librarian_continuity_output_schema
     | None -> false)

let test_a_question_that_differs_does_not_match_the_step () =
  with_fixture @@ fun ~owner ~other_owner:_ ~fresh_store ->
  let chain = chain ~owner in
  let first_record = retain ~store:(fresh_store ()) chain.first_step (Step.to_json chain.first_step) in
  let restored = Step.restore ~owner first_record |> ok in
  expect_error "the second question for the first step" ~mentioning:"not the question it was asked"
    (Step.matches_question chain.second_question restored);
  (* Same position, another message: the sources differ. *)
  let other = ask (machine_over [ message "another first message"; second_message ]) in
  expect_error "another message at the same position" ~mentioning:"not the question it was asked"
    (Step.matches_question other restored);
  (* Same position and message, another working state carried in. *)
  let carried = ask (machine_over ~previous_state:(Some "state carried in") messages) in
  expect_error "another carried working state" ~mentioning:"context differs"
    (Step.matches_question carried restored);
  (* Same position, message and context, another input around them. *)
  let around =
    question_over { (input messages) with keeper_instructions = "instructions around the same message" } in
  expect_error "another input around the same message" ~mentioning:"input differs from its question"
    (Step.matches_question around restored)

let test_a_tampered_request_is_refused () =
  with_fixture @@ fun ~owner ~other_owner ~fresh_store ->
  let chain = chain ~owner in
  let refused label ~mentioning question step edit =
    let record = retain ~store:(fresh_store ()) step (edit (Step.to_json step)) in
    expect_error label ~mentioning (restore_for ~owner question record) in
  refused "a moved position" ~mentioning:"not the question it was asked" chain.second_question
    chain.second_step (replace_field "position" (fun _ -> `Int 7));
  refused "a range digest that is no digest" ~mentioning:"link digest is invalid" chain.first_question
    chain.first_step (replace_field "range" (replace_field "request_digest" (fun _ -> `String "not-a-digest")));
  refused "a first step that names a previous step" ~mentioning:"position disagrees" chain.first_question
    chain.first_step
    (replace_field "previous" (fun _ ->
       `Assoc [ "request_id", `String (Step.request_id chain.second_step); "request_digest", `String (sha_hex 'b') ]));
  refused "a prompt digest that names another prompt" ~mentioning:"differs from the one its host request named"
    chain.first_question chain.first_step
    (replace_field "preparation" (replace_field "rendered_prompt_sha256" (fun _ -> `String (sha_hex 'c'))));
  refused "a step of another kind" ~mentioning:"schema or kind" chain.first_question chain.first_step
    (replace_field "kind" (fun _ -> `String "completed-history-execution"));
  refused "an input edited after its prompt was rendered" ~mentioning:"prompt differs" chain.first_question
    chain.first_step (replace_field "input" (replace_field "keeper_instructions" (fun _ -> `String "edited")));
  refused "a carried state edited after its prompt was rendered" ~mentioning:"prompt differs"
    chain.first_question chain.first_step
    (replace_field "context" (replace_field "previous_state" (fun _ -> `String "edited")));
  refused "a source that is not the hash of its message" ~mentioning:"source hash differs"
    chain.first_question chain.first_step
    (replace_field "sources" (fun _ -> `List [ Unread.source_to_json (source_of 0 (message "another message")) ]));
  let record = retain ~store:(fresh_store ()) chain.first_step (Step.to_json chain.first_step) in
  expect_error "a step restored for another owner" ~mentioning:"changed"
    (Step.restore ~owner:other_owner record)

(* The host reads a record's place in a chain, and the owner it names, before it
   restores the input; a record whose input is unreadable still has a header. *)
let test_a_header_and_an_owner_are_read_without_the_input () =
  with_fixture @@ fun ~owner ~other_owner ~fresh_store ->
  let chain = chain ~owner in
  let store = fresh_store () in
  let broken = retain ~store chain.second_step (replace_field "input" (fun _ -> `Null) (Step.to_json chain.second_step)) in
  expect_error "a step whose input is unreadable" ~mentioning:"" (Step.restore ~owner broken);
  let header = Step.header ~owner broken |> ok in
  check bool "still has its place in the chain" true
    (header.position = 1 && header.range = chain.range
     && header.previous = Some { Step.request_id = Step.request_id chain.first_step;
                                 request_digest = (retain ~store chain.first_step (Step.to_json chain.first_step)).request_digest }
     && header.sources = chain.second_question.sources);
  check bool "and the destination its request names" true (header.destination = Step.destination chain.second_step);
  let observed =
    Step.observe_record_owner ~base_path:(Durable.base_path owner) ~keepers_dir:(Durable.keepers_dir owner) broken
    |> ok in
  check bool "the owner a record names is the live one" true (observed = owner);
  let record = retain ~store chain.first_step (Step.to_json chain.first_step) in
  (* A destructive Memory epoch reset after the step was retained: the owner the
     record names is no longer the live one. *)
  let epoch_path = Memory.epoch_path ~keepers_dir:(Durable.keepers_dir owner) ~keeper_id:keeper in
  let epoch_before = In_channel.with_open_bin epoch_path In_channel.input_all in
  Out_channel.with_open_bin epoch_path (fun channel ->
    output_string channel {|{"schema_version":1,"epoch":"a-memory-epoch-after-a-reset"}|});
  expect_error "an owner whose Memory epoch was reset" ~mentioning:"changed"
    (Step.observe_record_owner ~base_path:(Durable.base_path owner) ~keepers_dir:(Durable.keepers_dir owner) record);
  Out_channel.with_open_bin epoch_path (fun channel -> output_string channel epoch_before);
  expect_error "a header read for another owner" ~mentioning:"changed" (Step.header ~owner:other_owner record);
  expect_error "a header whose first step names a previous step" ~mentioning:"position disagrees"
    (Step.header ~owner (retain ~store:(fresh_store ()) chain.first_step
       (replace_field "previous" (fun _ ->
          `Assoc [ "request_id", `String (Step.request_id chain.second_step); "request_digest", `String (sha_hex 'b') ])
          (Step.to_json chain.first_step))));
  expect_error "a header whose range is not a history request" ~mentioning:"request ID"
    (Step.header ~owner (retain ~store:(fresh_store ()) chain.first_step
       (replace_field "range" (replace_field "request_id" (fun _ -> `String (Step.request_id chain.second_step)))
          (Step.to_json chain.first_step))));
  expect_error "a header of another kind" ~mentioning:"schema or kind"
    (Step.header ~owner (retain ~store:(fresh_store ()) chain.first_step
       (replace_field "kind" (fun _ -> `String "completed-history-execution") (Step.to_json chain.first_step))))

let test_links_and_positions_are_checked_when_a_step_is_made () =
  with_fixture @@ fun ~owner ~other_owner ~fresh_store:_ ->
  let chain = chain ~owner in
  let make ?(destination = destination) ?(request_id = Step.fresh_request_id owner) ~range ~previous question =
    Step.create ~request_id ~owner ~destination ~range ~previous ~question ~step:(prepare question) () in
  let link_to request_id = { Step.request_id; request_digest = sha_hex 'd' } in
  let previous_step = Some (link_to (Step.request_id chain.first_step)) in
  expect_error "a previous step before the first message" ~mentioning:"position disagrees"
    (make ~range:chain.range ~previous:previous_step chain.first_question);
  expect_error "no previous step after the first message" ~mentioning:"position disagrees"
    (make ~range:chain.range ~previous:None chain.second_question);
  expect_error "a range that is a step" ~mentioning:"request ID"
    (make ~range:(link_to (Step.fresh_request_id owner)) ~previous:None chain.first_question);
  expect_error "a previous step that is a history original" ~mentioning:"request ID"
    (make ~range:chain.range ~previous:(Some (link_to (Durable.fresh_request_id owner))) chain.second_question);
  let id = Step.fresh_request_id owner in
  expect_error "a step that follows itself" ~mentioning:"outside its scope or itself"
    (make ~request_id:id ~range:chain.range ~previous:(Some (link_to id)) chain.second_question);
  expect_error "a range digest that is no digest" ~mentioning:"outside its physical scope"
    (make ~range:{ chain.range with request_digest = "short" } ~previous:None chain.first_question);
  expect_error "a range of another owner" ~mentioning:"outside its physical scope"
    (make ~range:(link_to (Durable.fresh_request_id other_owner)) ~previous:None chain.first_question);
  expect_error "a previous step of another owner" ~mentioning:"outside its scope or itself"
    (make ~range:chain.range ~previous:(Some (link_to (Step.fresh_request_id other_owner))) chain.second_question);
  expect_error "a question of another Keeper" ~mentioning:"another Keeper"
    (make ~range:chain.range ~previous:None (ask (machine_over ~keeper_name:other_keeper messages)));
  expect_error "a question that borrows a task's Goal context" ~mentioning:"Goal context"
    (make ~range:chain.range ~previous:None
       (question_over { (input messages) with
         goal_context = Librarian.Task_goals { task_id = "a-task"; criteria = Error "no goals read" } }));
  expect_error "another tool than the durable one" ~mentioning:"tool"
    (make ~destination:{ destination with tool = "not-the-durable-tool" } ~range:chain.range ~previous:None
       chain.first_question);
  let wrong_input =
    { chain.first_question.input with Librarian.keeper_instructions = "instructions the question did not carry" } in
  let altered =
    Runtime.prepare_durable_step ~now:1_000_000.
      ~context:{ Runtime.previous_state = chain.first_question.previous_state
               ; unread_messages = chain.first_question.unread_messages }
      wrong_input |> ok in
  expect_error "a preparation of another input" ~mentioning:"input differs from its question"
    (Step.create ~request_id:(Step.fresh_request_id owner) ~owner ~destination ~range:chain.range
       ~previous:None ~question:chain.first_question ~step:altered ());
  let other_context =
    Runtime.prepare_durable_step ~now:1_000_000.
      ~context:{ Runtime.previous_state = Some "a state the question did not carry"
               ; unread_messages = chain.first_question.unread_messages }
      chain.first_question.input |> ok in
  expect_error "a preparation with another context" ~mentioning:"context differs from its question"
    (Step.create ~request_id:(Step.fresh_request_id owner) ~owner ~destination ~range:chain.range
       ~previous:None ~question:chain.first_question ~step:other_context ())

let test_step_and_history_ids_do_not_mix () =
  with_fixture @@ fun ~owner ~other_owner ~fresh_store:_ ->
  let step_id = Step.fresh_request_id owner and history_id = Durable.fresh_request_id owner in
  check bool "a step has a scope of its own" true (Step.scope owner <> Durable.scope owner);
  check bool "a step ID names its owner's step scope" true
    (Step.scope_of_request_id step_id = Ok (Step.scope owner));
  expect_error "a history ID as a step ID" ~mentioning:"Invalid"
    (Step.scope_of_request_id history_id);
  expect_error "a step ID as a history ID" ~mentioning:"Invalid"
    (Durable.scope_of_request_id step_id);
  check bool "another owner has another step scope" true (Step.scope other_owner <> Step.scope owner)

let test_a_record_of_another_step_is_not_this_steps () =
  with_fixture @@ fun ~owner ~other_owner:_ ~fresh_store ->
  let chain = chain ~owner in
  let store = fresh_store () in
  let first_record = retain ~store chain.first_step (Step.to_json chain.first_step) in
  let second_record = retain ~store chain.second_step (Step.to_json chain.second_step) in
  expect_error "the second step against the first record" ~mentioning:"host binding differs"
    (Step.confirm_record chain.second_step first_record);
  expect_error "the first step against the second record" ~mentioning:"host binding differs"
    (Step.confirm_record chain.first_step second_record);
  (* A record keyed by one ID that holds the body of another step. *)
  let mislabeled =
    retain ~request_id:(Step.fresh_request_id owner) ~store chain.first_step (Step.to_json chain.first_step) in
  expect_error "a record whose ID is not the one its request names" ~mentioning:"host binding differs"
    (Step.restore ~owner mislabeled);
  expect_error "and the same for its header" ~mentioning:"host binding differs" (Step.header ~owner mislabeled)

let test_a_step_answer_needs_a_working_state () =
  with_fixture @@ fun ~owner ~other_owner:_ ~fresh_store:_ ->
  let chain = chain ~owner in
  let answer state = `Assoc
    [ "new_claims", `List []; "dropped", `List []; "working_contexts", `List []; "working_state", state ] in
  check bool "a nonblank working state is read" true
    (match Step.validate_proposal chain.first_step (answer (`String "kept")) with
     | Ok proposal -> proposal.working_state = "kept"
     | Error _ -> false);
  expect_error "an answer without a working state" ~mentioning:"" (Step.validate_proposal chain.first_step (answer `Null))

let () =
  run "keeper_librarian_floor_step_request"
    [ ( "step request"
      , [ test_case "restores from its record alone" `Quick test_a_step_restores_from_its_record_alone
        ; test_case "a question that differs does not match it" `Quick
            test_a_question_that_differs_does_not_match_the_step
        ; test_case "a tampered request is refused" `Quick test_a_tampered_request_is_refused
        ; test_case "a header and an owner are read without the input" `Quick
            test_a_header_and_an_owner_are_read_without_the_input
        ; test_case "links and positions are checked when it is made" `Quick
            test_links_and_positions_are_checked_when_a_step_is_made
        ; test_case "step and history IDs do not mix" `Quick test_step_and_history_ids_do_not_mix
        ; test_case "a record of another step is not this step's" `Quick
            test_a_record_of_another_step_is_not_this_steps
        ; test_case "an answer needs a working state" `Quick test_a_step_answer_needs_a_working_state
        ] )
    ]
