open Alcotest

module Store = Masc.Keeper_memory_os_store
module Types = Masc.Keeper_memory_os_types
module Head = Fs_compat.Capability_head

let require_ok = function
  | Ok value -> value
  | Error error -> fail (Store.error_to_string error)
;;

let expect_error_tag label expected = function
  | Error error ->
    check
      bool
      label
      true
      (Store.For_testing.error_tag error = expected)
  | Ok _ -> failf "%s: expected an error" label
;;

let expect_single_warning_tag label expected = function
  | [ warning ] ->
    check
      bool
      label
      true
      (Store.For_testing.warning_tag warning = expected)
  | warnings ->
    failf
      "%s: expected exactly one warning, observed %d"
      label
      (List.length warnings)
;;

let rec remove_tree path =
  match Unix.lstat path with
  | stat ->
    (match stat.Unix.st_kind with
     | Unix.S_DIR ->
       Sys.readdir path
       |> Array.iter (fun leaf ->
         remove_tree (Filename.concat path leaf));
       Unix.rmdir path
     | _ -> Unix.unlink path)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_root ~fs prefix fn =
  let root = Filename.temp_file prefix ".tmp" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () -> fn root Eio.Path.(fs / root))
;;

let entropy_source ?(chunks = 256) seed =
  Eio.Flow.string_source
    (String.init
       (32 * chunks)
       (fun offset -> Char.chr ((offset + (seed * 67)) mod 251)))
;;

let collision_source () =
  Eio.Flow.string_source (String.make (32 * 8) '\x42')
;;

let within_store ?(seed = 0) ~root ~owner fn =
  let secure_random = entropy_source seed in
  require_ok
    (Store.with_store
       ~secure_random
       ~root
       ~owner_id:owner
       (fun store -> Ok (fn store)))
;;

let fact claim =
  { Types.claim
  ; category = Fact
  ; claim_kind = Some Durable_knowledge
  ; source = { trace_id = "trace-1"; turn = 1; tool_call_id = None }
  ; observed_by = []
  ; first_seen = 10.0
  ; valid_until = None
  ; last_verified_at = None
  ; schema_version = Types.schema_version
  ; claim_id = Some ("claim-" ^ claim)
  }
;;

let episode claim =
  { Types.trace_id = "trace-" ^ claim
  ; generation = 1
  ; episode_summary = "summary-" ^ claim
  ; claims = [ fact claim ]
  ; open_items = []
  ; constraints = []
  ; preserved_tool_refs = []
  ; source_turn_range = Some (1, 1)
  ; created_at = 10.0
  ; valid_until = None
  ; terminal_marker = None
  ; schema_version = Types.schema_version
  }
;;

let state claim =
  { Store.facts = [ fact claim ]; episodes = [ episode claim ] }
;;

let prepare_new store expected operation_id value =
  match
    require_ok
      (Store.prepare
         store
         ~expected
         ~operation_id
         ~state:value)
  with
  | Store.Prepared prepared -> prepared
  | Store.Current_commit_replay _ ->
    failf "operation %S unexpectedly replayed" operation_id
  | Store.Stale_expected _ ->
    failf "operation %S unexpectedly observed a stale snapshot" operation_id
;;

let publish_committed store prepared =
  match require_ok (Store.publish store prepared) with
  | Store.Committed receipt -> receipt
  | Store.Stale _ -> fail "fresh prepared commit was stale"
  | Store.Indeterminate _ -> fail "normal publication was indeterminate"
;;

let check_state_claim label expected snapshot =
  let value = Store.snapshot_state snapshot in
  check int (label ^ " fact count") 1 (List.length value.facts);
  check int (label ^ " episode count") 1 (List.length value.episodes);
  match value.facts with
  | [ observed ] -> check string label expected observed.claim
  | _ -> failf "%s: expected exactly one fact" label
;;

let sha256_string value =
  Store.Sha256.to_string value
;;

let load_raw path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      really_input_string channel (in_channel_length channel))
;;

let save_raw path raw =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel raw);
  Unix.chmod path 0o600
;;

let json_field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> failf "JSON field %S is missing" name)
  | _ -> failf "JSON object required for field %S" name
;;

