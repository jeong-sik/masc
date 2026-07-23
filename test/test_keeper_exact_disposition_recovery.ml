module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence
module Queue = Keeper_event_queue

let require_ok = function
  | Ok value -> value
  | Error detail -> Alcotest.fail detail
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let require_fsync = function
  | Persistence.Fsync_completed -> ()
  | Persistence.Visible_sync_unconfirmed detail ->
    Alcotest.failf "durability unknown: %s" detail
;;

let checkpoint_ref ~sha =
  let trace_id =
    Keeper_id.Trace_id.of_string "exact-disposition-recovery-trace"
    |> require_ok
  in
  match
    Keeper_checkpoint_ref.of_persisted
      ~trace_id
      ~generation:4
      ~turn_count:12
      ~sha256:sha
  with
  | Ok reference -> reference
  | Error _ -> Alcotest.fail "invalid checkpoint fixture"
;;

let source_ref = checkpoint_ref ~sha:(String.make 64 '0')

let stimulus post_id arrived_at =
  { Keeper_event_queue.post_id
  ; urgency = Keeper_event_queue.Immediate
  ; arrived_at
  ; payload = Keeper_event_queue.Manual_compaction_requested
  }
;;

let claimed_state ?(post_id = "manual-exact") () =
  let pending =
    Keeper_event_queue.enqueue
      Keeper_event_queue.empty
      (stimulus post_id 1.0)
  in
  let state = State.with_pending pending State.empty in
  let state, lease =
    State.claim_when ~claimed_at:2.0 ~ready:(fun _ -> true) state
    |> require_ok
  in
  match lease with
  | Some lease -> state, lease
  | None -> Alcotest.fail "fixture lease was not claimed"
;;

let bound_state ?post_id () =
  let state, lease = claimed_state ?post_id () in
  let state =
    State.bind_exact_execution
      ~lease
      ~slot_id:"slot-a"
      ~call_id:"call-a"
      ~plan_fingerprint:"plan-a"
      ~request_body_sha256:(String.make 64 'a')
      state
    |> require_ok
  in
  state, lease
;;

let exact_terminal
      ?(slot_id = "slot-a")
      ?(call_id = "call-a")
      ?(plan_fingerprint = "plan-a")
      ?(request_body_sha256 = String.make 64 'a')
      cause
  : State.exact_execution_terminal
  =
  { cause; slot_id; call_id; plan_fingerprint; request_body_sha256 }
;;

let prepare_terminal ?(prepared_at = 3.0) state lease =
  State.prepare_exact_source_disposition
    ~lease
    ~source:source_ref
    ~terminal:(exact_terminal State.Domain_invalid_output)
    ~semantic:State.Exact_no_compaction
    ~prepared_at
    state
  |> require_ok
;;

let test_terminal_persistence_recovery_retains_full_proof () =
  with_temp_dir "masc-exact-disposition-recovery" @@ fun base_path ->
  let keeper_name = "exact_disposition_recovery" in
  (match
     Persistence.update_checked_result
       ~base_path
       ~keeper_name
       (fun pending -> Ok (Queue.enqueue pending (stimulus "persisted-exact" 1.0)))
   with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "source persist failed: %s" detail);
  let lease =
    match
      Persistence.claim_when_result
        ~base_path
        ~keeper_name
        ~claimed_at:2.0
        ~ready:(fun _ -> true)
        ()
    with
    | Ok (Some lease) -> lease
    | Ok None -> Alcotest.fail "persisted source was not claimed"
    | Error detail -> Alcotest.failf "persisted claim failed: %s" detail
  in
  Persistence.bind_exact_execution_result
    ~base_path
    ~keeper_name
    ~lease
    ~slot_id:"slot-a"
    ~call_id:"call-a"
    ~plan_fingerprint:"plan-a"
    ~request_body_sha256:(String.make 64 'a')
    ()
  |> require_ok
  |> require_fsync;
  let terminal = exact_terminal State.Domain_invalid_output in
  let disposition, durability =
    Persistence.prepare_exact_source_disposition_result
      ~base_path
      ~keeper_name
      ~lease
      ~source:source_ref
      ~terminal
      ~semantic:Persistence.Exact_no_compaction
      ~prepared_at:3.0
      ()
    |> require_ok
  in
  require_fsync durability;
  let pending =
    Persistence.prepare_registration_after_exact_recovery_result
      ~base_path
      ~keeper_name
      ~settled_at:4.0
      ()
    |> require_ok
  in
  Alcotest.(check bool) "recovery consumed source" true (Queue.is_empty pending);
  let recovered =
    Persistence.load_state_result ~base_path ~keeper_name |> require_ok
  in
  Alcotest.(check int)
    "recovery consumed lease"
    0
    (List.length (State.leases recovered));
  let entry =
    match State.transition_outbox recovered with
    | [ entry ] -> entry
    | [] | _ :: _ :: _ -> Alcotest.fail "durable exact outbox is not singular"
  in
  Alcotest.(check string)
    "deterministic exact transition"
    (lease.lease_id ^ ":settle_exact:" ^ disposition.disposition_id)
    entry.receipt.transition_id;
  (match entry.receipt.settlement with
   | State.Settle_exact proof ->
     Alcotest.(check string)
       "request proof retained"
       disposition.request_body_sha256
       proof.request_body_sha256;
     Alcotest.(check string)
       "plan proof retained"
       disposition.plan_fingerprint
       proof.plan_fingerprint
   | _ -> Alcotest.fail "durable WAL receipt did not carry Settle_exact");
  let replay_pending =
    Persistence.prepare_registration_after_exact_recovery_result
      ~base_path
      ~keeper_name
      ~settled_at:5.0
      ()
    |> require_ok
  in
  Alcotest.(check bool)
    "restart replay remains consumed"
    true
    (Queue.is_empty replay_pending)
