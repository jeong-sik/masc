(** The durable message floor's chain, through the actual configured Runtime, the
    Python worker and the common host Exact HTTP. Each question of a range that
    exceeded the worker frame is a retained step that runs at most once; the
    chain rebuilds the floor's machine from what its steps retained, so a restart
    is the same call and asks the provider for nothing a step already answered.
    These tests do not claim Docker, real paid providers or visible UI. *)
open Alcotest
open Masc
open Librarian_floor_fixture
module Chain = Keeper_librarian_floor_chain
module Exact = Lane_addon_exact
module Program = Keeper_memory_os_program
module Types = Keeper_memory_os_types
module Refusal = Keeper_librarian_input_refusal

let first_message = message first_text
let second_message = message second_text

let unread_message messages source ~reasons =
  match source with
  | Unread.Official_turn { turn_ref; boundary_line; message_in_turn; _ } ->
    Unread.for_official_turn ~turn_ref ~boundary_line ~message_in_turn ~messages ~reasons
  | Unread.Atom _ -> Error "the chain fixture reads official turns only"

let fresh : Chain.fresh =
  { transaction_id = "floor-chain-transaction-1"; current = None; previous_state = None; unread_messages = [] }

let run_once fixture ~owner ~range ?(messages = messages) ?(fresh = fresh) () =
  Chain.run ~store:fixture.store ~config:fixture.config ~reserved:(Edge.reserved ()) ~owner ~range
    ~input:(input_over messages) ~sources:(sources_of messages) ~fresh
    ~unread_message:(unread_message messages)

(* Run the chain as the consumer's wakes do: a chain that waits on a worker runs
   again after the worker's delivery, never earlier. *)
let drive fixture ~owner ~range ?messages ?fresh () =
  let rec go attempts =
    let before = !(fixture.deliveries) in
    match run_once fixture ~owner ~range ?messages ?fresh () with
    | Ok (Chain.Pending _) when attempts > 0 -> await_delivery fixture ~after:before; go (attempts - 1)
    | result -> result in
  go 12

(* The provider reads the message a request carries. A request that carries one
   of [refuse] is refused as too large; any other is answered with a claim and a
   working state numbered by the message it carries. *)
let answering ?(refuse = []) () body =
  if List.exists (contains body) refuse then size_refusal
  else
    let which = if contains body second_text then 2 else 1 in
    `OK, F.openai_response (answer ~claim:(Printf.sprintf "claim %d" which) ~state:(Printf.sprintf "state %d" which))

let claims (program : Program.t) =
  List.concat_map (fun (stage : Program.stage) ->
    List.map (fun (fact : Types.fact) -> fact.claim) stage.decision.new_claims) program.stages

let finished = function
  | Ok (Chain.Finished finished) -> finished
  | Ok (Chain.Pending detail) -> failf "the chain was still pending: %s" detail
  | Ok (Chain.Stopped { position; report }) -> failf "the chain stopped at %d: %s" position report.detail
  | Error detail -> failf "the chain refused: %s" detail

let steps_of fixture ~owner =
  Step_owner.discover ~store:fixture.store ~owner |> Result.map_error Step_owner.error_to_string |> get

let test_a_chain_runs_each_step_once_and_a_restart_replays_it () = with_fixture (fun fixture ->
  fixture.respond := answering ();
  let owner = owner fixture and range = range_link (owner fixture) in
  let first = finished (drive fixture ~owner ~range ()) in
  check (list string) "every message has a decision, in order" [ "claim 1"; "claim 2" ] (claims first.program);
  check string "the program carries the chain's transaction" fresh.transaction_id first.program.transaction_id;
  check bool "the last step's working state is the chain's" true (first.working_state = Some "state 2");
  check bool "a durable answer names no slot" true (first.served_by = None);
  check int "each step asked the provider once" 2 (F.post_count fixture.server);
  check int "and retained one step each" 2 (List.length (steps_of fixture ~owner));
  let run_ids = List.map (fun (stage : Program.stage) -> stage.decision.run_id) first.program.stages in
  check int "every decision has a run identity of its own" 2 (List.length (List.sort_uniq String.compare run_ids));
  (* A restart is the same call: the steps restore, the gate replays, and the
     provider is asked for nothing. *)
  let again = finished (drive fixture ~owner ~range ()) in
  check bool "the restart makes the same program" true
    (Yojson.Safe.equal (Program.to_json again.program) (Program.to_json first.program));
  check int "and asks the provider nothing" 2 (F.post_count fixture.server);
  check int "and retains no more steps" 2 (List.length (steps_of fixture ~owner)))

let test_a_message_every_slot_refuses_as_too_large_becomes_a_hole () = with_fixture (fun fixture ->
  fixture.respond := answering ~refuse:[ first_text ] ();
  let owner = owner fixture and range = range_link (owner fixture) in
  let first = finished (drive fixture ~owner ~range ()) in
  check (list string) "only the readable message has a decision" [ "claim 2" ] (claims first.program);
  let hole = match first.program.unread with
    | [ hole ] -> hole
    | [] | _ :: _ :: _ -> fail "the refused message is the one unread hole" in
  check bool "the hole is the first message" true (hole.source = source_of 0 first_message);
  check bool "with the host's named refusal" true (hole.reasons <> []);
  check bool "and is the value the floor makes again from that source and cause" true
    (unread_message messages hole.source ~reasons:hole.reasons |> get = hole);
  check int "both messages have a step" 2 (List.length (steps_of fixture ~owner));
  let calls = F.post_count fixture.server in
  let again = finished (drive fixture ~owner ~range ()) in
  check bool "the restart keeps the hole and the decision" true
    (Yojson.Safe.equal (Program.to_json again.program) (Program.to_json first.program));
  check int "and asks the provider nothing" calls (F.post_count fixture.server))

let unusable_answer = `Assoc
  [ "new_claims", `List [ `Assoc [ "claim", `String "a claim"; "category", `String "fact"; "board_post_id", `Null;
      "board_comment_id", `Null; "supersedes", `String "m404"; "absorbs", `List [] ] ];
    "dropped", `List []; "working_contexts", `List []; "working_state", `String "a working state" ]

let test_a_refusal_that_shows_nothing_about_reading_less_stops_the_chain () = with_fixture (fun fixture ->
  fixture.respond := (fun _ -> `OK, F.openai_response unusable_answer);
  let owner = owner fixture and range = range_link (owner fixture) in
  (match drive fixture ~owner ~range () with
   | Ok (Chain.Stopped { position; report }) ->
     check int "at the first message" 0 position;
     check bool "its report does not let the floor read less" true
       (report.message_descent <> Memory_runtime.Smaller_input_may_help && report.provider_input_refusals = [])
   | Ok (Chain.Finished _ | Chain.Pending _) -> fail "the chain went past a message no slot could answer"
   | Error detail -> fail detail);
  check int "no second message was asked" 1 (List.length (steps_of fixture ~owner));
  let calls = F.post_count fixture.server in
  (match drive fixture ~owner ~range () with
   | Ok (Chain.Stopped { position; _ }) -> check int "a restart stops at the same message" 0 position
   | Ok (Chain.Finished _ | Chain.Pending _) | Error _ -> fail "a restart did not stop at the same message");
  check int "without asking the provider again" calls (F.post_count fixture.server))

