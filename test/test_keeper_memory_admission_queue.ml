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
  Current.apply_disposition ~explicit_candidate_ids:range ~absorbed:[] ~revisions:[]
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
  let selected = Queue.candidate_ids (batch keepers_dir) in
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
  check int "remaining sequence stays original" 2 (List.hd (Queue.candidates remaining)).sequence;
  acknowledge keepers_dir;
  check int "repeat recovery does not consume tail" 1 (List.length (Queue.candidates (batch keepers_dir)));
  ignore (commit keepers_dir (Queue.candidate_ids remaining) []);
  acknowledge keepers_dir;
  check bool "no-change decision consumes its input" true (pending keepers_dir = None);
  check int "sequence continues after queue empties" 3 (append keepers_dir "three" "third rule").sequence)

let test_wrong_digest_keeps_candidates () = with_store (fun keepers_dir ->
  ignore (append keepers_dir "one" "first rule");
  let selected = Queue.candidate_ids (batch keepers_dir) in
  let wrong = List.map (fun (id : Current.explicit_candidate_id) ->
    {id with input_sha256 = String.make 64 '0'}) selected in
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
  let selected = Queue.candidate_ids (batch keepers_dir) in
  (* The model selected this destination from the earlier snapshot. *)
  ignore (Current.replace ~keepers_dir ~keeper_id:"keeper"
    ~expected_revision:(Some initial.revision) ~now:200.
    ~source:{kind=Current.Librarian; trace_id="retire"} ~facts:[] () |> require);
  (match Current.apply_disposition ~explicit_candidate_ids:selected
     ~required_memory_ids:[Types.memory_id destination] ~absorbed:[] ~revisions:[]
     ~keepers_dir ~keeper_id:"keeper" ~now:300.
     ~source:{kind=Current.Librarian; trace_id="admission"} ~new_claims:[] () with
   | Error _ -> () | Ok _ -> fail "a missing destination authorized consumption");
  acknowledge keepers_dir;
  check int "candidate remains pending for a fresh judgment" 1
    (List.length (Queue.candidates (batch keepers_dir))))

let test_worker_recovers_before_judging () = with_store (fun keepers_dir ->
  ignore (append keepers_dir "one" "rule");
  ignore (commit keepers_dir (Queue.candidate_ids (batch keepers_dir)) []);
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
      ignore (commit keepers_dir (Queue.candidate_ids batch) (List.map (fun (row : Queue.candidate) -> row.fact) rows));
      Worker.Committed in
  let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper" ~judge in
  check (list (list string)) "both disjoint halves execute after capacity refusal"
    [["one";"two";"three";"four"];["one";"two"];["three";"four"]] (List.rev !calls);
  check bool "completed siblings need no retry wake" true (outcome = Worker.Settled {has_more=false});
  check bool "both sibling receipts consumed their input" true (pending keepers_dir=None))

let test_worker_does_not_consume_uncertainty () = with_store (fun keepers_dir ->
  ignore (append keepers_dir "one" "uncertain rule");
  let calls = ref 0 in
  let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
    ~judge:(fun _ -> incr calls; Worker.Awaiting_evidence) in
  check int "uncertainty does not privately retry" 1 !calls;
  (match outcome with Worker.Pending _ -> () | _ -> fail "semantic uncertainty was not retained");
  check int "uncertain input retained" 1 (List.length (Queue.candidates (batch keepers_dir)));
  (match Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper" ~judge:(fun _ -> Worker.Committed) with
   | Worker.Unavailable _ -> () | _ -> fail "callback without durable receipt consumed input");
  check int "callback cannot authorize consumption" 1 (List.length (Queue.candidates (batch keepers_dir))))

