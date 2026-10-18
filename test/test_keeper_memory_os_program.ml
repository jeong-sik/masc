open Alcotest
module Memory = Masc.Keeper_memory_os_types
module Program = Masc.Keeper_memory_os_program
module Source = Masc.Keeper_librarian_unread

let require = function Ok value -> value | Error detail -> fail detail
let refused = function Ok _ -> fail "invalid Memory program was accepted" | Error _ -> ()
let keeper_id = match Masc.Keeper_identity.Keeper_id.of_string "program-fixture" with
  | Some keeper -> keeper | None -> fail "invalid fixture Keeper"
let turn_ref = Ids.Turn_ref.make ~trace_id:"program-source" ~absolute_turn:3
let fact claim = Memory.observed ~claim ~category:Memory.Fact ~now:10.
  ~origin:{Memory.kind=Memory.Authored;trace_id="program-origin"}
let a = fact "Original observation."
let b = fact "Intermediate conclusion."
let c = fact "Final conclusion."
let unrelated = fact "Concurrent unrelated observation."
let message text = Agent_core.Types.make_message ~role:Agent_core.Types.User [Agent_core.Types.Text text]
let source index text = Source.Official_turn {turn_ref;boundary_line=7;message_in_turn=index;
  message_sha256=Source.message_digest (message text)}
let first_source = source 0 "first observation"
let second_source = source 1 "second observation"
let drop fact = {Memory.memory_id=Memory.memory_id fact;reason="A later observation revises this claim."}
let decision ~run_id ~source ~current ~next =
  {Program.run_id;keeper_id;turn_ref;input_current=Some [current];sources=[source];
   input_evidence=`Null;gate_evidence=`Null;working_state=run_id;new_claims=[next];
   dropped=[drop current];absorbed=[];
   revisions=[{Memory.superseded=Memory.memory_id current;superseded_by=Memory.memory_id next}]}
let first = decision ~run_id:"first" ~source:first_source ~current:a ~next:b
let second = decision ~run_id:"second" ~source:second_source ~current:b ~next:c
let create ?(sources=[first_source;second_source]) ?(unread=[]) decisions =
  Program.create ~transaction_id:"program-transaction" ~keeper_id ~turn_ref ~sources ~unread
    ~initial_current:(Some [a]) ~decisions
let chain () = create [first;second] |> require
let check_facts label expected actual =
  check (list string) label (List.map (fun fact -> Yojson.Safe.to_string (Memory.fact_to_json fact)) expected)
    (List.map (fun fact -> Yojson.Safe.to_string (Memory.fact_to_json fact)) actual)

let test_chain_roundtrip_and_extras () =
  let program = chain () in
  let decoded = Program.of_json (Program.to_json program) |> require in
  let reobserved = {a with Memory.last_seen=25.} in
  let concurrent = {unrelated with Memory.first_seen=9.;last_seen=30.} in
  let execution = Program.replay decoded ~current:[concurrent;reobserved] |> require in
  check_facts "concurrent payload and original order survive" [concurrent;c] execution.final_facts;
  (match execution.stages with
   | [one;two] ->
     check_facts "first actual step keeps reobservation fields" [concurrent;reobserved] one.before;
     check_facts "second actual step consumes the virtual intermediate" [concurrent;b] two.before;
     check string "continuation stays with its decision" "second" two.decision.working_state
   | [] | [_] | _ :: _ :: _ :: _ -> fail "expected two actual stages");
  let roundtrip = Program.execution_of_json (Program.execution_to_json execution) |> require in
  check bool "actual replay proof roundtrips distinctly from original plan" true (roundtrip=execution)

let test_net_zero_lineage () =
  let recreated = {a with Memory.first_seen=99.;last_seen=99.} in
  let back = decision ~run_id:"back" ~source:second_source ~current:b ~next:recreated in
  let program = create [first;back] |> require in
  let execution = Program.replay program ~current:[a] |> require in
  check_facts "recreated identity carries the later incarnation" [recreated] execution.final_facts;
  check (list string) "outer identity equality does not erase intermediate history"
    (List.sort String.compare [Memory.memory_id a;Memory.memory_id b]) (Program.touched_ids execution);
  let one_step = {first with Program.new_claims=[a];revisions=[]} in
  create ~sources:[first_source] [one_step] |> refused

