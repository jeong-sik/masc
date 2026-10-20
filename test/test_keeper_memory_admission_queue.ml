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
  Queue.append ~keepers_dir ~keeper_id:"keeper" ~request_id (fact claim) |> Result.map_error Queue.append_error_to_string |> require
let pending keepers_dir = Queue.read_pending ~keepers_dir ~keeper_id:"keeper" |> require
let batch keepers_dir = match pending keepers_dir with Some batch -> batch | None -> fail "missing candidates"
let acknowledge keepers_dir = Queue.acknowledge_committed ~keepers_dir ~keeper_id:"keeper" |> require
let commit keepers_dir range new_claims =
  Current.apply_disposition ~explicit_candidate_ids:range ~absorbed:[] ~revisions:[]
    ~keepers_dir ~keeper_id:"keeper" ~now:200.
    ~source:{kind = Current.Librarian; trace_id = "admission-judge"} ~new_claims () |> require

let test_concurrent_acknowledgement_preserves_deferred_input () = with_store (fun keepers_dir ->
  ignore (append keepers_dir "a" "deferred A");
  ignore (append keepers_dir "b" "settled B");
  let selected = List.filter (fun (id : Current.explicit_candidate_id) ->
    id.request_id = "b") (Queue.candidate_ids (batch keepers_dir)) in
  let interleaved = ref false in
  Queue.For_testing.acknowledge_with ~keepers_dir ~keeper_id:"keeper"
    ~read_receipts:(fun ~queue_generation ->
      let earlier = Current.committed_explicit_candidates ~keepers_dir
        ~keeper_id:"keeper" ~queue_generation |> require in
      if not !interleaved then (
        interleaved := true;
        ignore (commit keepers_dir selected [fact "settled B"]);
        acknowledge keepers_dir);
      Ok earlier) |> require;
  check (list string) "another acknowledgement removes only committed B" ["a"]
    (List.map (fun (row : Queue.candidate) -> row.request_id)
      (Queue.candidates (batch keepers_dir))))