let test_sparse_consumption_retains_gap_and_append () = with_store (fun keepers_dir ->
  ignore (append keepers_dir "a" "uncertain A");
  ignore (append keepers_dir "b" "settled B");
  let selected = batch keepers_dir in
  let b = List.find (fun (id : Current.explicit_candidate_id) -> id.request_id="b")
    (Queue.candidate_ids selected) in
  let written = commit keepers_dir [b] [fact "settled B"] in
  (* Crash boundary: commit persisted, acknowledgement not yet performed. *)
  ignore (append keepers_dir "c" "new C");
  ignore (Current.replace ~keepers_dir ~keeper_id:"keeper"
    ~expected_revision:(Some written.snapshot.revision) ~now:300.
    ~source:{kind=Current.Librarian; trace_id="retire"} ~facts:[] () |> require);
  acknowledge keepers_dir;
  check (list string) "only committed B is removed across retirement and append" ["a";"c"]
    (List.map (fun (row : Queue.candidate) -> row.request_id) (Queue.candidates (batch keepers_dir)));
  check (list int) "sparse original sequences survive" [1;3]
    (List.map (fun (row : Queue.candidate) -> row.sequence) (Queue.candidates (batch keepers_dir)));
  acknowledge keepers_dir;
  check int "append never reuses consumed sequence" 4 (append keepers_dir "d" "new D").sequence;
  (match Current.apply_disposition ~explicit_candidate_ids:[b] ~absorbed:[] ~revisions:[]
      ~keepers_dir ~keeper_id:"keeper" ~now:400.
      ~source:{kind=Current.Librarian; trace_id="stale"} ~new_claims:[fact "settled B"] () with
   | Error _ -> () | Ok _ -> fail "consumed B resurrected after retirement");
  let snapshot = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" |> require in
  check bool "recovery did not restore retired claim" true
    (match snapshot with Some snapshot -> snapshot.facts=[] | None -> false))

let test_worker_partial_consumption_wakes_only_new_input () =
  List.iter (fun append_during_judgment -> with_store (fun keepers_dir ->
    ignore (append keepers_dir "a" "uncertain A");
    ignore (append keepers_dir "b" "settled B");
    let calls = ref 0 in
    let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
      ~judge:(fun selected ->
        incr calls;
        let b = List.find (fun (id : Current.explicit_candidate_id) -> id.request_id="b")
          (Queue.candidate_ids selected) in
        if append_during_judgment then ignore (append keepers_dir "c" "new C");
        ignore (commit keepers_dir [b] []);
        Worker.Committed) in
    check int "one partial judgment does not retry deferred gap" 1 !calls;
    check bool "only input not evaluated yet schedules another wake" true
      (outcome=Worker.Settled {has_more=append_during_judgment});
    check (list string) "deferred A stays pending without blocking B"
      (if append_during_judgment then ["a";"c"] else ["a"])
      (List.map (fun (row : Queue.candidate) -> row.request_id) (Queue.candidates (batch keepers_dir)))))
    [false;true]

let candidate_names selected =
  List.map (fun (row : Queue.candidate) -> row.request_id) (Queue.candidates selected)

let test_capacity_left_uncertainty_does_not_block_right () =
  List.iter (fun append_tail -> with_store (fun keepers_dir ->
    List.iter (fun id -> ignore (append keepers_dir id ("rule " ^ id))) ["a";"b";"c";"d"];
    let calls = ref [] in
    let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
      ~judge:(fun selected ->
        let names = candidate_names selected in calls := names :: !calls;
        match names with
        | ["a";"b";"c";"d"] -> Worker.Input_size_refused "full request too large"
        | ["a";"b"] ->
          if append_tail then ignore (append keepers_dir "e" "new E");
          Worker.Awaiting_evidence
        | ["c";"d"] -> ignore (commit keepers_dir (Queue.candidate_ids selected) []); Worker.Committed
        | _ -> fail "unexpected or repeated capacity slice") in
    check (list (list string)) "deferred left is not retried and right still runs"
      [["a";"b";"c";"d"];["a";"b"];["c";"d"]] (List.rev !calls);
    check bool "only concurrently appended tail requests another wake" true
      (outcome=Worker.Settled {has_more=append_tail});
    check (list string) "deferred left and new tail remain durable"
      (if append_tail then ["a";"b";"e"] else ["a";"b"])
      (candidate_names (batch keepers_dir)))) [false;true]

