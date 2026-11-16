open Keeper_event_queue

let checks = ref 0
let check label condition = incr checks; if not condition then failwith label
let member name = function `Assoc fields -> List.assoc name fields | _ -> failwith name
let string = function `String s -> s | _ -> failwith "string"
let list = function `List xs -> xs | _ -> failwith "list"

let selection ?(arrival=1L) ?(incarnation=1L) ?(urgency=Normal) id payload =
  { Keeper_event_queue_state.source = {post_id=id;urgency;arrived_at=123.5;payload}
  ; arrival; admitted_revision=incarnation; checkpoint_retentions=0;first_admitted_at=None }

let channel = Keeper_continuation_channel.discord
  ~guild_id:None ~channel_id:"fixture-channel" ~parent_channel_id:None
  ~thread_id:None ~user_id:"fixture-user" () |> Result.get_ok
let connector ?(urgency=Low) id = selection ~urgency id
  (Connector_attention {event_id=id;channel})
let schedule ?(arrival=1L) ?(incarnation=1L) ?(urgency=Normal) group id due_at =
  selection ~arrival ~incarnation ~urgency id (Schedule_due
    {occurrence_id=id;schedule_instance_id="instance-"^group;schedule_id=group;due_at
    ;payload_digest="digest-"^id;title=Some "schedule fixture";message="private schedule body"
    ;result_delivery=None})

let oracle source = Keeper_event_queue.stimulus_to_yojson source
  |> Yojson.Safe.to_string |> Agent_core_sha256.digest_string |> Agent_core_sha256.to_hex

let cases = ref []
let run label expected_before expected_after selections =
  Counter.calls := 0;
  let before = Before.rows_for_queue_snapshot ~keeper_name:"fixture"
    ~source:Before.Event_queue_pending ~next_action:"drain" selections in
  let before_calls = !(Counter.calls) in
  Counter.calls := 0;
  let after = After.rows_for_queue_snapshot ~keeper_name:"fixture"
    ~source:After.Event_queue_pending ~next_action:"drain" selections in
  let after_calls = !(Counter.calls) in
  let before_wire = `List (List.map Before.waiting_row_json before) |> Yojson.Safe.to_string in
  let after_wire = `List (List.map After.waiting_row_json after) |> Yojson.Safe.to_string in
  check (label^": byte-identical complete row output") (String.equal before_wire after_wire);
  check (label^": original hash count") (before_calls = expected_before);
  check (label^": candidate hash count") (after_calls = expected_after);
  let address_exists detail =
    let digest = member "source_ref" detail |> string in
    let incarnation = member "source_incarnation" detail |> string in
    List.exists (fun (s:Keeper_event_queue_state.pending_selection) ->
      String.equal digest (oracle s.source)
      && String.equal incarnation (Int64.to_string s.admitted_revision)) selections
  in
  List.iter (fun (row:After.waiting_row) ->
    check (label^": emitted anchor exact digest/incarnation") (address_exists row.detail);
    match row.detail with
    | `Assoc fields -> (match List.assoc_opt "group_members" fields with
      | Some (`List members) -> List.iter (fun address ->
          check (label^": group member exact digest/incarnation") (address_exists address)) members
      | _ -> ())
    | _ -> failwith "row detail") after;
  cases := (`Assoc ["case",`String label;"before_hash_calls",`Int before_calls
    ;"after_hash_calls",`Int after_calls;"wire_bytes",`Int (String.length after_wire)]) :: !cases;
  after

let () =
  ignore(run "empty" 0 0 []);
  ignore(run "single bootstrap" 1 1 [selection "boot" Bootstrap]);
  ignore(run "single connector" 1 1 [connector "c1"]);
  ignore(run "duplicate arrivals, mixed connector urgencies" 3 1
    [connector ~urgency:Low "c1";connector ~urgency:Immediate "c2";connector ~urgency:Normal "c3"]);
  ignore(run "connector group with independent row and queue indexes" 4 2
    [connector "c1";selection "boot" Bootstrap;connector "c2";connector "c3"]);
  ignore(run "bounded connector ids" 11 1
    (List.init 11 (fun i -> connector ("connector-"^string_of_int i))));
  ignore(run "single schedule" 1 1 [schedule "g" "s1" 10.]);
  let a = schedule ~incarnation:4L "g" "a" 40. in
  let b = schedule ~incarnation:9L "g" "b" 10. in
  let c = schedule ~incarnation:15L "g" "c" 70. in
  let permutations = [[a;b;c];[a;c;b];[b;a;c];[b;c;a];[c;a;b];[c;b;a]] in
  List.iteri (fun i xs -> ignore(run ("schedule due permutation "^string_of_int i) 6 3 xs)) permutations;
  let rows = run "queue anchor differs from first due member" 6 3 [a;b;c] in
  let detail = (List.hd rows).After.detail in
  check "anchor remains queue-first a" (member "source_ref" detail = `String(oracle a.source));
  let members = member "group_members" detail |> list in
  check "member order remains due b,a,c"
    (List.map (fun m -> member "source_ref" m) members = List.map (fun s -> `String(oracle s.Keeper_event_queue_state.source)) [b;a;c]);
  ignore(run "equal due times stable order" 4 2
    [schedule ~incarnation:8L "g" "equal-second" 10.;schedule ~incarnation:2L "g" "equal-first" 10.]);
  ignore(run "interleaved independent schedule groups" 9 5
    [a;schedule "h" "h1" 20.;b;schedule "single" "solo" 6.;schedule "h" "h2" 5.]);
  ignore(run "two-member group same post different urgency" 4 2
    [schedule ~urgency:Low "g" "shared-post" 5.;schedule ~urgency:Immediate "g" "shared-post" 5.]);
  ignore(run "same source object different incarnation" 4 2
    [a;{a with admitted_revision=77L}]);
  ignore(run "repeated exact selection object" 4 1 [a;a]);
  let signal = {kind=Post_created;author="private-author";title="private-title"
    ;content="private-body";hearth=Some "private-hearth";updated_at=None;audience=Audience_targets["private-target"]} in
  let boards = [selection "private-post" (Board_signal signal)
    ;selection "private-post" (Board_routing_pending signal)
    ;selection "private-post" (Board_attention {candidate_id="private-candidate";signal})] in
  let rows = run "all private Board variants" 3 3 boards in
  List.iter (fun (row:After.waiting_row) -> match row.detail with
    | `Assoc fields -> check "Board detail has only opaque address fields"
        (List.map fst fields = ["source_ref";"source_incarnation"])
    | _ -> failwith "Board detail") rows;
  ignore(run "mixed Board, schedules and connector skip rows" 12 8
    (List.hd boards :: a :: connector "c1" :: b :: connector "c2"
     :: List.nth boards 1 :: c :: List.nth boards 2 :: [selection "boot" Bootstrap]));
  ()

let probe_result existing_tests = `Assoc
    ["cases",`List(List.rev !cases);"assertions",`Int !checks
    ;"existing_grouping_tests",`List(List.map (fun s -> `String s) existing_tests)
    ;"scope",`String "source-extracted complete pure row projection; real prebuilt queue encoder/SHA and type interfaces; no product I/O"]
