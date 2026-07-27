open Alcotest
open Test_keeper_dead_revival_payload_support

let test_create_mode_replay_evidence_and_conflict () =
  with_workspace "masc_dead_revival_payload_create_" @@ fun config ->
  let fixture =
    make_fixture ~candidate_instructions:"candidate-a" config
  in
  let created = create_first fixture in
  check_reference
    "created prepared"
    fixture.reference
    (Payload.prepared_ref created);
  let path = payload_path fixture fixture.reference in
  let stat = Unix.lstat path in
  check bool "created target is regular" true (stat.st_kind = Unix.S_REG);
  check int "created target mode" 0o600 (stat.st_perm land 0o777);
  let original_bytes = Payload.payload_to_bytes fixture.payload in
  check string "created bytes" original_bytes (read_file path);
  (match Payload.create config fixture.prepared with
   | Error
       (Payload.Create_unsettled
          { prepared; initial_failure }) ->
     check
       bool
       "identical replay evidence target unchanged"
       true
       (initial_failure.target_effect = Fs_compat.Target_unchanged);
     check
       bool
       "identical replay evidence operation"
       true
       (initial_failure.operation
        = Fs_compat.Create_exclusive_operation);
     check_reference
       "identical replay prepared evidence"
       fixture.reference
       (Payload.prepared_ref prepared)
   | Error error ->
     failf
       "identical replay returned wrong error: %s"
       (Payload.error_to_string error)
   | Ok _ ->
     fail "identical replay was promoted without file-data durability");
  check
    string
    "identical replay preserves bytes"
    original_bytes
    (read_file path);
  let conflicting =
    make_fixture ~candidate_instructions:"candidate-b" config
  in
  check
    string
    "conflict shares transaction leaf"
    (Payload.immutable_ref_transaction_leaf fixture.reference)
    (Payload.immutable_ref_transaction_leaf conflicting.reference);
  check
    bool
    "conflict changes payload digest"
    false
    (String.equal
       (Payload.immutable_ref_sha256 fixture.reference)
       (Payload.immutable_ref_sha256 conflicting.reference));
  (match Payload.create config conflicting.prepared with
   | Error
       (Payload.Create_unsettled
          { prepared; initial_failure }) ->
     check
       bool
       "same-leaf conflict target unchanged"
       true
       (initial_failure.target_effect = Fs_compat.Target_unchanged);
     check_reference
       "same-leaf conflict prepared evidence"
       conflicting.reference
       (Payload.prepared_ref prepared)
   | Error error ->
     failf
       "same-leaf conflict returned wrong error: %s"
       (Payload.error_to_string error)
   | Ok _ -> fail "same-leaf conflict replaced immutable bytes");
  check
    string
    "same-leaf conflict preserves original bytes"
    original_bytes
    (read_file path)
;;

let test_target_created_reconciles_with_retained_evidence () =
  with_workspace "masc_dead_revival_payload_reconcile_created_" @@ fun config ->
  let fixture = make_fixture config in
  ignore (create_first fixture);
  let path = payload_path fixture fixture.reference in
  let original_bytes = read_file path in
  let reconciliation_read_observed = ref false in
  let parent_sync_observed = ref false in
  let hooks =
    Payload.For_testing.hooks
      ~create_target_effect:Fs_compat.Target_created
      ~reconciliation_read:(fun () ->
        reconciliation_read_observed := true;
        `Use_production)
      ~parent_sync:(fun () ->
        parent_sync_observed := true;
        `Use_production)
      ()
  in
  let outcome =
    Payload.For_testing.with_hooks hooks (fun () ->
      Payload.create config fixture.prepared)
  in
  (match outcome with
   | Ok
       (Payload.Reconciled_created
          { prepared; initial_failure }) ->
     check
       bool
       "reconciled-created retains target effect"
       true
       (initial_failure.target_effect = Fs_compat.Target_created);
     check
       bool
       "reconciled-created retains operation"
       true
       (initial_failure.operation
        = Fs_compat.Create_exclusive_operation);
     check_reference
       "reconciled-created prepared evidence"
       fixture.reference
       (Payload.prepared_ref prepared)
   | Ok (Payload.Created _) ->
     fail "injected Target_created unexpectedly returned Created"
   | Error error ->
     failf
       "Target_created reconciliation failed: %s"
       (Payload.error_to_string error));
  check
    bool
    "Target_created performs exact reread"
    true
    !reconciliation_read_observed;
  check
    bool
    "Target_created performs parent sync"
    true
    !parent_sync_observed;
  check
    string
    "Target_created reconciliation preserves bytes"
    original_bytes
    (read_file path);
  (match Payload.create config fixture.prepared with
   | Error
       (Payload.Create_unsettled
          { prepared; initial_failure }) ->
     check
       bool
       "fiber-local hook does not escape scope"
       true
       (initial_failure.target_effect = Fs_compat.Target_unchanged);
     check_reference
       "post-scope unsettled prepared evidence"
       fixture.reference
       (Payload.prepared_ref prepared)
   | Error error ->
     failf
       "post-scope create returned wrong error: %s"
       (Payload.error_to_string error)
   | Ok _ -> fail "Target_created hook escaped its fiber-local scope")
;;

