open Alcotest
module Queue = Masc.Keeper_memory_admission_queue
module Current = Masc.Keeper_memory_os_current
module Types = Masc.Keeper_memory_os_types
module Worker = Masc.Keeper_memory_admission_worker

let require = function Ok value -> value | Error detail -> fail detail
let fact claim : Types.fact =
  {claim; category = Types.Fact; first_seen = 100.; last_seen = 100.;
   origin = {kind = Types.Authored; trace_id = "candidate-trace"};
   basis = Types.Observed Types.Transcript}
let with_store f =
  let keepers_dir = Filename.temp_dir "admission-queue-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree keepers_dir)
    (fun () -> f keepers_dir)
let append keepers_dir request_id claim =
  Queue.append ~keepers_dir ~keeper_id:"keeper" ~request_id (fact claim) |> require
let pending keepers_dir = Queue.read_pending ~keepers_dir ~keeper_id:"keeper" |> require
let batch keepers_dir = match pending keepers_dir with Some batch -> batch | None -> fail "missing candidates"
let acknowledge keepers_dir = Queue.acknowledge_committed ~keepers_dir ~keeper_id:"keeper" |> require
let commit keepers_dir range new_claims =
  Current.apply_disposition ~explicit_write_range_id:range ~absorbed:[] ~revisions:[]
    ~keepers_dir ~keeper_id:"keeper" ~now:200.
    ~source:{kind = Current.Librarian; trace_id = "admission-judge"} ~new_claims () |> require