let json_string label = function
  | `String value -> value
  | _ -> failf "JSON string required for %s" label
;;

let replace_json_field name replacement = function
  | `Assoc fields ->
    if not (List.exists (fun (field, _) -> String.equal field name) fields)
    then failf "JSON field %S is missing" name;
    `Assoc
      (List.map
         (fun (field, value) ->
           if String.equal field name
           then field, replacement
           else field, value)
         fields)
  | _ -> failf "JSON object required to replace field %S" name
;;

let head_path root = Filename.concat root "HEAD"

let load_head root =
  load_raw (head_path root) |> Yojson.Safe.from_string
;;

let save_head root head =
  save_raw (head_path root) (Yojson.Safe.to_string head ^ "\n")
;;

let commit_leaf_of_head head =
  json_field "commit" head
  |> json_field "leaf"
  |> json_string "HEAD commit leaf"
;;

let seed_commit ?(seed = 0) ~root claim =
  within_store ~seed ~root ~owner:"keeper-a" @@ fun store ->
  let empty = require_ok (Store.load store) in
  let prepared =
    prepare_new store empty ("operation-" ^ claim) (state claim)
  in
  publish_committed store prepared
;;

let load_result ?(seed = 101) ~root () =
  Store.with_store
    ~secure_random:(entropy_source seed)
    ~root
    ~owner_id:"keeper-a"
    (fun store -> Store.load store)
;;

let test_genesis_roundtrip_reopen ~fs () =
  with_root ~fs "masc_memory_os_genesis_" @@ fun _root root ->
  let receipt_id, state_sha256 =
    within_store ~root ~owner:"keeper-a" @@ fun store ->
    let empty = require_ok (Store.load store) in
    check int64 "fresh generation" 0L
      (Store.snapshot_generation empty);
    check int "fresh facts" 0
      (List.length (Store.snapshot_state empty).facts);
    let prepared =
      prepare_new store empty "operation-alpha" (state "alpha")
    in
    let receipt = publish_committed store prepared in
    check int64 "receipt generation" 1L
      (Store.commit_receipt_generation receipt);
    check string "receipt operation" "operation-alpha"
      (Store.commit_receipt_operation_id receipt);
    check int "receipt has no settlement warnings" 0
      (List.length
         (Store.commit_receipt_settlement_warnings receipt));
    let committed = Store.committed_snapshot receipt in
    check_state_claim "committed state" "alpha" committed;
    ( sha256_string (Store.commit_receipt_id receipt)
    , sha256_string (Store.commit_receipt_state_sha256 receipt) )
  in
  within_store ~seed:1 ~root ~owner:"keeper-a" @@ fun store ->
  let reopened = require_ok (Store.load store) in
  check int64 "reopened generation" 1L
    (Store.snapshot_generation reopened);
  check_state_claim "reopened state" "alpha" reopened;
  (match
     require_ok
       (Store.prepare
          store
          ~expected:reopened
          ~operation_id:"operation-alpha"
          ~state:(state "alpha"))
   with
   | Store.Current_commit_replay replay ->
     check string "reopen preserves exact receipt" receipt_id
       (sha256_string (Store.commit_receipt_id replay));
     check string "reopen preserves committed state digest" state_sha256
       (sha256_string (Store.commit_receipt_state_sha256 replay));
     check int64 "replayed generation" 1L
       (Store.commit_receipt_generation replay)
   | Store.Prepared _ ->
     fail "reopen allocated a duplicate current commit"
   | Store.Stale_expected _ ->
     fail "reopened current snapshot was reported stale")
;;

let test_current_replay_and_conflict ~fs () =
  with_root ~fs "masc_memory_os_replay_" @@ fun _root root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let empty = require_ok (Store.load store) in
  let receipt =
    prepare_new store empty "same-operation" (state "alpha")
    |> publish_committed store
  in
  let current = require_ok (Store.load store) in
  (match
     require_ok
       (Store.prepare
          store
          ~expected:current
          ~operation_id:"same-operation"
          ~state:(state "alpha"))
   with
   | Store.Current_commit_replay replay ->
     check string "current replay receipt"
       (sha256_string (Store.commit_receipt_id receipt))
       (sha256_string (Store.commit_receipt_id replay))
   | Store.Prepared _ -> fail "exact current operation did not replay"
   | Store.Stale_expected _ -> fail "exact current snapshot became stale");
  expect_error_tag
    "same operation with different state conflicts"
    Store.For_testing.Conflicting_operation_error
    (Store.prepare
       store
       ~expected:current
       ~operation_id:"same-operation"
       ~state:(state "different"))
;;

let test_stale_prepare_and_publish_one_winner ~fs () =
  with_root ~fs "masc_memory_os_stale_" @@ fun _root root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let empty = require_ok (Store.load store) in
  let winner =
    prepare_new store empty "winner-operation" (state "winner")
  in
  let loser =
    prepare_new store empty "loser-operation" (state "loser")
  in
  ignore (publish_committed store winner : Store.commit_receipt);
  (match require_ok (Store.publish store loser) with
   | Store.Stale current ->
     check int64 "stale publish observes winner generation" 1L
       (Store.snapshot_generation current);
     check_state_claim "stale publish authority" "winner" current
   | Store.Committed _ -> fail "stale prepared commit overwrote HEAD"
   | Store.Indeterminate _ ->
     fail "conflicting stale publication became indeterminate");
  (match
     require_ok
       (Store.prepare
          store
          ~expected:empty
          ~operation_id:"third-operation"
          ~state:(state "third"))
   with
   | Store.Stale_expected current ->
     check int64 "stale prepare observes winner generation" 1L
       (Store.snapshot_generation current);
     check_state_claim "stale prepare authority" "winner" current
   | Store.Prepared _ -> fail "stale expected snapshot prepared a commit"
   | Store.Current_commit_replay _ ->
     fail "unrelated stale operation replayed");
  let current = require_ok (Store.load store) in
  check_state_claim "one winner remains current" "winner" current
;;

let test_runtime_binding_rejections ~fs () =
  with_root ~fs "masc_memory_os_binding_a_" @@ fun _root_a root_a ->
  with_root ~fs "masc_memory_os_binding_b_" @@ fun _root_b root_b ->
  within_store ~root:root_a ~owner:"keeper-a" @@ fun store_a ->
  let snapshot_a = require_ok (Store.load store_a) in
  within_store ~seed:1 ~root:root_b ~owner:"keeper-a" @@ fun store_b ->
  expect_error_tag
    "active cross-store snapshot rejected"
    Store.For_testing.Runtime_store_binding_mismatch_error
    (Store.prepare
       store_b
       ~expected:snapshot_a
       ~operation_id:"cross-store"
       ~state:(state "cross-store"));
  let escaped_store =
    within_store ~seed:2 ~root:root_a ~owner:"keeper-a"
      (fun store -> store)
  in
  expect_error_tag
    "post-callback store rejected"
    Store.For_testing.Store_not_active_error
    (Store.load escaped_store);
  let escaped_snapshot =
    within_store ~seed:3 ~root:root_a ~owner:"keeper-a"
      (fun store -> require_ok (Store.load store))
  in
  within_store ~seed:4 ~root:root_a ~owner:"keeper-a" @@ fun reopened ->
  expect_error_tag
    "post-callback snapshot rejected"
    Store.For_testing.Runtime_store_binding_mismatch_error
    (Store.prepare
       reopened
       ~expected:escaped_snapshot
       ~operation_id:"escaped-snapshot"
       ~state:(state "escaped"));
  let escaped_prepared =
    within_store ~seed:5 ~root:root_a ~owner:"keeper-a"
      (fun store ->
         let current = require_ok (Store.load store) in
         prepare_new
           store
           current
           "escaped-prepared"
           (state "escaped-prepared"))
  in
  within_store ~seed:6 ~root:root_a ~owner:"keeper-a" @@ fun reopened ->
  expect_error_tag
    "post-callback prepared commit rejected"
    Store.For_testing.Runtime_store_binding_mismatch_error
    (Store.publish reopened escaped_prepared)
;;

let test_same_length_digest_precedes_decode ~fs () =
  with_root ~fs "masc_memory_os_digest_" @@ fun root_path root ->
  ignore (seed_commit ~root "alpha" : Store.commit_receipt);
  let head = load_head root_path in
  let commit_path =
    Filename.concat root_path (commit_leaf_of_head head)
  in
  let original = load_raw commit_path in
  if String.length original = 0
  then fail "committed object was empty";
  let corrupted = Bytes.of_string original in
  Bytes.set corrupted 0 '!';
  let corrupted = Bytes.unsafe_to_string corrupted in
  check int "same-length corruption"
    (String.length original)
    (String.length corrupted);
  save_raw commit_path corrupted;
  expect_error_tag
    "digest mismatch precedes invalid JSON decode"
    Store.For_testing.Immutable_digest_mismatch_error
    (load_result ~root ())
;;

let test_head_identity_and_ref_tamper_fail_closed ~fs () =
  let zero_digest = String.make 64 '0' in
  let cases =
    [ ( "owner"
      , (fun head ->
          replace_json_field
            "owner_id"
            (`String "keeper-b")
            head)
      , Store.For_testing.Persisted_store_binding_mismatch_error )
    ; ( "store"
      , (fun head ->
          replace_json_field
            "store_id"
            (`String zero_digest)
            head)
      , Store.For_testing.Persisted_store_binding_mismatch_error )
    ; ( "generation"
      , (fun head ->
          replace_json_field "generation" (`Intlit "2") head)
      , Store.For_testing.Persisted_store_binding_mismatch_error )
    ; ( "commit-ref"
      , (fun head ->
          let commit =
            json_field "commit" head
            |> replace_json_field
                 "sha256"
                 (`String zero_digest)
          in
          replace_json_field "commit" commit head)
      , Store.For_testing.Immutable_digest_mismatch_error )
    ]
  in
  List.iteri
    (fun index (label, tamper, expected_tag) ->
      with_root
        ~fs
        ("masc_memory_os_head_tamper_" ^ label ^ "_")
      @@ fun root_path root ->
      ignore
        (seed_commit ~seed:index ~root "alpha"
          : Store.commit_receipt);
      load_head root_path |> tamper |> save_head root_path;
      expect_error_tag
        (label ^ " tamper fails closed")
        expected_tag
        (load_result ~seed:(100 + index) ~root ()))
    cases
;;

let test_valid_opaque_orphan_is_ignored ~fs () =
  with_root ~fs "masc_memory_os_orphan_" @@ fun _root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let empty = require_ok (Store.load store) in
  let orphan =
    prepare_new store empty "orphan-operation" (state "orphan")
  in
  let winner =
    prepare_new store empty "winner-operation" (state "winner")
  in
  ignore (publish_committed store winner : Store.commit_receipt);
  let current = require_ok (Store.load store) in
  check_state_claim "valid orphan was not adopted" "winner" current;
  (match require_ok (Store.publish store orphan) with
   | Store.Stale authoritative ->
     check_state_claim
       "opaque orphan remains non-authoritative"
       "winner"
       authoritative
   | Store.Committed _ -> fail "opaque orphan overwrote current HEAD"
   | Store.Indeterminate _ ->
     fail "stale opaque orphan publication became indeterminate");
  within_store ~seed:1 ~root ~owner:"keeper-a" @@ fun reopened ->
  let current = require_ok (Store.load reopened) in
  check_state_claim "reopen ignores valid opaque orphan" "winner" current
;;

let test_secure_random_collision_never_overwrites ~fs () =
  with_root ~fs "masc_memory_os_collision_" @@ fun _root_path root ->
  let secure_random = collision_source () in
  require_ok
    (Store.with_store
       ~secure_random
       ~root
       ~owner_id:"keeper-a"
       (fun store ->
          let empty = require_ok (Store.load store) in
          let first =
            prepare_new
              store
              empty
              "first-operation"
              (state "first")
          in
          ignore
            (publish_committed store first : Store.commit_receipt);
          let current = require_ok (Store.load store) in
          expect_error_tag
            "exclusive random leaf collision fails"
            Store.For_testing.Immutable_create_failed_error
            (Store.prepare
               store
               ~expected:current
               ~operation_id:"second-operation"
               ~state:(state "second"));
          let preserved = require_ok (Store.load store) in
          check int64 "collision did not advance generation" 1L
            (Store.snapshot_generation preserved);
          check_state_claim
            "collision did not overwrite referenced bytes"
            "first"
            preserved;
          Ok ()));
  within_store ~seed:17 ~root ~owner:"keeper-a" @@ fun reopened ->
  let current = require_ok (Store.load reopened) in
  check_state_claim "reopen after collision" "first" current
;;

let test_published_late_failure_is_committed ~fs () =
  with_root ~fs "masc_memory_os_published_failure_" @@ fun _root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let empty = require_ok (Store.load store) in
  let prepared =
    prepare_new store empty "published-operation" (state "published")
  in
  let hook_calls = ref 0 in
  let hooks =
    Head.For_testing.hooks
      ~after_verified:(fun () ->
        incr hook_calls;
        raise Exit)
      ()
  in
  (match
     require_ok
       (Store.For_testing.publish_with_head_hooks hooks store prepared)
   with
   | Store.Committed receipt ->
     check int "late published hook called once" 1 !hook_calls;
     expect_single_warning_tag
       "late published failure is retained as an effect warning"
       Store.For_testing.Head_effect_warning_tag
       (Store.commit_receipt_settlement_warnings receipt);
     check_state_claim
       "late failure receipt carries published state"
       "published"
       (Store.committed_snapshot receipt)
   | Store.Stale _ -> fail "late published failure became stale"
   | Store.Indeterminate _ ->
     fail "verified publication was downgraded to indeterminate");
  let current = require_ok (Store.load store) in
  check_state_claim "late failure HEAD is visible" "published" current
;;

let test_indeterminate_settles_committed ~fs () =
  with_root ~fs "masc_memory_os_indeterminate_commit_" @@ fun _root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let empty = require_ok (Store.load store) in
  let prepared =
    prepare_new store empty "pending-operation" (state "pending")
  in
  let hook_calls = ref 0 in
  let hooks =
    Head.For_testing.hooks
      ~after_rename:(fun () ->
        incr hook_calls;
        raise Exit)
      ()
  in
  let pending =
    match
      require_ok
        (Store.For_testing.publish_with_head_hooks hooks store prepared)
    with
    | Store.Indeterminate pending -> pending
    | Store.Committed _ ->
      fail "post-rename failure was reported committed before settlement"
    | Store.Stale _ -> fail "post-rename failure became stale"
  in
  check int "indeterminate hook called once" 1 !hook_calls;
  expect_single_warning_tag
    "indeterminate publication retains a typed warning"
    Store.For_testing.Head_indeterminate_warning_tag
    (Store.pending_publication_settlement_warnings pending);
  (match require_ok (Store.settle store pending) with
   | Store.Settled_committed receipt ->
     check string
       "settlement preserves pending receipt"
       (sha256_string (Store.pending_publication_receipt_id pending))
       (sha256_string (Store.commit_receipt_id receipt));
     check_state_claim
       "settlement observes committed state"
       "pending"
       (Store.committed_snapshot receipt)
   | Store.Settled_not_published _ ->
     fail "visible renamed HEAD was reported not published"
   | Store.Still_indeterminate _ ->
     fail "visible renamed HEAD remained indeterminate")
;;

let test_indeterminate_after_successor_stays_pending ~fs () =
  with_root ~fs "masc_memory_os_indeterminate_successor_" @@ fun _root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let empty = require_ok (Store.load store) in
  let prepared_a =
    prepare_new store empty "pending-a" (state "pending-a")
  in
  let hook_calls = ref 0 in
  let hooks =
    Head.For_testing.hooks
      ~after_rename:(fun () ->
        incr hook_calls;
        raise Exit)
      ()
  in
  let pending_a =
    match
      require_ok
        (Store.For_testing.publish_with_head_hooks hooks store prepared_a)
    with
    | Store.Indeterminate pending -> pending
    | Store.Committed _ | Store.Stale _ ->
      fail "post-rename fixture did not produce a pending publication"
  in
  let current_a = require_ok (Store.load store) in
  let prepared_b =
    prepare_new store current_a "successor-b" (state "successor-b")
  in
  ignore (publish_committed store prepared_b : Store.commit_receipt);
  let first_pending =
    match require_ok (Store.settle store pending_a) with
    | Store.Still_indeterminate pending -> pending
    | Store.Settled_committed _ ->
      fail "later authority falsely proved the earlier pending commit"
    | Store.Settled_not_published _ ->
      fail "later authority falsely proved the earlier commit absent"
  in
  let second_pending =
    match require_ok (Store.settle store first_pending) with
    | Store.Still_indeterminate pending -> pending
    | Store.Settled_committed _ | Store.Settled_not_published _ ->
      fail "repeated settlement changed unresolved authority"
  in
  check int "indeterminate successor hook called once" 1 !hook_calls;
  check string
    "still-indeterminate settlement reuses the pending receipt"
    (sha256_string (Store.pending_publication_receipt_id pending_a))
    (sha256_string (Store.pending_publication_receipt_id second_pending));
  let current_b = require_ok (Store.load store) in
  check_state_claim "successor remains authoritative" "successor-b" current_b
;;

let test_settlement_read_error_reuses_pending ~fs () =
  with_root ~fs "masc_memory_os_settle_read_error_" @@ fun root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let empty = require_ok (Store.load store) in
  let prepared =
    prepare_new store empty "read-error-pending" (state "read-error")
  in
  let hook_calls = ref 0 in
  let hooks =
    Head.For_testing.hooks
      ~after_rename:(fun () ->
        incr hook_calls;
        raise Exit)
      ()
  in
  let pending =
    match
      require_ok
        (Store.For_testing.publish_with_head_hooks hooks store prepared)
    with
    | Store.Indeterminate pending -> pending
    | Store.Committed _ | Store.Stale _ ->
      fail "post-rename fixture did not produce a pending publication"
  in
  let original_head = load_raw (head_path root_path) in
  save_raw (head_path root_path) "corrupt-without-line-feed";
  let failed_settlement = Store.settle store pending in
  save_raw (head_path root_path) original_head;
  expect_error_tag
    "settlement read failure is typed"
    Store.For_testing.Head_operation_failed_error
    failed_settlement;
  check int "settlement read-error hook called once" 1 !hook_calls;
  (match require_ok (Store.settle store pending) with
   | Store.Settled_committed receipt ->
     check string
       "same pending value settles after read repair"
       (sha256_string (Store.pending_publication_receipt_id pending))
       (sha256_string (Store.commit_receipt_id receipt))
   | Store.Settled_not_published _ | Store.Still_indeterminate _ ->
     fail "repaired pending publication did not settle committed")
;;

let test_unchanged_failure_and_cancellation_do_not_publish ~fs () =
  with_root ~fs "masc_memory_os_unchanged_failure_" @@ fun _root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let empty = require_ok (Store.load store) in
  let failed_prepared =
    prepare_new store empty "unchanged-error" (state "unchanged-error")
  in
  let failure_calls = ref 0 in
  let failure_hooks =
    Head.For_testing.hooks
      ~before_rename:(fun () ->
        incr failure_calls;
        raise Exit)
      ()
  in
  expect_error_tag
    "pre-rename non-conflict failure is typed"
    Store.For_testing.Head_operation_failed_error
    (Store.For_testing.publish_with_head_hooks
       failure_hooks
       store
       failed_prepared);
  check int "unchanged failure hook called once" 1 !failure_calls;
  let after_failure = require_ok (Store.load store) in
  check int64 "unchanged failure leaves generation zero" 0L
    (Store.snapshot_generation after_failure);
  let cancelled_prepared =
    prepare_new
      store
      after_failure
      "unchanged-cancel"
      (state "unchanged-cancel")
  in
  let cancellation_calls = ref 0 in
  let cancellation_hooks =
    Head.For_testing.hooks
      ~before_rename:(fun () ->
        incr cancellation_calls;
        raise
          (Eio.Cancel.Cancelled
             (Failure "injected Store pre-publication cancellation")))
      ()
  in
  (match
     Store.For_testing.publish_with_head_hooks
       cancellation_hooks
       store
       cancelled_prepared
   with
   | exception Eio.Cancel.Cancelled _ -> ()
   | Error error ->
     failf
       "pre-publication cancellation was flattened: %s"
       (Store.error_to_string error)
   | Ok _ -> fail "pre-publication cancellation returned an outcome");
  check int "cancellation hook called once" 1 !cancellation_calls;
  let after_cancellation = require_ok (Store.load store) in
  check int64 "cancellation leaves generation zero" 0L
    (Store.snapshot_generation after_cancellation)
;;

let test_resource_settlement_warning_preserves_commit ~fs () =
  with_root ~fs "masc_memory_os_resource_warning_" @@ fun _root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let empty = require_ok (Store.load store) in
  let prepared =
    prepare_new store empty "resource-warning" (state "resource-warning")
  in
  let hook_calls = ref 0 in
  let hooks =
    Head.For_testing.hooks
      ~on_resource_settlement:(fun () ->
        incr hook_calls;
        raise Exit)
      ()
  in
  (match
     require_ok
       (Store.For_testing.publish_with_head_hooks hooks store prepared)
   with
   | Store.Committed receipt ->
     check int "resource-settlement hook called once" 1 !hook_calls;
     expect_single_warning_tag
       "resource settlement warning is retained"
       Store.For_testing.Head_settlement_warning_tag
       (Store.commit_receipt_settlement_warnings receipt)
   | Store.Stale _ | Store.Indeterminate _ ->
     fail "resource settlement warning changed publication effect");
  let current = require_ok (Store.load store) in
  check_state_claim
    "resource warning does not hide committed HEAD"
    "resource-warning"
    current
;;

let test_non_current_operation_is_not_replayed ~fs () =
  with_root ~fs "masc_memory_os_current_only_replay_" @@ fun _root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let empty = require_ok (Store.load store) in
  let prepared_a =
    prepare_new store empty "operation-a" (state "state-a")
  in
  ignore (publish_committed store prepared_a : Store.commit_receipt);
  let current_a = require_ok (Store.load store) in
  let prepared_b =
    prepare_new store current_a "operation-b" (state "state-b")
  in
  ignore (publish_committed store prepared_b : Store.commit_receipt);
  let current_b = require_ok (Store.load store) in
  let prepared_a_again =
    match
      require_ok
        (Store.prepare
           store
           ~expected:current_b
           ~operation_id:"operation-a"
           ~state:(state "state-a"))
    with
    | Store.Prepared prepared -> prepared
    | Store.Current_commit_replay _ ->
      fail "non-current operation A was replayed after A-B"
    | Store.Stale_expected _ ->
      fail "current B snapshot became stale while preparing A again"
  in
  let receipt_a_again = publish_committed store prepared_a_again in
  check int64 "A-B-A creates a new generation" 3L
    (Store.commit_receipt_generation receipt_a_again);
  check_state_claim
    "A-B-A publishes the new current A state"
    "state-a"
    (Store.committed_snapshot receipt_a_again)
;;

let () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  run
    "keeper memory os canonical store"
    [ ( "store"
      , [ test_case "genesis roundtrip reopen" `Quick
            (test_genesis_roundtrip_reopen ~fs)
        ; test_case "current replay and conflict" `Quick
            (test_current_replay_and_conflict ~fs)
        ; test_case "stale prepare and publish one winner" `Quick
            (test_stale_prepare_and_publish_one_winner ~fs)
        ; test_case "runtime binding rejections" `Quick
            (test_runtime_binding_rejections ~fs)
        ; test_case "same-length digest before decode" `Quick
            (test_same_length_digest_precedes_decode ~fs)
        ; test_case "HEAD identity and ref tamper" `Quick
            (test_head_identity_and_ref_tamper_fail_closed ~fs)
        ; test_case "valid opaque orphan ignored" `Quick
            (test_valid_opaque_orphan_is_ignored ~fs)
        ; test_case "secure random collision no overwrite" `Quick
            (test_secure_random_collision_never_overwrites ~fs)
        ; test_case "published late failure is committed" `Quick
            (test_published_late_failure_is_committed ~fs)
        ; test_case "indeterminate settles committed" `Quick
            (test_indeterminate_settles_committed ~fs)
        ; test_case "successor keeps earlier publication pending" `Quick
            (test_indeterminate_after_successor_stays_pending ~fs)
        ; test_case "settlement read error reuses pending" `Quick
            (test_settlement_read_error_reuses_pending ~fs)
        ; test_case "unchanged failure and cancellation" `Quick
            (test_unchanged_failure_and_cancellation_do_not_publish ~fs)
        ; test_case "resource warning preserves commit" `Quick
            (test_resource_settlement_warning_preserves_commit ~fs)
        ; test_case "non-current operation is not replayed" `Quick
            (test_non_current_operation_is_not_replayed ~fs)
        ] )
    ]
;;