let test_capacity_outage_stops_before_sibling () = with_store (fun keepers_dir ->
  List.iter (fun id -> ignore (append keepers_dir id ("rule " ^ id))) ["a";"b"];
  let path = Queue.path ~keepers_dir ~keeper_id:"keeper" in
  let before = Fs_compat.load_file path in
  let calls = ref [] in
  let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
    ~judge:(fun selected ->
      let names = candidate_names selected in calls := names :: !calls;
      match names with
      | ["a";"b"] -> Worker.Input_size_refused "full request too large"
      | ["a"] -> Worker.Deferred "provider unavailable"
      | _ -> fail "provider outage incorrectly dispatched sibling") in
  check (list (list string)) "outage stops traversal" [["a";"b"];["a"]] (List.rev !calls);
  check bool "outage cause remains explicit" true (outcome=Worker.Pending "provider unavailable");
  check string "outage preserves all pending bytes" before (Fs_compat.load_file path))

let test_worker_deferred_after_commit_reports_commit () = with_store (fun keepers_dir ->
  List.iter (fun id -> ignore (append keepers_dir id ("rule " ^ id))) ["a";"b"];
  let calls = ref [] in
  let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
    ~judge:(fun selected ->
      let names = candidate_names selected in calls := names :: !calls;
      match names with
      | ["a";"b"] -> Worker.Input_size_refused "full request too large"
      | ["a"] -> ignore (commit keepers_dir (Queue.candidate_ids selected) []); Worker.Committed
      | ["b"] -> Worker.Deferred "provider unavailable"
      | _ -> fail "unexpected or repeated capacity slice") in
  check (list (list string)) "deferred sibling still stops the pass after a commit"
    [["a";"b"];["a"];["b"]] (List.rev !calls);
  check bool "earlier commit is reported settled, not pending" true
    (outcome=Worker.Settled {has_more=false});
  check (list string) "deferred sibling remains durable" ["b"] (candidate_names (batch keepers_dir)))

let test_nested_capacity_retains_indivisible_input () = with_store (fun keepers_dir ->
  List.iter (fun id -> ignore (append keepers_dir id ("rule " ^ id))) ["a";"b";"c";"d"];
  let calls = ref [] in
  let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
    ~judge:(fun selected ->
      let names = candidate_names selected in calls := names :: !calls;
      match names with
      | ["a"] -> Worker.Input_size_refused "indivisible candidate too large"
      | [_] -> ignore (commit keepers_dir (Queue.candidate_ids selected) []); Worker.Committed
      | _ -> Worker.Input_size_refused "combined request too large") in
  check (list (list string)) "nested traversal preserves original sibling order"
    [["a";"b";"c";"d"];["a";"b"];["a"];["b"];["c";"d"];["c"];["d"]]
    (List.rev !calls);
  check bool "indivisible leftover does not cause immediate retry" true
    (outcome=Worker.Settled {has_more=false});
  check (list string) "only oversized original remains" ["a"] (candidate_names (batch keepers_dir)))

let test_capacity_all_siblings_deferred_do_not_spin () = with_store (fun keepers_dir ->
  List.iter (fun id -> ignore (append keepers_dir id ("rule " ^ id))) ["a";"b"];
  let before = Fs_compat.load_file (Queue.path ~keepers_dir ~keeper_id:"keeper") in
  let calls = ref [] in
  let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
    ~judge:(fun selected ->
      let names = candidate_names selected in calls := names :: !calls;
      match names with
      | ["a";"b"] -> Worker.Input_size_refused "full request too large"
      | [_] -> Worker.Awaiting_evidence
      | _ -> fail "unexpected slice") in
  check (list (list string)) "each deferred sibling is visited once"
    [["a";"b"];["a"];["b"]] (List.rev !calls);
  (match outcome with Worker.Pending _ -> () | _ -> fail "all deferred scheduled an immediate retry");
  check string "all uncertain inputs remain byte-exact" before
    (Fs_compat.load_file (Queue.path ~keepers_dir ~keeper_id:"keeper")))