let test_unsettled_target_effects_retain_evidence () =
  with_workspace "masc_dead_revival_payload_unsettled_effects_" @@ fun config ->
  let fixture = make_fixture config in
  let cases =
    [ "created incomplete", Fs_compat.Target_created_incomplete
    ; "state unknown", Fs_compat.Target_state_unknown
    ; "replaced", Fs_compat.Target_replaced
    ]
  in
  List.iter
    (fun (label, target_effect) ->
       let hooks =
         Payload.For_testing.hooks
           ~create_target_effect:target_effect
           ()
       in
       let outcome =
         Payload.For_testing.with_hooks hooks (fun () ->
           Payload.create config fixture.prepared)
       in
       match outcome with
       | Error
           (Payload.Create_unsettled
              { prepared; initial_failure }) ->
         check
           bool
           (label ^ " target effect")
           true
           (initial_failure.target_effect = target_effect);
         check
           bool
           (label ^ " operation")
           true
           (initial_failure.operation
            = Fs_compat.Create_exclusive_operation);
         check_reference
           (label ^ " prepared evidence")
           fixture.reference
           (Payload.prepared_ref prepared)
       | Error error ->
         failf
           "%s returned wrong error: %s"
           label
           (Payload.error_to_string error)
       | Ok _ -> failf "%s was promoted to success" label)
    cases;
  check
    bool
    "unsettled injected effects do not publish target"
    false
    (Sys.file_exists (payload_path fixture fixture.reference))
;;

let test_create_reconciliation_read_failure () =
  with_workspace "masc_dead_revival_payload_reconcile_read_failure_" @@ fun config ->
  let fixture = make_fixture config in
  let read_hook_observed = ref false in
  let hooks =
    Payload.For_testing.hooks
      ~create_target_effect:Fs_compat.Target_created
      ~reconciliation_read:(fun () ->
        read_hook_observed := true;
        `Fail "injected reconciliation read failure")
      ()
  in
  let outcome =
    Payload.For_testing.with_hooks hooks (fun () ->
      Payload.create config fixture.prepared)
  in
  (match outcome with
   | Error
       (Payload.Create_reconciliation_failed
          { prepared
          ; initial_failure
          ; reconciliation_failure =
              Payload.Reconciliation_read_injected _
          }) ->
     check
       bool
       "read failure retains Target_created"
       true
       (initial_failure.target_effect = Fs_compat.Target_created);
     check_reference
       "read failure prepared evidence"
       fixture.reference
       (Payload.prepared_ref prepared)
   | Error error ->
     failf
       "reconciliation read returned wrong error: %s"
       (Payload.error_to_string error)
   | Ok _ -> fail "reconciliation read failure was promoted to success");
  check
    bool
    "reconciliation read hook executed"
    true
    !read_hook_observed
;;

let test_create_reconciliation_parent_sync_failure () =
  with_workspace "masc_dead_revival_payload_reconcile_sync_failure_" @@ fun config ->
  let fixture = make_fixture config in
  ignore (create_first fixture);
  let parent_sync_hook_observed = ref false in
  let hooks =
    Payload.For_testing.hooks
      ~create_target_effect:Fs_compat.Target_created
      ~parent_sync:(fun () ->
        parent_sync_hook_observed := true;
        `Fail "injected reconciliation parent sync failure")
      ()
  in
  let outcome =
    Payload.For_testing.with_hooks hooks (fun () ->
      Payload.create config fixture.prepared)
  in
  (match outcome with
   | Error
       (Payload.Create_reconciliation_failed
          { prepared
          ; initial_failure
          ; reconciliation_failure =
              Payload.Reconciliation_parent_sync_injected _
          }) ->
     check
       bool
       "parent sync failure retains Target_created"
       true
       (initial_failure.target_effect = Fs_compat.Target_created);
     check_reference
       "parent sync failure prepared evidence"
       fixture.reference
       (Payload.prepared_ref prepared)
   | Error error ->
     failf
       "parent sync returned wrong error: %s"
       (Payload.error_to_string error)
   | Ok _ -> fail "parent sync failure was promoted to success");
  check
    bool
    "parent sync hook executed"
    true
    !parent_sync_hook_observed
;;

let test_target_created_classifies_same_leaf_conflict () =
  with_workspace "masc_dead_revival_payload_reconcile_conflict_" @@ fun config ->
  let original =
    make_fixture ~candidate_instructions:"candidate-a" config
  in
  let conflicting =
    make_fixture ~candidate_instructions:"candidate-b" config
  in
  ignore (create_first original);
  let path = payload_path original original.reference in
  let original_bytes = read_file path in
  let reconciliation_read_observed = ref false in
  let parent_sync_observed = ref false in
  let hooks =
    Payload.For_testing.hooks
      ~create_target_effect:Fs_compat.Target_created
      ~reconciliation_read:(fun () ->
        reconciliation_read_observed := true;
        `Use_production)
      ~parent_sync:(fun () ->
        parent_sync_observed := true;
        `Use_production)
      ()
  in
  let outcome =
    Payload.For_testing.with_hooks hooks (fun () ->
      Payload.create config conflicting.prepared)
  in
  (match outcome with
   | Error
       (Payload.Create_conflict
          { prepared; initial_failure }) ->
     check
       bool
       "conflict retains Target_created"
       true
       (initial_failure.target_effect = Fs_compat.Target_created);
     check_reference
       "conflict prepared evidence"
       conflicting.reference
       (Payload.prepared_ref prepared)
   | Error error ->
     failf
       "same-leaf conflict returned wrong error: %s"
       (Payload.error_to_string error)
   | Ok _ -> fail "same-leaf different bytes were reconciled");
  check
    bool
    "same-leaf conflict performs exact reread"
    true
    !reconciliation_read_observed;
  check
    bool
    "same-leaf conflict skips parent sync"
    false
    !parent_sync_observed;
  check
    string
    "same-leaf conflict preserves original bytes"
    original_bytes
    (read_file path)
;;
