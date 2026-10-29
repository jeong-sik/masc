(** One question of the durable message floor, run through the actual configured
    Runtime, the Python worker and the common host Exact HTTP. Only container
    launch/cleanup and the provider's HTTP server are substituted. A step is
    retained before dispatch, runs at most once, and ends at its answer or its
    refusal. These tests do not claim Docker, real paid providers or visible UI. *)
open Alcotest
open Masc
open Librarian_floor_fixture
module Exact = Lane_addon_exact
module Failure = Keeper_exact_walk_failure
module Refusal = Keeper_librarian_input_refusal

let test_a_step_runs_once_and_keeps_its_answer () = with_fixture (fun fixture ->
  fixture.respond := (fun _ -> `OK, F.openai_response (answer ~claim:"claim of the first step" ~state:"state of the first step"));
  let owner = owner fixture and range = range_link (owner fixture) in
  let question = ask (machine ()) in
  let step = new_step fixture ~owner ~range ~previous:None question in
  let record = retain fixture step in
  check string "a retained step has made no call" "captured" (phase_name record);
  check int "and the provider has seen nothing" 0 (F.post_count fixture.server);
  let answered_record = match run_step fixture record step with
    | Step_owner.Answered ({ proposal; _ }, record) ->
      check string "the step's working state is the provider's answer" "state of the first step" proposal.working_state;
      check bool "its new claim is the provider's" true
        (List.map (fun (fact : Keeper_memory_os_types.fact) -> fact.claim) proposal.proposal.absorption.new_claims
         = [ "claim of the first step" ]);
      record
    | Step_owner.Pending _ -> fail "the step was still pending after its worker delivered"
    | Step_owner.Refused (final, _) ->
      failf "the provider's answer was refused: %s" (Yojson.Safe.to_string (Exact.final_to_json final)) in
  check string "the answer is the judgment of a judged record" "judged" (phase_name answered_record);
  check int "the provider was called once" 1 (F.post_count fixture.server);
  (* The answer survives a restart: the record alone, with the question the
     floor asks again, restores it and no worker is asked a second time. *)
  let restored = Step.restore ~owner answered_record |> get in
  Step.matches_question question restored |> get;
  check bool "the restored step is the created one" true
    (Yojson.Safe.equal (Step.to_json restored) (Step.to_json step));
  (match resume fixture answered_record restored with
   | Step_owner.Answered ({ proposal; _ }, _) ->
     check string "the second resume reads the same answer" "state of the first step" proposal.working_state
   | Step_owner.Pending _ | Step_owner.Refused _ -> fail "the retained answer was not read back");
  check int "and calls no provider again" 1 (F.post_count fixture.server))

let test_a_size_refused_step_is_refused_with_its_evidence () = with_fixture (fun fixture ->
  fixture.respond := (fun _ -> size_refusal);
  let owner = owner fixture and range = range_link (owner fixture) in
  let question = ask (machine ()) in
  let step = new_step fixture ~owner ~range ~previous:None question in
  let record = retain fixture step in
  let refused_record, final = match run_step fixture record step with
    | Step_owner.Refused (final, record) -> record, final
    | Step_owner.Answered _ -> fail "a refused request was answered"
    | Step_owner.Pending _ -> fail "the step was still pending after its worker delivered" in
  check string "a refused step is a rejected record" "rejected" (phase_name refused_record);
  let calls = F.post_count fixture.server in
  check bool "the provider was asked" true (calls >= 1);
  let evidence = io (fun () -> Step.refusal_evidence ~store:fixture.store step final) |> get in
  check bool "the refusal shows the input was too large" true (Failure.shows_range_size evidence);
  check bool "and names the refusal" true (evidence.provider_input_refusals <> []);
  (match resume fixture refused_record step with
   | Step_owner.Refused (_, record) -> check string "the refusal is read back" "rejected" (phase_name record)
   | Step_owner.Answered _ | Step_owner.Pending _ -> fail "the retained refusal was not read back");
  check int "and no provider is asked again" calls (F.post_count fixture.server))

(* The floor's first message was unreadable: it becomes a hole and the floor
   asks about the second. *)
let skip machine =
  let question = ask machine in
  let reasons = [ Refusal.Request_body_refused ] in
  let hole = match question.sources with
    | [ Unread.Official_turn { turn_ref; boundary_line; message_in_turn; _ } ] ->
      Unread.for_official_turn ~turn_ref ~boundary_line ~message_in_turn ~messages ~reasons |> get
    | [] | [ Unread.Atom _ ] | _ :: _ :: _ -> fail "the fixture reads one official-turn message per question" in
  Machine.unreadable machine ~reasons ~hole |> get

let discover fixture ~owner =
  Step_owner.discover ~store:fixture.store ~owner |> Result.map_error Step_owner.error_to_string |> get

let test_a_chain_is_found_by_the_headers_of_its_steps () = with_fixture (fun fixture ->
  let owner = owner fixture and range = range_link (owner fixture) in
  check int "no step is retained yet" 0 (List.length (discover fixture ~owner));
  let machine = machine () in
  let first_question = ask machine in
  let first = new_step fixture ~owner ~range ~previous:None first_question in
  let first_record = retain fixture first in
  let second_question = ask (skip machine) in
  let previous =
    Some { Step.request_id = first_record.request_id; request_digest = first_record.request_digest } in
  let second = new_step fixture ~owner ~range ~previous second_question in
  let second_record = retain fixture second in
  let found = discover fixture ~owner in
  let header_of (record : Owner.retained) =
    match List.find_opt (fun ((found : Owner.retained), _) -> found.request_id = record.request_id) found with
    | Some (_, header) -> header
    | None -> fail "a retained step was not found" in
  check int "both steps are found" 2 (List.length found);
  let first_header = header_of first_record and second_header = header_of second_record in
  check bool "the first step is at position 0 with no previous step" true
    (first_header.position = 0 && first_header.previous = None && first_header.range = range
     && first_header.sources = first_question.sources);
  check bool "the second is at position 1 and names the first by ID and digest" true
    (second_header.position = 1 && second_header.previous = previous && second_header.range = range
     && second_header.sources = second_question.sources);
  check bool "a header carries the destination its request names" true
    (first_header.destination = Step.destination first);
  (* Retaining a step again is the same step and keeps what it has recorded. *)
  let again = retain fixture first in
  check bool "retaining the same step again finds the same record" true
    (again.request_digest = first_record.request_digest))

(* The host checks a model's answer against the step's own input before it takes
   the answer as final. This answer fits the output schema but names a memory the
   step never saw: it is invalid output, not an answer. *)
let test_the_host_does_not_take_an_answer_the_step_cannot_use () = with_fixture (fun fixture ->
  let unknown_memory = `Assoc [ "claim", `String "a claim"; "category", `String "fact"; "board_post_id", `Null;
    "board_comment_id", `Null; "supersedes", `String "m404"; "absorbs", `List [] ] in
  fixture.respond := (fun _ -> `OK, F.openai_response
    (`Assoc [ "new_claims", `List [ unknown_memory ]; "dropped", `List []; "working_contexts", `List [];
              "working_state", `String "a working state" ]));
  let owner = owner fixture and range = range_link (owner fixture) in
  let question = ask (machine ()) in
  let step = new_step fixture ~owner ~range ~previous:None question in
  let record = retain fixture step in
  match run_step fixture record step with
  | Step_owner.Refused (Exact.Call_final (Exact.Invalid_output _ as final), refused_record) ->
    check string "a refused step is a rejected record" "rejected" (phase_name refused_record);
    let evidence = io (fun () -> Step.refusal_evidence ~store:fixture.store step (Exact.Call_final final)) |> get in
    check bool "invalid output shows nothing about reading less" true
      (not (Failure.shows_range_size evidence) && evidence.provider_input_refusals = [])
  | Step_owner.Refused (final, _) ->
    failf "the refusal was not invalid output: %s" (Yojson.Safe.to_string (Exact.final_to_json final))
  | Step_owner.Answered _ -> fail "an answer that names an unknown memory was taken"
  | Step_owner.Pending _ -> fail "the step was still pending after its worker delivered")