let test_concurrent_collision () =
  Program.replay (chain ()) ~current:[a;b] |> refused;
  Program.replay (chain ()) ~current:[a;{b with Memory.last_seen=50.}] |> refused;
  Program.replay (chain ()) ~current:[{a with Memory.first_seen=5.}] |> refused;
  Program.replay (chain ()) ~current:[{a with Memory.origin={a.origin with kind=Memory.Injected}}] |> refused

let test_support_loss_of_concurrent_addition () =
  let derived = Memory.derived ~claim:"Concurrent inference from the original observation."
    ~category:Memory.Fact ~now:15. ~origin:a.origin
    ~derivations:[{Memory.rule_id="fixture-proof";premise_ids=[Memory.memory_id a]}] |> require in
  Program.replay (chain ()) ~current:[a;derived] |> refused

let test_forged_public_program () =
  let program = chain () in
  let another = Ids.Turn_ref.make ~trace_id:"different-source" ~absolute_turn:3 in
  let wrong_owner = List.map (fun (stage : Program.stage) ->
    {stage with decision={stage.decision with turn_ref=another}}) program.stages in
  Program.replay {program with stages=wrong_owner} ~current:[a] |> refused;
  Program.replay {program with final_facts=[]} ~current:[a] |> refused;
  let wrong_input = List.map (fun (stage : Program.stage) ->
    {stage with decision={stage.decision with input_current=None}}) program.stages in
  Program.replay {program with stages=wrong_input} ~current:[a] |> refused

let test_relationships () =
  let one value = create ~sources:[first_source] [value] |> refused in
  one {first with dropped=[drop unrelated]};
  one {first with dropped=[]};
  one {first with absorbed=[{Memory.absorbed=Memory.memory_id a;into=Memory.memory_id b}]};
  one {first with dropped=[];revisions=[];
    absorbed=[{Memory.absorbed=Memory.memory_id a;into=Memory.memory_id b};
      {Memory.absorbed=Memory.memory_id a;into=Memory.memory_id c}];new_claims=[b;c]};
  one {first with new_claims=[]};
  one {first with new_claims=[a];revisions=[]}

let test_exact_partition () =
  create ~sources:[second_source;first_source] [first;second] |> refused;
  create ~sources:[first_source] [first;second] |> refused;
  create ~sources:[first_source;first_source] [first;second] |> refused;
  let hole = Source.for_official_turn ~turn_ref ~boundary_line:7 ~message_in_turn:1
    ~messages:[message "first observation";message "second observation"]
    ~reasons:[Masc.Keeper_librarian_input_refusal.Context_overflow] |> require in
  let partial = create ~unread:[hole] [first] |> require in
  check int "explicit hole remains distinct from processed source" 1 (List.length partial.unread);
  check_facts "unread source contributes no invented decision" [b] partial.final_facts;
  let changed = source 1 "different message bytes" in
  create ~sources:[first_source;changed] ~unread:[hole] [first] |> refused

let test_forged_codec_outcomes () =
  let program = chain () in
  let forged = {program with Program.final_facts=[a]} in
  Program.of_json (Program.to_json forged) |> refused;
  let execution = Program.replay program ~current:[a] |> require in
  Program.execution_of_json (Program.execution_to_json {execution with final_facts=[]}) |> refused;
  (match Program.to_json program with
   | `Assoc fields ->
     Program.of_json (`Assoc (("schema_version",`Int 1)::fields)) |> refused;
     Program.of_json (`Assoc (("unknown_authority",`Bool true)::fields)) |> refused
   | _ -> fail "program codec did not encode an object")

let () = run "keeper_memory_os_program"
  ["ordered replay", [
    test_case "chain, reobservation and concurrent payload roundtrip" `Quick test_chain_roundtrip_and_extras;
    test_case "net-zero outer identities retain virtual incarnation history" `Quick test_net_zero_lineage;
    test_case "concurrent intermediate identity cannot be adopted" `Quick test_concurrent_collision;
    test_case "concurrent support loss rejects the whole replay" `Quick test_support_loss_of_concurrent_addition;
    test_case "public forged records are revalidated" `Quick test_forged_public_program;
    test_case "contradictory retirement and lineage reject" `Quick test_relationships;
    test_case "processed sources and holes exactly partition the manifest" `Quick test_exact_partition;
    test_case "codec recomputes program and locked outcomes" `Quick test_forged_codec_outcomes]]