let stale_fact = Types.observed ~claim:"a fact from the Memory of another moment" ~category:Types.Fact
  ~now:1_000_000. ~origin:{ Types.kind = Types.Authored; trace_id = "" }

let test_a_restart_takes_its_start_from_the_first_step () = with_fixture (fun fixture ->
  fixture.respond := answering ();
  let owner = owner fixture and range = range_link (owner fixture) in
  let first = finished (drive fixture ~owner ~range ()) in
  let other_hole = unread_message [ first_message; second_message ] (source_of 0 first_message)
    ~reasons:[ Refusal.Request_body_refused ] |> get in
  let elsewhere : Chain.fresh =
    { transaction_id = "another-transaction"; current = Some { Keeper_librarian.facts = [ stale_fact ] };
      previous_state = Some "a state from another moment"; unread_messages = [ other_hole ] } in
  let again = finished (drive fixture ~owner ~range ~fresh:elsewhere ()) in
  check bool "another start changes nothing a first step retained" true
    (Yojson.Safe.equal (Program.to_json again.program) (Program.to_json first.program));
  check string "the transaction is the first step's" fresh.transaction_id again.program.transaction_id;
  check bool "and the program starts from the facts it started with" true
    (again.program.initial_current = first.program.initial_current);
  check int "the provider was asked nothing" 2 (F.post_count fixture.server))

let replace_field name value = function
  | `Assoc members -> `Assoc (List.map (fun (key, old) -> key, (if key = name then value else old)) members)
  | _ -> fail "a step encodes as an object"

(* Another record in the same scope that holds the body of [record], under an ID
   of its own, with [edit] applied to the body. *)