(* The worker's word is no proof. A reply that says the request finished with
   an answer, while the host holds no terminal record of one, is not an answer. *)
let test_a_worker_reply_the_host_has_no_record_of_is_not_an_answer () = with_fixture (fun fixture ->
  let arrived, signal = Eio.Promise.create () and release, unblock = Eio.Promise.create () in
  fixture.respond := (fun _ ->
    ignore (Eio.Promise.try_resolve signal ());
    Eio.Promise.await release;
    `OK, F.openai_response (answer ~claim:"claim of the first step" ~state:"state of the first step"));
  Fun.protect ~finally:(fun () ->
    fixture.transform_reply := (fun _ response -> response);
    ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    let owner = owner fixture and range = range_link (owner fixture) in
    let step = new_step fixture ~owner ~range ~previous:None (ask (machine ())) in
    let record = retain fixture step in
    (match resume fixture record step with
     | Step_owner.Pending (_, _) -> ()
     | Step_owner.Answered _ | Step_owner.Refused _ -> fail "the provider had not answered yet");
    Eio.Promise.await arrived;
    let forged = `Assoc [ "status", `String "answered"; "slot", `String "forged-worker-slot";
                          "output", answer ~claim:"a claim the host never saw" ~state:"a forged state" ] in
    let forged_reads = ref 0 in
    fixture.transform_reply := (fun arguments response ->
      match Yojson.Safe.Util.member "kind" arguments with
      | `String "read" ->
        incr forged_reads;
        { response with Mcp_protocol.Mcp_types.structured_content = Some (`Assoc [
            "request_id", `String record.request_id; "state", `String "finished"; "result", forged ]);
          is_error = Some false }
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> response);
    (match Step_owner.resume ~store:fixture.store ~config:fixture.config ~reserved:(Edge.reserved ())
             ~original:record ~step ~call:(Edge.call ~config:fixture.config ~reserved:(Edge.reserved ())) with
     | Ok (Step_owner.Answered _) -> fail "a worker reply with no host record was taken as an answer"
     | Ok (Step_owner.Pending _ | Step_owner.Refused _) | Error _ -> ());
    check bool "the untrusted reply reached the step owner" true (!forged_reads > 0);
    let fresh = Owner.load ~store:fixture.store ~scope:record.scope ~request_id:record.request_id in
    check bool "and the step is still not judged" true
      (match fresh with
       | Ok (Some { Owner.progress; _ }) -> (match Progress.phase progress with Progress.Judged _ -> false | _ -> true)
       | Ok None | Error _ -> false)))