let test_concurrent_receipt_loss_leaves_remaining_input () =
  List.iter (fun reuse_request_id -> with_store (fun keepers_dir ->
  ignore (append keepers_dir "a" "deferred A");
  ignore (append keepers_dir "b" "settled B");
  let selected = List.filter (fun (id : Current.explicit_candidate_id) ->
    id.request_id = "b") (Queue.candidate_ids (batch keepers_dir)) in
  let interleaved = ref false in
  let queue_path = Queue.path ~keepers_dir ~keeper_id:"keeper" in
  let after_other_ack = ref "" in
  Queue.For_testing.acknowledge_with ~keepers_dir ~keeper_id:"keeper"
    ~read_receipts:(fun ~queue_generation ->
      let earlier = Current.committed_explicit_candidates ~keepers_dir
        ~keeper_id:"keeper" ~queue_generation |> require in
      if not !interleaved then (
        interleaved := true;
        ignore (commit keepers_dir selected [fact "settled B"]);
        acknowledge keepers_dir;
        if reuse_request_id then ignore (append keepers_dir "b" "new B occurrence");
        after_other_ack := Fs_compat.load_file queue_path;
        Sys.remove (Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper"));
      Ok earlier) |> require;
  check string "receipt loss rewrites no queue byte" !after_other_ack
    (Fs_compat.load_file queue_path);
  check (list string) "another acknowledgement removes only committed B" (if reuse_request_id then ["a";"b"] else ["a"])
    (List.map (fun (row : Queue.candidate) -> row.request_id)
      (Queue.candidates (batch keepers_dir))))) [false; true]

let test_concurrently_consumed_tail_is_left_to_its_acknowledgement () =
  List.iter (fun lose_receipt -> with_store (fun keepers_dir ->
    ignore (append keepers_dir "a" "deferred A");
    let interleaved = ref false in
    let queue_path = Queue.path ~keepers_dir ~keeper_id:"keeper" in
    let after_other_ack = ref "" in
    Queue.For_testing.acknowledge_with ~keepers_dir ~keeper_id:"keeper"
      ~read_receipts:(fun ~queue_generation ->
        let earlier = Current.committed_explicit_candidates ~keepers_dir
          ~keeper_id:"keeper" ~queue_generation |> require in
        if not !interleaved then (
          interleaved := true;
          ignore (append keepers_dir "b" "settled B");
          let selected = List.filter (fun (id : Current.explicit_candidate_id) ->
            id.request_id = "b") (Queue.candidate_ids (batch keepers_dir)) in
          ignore (commit keepers_dir selected [fact "settled B"]);
          acknowledge keepers_dir;
          after_other_ack := Fs_compat.load_file queue_path;
          if lose_receipt then
            Sys.remove (Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper"));
        Ok earlier) |> require;
    check string "outer acknowledgement preserves queue bytes" !after_other_ack
      (Fs_compat.load_file queue_path);
    check (list string) "deferred A stays pending" ["a"]
      (List.map (fun (row : Queue.candidate) -> row.request_id)
        (Queue.candidates (batch keepers_dir))))) [false; true]

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

let test_stale_retirement_after_source_reobservation () = with_store (fun keepers_dir ->
  let keeper_id = "keeper" in
  let original = fact "ordinary observation to retire" in
  let retained = { (fact "unmentioned observation") with last_seen=175. } in
  let seeded = Current.replace ~keepers_dir ~keeper_id ~expected_revision:None
    ~now:100. ~source:{kind=Current.Explicit_write; trace_id="seed"}
    ~facts:[original;retained] () |> require in
  ignore (append keepers_dir "one" "judgment input");
  let selected = Queue.candidate_ids (batch keepers_dir) in
  let stale_drop : Types.dropped_statement =
    {memory_id=Types.memory_id original; reason="the original claim is no longer useful"} in
  let withdrawn = Current.replace ~keepers_dir ~keeper_id
    ~expected_revision:(Some seeded.revision) ~now:200.
    ~source:{kind=Current.Explicit_retract; trace_id="withdraw"}
    ~facts:[retained] () |> require in
  let reobserved = {original with last_seen=300.;
    origin={kind=Types.Authored; trace_id="reobserved"}} in
  let restored = Current.upsert_fact ~keepers_dir ~keeper_id ~now:300.
    ~source:{kind=Current.Explicit_write; trace_id="reobserve"} reobserved
    |> Result.map_error Current.upsert_error_to_string |> require in
  check bool "reobservation is a new durable revision" true
    (restored.revision > withdrawn.revision);
  check bool "the exact reobserved source is current before the stale decision" true
    (List.mem reobserved restored.facts);
  let callbacks = ref 0 in
  let committed = Current.apply_disposition ~keepers_dir ~keeper_id ~now:400.
    ~on_committed:(fun _ -> incr callbacks) ~explicit_candidate_ids:selected
    ~source:{kind=Current.Librarian; trace_id="stale-retirement"}
    ~dropped_statements:[stale_drop] ~absorbed:[] ~revisions:[] ~new_claims:[] () |> require in
  check int "only the successful publication invokes its callback" 1 !callbacks;
  check bool "the unmentioned fact retains every stored field and basis" true
    (committed.snapshot.facts = [retained]);
  check bool "the published snapshot is the cold read authority" true
    (Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require = Some committed.snapshot);
  check bool "retirement does not invent revision or absorption edges" true
    (committed.revisions_applied=[] && committed.absorbed_applied=[]);
  (match Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:1 with
   | [Ok (Current.Journal_committed entry)] ->
     check bool "the journal removes the exact restored fields and basis" true
       (entry.change.removed = [reobserved]);
     check bool "the original retirement reason remains attached" true
       (entry.dropped = Some [stale_drop])
   | _ -> fail "missing committed retirement journal");
  check bool "retirement creates no absorbed rows" true
    (Masc.Keeper_memory_absorbed.read ~keepers_dir ~keeper_id |> require = []);
  let generation = (List.hd selected).Current.queue_generation in
  check bool "the decision receipt is durable before acknowledgement" true
    (Current.committed_explicit_candidates ~keepers_dir ~keeper_id ~queue_generation:generation
      |> require = selected);
  acknowledge keepers_dir;
  check bool "only committed input is acknowledged" true (pending keepers_dir=None))

let test_destination_lost_during_support_maintenance_preserves_publication () =
  with_store (fun keepers_dir ->
    let keeper_id = "keeper" in
    let premise = fact "destination premise" in
    let source = fact "absorption source" in
    let destination = Types.derived ~claim:"derived destination" ~category:Types.Fact
      ~now:100. ~origin:{kind=Types.Authored; trace_id="derived"}
      ~derivations:[{rule_id="support"; premise_ids=[Types.memory_id premise]}] |> require in
    let seeded = Current.replace ~keepers_dir ~keeper_id ~expected_revision:None ~now:100.
      ~source:{kind=Current.Explicit_write; trace_id="seed"}
      ~facts:[premise;destination;source] () |> require in
    ignore (append keepers_dir "one" "explicit input awaiting its representation");
    let selected = Queue.candidate_ids (batch keepers_dir) in
    let paths =
      [Current.path_for_keepers_dir ~keepers_dir ~keeper_id;
       Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id;
       Current.durable_range_receipt_path ~keepers_dir ~keeper_id;
       Current.publication_receipt_path ~keepers_dir ~keeper_id;
       Masc.Keeper_memory_absorbed.path_for_keepers_dir ~keepers_dir ~keeper_id;
       Queue.path ~keepers_dir ~keeper_id] in
    let before = List.map Fs_compat.load_file_opt paths in
    let callbacks = ref 0 in
    (match Current.apply_disposition ~keepers_dir ~keeper_id ~now:200.
      ~on_committed:(fun _ -> incr callbacks) ~explicit_candidate_ids:selected
      ~required_memory_ids:[Types.memory_id destination]
      ~source:{kind=Current.Librarian; trace_id="support-loss"}
      ~dropped_statements:[{memory_id=Types.memory_id premise; reason="premise withdrawn"}]
      ~absorbed:[{absorbed=Types.memory_id source; into=Types.memory_id destination}]
      ~revisions:[] ~new_claims:[fact "would be a new current claim"] () with
     | Error _ -> () | Ok _ -> fail "an unsupported required destination consumed input");
    check int "refusal never invokes the commit observer" 0 !callbacks;
    check bool "snapshot, journal, receipts, publication, absorbed rows and queue are byte-exact" true
      (before = List.map Fs_compat.load_file_opt paths);
    check bool "the original fields and support basis remain authoritative" true
      (Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require = Some seeded);
    acknowledge keepers_dir;
    check bool "no consumption receipt can acknowledge the refused input" true
      (Queue.candidate_ids (batch keepers_dir) = selected))

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

(* Accepted B no longer has a queue row after acknowledgement. Memory its
   receipt cannot be verified against, or a receipt file that cannot be read,
   must not turn that state into a fresh empty memory store. *)
let test_sparse_authority_loss_refuses_judgment () =
  List.iter (fun damage -> with_store (fun keepers_dir ->
    ignore (append keepers_dir "a" "uncertain A");
    ignore (append keepers_dir "b" "settled B");
    let selected=batch keepers_dir in
    let b=List.find (fun (id:Current.explicit_candidate_id) -> id.request_id="b")
      (Queue.candidate_ids selected) in
    let source_fact=(List.find (fun (row:Queue.candidate) -> row.request_id="b")
      (Queue.candidates selected)).fact in
    let target=fact "settled B" in
    let binding={Current.candidate_id=b;source_fact;target_memory_id=Types.memory_id target} in
    ignore(Current.apply_disposition ~explicit_candidate_ids:[b]
      ~admission_recall:{Current.decided_at_revision=None; bindings=[binding]}
      ~absorbed:[] ~revisions:[]
      ~keepers_dir ~keeper_id:"keeper" ~now:200.
      ~source:{kind=Current.Librarian;trace_id="authority-fixture"} ~new_claims:[target] ()
      |> require : Current.disposition);
    acknowledge keepers_dir;
    check (list string) "B settled while A remains deferred" ["a"]
      (List.map (fun (row:Queue.candidate) -> row.request_id) (Queue.candidates (batch keepers_dir)));
    let snapshot=Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
    let receipt=Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper" in
    let queue=Queue.path ~keepers_dir ~keeper_id:"keeper" in
    let journal=Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
    (match damage with
     | `Missing_snapshot -> Sys.remove snapshot
     | `Corrupt_snapshot -> Fs_compat.save_file snapshot "{broken snapshot"
     | `Mismatched_snapshot ->
       let json=Yojson.Safe.from_file snapshot in
       let fields=Yojson.Safe.Util.to_assoc json in
       Fs_compat.save_file snapshot (Yojson.Safe.to_string
         (`Assoc (("updated_at",`Float 999.) :: List.remove_assoc "updated_at" fields)))
     | `Corrupt_receipt -> Fs_compat.save_file receipt "{broken receipt");
    let before=List.map (fun path -> path,Fs_compat.load_file_opt path) [snapshot;receipt;queue;journal] in
    let calls=ref 0 in
    let outcome=Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
      ~judge:(fun _ -> incr calls; Worker.Awaiting_evidence) in
    check int "missing authority never reaches semantic judgment" 0 !calls;
    (match outcome with Worker.Unavailable _ -> ()
     | _ -> fail "lost sparse admission authority was treated as ordinary pending input");
    List.iter (fun (path,bytes) -> check (option string)
      "failed authority check preserves every surviving store byte" bytes (Fs_compat.load_file_opt path)) before))
    [`Missing_snapshot;`Corrupt_snapshot;`Mismatched_snapshot;`Corrupt_receipt]

let test_contiguous_pending_recovers_without_sparse_authority () =
  List.iter (fun empty_receipts -> with_store (fun keepers_dir ->
    ignore (append keepers_dir "fresh" "recoverable current fact");
    let snapshot = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
    Fs_compat.save_file snapshot "{broken snapshot";
    if empty_receipts then Fs_compat.save_file
      (Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper")
      {|{"receipts":[]}|};
    let calls = ref 0 in
    let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
      ~judge:(fun selected ->
        incr calls;
        ignore (commit keepers_dir (Queue.candidate_ids selected)
          [fact "recoverable current fact"]);
        Worker.Committed) in
    check int "contiguous pending input reaches judgment once" 1 !calls;
    check bool "recovery settles the queue" true
      (outcome = Worker.Settled {has_more=false});
    let current = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" |> require in
    check bool "ordinary commit replaces undecodable snapshot" true
      (match current with Some current ->
         List.exists (fun (f : Types.fact) -> f.claim = "recoverable current fact") current.facts
       | None -> false))) [false;true]

(* Characterization, not a recovery guarantee: B committed but its own
   acknowledgement never ran, so losing its receipt makes B indistinguishable
   from input never committed, and B is judged again. A row acknowledged
   earlier does not change that. *)
let test_lost_receipt_of_unacknowledged_commit_is_judged_again () =
  List.iter (fun earlier_acknowledged -> with_store (fun keepers_dir ->
  if earlier_acknowledged then (
    ignore (append keepers_dir "x" "settled X");
    ignore (commit keepers_dir (Queue.candidate_ids (batch keepers_dir)) [fact "settled X"]);
    acknowledge keepers_dir);
  ignore (append keepers_dir "a" "uncertain A");
  ignore (append keepers_dir "b" "settled B");
  let b=List.find (fun (id:Current.explicit_candidate_id) -> id.request_id="b")
    (Queue.candidate_ids (batch keepers_dir)) in
  ignore (commit keepers_dir [b] [fact "settled B"]);
  let receipt=Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper" in
  Sys.remove receipt;
  let queue=Queue.path ~keepers_dir ~keeper_id:"keeper" in
  let before=Fs_compat.load_file queue in
  let calls=ref [] in
  let outcome=Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
    ~judge:(fun selected ->
      calls:=List.map (fun (row:Queue.candidate) -> row.request_id) (Queue.candidates selected) :: !calls;
      Worker.Awaiting_evidence) in
  check (list (list string)) "the unacknowledged commit reaches judgment again"
    [["a";"b"]] !calls;
  (match outcome with Worker.Pending _ -> () | _ -> fail "unexpected diagnostic outcome");
  check string "diagnostic performs no consumption or reconstruction" before (Fs_compat.load_file queue);
  check (option string) "missing receipt is not fabricated" None (Fs_compat.load_file_opt receipt)))
  [false; true]

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

let test_bulk_append_preserves_length_and_order () = with_store (fun keepers_dir ->
  let count = 2000 in
  for index = 1 to count do
    ignore (append keepers_dir (Printf.sprintf "bulk-%d" index) (Printf.sprintf "rule %d" index))
  done;
  let rows = Queue.candidates (batch keepers_dir) in
  check int "every bulk append is retained" count (List.length rows);
  check (list int) "sequences stay ascending from 1"
    (List.init count (fun index -> index + 1))
    (List.map (fun (row : Queue.candidate) -> row.sequence) rows);
  let retried = append keepers_dir "bulk-1" "rule 1" in
  check int "retry keeps its original sequence" 1 retried.sequence;
  acknowledge keepers_dir;
  check int "retry adds no row" count
    (List.length (Queue.candidates (batch keepers_dir))))

let test_byte_cap_refuses_append_before_write () = with_store (fun keepers_dir ->
  ignore (append keepers_dir "one" "first rule");
  let queue_path = Queue.path ~keepers_dir ~keeper_id:"keeper" in
  let size_after_one = String.length (Fs_compat.load_file queue_path) in
  let before = Fs_compat.load_file queue_path in
  Masc_test_deps.with_process_env
    Env_config.KeeperMemoryOs.pending_max_bytes_env_key (Some (string_of_int size_after_one))
  @@ fun () ->
  (* The current file exactly meets the cap; growing it must be refused. *)
  (match Queue.append ~keepers_dir ~keeper_id:"keeper" ~request_id:"two" (fact "second rule") with
   | Ok _ -> fail "append past the byte cap was accepted"
   | Error (Queue.Append_failed detail) -> fail detail
   | Error (Queue.Capacity_exceeded {required_bytes; limit_bytes}) ->
     check int "declared cap" size_after_one limit_bytes;
     check bool "candidate exceeds actual serialized capacity" true (required_bytes > limit_bytes));
  check string "refusal rewrote no pending bytes" before (Fs_compat.load_file queue_path);
  check int "refused row is not pending" 1
    (List.length (Queue.candidates (batch keepers_dir)));
  (* An idempotent retry of an already-pending identity is not growth and
     stays allowed at the cap. *)
  ignore (append keepers_dir "one" "first rule");
  (* Raising the cap admits the refused request: the refusal never persisted
     last_sequence, so no sequence was burned. *)
  Masc_test_deps.with_process_env
    Env_config.KeeperMemoryOs.pending_max_bytes_env_key
    (Some (string_of_int (size_after_one * 4)))
  @@ fun () ->
  let admitted = append keepers_dir "two" "second rule" in
  check int "refused sequence is not burned" 2 admitted.sequence;
  check (list string) "both rows pending in order" ["one"; "two"]
    (candidate_names (batch keepers_dir)))

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

(* The live shape of 2026-10-19: rows consumed before a receipt schema cut
   lost their receipts while Memory stayed current. The rows that remain reach
   judgment against that Memory; the consumed ones are not judged again because
   the queue no longer holds them. *)
let test_lost_receipts_do_not_block_remaining_input () =
  List.iter (fun loss -> with_store (fun keepers_dir ->
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
    (match loss with
     | `Receipts_removed -> Sys.remove receipt_path
     | `Older_receipts_restored ->
       Fs_compat.save_file_atomic_strict receipt_path receipts_naming_only_a |> require);
    let queue_path = Queue.path ~keepers_dir ~keeper_id:"keeper" in
    let before = Fs_compat.load_file queue_path in
    acknowledge keepers_dir;
    check string "a lost receipt rewrites no pending byte" before
      (Fs_compat.load_file queue_path);
    let judged = ref [] in
    let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
      ~judge:(fun selected ->
        judged := candidate_names selected :: !judged;
        ignore (commit keepers_dir (Queue.candidate_ids selected) [fact "rule c"]);
        Worker.Committed) in
    check (list (list string)) "only the remaining row is judged" [["c"]] !judged;
    check bool "the remaining row settles" true (outcome = Worker.Settled {has_more=false});
    check bool "the queue drains" true (pending keepers_dir = None);
    let current = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" |> require in
    check (list string) "Memory keeps the consumed and the new facts"
      ["rule a"; "rule b"; "rule c"]
      (match current with
       | Some current ->
         List.sort String.compare (List.map (fun (f : Types.fact) -> f.claim) current.facts)
       | None -> []);
    check int "append never reuses a consumed sequence" 4 (append keepers_dir "d" "rule d").sequence))
    [`Receipts_removed; `Older_receipts_restored]

(* The snapshot itself is gone. Right after the loss the receipts it proved
   still refuse judgment. The next ordinary Librarian read reconciles the
   receipt sidecar against no snapshot and drops them, and the remaining
   explicit input then joins the Memory that starts again, as durable and
   continuity input do; it is not held back for a snapshot nothing restores. *)
let test_snapshot_loss_admits_remaining_input_into_new_memory () = with_store (fun keepers_dir ->
  List.iter (fun id -> ignore (append keepers_dir id ("rule " ^ id))) ["a";"b";"c"];
  let consumed = List.filter (fun (id : Current.explicit_candidate_id) -> id.request_id <> "c")
    (Queue.candidate_ids (batch keepers_dir)) in
  ignore (commit keepers_dir consumed [fact "rule a"; fact "rule b"]);
  acknowledge keepers_dir;
  Sys.remove (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper");
  (match Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
     ~judge:(fun _ -> fail "input judged against a receipt whose snapshot is gone") with
   | Worker.Unavailable _ -> ()
   | Worker.Disabled | Worker.Idle | Worker.Recheck_new_input | Worker.Settled _
   | Worker.Pending _ -> fail "a receipt without its snapshot was accepted");
  ignore (Current.committed_durable_coverage ~keepers_dir ~keeper_id:"keeper"
    ~receipt_scope:"ordinary-librarian-read" |> require);
  let judged = ref [] in
  let outcome = Worker.For_testing.run_with ~keepers_dir ~keeper_name:"keeper"
    ~judge:(fun selected ->
      judged := candidate_names selected :: !judged;
      ignore (commit keepers_dir (Queue.candidate_ids selected) [fact "rule c"]);
      Worker.Committed) in
  check (list (list string)) "only the remaining row is judged" [["c"]] !judged;
  check bool "the remaining row settles" true (outcome = Worker.Settled {has_more=false});
  let current = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" |> require in
  check (list string) "the new Memory holds what reached it after the loss" ["rule c"]
    (match current with
     | Some current -> List.map (fun (f : Types.fact) -> f.claim) current.facts
     | None -> []))

let test_size_with_a_same_failure_is_deferred_whole () =
  let reason ~capacity ~same : Masc.Keeper_librarian_runtime.not_committed =
    { detail = "walk"; walk_shows_size = capacity;
      message_descent =
        (if capacity then Masc.Keeper_librarian_runtime.Smaller_input_may_help
         else Masc.Keeper_librarian_runtime.No_descent_evidence);
      input_capacity_evidence =
        (if capacity then Masc.Keeper_librarian_runtime.Input_capacity_refused
         else Masc.Keeper_librarian_runtime.No_input_capacity_refusal);
      provider_input_refusals = []; smaller_range_meets_same_failure = same } in
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
    test_case "concurrently consumed tail is left to its own acknowledgement" `Quick test_concurrently_consumed_tail_is_left_to_its_acknowledgement;
    test_case "concurrent receipt loss leaves remaining input" `Quick test_concurrent_receipt_loss_leaves_remaining_input;
    test_case "concurrent acknowledgement preserves deferred input" `Quick test_concurrent_acknowledgement_preserves_deferred_input;
    test_case "a lost receipt of an unacknowledged commit is judged again" `Quick test_lost_receipt_of_unacknowledged_commit_is_judged_again;
    test_case "contiguous pending recovers without sparse authority" `Quick test_contiguous_pending_recovers_without_sparse_authority;
    test_case "lost sparse authority refuses judgment without retiring evidence" `Quick test_sparse_authority_loss_refuses_judgment;
    test_case "new input during semantic deferral is recheck, not commit" `Quick test_semantic_deferral_with_new_tail_is_not_commit;
    test_case "capacity siblings continue past semantic uncertainty" `Quick test_capacity_left_uncertainty_does_not_block_right;
    test_case "capacity sibling traversal stops on provider outage" `Quick test_capacity_outage_stops_before_sibling;
    test_case "deferred sibling after a commit still reports the commit" `Quick test_worker_deferred_after_commit_reports_commit;
    test_case "size with a same failure is deferred whole" `Quick test_size_with_a_same_failure_is_deferred_whole;
    test_case "nested capacity split retains indivisible input" `Quick test_nested_capacity_retains_indivisible_input;
    test_case "all deferred capacity siblings do not spin" `Quick test_capacity_all_siblings_deferred_do_not_spin;
    test_case "lost receipts do not block the remaining input" `Quick test_lost_receipts_do_not_block_remaining_input;
    test_case "snapshot loss admits remaining input into the new Memory" `Quick test_snapshot_loss_admits_remaining_input_into_new_memory;
    test_case "sparse receipt recovery preserves deferred gap and new append" `Quick test_sparse_consumption_retains_gap_and_append;
    test_case "partial worker wakes only newly unjudged input" `Quick test_worker_partial_consumption_wakes_only_new_input;
    test_case "pending is distinct from current Memory" `Quick test_pending_is_not_current;
    test_case "commit then retirement recovers without losing new tail" `Quick test_recovery_preserves_new_tail;
    test_case "input digest mismatch retains candidates" `Quick test_wrong_digest_keeps_candidates;
    test_case "retired destination refuses consumption" `Quick test_removed_destination_cannot_consume;
    test_case "stale retirement follows withdrawal and source reobservation" `Quick test_stale_retirement_after_source_reobservation;
    test_case "same-settle support loss preserves required destination input" `Quick test_destination_lost_during_support_maintenance_preserves_publication;
    test_case "worker restores committed input before judging" `Quick test_worker_recovers_before_judging;
    test_case "worker retries size refusal without discarding tail" `Quick test_worker_size_refusal_preserves_tail;
    test_case "worker retains uncertainty and requires durable commit" `Quick test_worker_does_not_consume_uncertainty;
    test_case "corruption cannot reset pending input" `Quick test_corruption_is_not_empty;
    test_case "bulk append retains every row in ascending order" `Quick test_bulk_append_preserves_length_and_order;
    test_case "byte cap refuses append before any write" `Quick test_byte_cap_refuses_append_before_write]]