let retain_copy ~store ~owner (record : Owner.retained) ~edit =
  let request_id = Step.fresh_request_id owner in
  let request = edit (replace_field "request_id" (`String request_id) record.request) in
  match Owner.retain ~store ~scope:record.scope ~request_id ~installation_id:record.installation_id
          ~package_id:record.package_id ~tool:record.tool ~summary:`Null ~request with
  | Ok () -> ()
  | Error error -> fail (Owner.error_to_string error)

let expect_refused label ~mentioning = function
  | Error detail -> check bool (Printf.sprintf "%s (%s)" label detail) true (contains detail mentioning)
  | Ok (Chain.Finished _ | Chain.Pending _ | Chain.Stopped _) -> failf "%s was accepted" label

let test_a_chain_that_disagrees_with_itself_is_refused () = with_fixture (fun fixture ->
  fixture.respond := answering ();
  let owner = owner fixture and range = range_link (owner fixture) in
  ignore (finished (drive fixture ~owner ~range ()) : Machine.finished);
  let records = List.map fst (steps_of fixture ~owner) in
  let step_zero = List.find (fun (record : Owner.retained) ->
    match Step.header ~owner record with Ok header -> header.position = 0 | Error _ -> false) records in
  (* A question that is not the one the first run answered. *)
  expect_refused "a different message at a position a step answered" ~mentioning:"not the question it was asked"
    (run_once fixture ~owner ~range ~messages:[ message "another first message"; second_message ] ());
  (* Two answers to one question. *)
  retain_copy ~store:fixture.store ~owner step_zero ~edit:Fun.id;
  expect_refused "two steps at one position" ~mentioning:"two steps at position 0"
    (run_once fixture ~owner ~range ()))

let test_a_step_the_floor_never_asked_about_is_refused () = with_fixture (fun fixture ->
  fixture.respond := answering ();
  let owner = owner fixture and range = range_link (owner fixture) in
  ignore (finished (drive fixture ~owner ~range ()) : Machine.finished);
  let step_one = List.find (fun ((_ : Owner.retained), (header : Step.header)) -> header.position = 1)
    (steps_of fixture ~owner) |> fst in
  retain_copy ~store:fixture.store ~owner step_one ~edit:(replace_field "position" (`Int 5));
  expect_refused "a step at a position the floor never reaches" ~mentioning:"never asked about"
    (run_once fixture ~owner ~range ()))

let test_chains_of_other_ranges_do_not_mix () = with_fixture (fun fixture ->
  fixture.respond := answering ();
  let owner = owner fixture in
  let range_a = range_link owner and range_b = range_link owner in
  let a = finished (drive fixture ~owner ~range:range_a ()) in
  let b = finished (drive fixture ~owner ~range:range_b ~fresh:{ fresh with transaction_id = "the other chain" } ()) in
  check int "each chain asked the provider for its own steps" 4 (F.post_count fixture.server);
  check int "and retained them under its own range" 4 (List.length (steps_of fixture ~owner));
  check string "the first chain keeps its transaction" fresh.transaction_id a.program.transaction_id;
  check string "the second has its own" "the other chain" b.program.transaction_id;
  check (list string) "both read the same turn the same way" (claims a.program) (claims b.program))

(* The facts a chain starts from are part of its first question. A restart that
   names no facts, or other facts, gets the ones the first step retained. *)
let test_a_chain_that_starts_from_facts_gets_them_back_on_restart () = with_fixture (fun fixture ->
  fixture.respond := answering ();
  let owner = owner fixture and range = range_link (owner fixture) in
  let starting : Chain.fresh = { fresh with current = Some { Keeper_librarian.facts = [ stale_fact ] } } in
  let first = finished (drive fixture ~owner ~range ~fresh:starting ()) in
  check bool "the program starts from those facts" true (first.program.initial_current = Some [ stale_fact ]);
  check bool "and the first step asked about them" true
    (List.exists (fun ((record : Owner.retained), (header : Step.header)) ->
       header.position = 0
       && (match Step.restore ~owner record with
           | Ok step -> (Step.step step).preparation.source_input.current = Some { Keeper_librarian.facts = [ stale_fact ] }
           | Error _ -> false)) (steps_of fixture ~owner));
  let calls = F.post_count fixture.server in
  let without = finished (drive fixture ~owner ~range ()) in
  check bool "a restart that names no facts restores them" true (without.program.initial_current = Some [ stale_fact ]);
  check bool "and makes the same program" true
    (Yojson.Safe.equal (Program.to_json without.program) (Program.to_json first.program));
  let other = { fresh with current = Some { Keeper_librarian.facts = [] } } in
  let elsewhere = finished (drive fixture ~owner ~range ~fresh:other ()) in
  check bool "and so does one that names other facts" true
    (Yojson.Safe.equal (Program.to_json elsewhere.program) (Program.to_json first.program));
  check int "none of them asks the provider anything" calls (F.post_count fixture.server))

let () =
  run "keeper_librarian_floor_chain"
    [ ( "chain"
      , [ test_case "each step runs once and a restart replays it" `Slow
            test_a_chain_runs_each_step_once_and_a_restart_replays_it
        ; test_case "a message every slot refuses as too large becomes a hole" `Slow
            test_a_message_every_slot_refuses_as_too_large_becomes_a_hole
        ; test_case "a refusal that shows nothing about reading less stops it" `Slow
            test_a_refusal_that_shows_nothing_about_reading_less_stops_the_chain
        ; test_case "a restart takes its start from the first step" `Slow
            test_a_restart_takes_its_start_from_the_first_step
        ; test_case "a chain that starts from facts gets them back on restart" `Slow
            test_a_chain_that_starts_from_facts_gets_them_back_on_restart
        ; test_case "a chain that disagrees with itself is refused" `Slow
            test_a_chain_that_disagrees_with_itself_is_refused
        ; test_case "a step the floor never asked about is refused" `Slow
            test_a_step_the_floor_never_asked_about_is_refused
        ; test_case "chains of other ranges do not mix" `Slow test_chains_of_other_ranges_do_not_mix
        ] )
    ]