;;

let replace_assoc key value fields =
  (key, value) :: List.remove_assoc key fields
;;

let corrupt_disposition_proof = function
  | `Assoc state_fields ->
    let bindings =
      match List.assoc "exact_execution_bindings" state_fields with
      | `List [ `Assoc binding_fields ] ->
        let disposition =
          match List.assoc "disposition" binding_fields with
          | `Assoc fields ->
            `Assoc
              (replace_assoc
                 "request_body_sha256"
                 (`String (String.make 64 'f'))
                 fields)
          | _ -> Alcotest.fail "fixture disposition missing"
        in
        `List
          [ `Assoc
              (replace_assoc "disposition" disposition binding_fields)
          ]
      | _ -> Alcotest.fail "fixture binding missing"
    in
    `Assoc
      (replace_assoc "exact_execution_bindings" bindings state_fields)
  | _ -> Alcotest.fail "fixture state is not an object"
;;

let test_wrong_full_proof_is_rejected () =
  let state, lease = bound_state () in
  let prepared, _ = prepare_terminal state lease in
  match State.of_yojson (corrupt_disposition_proof (State.to_yojson prepared)) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "changed request proof retained the disposition id"
;;

let test_producer_proof_mismatches_are_rejected () =
  let state, lease = bound_state ~post_id:"bad-proof" () in
  let canonical = exact_terminal State.Domain_invalid_output in
  let rejects label terminal =
    match
      State.prepare_exact_source_disposition
        ~lease
        ~source:source_ref
        ~terminal
        ~semantic:State.Exact_no_compaction
        ~prepared_at:6.0
        state
    with
    | Error _ -> ()
    | Ok _ -> Alcotest.failf "%s producer proof mismatch was accepted" label
  in
  rejects "slot_id" { canonical with slot_id = "slot-b" };
  rejects "call_id" { canonical with call_id = "call-b" };
  rejects
    "plan_fingerprint"
    { canonical with plan_fingerprint = "plan-b" };
  rejects
    "request_body_sha256"
    { canonical with request_body_sha256 = String.make 64 'b' };
  match State.exact_execution_binding state with
  | Some { status = State.Dispatch_uncertain; _ } -> ()
  | Some _ -> Alcotest.fail "proof mismatch changed the durable binding"
  | None -> Alcotest.fail "proof mismatch removed the durable binding"
;;

let test_retry_adopts_stored_prepared_at () =
  let state, lease = bound_state ~post_id:"stable-retry" () in
  let prepared, original = prepare_terminal state lease in
  let _, retried = prepare_terminal ~prepared_at:99.0 prepared lease in
  Alcotest.(check string)
    "stable disposition id"
    original.disposition_id
    retried.disposition_id;
  Alcotest.(check (float 0.0))
    "stored observation retained"
    original.prepared_at
    retried.prepared_at
;;

let legacy_v4_json = function
  | `Assoc state_fields ->
    let bindings =
      match List.assoc "exact_execution_bindings" state_fields with
      | `List rows ->
        `List
          (List.map
             (function
               | `Assoc fields ->
                 `Assoc (List.remove_assoc "disposition" fields)
               | row -> row)
             rows)
      | value -> value
    in
    `Assoc
      (state_fields
       |> replace_assoc "schema" (`String "keeper.event_queue.state.v4")
       |> replace_assoc "exact_execution_bindings" bindings)
  | json -> json
;;

let test_v4_cause_only_remains_fail_closed () =
  let state, lease = bound_state () in
  let terminal = exact_terminal State.Domain_invalid_output in
  let quarantined =
    State.quarantine_exact_execution
      ~lease
      ~terminal
      state
    |> require_ok
  in
  let migrated =
    State.of_yojson (legacy_v4_json (State.to_yojson quarantined))
    |> require_ok
  in
  (match State.exact_execution_binding migrated with
   | Some { status = State.Terminal_quarantined State.Domain_invalid_output; _ } ->
     ()
   | _ -> Alcotest.fail "v4 cause-only binding was synthesized");
  (match State.recover_leases ~settled_at:5.0 migrated with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "generic registration recovered a cause-only exact lease")
;;

let () =
  Alcotest.run
    "keeper exact disposition recovery"
    [ ( "recovery"
      , [ Alcotest.test_case
            "terminal persistence recovery retains full proof"
            `Quick
            test_terminal_persistence_recovery_retains_full_proof
        ; Alcotest.test_case
            "wrong full proof is rejected"
            `Quick
            test_wrong_full_proof_is_rejected
        ; Alcotest.test_case
            "producer proof mismatches are rejected"
            `Quick
            test_producer_proof_mismatches_are_rejected
        ; Alcotest.test_case
            "retry adopts stored prepared_at"
            `Quick
            test_retry_adopts_stored_prepared_at
        ; Alcotest.test_case
            "v4 cause-only remains fail-closed"
            `Quick
            test_v4_cause_only_remains_fail_closed
        ] )
    ]
;;