let test_pending_is_not_current () = with_store (fun keepers_dir ->
  let first = append keepers_dir "one" "first rule" in
  let repeated = append keepers_dir "one" "first rule" in
  check bool "pending retry returns same candidate" true (first = repeated);
  check int "one pending candidate" 1 (List.length (Queue.candidates (batch keepers_dir)));
  check bool "no current Memory before judgment" true
    (Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" |> require = None);
  (match Queue.append ~keepers_dir ~keeper_id:"keeper" ~request_id:"one" (fact "different") with
   | Error _ -> () | Ok _ -> fail "identity conflict accepted");
  acknowledge keepers_dir;
  check int "no receipt cannot consume candidate" 1 (List.length (Queue.candidates (batch keepers_dir))))

let test_recovery_preserves_new_tail () = with_store (fun keepers_dir ->
  ignore (append keepers_dir "one" "first rule");
  let selected = Queue.range_id (batch keepers_dir) in
  ignore (append keepers_dir "two" "second rule");
  let committed = commit keepers_dir selected [fact "first rule"] in
  (* Model commit succeeded but the queue has not acknowledged it. A later
     real store retirement must not erase the evidence for consuming input. *)
  ignore (Current.replace ~keepers_dir ~keeper_id:"keeper"
    ~expected_revision:(Some committed.snapshot.revision) ~now:300.
    ~source:{kind = Current.Librarian; trace_id = "retire"} ~facts:[] () |> require);
  acknowledge keepers_dir;
  let remaining = batch keepers_dir in
  check (list string) "new tail survives committed prefix" ["two"]
    (List.map (fun (row : Queue.candidate) -> row.request_id) (Queue.candidates remaining));
  check int "frontier advances" 1 (Queue.range_id remaining).after_sequence;
  acknowledge keepers_dir;
  check int "repeat recovery does not consume tail" 1 (List.length (Queue.candidates (batch keepers_dir)));
  ignore (commit keepers_dir (Queue.range_id remaining) []);
  acknowledge keepers_dir;
  check bool "no-change decision consumes its input" true (pending keepers_dir = None);
  check int "sequence continues after queue empties" 3 (append keepers_dir "three" "third rule").sequence)

let test_wrong_digest_keeps_candidates () = with_store (fun keepers_dir ->
  ignore (append keepers_dir "one" "first rule");
  let selected = Queue.range_id (batch keepers_dir) in
  let wrong = {selected with Current.input_sha256 = String.make 64 '0'} in
  ignore (commit keepers_dir wrong []);
  (match Queue.acknowledge_committed ~keepers_dir ~keeper_id:"keeper" with
   | Error _ -> () | Ok () -> fail "wrong input digest consumed candidate");
  check int "candidate retained" 1 (List.length (Queue.candidates (batch keepers_dir))))

let test_corruption_is_not_empty () = with_store (fun keepers_dir ->
  let path = Queue.path ~keepers_dir ~keeper_id:"keeper" in
  Fs_compat.save_file_atomic_strict path "{broken" |> require;
  (match Queue.read_pending ~keepers_dir ~keeper_id:"keeper" with
   | Error _ -> () | Ok _ -> fail "corruption interpreted as empty");
  (match Queue.append ~keepers_dir ~keeper_id:"keeper" ~request_id:"one" (fact "rule") with
   | Error _ -> () | Ok _ -> fail "corruption overwritten");
  check (option string) "rejected bytes preserved" (Some "{broken") (Fs_compat.load_file_opt path))

let test_removed_destination_cannot_consume () = with_store (fun keepers_dir ->
  let destination = fact "existing representation" in
  let initial = Current.replace ~keepers_dir ~keeper_id:"keeper" ~expected_revision:None
    ~now:100. ~source:{kind=Current.Librarian; trace_id="seed"} ~facts:[destination] () |> require in
  ignore (append keepers_dir "one" "same event observed again");
  let selected = Queue.range_id (batch keepers_dir) in
  (* The model selected this destination from the earlier snapshot. *)
  ignore (Current.replace ~keepers_dir ~keeper_id:"keeper"
    ~expected_revision:(Some initial.revision) ~now:200.
    ~source:{kind=Current.Librarian; trace_id="retire"} ~facts:[] () |> require);
  (match Current.apply_disposition ~explicit_write_range_id:selected
     ~required_memory_ids:[Types.memory_id destination] ~absorbed:[] ~revisions:[]
     ~keepers_dir ~keeper_id:"keeper" ~now:300.
     ~source:{kind=Current.Librarian; trace_id="admission"} ~new_claims:[] () with
   | Error _ -> () | Ok _ -> fail "a missing destination authorized consumption");
  acknowledge keepers_dir;
  check int "candidate remains pending for a fresh judgment" 1
    (List.length (Queue.candidates (batch keepers_dir))))

let test_worker_recovers_before_judging () = with_store (fun keepers_dir ->
  ignore (append keepers_dir "one" "rule");
  ignore (commit keepers_dir (Queue.range_id (batch keepers_dir)) []);
  let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
    ~judge:(fun _ -> fail "restart replayed input already committed") in
  check bool "restart acknowledges before dispatch" true (outcome = Worker.Idle);
  check bool "pending input recovered" true (pending keepers_dir = None))

let test_worker_size_refusal_preserves_tail () = with_store (fun keepers_dir ->
  List.iter (fun id -> ignore (append keepers_dir id ("rule " ^ id))) ["one";"two";"three";"four"];
  let calls = ref [] in
  let judge batch =
    let rows = Queue.candidates batch in
    calls := List.map (fun (row : Queue.candidate) -> row.request_id) rows :: !calls;
    match rows with
    | [_;_;_;_] -> Worker.Input_size_refused "synthetic provider refused full input"
    | _ ->
      ignore (commit keepers_dir (Queue.range_id batch) (List.map (fun (row : Queue.candidate) -> row.fact) rows));
      Worker.Committed in
  let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper" ~judge in
  check (list (list string)) "only complete prefix retried after capacity refusal"
    [["one";"two";"three";"four"];["one";"two"]] (List.rev !calls);
  check bool "successful prefix leaves another wake" true (outcome = Worker.Settled {has_more=true});
  check (list string) "unjudged tail remains pending" ["three";"four"]
    (List.map (fun (row : Queue.candidate) -> row.request_id) (Queue.candidates (batch keepers_dir)));
  let completed = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper" ~judge in
  check bool "next wake consumes only remaining input" true (completed = Worker.Settled {has_more=false}))

let test_worker_does_not_consume_uncertainty () = with_store (fun keepers_dir ->
  ignore (append keepers_dir "one" "uncertain rule");
  let calls = ref 0 in
  let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
    ~judge:(fun _ -> incr calls; Worker.Deferred "need more evidence") in
  check int "uncertainty does not privately retry" 1 !calls;
  check bool "uncertainty remains explicit" true (outcome = Worker.Pending "need more evidence");
  check int "uncertain input retained" 1 (List.length (Queue.candidates (batch keepers_dir)));
  (match Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper" ~judge:(fun _ -> Worker.Committed) with
   | Worker.Unavailable _ -> () | _ -> fail "callback without durable receipt consumed input");
  check int "callback cannot authorize consumption" 1 (List.length (Queue.candidates (batch keepers_dir))))

let () = run "durable explicit admission queue"
  ["storage boundaries", [
    test_case "pending is distinct from current Memory" `Quick test_pending_is_not_current;
    test_case "commit then retirement recovers without losing new tail" `Quick test_recovery_preserves_new_tail;
    test_case "input digest mismatch retains candidates" `Quick test_wrong_digest_keeps_candidates;
    test_case "retired destination refuses consumption" `Quick test_removed_destination_cannot_consume;
    test_case "worker restores committed input before judging" `Quick test_worker_recovers_before_judging;
    test_case "worker retries size refusal without discarding tail" `Quick test_worker_size_refusal_preserves_tail;
    test_case "worker retains uncertainty and requires durable commit" `Quick test_worker_does_not_consume_uncertainty;
    test_case "corruption cannot reset pending input" `Quick test_corruption_is_not_empty]]