(* A destructive Memory epoch reset after the step was retained: the owner the
   step names is no longer the live one, so the step is not run. *)
let test_a_step_of_a_reset_memory_epoch_is_not_run () = with_fixture (fun fixture ->
  let owner = owner fixture and range = range_link (owner fixture) in
  let step = new_step fixture ~owner ~range ~previous:None (ask (machine ())) in
  let record = retain fixture step in
  let epoch_path = Memory.epoch_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
  io (fun () -> write epoch_path {|{"schema_version":1,"epoch":"a-memory-epoch-after-a-reset"}|});
  let reserved = Edge.reserved () in
  (match Step_owner.resume ~store:fixture.store ~config:fixture.config ~reserved ~original:record ~step
           ~call:(Edge.call ~config:fixture.config ~reserved) with
   | Error (Step_owner.Rejected detail) ->
     check bool "the step is refused for its changed owner" true (contains detail "changed")
   | Error (Step_owner.Unavailable _ | Step_owner.Uncertain _) -> fail "a reset epoch is a refusal, not an outage"
   | Ok _ -> fail "a step of a reset Memory epoch was run");
  check int "no provider was asked" 0 (F.post_count fixture.server);
  let fresh = Owner.load ~store:fixture.store ~scope:record.scope ~request_id:record.request_id in
  check bool "and the step was never dispatched" true
    (match fresh with
     | Ok (Some { Owner.progress; _ }) -> (match Progress.phase progress with Progress.Captured -> true | _ -> false)
     | Ok None | Error _ -> false))

let discover_wake fixture ~event =
  Server_librarian_addon_wake.For_testing.discover ~config:fixture.config ~store:fixture.store
    ~after_inventory:(fun () -> ()) ~on_original:(fun _ -> ()) ~event

(* A step's result must wake its Keeper like a history original's does, and the
   wake restores nothing of the step's input to do it. *)
let test_the_wake_recognizes_a_step () = with_fixture (fun fixture ->
  let owner = owner fixture and range = range_link (owner fixture) in
  let step = new_step fixture ~owner ~range ~previous:None (ask (machine ())) in
  let record = retain fixture step in
  let installation_id = (Step.destination step).installation_id in
  let keepers, refusals, original_keepers =
    discover_wake fixture ~event:Addon_runtime.Configuration_observed |> get in
  check (list string) "a configuration scan finds the step's Keeper among the originals" [ keeper_name ] original_keepers;
  check bool "and wakes it" true (List.mem keeper_name keepers);
  check (list string) "without refusing the step" [] refusals;
  let hinted =
    Addon_runtime.Exact_result_delivered { installation_id; instance_id = "fixture-instance"; request_id = record.request_id } in
  let keepers, refusals, original_keepers = discover_wake fixture ~event:hinted |> get in
  check (list string) "a result hint for the step wakes its Keeper only" [ keeper_name ] keepers;
  check (list string) "as the original's Keeper" [ keeper_name ] original_keepers;
  check (list string) "with nothing refused" [] refusals;
  (match discover_wake fixture
           ~event:(Addon_runtime.Exact_result_delivered
                     { installation_id = installation_id ^ "-other"; instance_id = "fixture-instance";
                       request_id = record.request_id }) with
   | Error detail -> check bool "a hint from another installation is refused" true (contains detail "different original installation")
   | Ok _ -> fail "a result hint from another installation was accepted"))

let () =
  run "keeper_librarian_floor_step_owner"
    [ ( "step owner"
      , [ test_case "a step runs once and keeps its answer" `Slow test_a_step_runs_once_and_keeps_its_answer
        ; test_case "a size-refused step is refused with its evidence" `Slow
            test_a_size_refused_step_is_refused_with_its_evidence
        ; test_case "the host does not take an answer the step cannot use" `Slow
            test_the_host_does_not_take_an_answer_the_step_cannot_use
        ; test_case "a worker reply the host has no record of is not an answer" `Slow
            test_a_worker_reply_the_host_has_no_record_of_is_not_an_answer
        ; test_case "a step of a reset Memory epoch is not run" `Slow test_a_step_of_a_reset_memory_epoch_is_not_run
        ; test_case "a chain is found by the headers of its steps" `Slow
            test_a_chain_is_found_by_the_headers_of_its_steps
        ; test_case "the wake recognizes a step" `Slow test_the_wake_recognizes_a_step
        ] )
    ]