let test_semantic_deferral_with_new_tail_is_not_commit () = with_store (fun keepers_dir ->
  ignore (append keepers_dir "a" "uncertain A");
  let calls = ref 0 in
  let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
    ~judge:(fun selected ->
      incr calls;
      check (list string) "only original input is evaluated" ["a"] (candidate_names selected);
      ignore (append keepers_dir "b" "new B");
      Worker.Awaiting_evidence) in
  check int "new input schedules another pass instead of immediate retry" 1 !calls;
  check bool "no commit is reported when only new input arrived" true
    (outcome=Worker.Recheck_new_input);
  let remaining = batch keepers_dir in
  check (list string) "uncertain original and new input remain durable" ["a";"b"]
    (candidate_names remaining);
  let generation = match Queue.candidate_ids remaining with
    | first :: _ -> first.Current.queue_generation | [] -> fail "missing input" in
  check bool "no candidate receipt was minted" true
    ((Current.committed_explicit_candidates ~keepers_dir ~keeper_id:"keeper"
      ~queue_generation:generation |> require) = []);
  check bool "semantic waiting did not create a Memory snapshot" true
    ((Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" |> require) = None))

let test_sparse_lost_receipts_keeps_queue_blocked () =
  List.iter (fun consume_all -> with_store (fun keepers_dir ->
    ignore (append keepers_dir "a" "pending A");
    ignore (append keepers_dir "b" "settled B");
    let ids = Queue.candidate_ids (batch keepers_dir) in
    let selected = if consume_all then ids else
      List.filter (fun (id : Current.explicit_candidate_id) -> id.request_id="b") ids in
    ignore (commit keepers_dir selected []);
    acknowledge keepers_dir;
    let queue_path = Queue.path ~keepers_dir ~keeper_id:"keeper" in
    let before = Fs_compat.load_file queue_path in
    Sys.remove (Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper");
    (match Queue.acknowledge_committed ~keepers_dir ~keeper_id:"keeper" with
     | Ok () -> fail "consumed sparse history without receipts was admitted"
     | Error detail -> check bool "absent product backup remains an explicit recovery blocker" true
         (Astring.String.is_infix ~affix:"independently attested exact backup that this product does not create" detail));
    check string "lost receipt never rewrites pending bytes or order" before
      (Fs_compat.load_file queue_path))) [false;true]

let test_partially_lost_receipts_keep_queue_blocked () = with_store (fun keepers_dir ->
  List.iter (fun id -> ignore (append keepers_dir id ("rule " ^ id))) ["a";"b";"c"];
  let ids = Queue.candidate_ids (batch keepers_dir) in
  let id_of request_id =
    List.find (fun (id : Current.explicit_candidate_id) -> id.request_id = request_id) ids in
  ignore (commit keepers_dir [id_of "a"] [fact "rule a"]);
  acknowledge keepers_dir;
  let receipt_path = Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper" in
  let receipts_naming_only_a = Fs_compat.load_file receipt_path in
  ignore (commit keepers_dir [id_of "b"] [fact "rule b"]);
  acknowledge keepers_dir;
  check (list int) "a and b consumed, c pending" [3]
    (List.map (fun (row : Queue.candidate) -> row.sequence) (Queue.candidates (batch keepers_dir)));
  (* An older but valid receipt file comes back: sequence 1 still has its
     receipt, nothing names consumed sequence 2. *)
  Fs_compat.save_file_atomic_strict receipt_path receipts_naming_only_a |> require;
  let queue_path = Queue.path ~keepers_dir ~keeper_id:"keeper" in
  let before = Fs_compat.load_file queue_path in
  (match Queue.acknowledge_committed ~keepers_dir ~keeper_id:"keeper" with
   | Ok () -> fail "a consumed sequence without its receipt was admitted"
   | Error _ -> ());
  check string "partial receipt loss never rewrites pending bytes" before
    (Fs_compat.load_file queue_path);
  (match Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
     ~judge:(fun _ -> fail "pending input judged past unproven consumption") with
   | Worker.Unavailable _ -> ()
   | Worker.Disabled | Worker.Idle | Worker.Recheck_new_input | Worker.Settled _
   | Worker.Pending _ ->
     fail "worker continued past a consumed sequence without its receipt"))

let test_size_with_a_same_failure_is_deferred_whole () =
  let reason ~capacity ~same : Masc.Keeper_librarian_runtime.not_committed =
    { detail = "walk"; walk_shows_size = capacity;
      input_capacity_evidence =
        (if capacity then Masc.Keeper_librarian_runtime.Input_capacity_refused
         else Masc.Keeper_librarian_runtime.No_input_capacity_refusal);
      smaller_range_meets_same_failure = same } in
  let name = function
    | Worker.Input_size_refused _ -> "split" | Worker.Deferred _ -> "defer"
    | Worker.Committed -> "committed" | Worker.Awaiting_evidence -> "awaiting" in
  List.iter (fun (label, capacity, same, expected) ->
    check string label expected
      (name (Worker.For_testing.judgment_of_not_committed (reason ~capacity ~same))))
    [ "a capacity refusal alone splits", true, false, "split"
    ; "a capacity refusal with a quota in the same walk is deferred whole", true, true, "defer"
    ; "no capacity refusal defers", false, false, "defer"
    ; "a quota without a capacity refusal defers", false, true, "defer" ]

let () = run "durable explicit admission queue"
  ["storage boundaries", [
    test_case "new input during semantic deferral is recheck, not commit" `Quick test_semantic_deferral_with_new_tail_is_not_commit;
    test_case "capacity siblings continue past semantic uncertainty" `Quick test_capacity_left_uncertainty_does_not_block_right;
    test_case "capacity sibling traversal stops on provider outage" `Quick test_capacity_outage_stops_before_sibling;
    test_case "deferred sibling after a commit still reports the commit" `Quick test_worker_deferred_after_commit_reports_commit;
    test_case "size with a same failure is deferred whole" `Quick test_size_with_a_same_failure_is_deferred_whole;
    test_case "nested capacity split retains indivisible input" `Quick test_nested_capacity_retains_indivisible_input;
    test_case "all deferred capacity siblings do not spin" `Quick test_capacity_all_siblings_deferred_do_not_spin;
    test_case "lost sparse receipts preserve the unrecoverable queue boundary" `Quick test_sparse_lost_receipts_keeps_queue_blocked;
    test_case "partially lost sparse receipts keep the queue blocked" `Quick test_partially_lost_receipts_keep_queue_blocked;
    test_case "sparse receipt recovery preserves deferred gap and new append" `Quick test_sparse_consumption_retains_gap_and_append;
    test_case "partial worker wakes only newly unjudged input" `Quick test_worker_partial_consumption_wakes_only_new_input;
    test_case "pending is distinct from current Memory" `Quick test_pending_is_not_current;
    test_case "commit then retirement recovers without losing new tail" `Quick test_recovery_preserves_new_tail;
    test_case "input digest mismatch retains candidates" `Quick test_wrong_digest_keeps_candidates;
    test_case "retired destination refuses consumption" `Quick test_removed_destination_cannot_consume;
    test_case "worker restores committed input before judging" `Quick test_worker_recovers_before_judging;
    test_case "worker retries size refusal without discarding tail" `Quick test_worker_size_refusal_preserves_tail;
    test_case "worker retains uncertainty and requires durable commit" `Quick test_worker_does_not_consume_uncertainty;
    test_case "corruption cannot reset pending input" `Quick test_corruption_is_not_empty]]
