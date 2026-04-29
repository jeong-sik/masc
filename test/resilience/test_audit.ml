(* Cycle 28 / Tier A12 tests — Resilience.Audit category enum + envelope wrap. *)

module A = Resilience.Audit
module E = Shared_audit.Envelope

(* ─── Category string round-trip ──────────────────────────────── *)

let all_categories : A.category list =
  [
    OutcomeRecorded;
    ConfidenceEvaluated;
    DegradationTriggered;
    DegradationRecovered;
    SpeculativeBranchStarted;
    SpeculativeBranchCompleted;
    SpeculativeWinnerSelected;
    RecoveryAttempted;
    RecoverySucceeded;
    RecoveryFailed;
    BudgetChecked;
    BudgetExceeded;
  ]

let test_category_roundtrip_total () =
  (* of_string ∘ to_string = Some on every variant. *)
  List.iter
    (fun c ->
      let s = A.category_to_string c in
      match A.category_of_string s with
      | Some c' -> assert (c' = c)
      | None ->
          Printf.eprintf "category_of_string failed for %s\n" s;
          assert false)
    all_categories

let test_category_of_string_unknown () =
  assert (A.category_of_string "" = None);
  assert (A.category_of_string "Unknown" = None);
  (* CREW's category should not collide with resilience's surface. *)
  assert (A.category_of_string "DeliberationTransition" = None)

let test_category_strings_all_distinct () =
  let strings = List.map A.category_to_string all_categories in
  let unique = List.sort_uniq String.compare strings in
  assert (List.length unique = List.length all_categories)

let test_category_to_json () =
  match A.category_to_json A.RecoveryAttempted with
  | `String "RecoveryAttempted" -> ()
  | _ -> assert false

(* ─── make_entry / envelope schema ────────────────────────────── *)

let test_make_entry_minimal () =
  let e =
    A.make_entry
      ~category:A.OutcomeRecorded
      ~payload:(`Assoc [ "outcome", `String "FullSuccess" ])
      ~prev_hash:None
      ()
  in
  assert (e.E.category = "OutcomeRecorded");
  assert (e.E.prev_hash = None);
  (* Payload Assoc preserved — no wrapping when keeper_name/session_id absent. *)
  match e.E.payload with
  | `Assoc kvs ->
      (match List.assoc_opt "outcome" kvs with
       | Some (`String "FullSuccess") -> ()
       | _ -> assert false);
      assert (List.assoc_opt "_keeper_name" kvs = None);
      assert (List.assoc_opt "_session_id" kvs = None)
  | _ -> assert false

let test_make_entry_with_keeper_and_session () =
  let e =
    A.make_entry
      ~category:A.RecoveryAttempted
      ~keeper_name:"dreamer"
      ~session_id:"sess-001"
      ~payload:(`Assoc [ "strategy", `String "Retry" ])
      ~prev_hash:(Some "abc123")
      ()
  in
  assert (e.E.category = "RecoveryAttempted");
  assert (e.E.prev_hash = Some "abc123");
  match e.E.payload with
  | `Assoc kvs ->
      (match List.assoc_opt "_keeper_name" kvs with
       | Some (`String "dreamer") -> ()
       | _ -> assert false);
      (match List.assoc_opt "_session_id" kvs with
       | Some (`String "sess-001") -> ()
       | _ -> assert false);
      (match List.assoc_opt "strategy" kvs with
       | Some (`String "Retry") -> ()
       | _ -> assert false)
  | _ -> assert false

let test_make_entry_non_assoc_payload_wrapped () =
  (* A scalar payload must be wrapped under "payload" so the envelope
     receives a well-formed Assoc. *)
  let e =
    A.make_entry
      ~category:A.BudgetChecked
      ~payload:(`Int 42)
      ~prev_hash:None
      ()
  in
  match e.E.payload with
  | `Assoc kvs ->
      (match List.assoc_opt "payload" kvs with
       | Some (`Int 42) -> ()
       | _ -> assert false)
  | _ -> assert false

let test_make_entry_id_and_ts_set () =
  let e =
    A.make_entry
      ~category:A.ConfidenceEvaluated
      ~payload:(`Assoc [])
      ~prev_hash:None
      ()
  in
  assert (String.length e.E.id > 0);
  assert (e.E.ts > 0.0)

(* ─── JSON round-trip via envelope ────────────────────────────── *)

let test_entry_json_roundtrip () =
  let e =
    A.make_entry
      ~category:A.SpeculativeWinnerSelected
      ~keeper_name:"k1"
      ~payload:(`Assoc [ "winner", `String "branch-2" ])
      ~prev_hash:(Some "deadbeef")
      ()
  in
  let json = A.entry_to_json e in
  match A.entry_of_json json with
  | Ok e' ->
      assert (e'.E.id = e.E.id);
      assert (e'.E.ts = e.E.ts);
      assert (e'.E.category = e.E.category);
      assert (e'.E.prev_hash = e.E.prev_hash);
      (* category_of_entry must lift the wire string back. *)
      (match A.category_of_entry e' with
       | Some A.SpeculativeWinnerSelected -> ()
       | _ -> assert false)
  | Error msg ->
      Printf.eprintf "entry_of_json: %s\n" msg;
      assert false

let test_category_of_entry_unknown_domain () =
  (* An envelope from a different domain should not lift to a typed
     resilience category. *)
  let foreign =
    Shared_audit.Envelope.make
      ~category:"DeliberationTransition"
      ~payload:(`Assoc [])
      ~prev_hash:None
  in
  assert (A.category_of_entry foreign = None)

(* ─── Hash chain still works through make_entry ───────────────── *)

let test_chain_continuity () =
  let e1 =
    A.make_entry
      ~category:A.OutcomeRecorded
      ~payload:(`Assoc [ "step", `Int 1 ])
      ~prev_hash:None
      ()
  in
  let h1 = E.hash_for_chain e1 in
  let e2 =
    A.make_entry
      ~category:A.OutcomeRecorded
      ~payload:(`Assoc [ "step", `Int 2 ])
      ~prev_hash:(Some h1)
      ()
  in
  assert (e2.E.prev_hash = Some h1)

let () =
  test_category_roundtrip_total ();
  test_category_of_string_unknown ();
  test_category_strings_all_distinct ();
  test_category_to_json ();
  test_make_entry_minimal ();
  test_make_entry_with_keeper_and_session ();
  test_make_entry_non_assoc_payload_wrapped ();
  test_make_entry_id_and_ts_set ();
  test_entry_json_roundtrip ();
  test_category_of_entry_unknown_domain ();
  test_chain_continuity ();
  print_endline "test_audit: all assertions passed"
