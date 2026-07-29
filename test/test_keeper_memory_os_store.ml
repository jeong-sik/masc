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

let with_absent_root ~fs prefix fn =
  let root = Filename.temp_file prefix ".tmp" in
  Sys.remove root;
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

let obligation_bytes store prepared =
  Store.publication_obligation_of_prepared store prepared
  |> require_ok
  |> Store.publication_obligation_to_bytes
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

let root_snapshot root =
  Sys.readdir root
  |> Array.to_list
  |> List.sort String.compare
  |> List.map (fun leaf ->
    let path = Filename.concat root leaf in
    leaf, load_raw path)
;;

let check_root_snapshot label expected actual =
  check
    (list (pair string string))
    label
    expected
    actual
;;

let immutable_object_sizes root =
  Sys.readdir root
  |> Array.to_list
  |> List.filter (String.starts_with ~prefix:"memory-os-")
  |> List.map (fun leaf ->
    (Unix.stat (Filename.concat root leaf)).Unix.st_size)
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
let store_identity_path root = Filename.concat root "store-identity.json"

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

let test_existing_read_absent_is_effect_free ~fs () =
  with_absent_root ~fs "masc_memory_os_existing_absent_"
  @@ fun root_path root ->
  (match
     require_ok
       (Store.read_existing_current_head
          ~root
          ~owner_id:"keeper-a")
   with
   | Store.Absent -> ()
   | Store.Existing _ ->
     fail "absent private root was reported as an existing store");
  check bool
    "absent private root remains absent"
    false
    (Sys.file_exists root_path);
  with_root ~fs "masc_memory_os_existing_empty_without_identity_"
  @@ fun empty_path empty_root ->
  let before = root_snapshot empty_path in
  (match
     require_ok
       (Store.read_existing_current_head
          ~root:empty_root
          ~owner_id:"keeper-a")
   with
   | Store.Absent -> ()
   | Store.Existing _ ->
     fail "identity-free empty root was reported as an existing store");
  check_root_snapshot
    "identity-free empty root remains byte-for-byte unchanged"
    before
    (root_snapshot empty_path)
;;

let test_missing_identity_preserves_settlement_warning ~fs () =
  with_root ~fs "masc_memory_os_identity_missing_warning_"
  @@ fun _root_path root ->
  match
    Store.For_testing.read_store_identity_with_parent_settlement_failure
      ~root
      ~owner_id:"keeper-a"
  with
  | Ok _ ->
    fail "identity absence silently discarded a settlement warning"
  | Error error ->
    check
      bool
      "missing identity with a settlement warning fails typed"
      true
      (Store.For_testing.error_tag error
       = Store.For_testing.Store_identity_read_failed_error);
    expect_single_warning_tag
      "missing identity preserves the settlement warning"
      Store.For_testing.Store_identity_settlement_warning_tag
      (Store.error_settlement_warnings error)
;;

let test_existing_read_empty_store_is_read_only ~fs () =
  with_root ~fs "masc_memory_os_existing_valid_empty_"
  @@ fun root_path root ->
  within_store ~root ~owner:"keeper-a" (fun _ -> ());
  let before = root_snapshot root_path in
  (match
     require_ok
       (Store.read_existing_current_head
          ~root
          ~owner_id:"keeper-a")
   with
   | Store.Existing { current_head = Store.Empty; _ } -> ()
   | Store.Existing { current_head = Store.Present _; _ } ->
     fail "identity-only store unexpectedly had a current HEAD"
   | Store.Absent ->
     fail "valid identity-only store was reported absent");
  check_root_snapshot
    "valid empty store read creates no stable lock or HEAD"
    before
    (root_snapshot root_path)
;;

let test_existing_read_populated_projection_is_exact ~fs () =
  with_root ~fs "masc_memory_os_existing_populated_"
  @@ fun root_path root ->
  let receipt = seed_commit ~root "projection" in
  let before = root_snapshot root_path in
  (match
     require_ok
       (Store.read_existing_current_head
          ~root
          ~owner_id:"keeper-a")
   with
   | Store.Existing
       { current_head =
           Store.Present
             { receipt_id
             ; operation_id
             ; state_digest
             ; generation
             }
       ; _
       } ->
     check string
       "projection receipt id"
       (sha256_string (Store.commit_receipt_id receipt))
       (sha256_string receipt_id);
     check string
       "projection operation id"
       "operation-projection"
       operation_id;
     check string
       "projection state digest"
       (sha256_string (Store.commit_receipt_state_sha256 receipt))
       (sha256_string state_digest);
     check int64
       "projection generation"
       (Store.commit_receipt_generation receipt)
       generation
   | Store.Existing { current_head = Store.Empty; _ } ->
     fail "populated store was projected as empty"
   | Store.Absent ->
     fail "populated store was reported absent");
  check_root_snapshot
    "populated projection read is byte-for-byte read-only"
    before
    (root_snapshot root_path)
;;

let test_existing_read_rejects_current_schema_failures ~fs () =
  with_root ~fs "masc_memory_os_existing_identity_tamper_"
  @@ fun root_path root ->
  within_store ~root ~owner:"keeper-a" (fun _ -> ());
  let identity_path = store_identity_path root_path in
  load_raw identity_path
  |> Yojson.Safe.from_string
  |> replace_json_field "store_id" (`String (String.make 64 'a'))
  |> Yojson.Safe.to_string
  |> save_raw identity_path;
  let before = root_snapshot root_path in
  expect_error_tag
    "tampered current identity fails closed"
    Store.For_testing.Invalid_store_identity_error
    (Store.read_existing_current_head
       ~root
       ~owner_id:"keeper-a");
  check_root_snapshot
    "identity failure is read-only"
    before
    (root_snapshot root_path);
  with_root ~fs "masc_memory_os_existing_foreign_owner_"
  @@ fun foreign_path foreign_root ->
  within_store ~root:foreign_root ~owner:"keeper-a" (fun _ -> ());
  let before = root_snapshot foreign_path in
  expect_error_tag
    "foreign owner identity fails closed"
    Store.For_testing.Invalid_store_identity_error
    (Store.read_existing_current_head
       ~root:foreign_root
       ~owner_id:"keeper-b");
  check_root_snapshot
    "foreign owner failure is read-only"
    before
    (root_snapshot foreign_path);
  with_root ~fs "masc_memory_os_existing_nonfresh_"
  @@ fun nonfresh_path nonfresh_root ->
  save_raw (Filename.concat nonfresh_path "legacy.json") "{}";
  let before = root_snapshot nonfresh_path in
  expect_error_tag
    "nonfresh data without current identity is never adopted"
    Store.For_testing.Store_identity_missing_from_non_fresh_root_error
    (Store.read_existing_current_head
       ~root:nonfresh_root
       ~owner_id:"keeper-a");
  check_root_snapshot
    "nonfresh rejection is read-only"
    before
    (root_snapshot nonfresh_path);
  with_root ~fs "masc_memory_os_existing_graph_tamper_"
  @@ fun graph_path graph_root ->
  ignore (seed_commit ~root:graph_root "graph-tamper"
    : Store.commit_receipt);
  let commit_path =
    load_head graph_path
    |> commit_leaf_of_head
    |> Filename.concat graph_path
  in
  let raw = load_raw commit_path in
  let tampered = Bytes.of_string raw in
  Bytes.set tampered 0 '[';
  save_raw commit_path (Bytes.unsafe_to_string tampered);
  let before = root_snapshot graph_path in
  expect_error_tag
    "reachable immutable graph tamper fails closed"
    Store.For_testing.Immutable_digest_mismatch_error
    (Store.read_existing_current_head
       ~root:graph_root
       ~owner_id:"keeper-a");
  check_root_snapshot
    "graph tamper failure is read-only"
    before
    (root_snapshot graph_path)
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

let test_concurrent_publish_has_single_cas_winner ~fs ~clock () =
  with_root ~fs "masc_memory_os_concurrent_cas_" @@ fun _root root ->
  let winner_receipt_id, winner_state_sha256 =
    require_ok
      (Store.with_store
         ~secure_random:(entropy_source 31)
         ~root
         ~owner_id:"keeper-a"
         (fun store_a ->
            Store.with_store
              ~secure_random:(entropy_source 67)
              ~root
              ~owner_id:"keeper-a"
              (fun store_b ->
                 let empty_a = require_ok (Store.load store_a) in
                 let empty_b = require_ok (Store.load store_b) in
                 let prepared_a =
                   prepare_new
                     store_a
                     empty_a
                     "concurrent-a"
                     (state "winner-a")
                 in
                 let prepared_b =
                   prepare_new
                     store_b
                     empty_b
                     "concurrent-b"
                     (state "loser-b")
                 in
                 let lock_held, resolve_lock_held =
                   Eio.Promise.create ()
                 in
                 let release_a, resolve_release_a =
                   Eio.Promise.create ()
                 in
                 let hooks =
                   Head.For_testing.hooks
                     ~after_lock_acquired:(fun () ->
                       Eio.Promise.resolve resolve_lock_held ();
                       match
                         Eio.Time.with_timeout clock 2.0 (fun () ->
                           Eio.Promise.await release_a)
                       with
                       | Ok () -> ()
                       | Error `Timeout ->
                         failwith
                           "timed out waiting for the contended CAS")
                     ()
                 in
                 let winner_result = ref None in
                 let contended_result = ref None in
                 (match
                    Eio.Time.with_timeout clock 3.0 (fun () ->
                      Eio.Fiber.both
                        (fun () ->
                           winner_result :=
                             Some
                               (Store.For_testing.publish_with_head_hooks
                                  hooks
                                  store_a
                                  prepared_a))
                        (fun () ->
                           Eio.Promise.await lock_held;
                           let result =
                             Fun.protect
                               ~finally:(fun () ->
                                 Eio.Promise.resolve
                                   resolve_release_a
                                   (Ok ()))
                               (fun () ->
                                  Store.publish store_b prepared_b)
                           in
                           contended_result := Some result);
                      Ok ())
                  with
                  | Ok () -> ()
                  | Error `Timeout ->
                    fail "concurrent CAS did not settle within 3s");
                 let require_fiber_result label = function
                   | Some result -> result
                   | None -> failf "%s fiber did not publish a result" label
                 in
                 let winner_result =
                   require_fiber_result "lock holder" !winner_result
                 in
                 let contended_result =
                   require_fiber_result "contender" !contended_result
                 in
                 let committed_count =
                   List.fold_left
                     (fun count -> function
                        | Ok (Store.Committed _) -> count + 1
                        | Ok (Store.Stale _ | Store.Indeterminate _)
                        | Error _ -> count)
                     0
                     [ winner_result; contended_result ]
                 in
                 check int "exactly one overlapping CAS committed" 1
                   committed_count;
                 let winner_receipt =
                   match winner_result with
                   | Ok (Store.Committed receipt) -> receipt
                   | Ok (Store.Stale _) ->
                     fail "lock holder became stale"
                   | Ok (Store.Indeterminate _) ->
                     fail "lock holder became indeterminate"
                   | Error error ->
                     failf
                       "lock holder failed: %s"
                       (Store.error_to_string error)
                 in
                 (match contended_result with
                  | Error error ->
                    check
                      bool
                      "contender observed typed Busy with unchanged HEAD"
                      true
                      (Store.For_testing.error_tag error
                       = Store.For_testing.Head_busy_unchanged_error)
                  | Ok (Store.Committed _) ->
                    fail "contender committed while the lock was held"
                  | Ok (Store.Stale _) ->
                    fail "contender observed stale instead of lock contention"
                  | Ok (Store.Indeterminate _) ->
                    fail "contender became indeterminate before dispatch");
                 (match require_ok (Store.publish store_b prepared_b) with
                  | Store.Stale current ->
                    check int64 "loser retry observes winner generation" 1L
                      (Store.snapshot_generation current);
                    check_state_claim
                      "loser retry observes winner authority"
                      "winner-a"
                      current
                  | Store.Committed _ ->
                    fail "loser retry overwrote the winner"
                  | Store.Indeterminate _ ->
                    fail "loser retry became indeterminate");
                 Ok
                   ( sha256_string
                       (Store.commit_receipt_id winner_receipt)
                   , sha256_string
                       (Store.commit_receipt_state_sha256
                          winner_receipt) ))))
  in
  within_store ~seed:89 ~root ~owner:"keeper-a" @@ fun reopened ->
  let current = require_ok (Store.load reopened) in
  check int64 "reopen preserves winner generation" 1L
    (Store.snapshot_generation current);
  check_state_claim
    "reopen ignores the loser immutable orphan"
    "winner-a"
    current;
  match
    require_ok
      (Store.prepare
         reopened
         ~expected:current
         ~operation_id:"concurrent-a"
         ~state:(state "winner-a"))
  with
  | Store.Current_commit_replay receipt ->
    check string "reopen preserves winner receipt"
      winner_receipt_id
      (sha256_string (Store.commit_receipt_id receipt));
    check string "reopen preserves winner state digest"
      winner_state_sha256
      (sha256_string (Store.commit_receipt_state_sha256 receipt));
    check int64 "replayed winner generation" 1L
      (Store.commit_receipt_generation receipt)
  | Store.Prepared _ ->
    fail "reopen did not recognize the current winner"
  | Store.Stale_expected _ ->
    fail "reopen snapshot became stale without another publication"
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

let expect_safety_violation
      label
      ~expected_artifact
      ~expected_ceiling
  = function
  | Error error ->
    (match Store.error_implementation_safety_violation error with
     | Some (violation : Store.implementation_safety_violation) ->
       check bool label true (violation.artifact = expected_artifact);
       check int64
         (label ^ " reports the exact implementation ceiling")
         expected_ceiling
         violation.ceiling_bytes;
       check bool
         (label ^ " reports bytes beyond that ceiling")
         true
         (Int64.compare
            violation.observed_at_least_bytes
            expected_ceiling
          > 0)
     | None ->
       failf
         "%s: expected implementation safety violation, got %s"
         label
         (Store.error_to_string error))
  | Ok _ -> failf "%s: expected an implementation safety violation" label
;;

let expect_any_safety_violation label = function
  | Error error ->
    (match Store.error_implementation_safety_violation error with
     | Some _ -> ()
     | None ->
       failf
         "%s: expected implementation safety violation, got %s"
         label
         (Store.error_to_string error))
  | Ok _ -> failf "%s: expected an implementation safety violation" label
;;

let prepare_rejected_without_effect
      ~root_path
      ~store
      ~expected
      ~maximum
      ~operation_id
      ~state
      ~artifact
  =
  let before = root_snapshot root_path in
  let result =
    Store.For_testing.prepare_with_implementation_ceiling
      ~maximum
      store
      ~expected
      ~operation_id
      ~state
  in
  expect_safety_violation
    "oversize artifact is typed"
    ~expected_artifact:artifact
    ~expected_ceiling:
      (if artifact = `Head_row
       then Int64.of_int Head.max_row_bytes
       else maximum)
    result;
  check
    bool
    "oversize rejection has no persistent effect"
    true
    (before = root_snapshot root_path)
;;

let test_facts_oversize_is_effect_free ~fs () =
  with_root ~fs "masc_memory_os_facts_oversize_"
  @@ fun root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let expected = require_ok (Store.load store) in
  let oversized = String.make 2048 'f' in
  prepare_rejected_without_effect
    ~root_path
    ~store
    ~expected
    ~maximum:1024L
    ~operation_id:"facts-oversize"
    ~state:{ Store.facts = [ fact oversized ]; episodes = [] }
    ~artifact:`Facts
;;

let test_last_episode_oversize_is_effect_free ~fs () =
  with_root ~fs "masc_memory_os_last_episode_oversize_"
  @@ fun root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let expected = require_ok (Store.load store) in
  let oversized = String.make 2048 'e' in
  prepare_rejected_without_effect
    ~root_path
    ~store
    ~expected
    ~maximum:1024L
    ~operation_id:"last-episode-oversize"
    ~state:
      { Store.facts = [ fact "small" ]
      ; episodes = [ episode "small"; episode oversized ]
      }
    ~artifact:`Episode
;;

let test_manifest_oversize_is_effect_free ~fs () =
  with_root ~fs "masc_memory_os_manifest_oversize_"
  @@ fun root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let expected = require_ok (Store.load store) in
  let episodes =
    List.init 12 (fun index -> episode (string_of_int index))
  in
  prepare_rejected_without_effect
    ~root_path
    ~store
    ~expected
    ~maximum:1024L
    ~operation_id:"manifest-oversize"
    ~state:{ Store.facts = [ fact "small" ]; episodes }
    ~artifact:`Manifest
;;

let test_commit_oversize_is_effect_free ~fs () =
  with_root ~fs "masc_memory_os_commit_oversize_"
  @@ fun root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let expected = require_ok (Store.load store) in
  prepare_rejected_without_effect
    ~root_path
    ~store
    ~expected
    ~maximum:1024L
    ~operation_id:(String.make 2048 'c')
    ~state:{ Store.facts = [ fact "small" ]; episodes = [] }
    ~artifact:`Commit
;;

let test_head_oversize_is_effect_free ~fs () =
  with_root ~fs "masc_memory_os_head_oversize_"
  @@ fun root_path root ->
  within_store ~root ~owner:(String.make 70_000 'o') @@ fun store ->
  let expected = require_ok (Store.load store) in
  prepare_rejected_without_effect
    ~root_path
    ~store
    ~expected
    ~maximum:(Int64.of_int (64 * 1024 * 1024))
    ~operation_id:"head-oversize"
    ~state:{ Store.facts = []; episodes = [] }
    ~artifact:`Head_row
;;

let test_exact_implementation_boundary ~fs () =
  let maximum =
    with_root ~fs "masc_memory_os_boundary_measure_"
    @@ fun root_path root ->
    within_store ~root ~owner:"keeper-a" @@ fun store ->
    let expected = require_ok (Store.load store) in
    ignore
      (prepare_new store expected "boundary-operation" (state "boundary")
        : Store.prepared_commit);
    match immutable_object_sizes root_path with
    | [] -> fail "boundary fixture created no immutable objects"
    | first :: rest -> List.fold_left max first rest
  in
  with_root ~fs "masc_memory_os_boundary_exact_"
  @@ fun _root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let expected = require_ok (Store.load store) in
  (match
     require_ok
       (Store.For_testing.prepare_with_implementation_ceiling
          ~maximum:(Int64.of_int maximum)
          store
          ~expected
          ~operation_id:"boundary-operation"
          ~state:(state "boundary"))
   with
   | Store.Prepared _ -> ()
   | Store.Current_commit_replay _ | Store.Stale_expected _ ->
     fail "exact implementation boundary did not prepare");
  with_root ~fs "masc_memory_os_boundary_exceeded_"
  @@ fun root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let expected = require_ok (Store.load store) in
  let before = root_snapshot root_path in
  expect_any_safety_violation
    "one byte below required maximum rejects"
    (Store.For_testing.prepare_with_implementation_ceiling
       ~maximum:(Int64.of_int (maximum - 1))
       store
       ~expected
       ~operation_id:"boundary-operation"
       ~state:(state "boundary"));
  check bool "boundary rejection has no effect" true
    (before = root_snapshot root_path)
;;

let test_canonical_state_and_digest_parity () =
  let special_fact =
    { (fact "quote:\" slash:\\ control:\x7f utf8:한글") with
      first_seen = Float.max_float
    ; valid_until = Some (-. Float.max_float)
    ; last_verified_at = Some 2.2250738585072014e-308
    }
  in
  let special_episode =
    { (episode "special") with
      claims = [ special_fact ]
    ; open_items = [ "line\nbreak" ]
    ; constraints = [ "tab\tvalue" ]
    ; preserved_tool_refs = [ "tool\\ref" ]
    ; created_at = -. Float.max_float
    ; terminal_marker = Some "terminal\rmarker"
    }
  in
  let value : Store.state =
    { facts = [ special_fact ]; episodes = [ special_episode ] }
  in
  let legacy =
    Yojson.Safe.to_string
      (`Assoc
         [ "schema", `String "masc-memory-os-state-v2"
         ; "facts", `List [ Types.fact_to_json special_fact ]
         ; "episodes", `List [ Types.episode_to_json special_episode ]
         ])
  in
  check string "streaming canonical bytes match Yojson" legacy
    (require_ok (Store.For_testing.canonical_state_bytes value));
  let expected_digest =
    Digestif.SHA256.(
      digest_string
        ("masc.memory_os.store/v2\000state\000" ^ legacy)
      |> to_hex)
  in
  check string "streaming state digest matches legacy digest"
    expected_digest
    (Store.For_testing.state_sha256 value |> sha256_string)
;;

let test_long_fact_list_is_stack_safe ~fs () =
  let rec build remaining values =
    if remaining = 0
    then values
    else build (remaining - 1) (fact "stack-safe" :: values)
  in
  let value : Store.state =
    { facts = build 20_000 []; episodes = [] }
  in
  check bool "long canonical state rendered" true
    (String.length
       (require_ok (Store.For_testing.canonical_state_bytes value))
     > 0);
  with_root ~fs "masc_memory_os_stack_safe_"
  @@ fun root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let expected = require_ok (Store.load store) in
  prepare_rejected_without_effect
    ~root_path
    ~store
    ~expected
    ~maximum:1L
    ~operation_id:"stack-safe"
    ~state:value
    ~artifact:`Facts
;;

let test_long_episode_claims_publish_reopen ~fs () =
  with_root ~fs "masc_memory_os_long_episode_claims_"
  @@ fun _root_path root ->
  let rec build remaining claims =
    if remaining = 0
    then claims
    else build (remaining - 1) (fact "long-claim" :: claims)
  in
  let claims = build 20_000 [] in
  let value : Store.state =
    { facts = []
    ; episodes = [ { (episode "long-claims") with claims } ]
    }
  in
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let empty = require_ok (Store.load store) in
  let prepared =
    prepare_new store empty "long-claims-operation" value
  in
  ignore (publish_committed store prepared : Store.commit_receipt);
  within_store ~seed:41 ~root ~owner:"keeper-a" @@ fun reopened ->
  let current = require_ok (Store.load reopened) in
  match (Store.snapshot_state current).episodes with
  | [ observed ] ->
    check int
      "all long episode claims survive publish and reopen"
      20_000
      (List.length observed.claims)
  | episodes ->
    failf
      "expected one reopened long-claims episode, observed %d"
      (List.length episodes)
;;

let test_genesis_obligation_recovers_not_published_after_reopen ~fs () =
  with_root ~fs "masc_memory_os_recover_genesis_" @@ fun root_path root ->
  let bytes =
    within_store ~root ~owner:"keeper-a" @@ fun store ->
    let empty = require_ok (Store.load store) in
    let prepared =
      prepare_new store empty "recover-genesis" (state "genesis")
    in
    obligation_bytes store prepared
  in
  let identity_before = load_raw (store_identity_path root_path) in
  within_store ~seed:31 ~root ~owner:"keeper-a" @@ fun reopened ->
  let obligation =
    require_ok (Store.publication_obligation_of_bytes bytes)
  in
  match require_ok (Store.recover_publication reopened obligation) with
  | Store.Recovered_not_published current ->
    check int64
      "reopened genesis expected authority remains current"
      0L
      (Store.snapshot_generation current);
    check string
      "reopening the original root preserves its exact store identity"
      identity_before
      (load_raw (store_identity_path root_path))
  | Store.Recovered_committed _ ->
    fail "unpublished genesis obligation recovered as committed"
  | Store.Recovered_superseded _ ->
    fail "unpublished genesis obligation recovered as superseded"
;;

let test_desired_obligation_recovers_same_receipt_after_reopen ~fs () =
  with_root ~fs "masc_memory_os_recover_desired_"
  @@ fun _root_path root ->
  let bytes, expected_receipt_id =
    within_store ~root ~owner:"keeper-a" @@ fun store ->
    let empty = require_ok (Store.load store) in
    let prepared =
      prepare_new store empty "recover-desired" (state "desired")
    in
    let bytes = obligation_bytes store prepared in
    let receipt = publish_committed store prepared in
    bytes, sha256_string (Store.commit_receipt_id receipt)
  in
  within_store ~seed:32 ~root ~owner:"keeper-a" @@ fun reopened ->
  let obligation =
    require_ok (Store.publication_obligation_of_bytes bytes)
  in
  match require_ok (Store.recover_publication reopened obligation) with
  | Store.Recovered_committed receipt ->
    check string
      "reopened recovery returns the exact committed receipt"
      expected_receipt_id
      (sha256_string (Store.commit_receipt_id receipt));
    check_state_claim
      "reopened desired authority"
      "desired"
      (Store.committed_snapshot receipt)
  | Store.Recovered_not_published _ ->
    fail "published desired obligation recovered as not published"
  | Store.Recovered_superseded _ ->
    fail "published desired obligation recovered as superseded"
;;

let test_nonempty_expected_obligation_recovers_not_published ~fs () =
  with_root ~fs "masc_memory_os_recover_nonempty_"
  @@ fun _root_path root ->
  ignore (seed_commit ~root "base" : Store.commit_receipt);
  let bytes =
    within_store ~seed:33 ~root ~owner:"keeper-a" @@ fun store ->
    let base = require_ok (Store.load store) in
    let prepared =
      prepare_new store base "recover-next" (state "next")
    in
    obligation_bytes store prepared
  in
  within_store ~seed:34 ~root ~owner:"keeper-a" @@ fun reopened ->
  let obligation =
    require_ok (Store.publication_obligation_of_bytes bytes)
  in
  match require_ok (Store.recover_publication reopened obligation) with
  | Store.Recovered_not_published current ->
    check_state_claim "nonempty prior remains current" "base" current
  | Store.Recovered_committed _ ->
    fail "unpublished nonempty obligation recovered as committed"
  | Store.Recovered_superseded _ ->
    fail "unchanged nonempty authority recovered as superseded"
;;

let test_third_authority_recovers_superseded ~fs () =
  with_root ~fs "masc_memory_os_recover_third_" @@ fun _root_path root ->
  ignore (seed_commit ~root "base" : Store.commit_receipt);
  let bytes =
    within_store ~seed:35 ~root ~owner:"keeper-a" @@ fun store ->
    let base = require_ok (Store.load store) in
    let prepared =
      prepare_new store base "recover-pending" (state "pending")
    in
    obligation_bytes store prepared
  in
  within_store ~seed:36 ~root ~owner:"keeper-a" @@ fun store ->
  let base = require_ok (Store.load store) in
  let successor =
    prepare_new store base "recover-successor" (state "successor")
  in
  ignore (publish_committed store successor : Store.commit_receipt);
  within_store ~seed:37 ~root ~owner:"keeper-a" @@ fun reopened ->
  let obligation =
    require_ok (Store.publication_obligation_of_bytes bytes)
  in
  match require_ok (Store.recover_publication reopened obligation) with
  | Store.Recovered_superseded current ->
    check_state_claim "valid third authority is retained" "successor" current
  | Store.Recovered_committed _ ->
    fail "third authority falsely proved desired committed"
  | Store.Recovered_not_published _ ->
    fail "third authority falsely proved desired not published"
;;

let test_foreign_empty_root_obligation_fails_closed ~fs () =
  with_root ~fs "masc_memory_os_recover_source_empty_" @@ fun _ source ->
  let bytes =
    within_store ~root:source ~owner:"keeper-a" @@ fun store ->
    let empty = require_ok (Store.load store) in
    let prepared =
      prepare_new store empty "foreign-empty" (state "foreign-empty")
    in
    obligation_bytes store prepared
  in
  with_root ~fs "masc_memory_os_recover_foreign_empty_"
  @@ fun _ foreign ->
  within_store ~seed:40 ~root:foreign ~owner:"keeper-a" @@ fun store ->
  let obligation =
    require_ok (Store.publication_obligation_of_bytes bytes)
  in
  expect_error_tag
    "same-owner foreign empty root lacks the desired commit scope proof"
    Store.For_testing.Publication_obligation_store_mismatch_error
    (Store.recover_publication store obligation)
;;

let test_foreign_populated_root_obligation_fails_closed ~fs () =
  with_root ~fs "masc_memory_os_recover_source_populated_"
  @@ fun _ source ->
  let bytes =
    within_store ~root:source ~owner:"keeper-a" @@ fun store ->
    let empty = require_ok (Store.load store) in
    let prepared =
      prepare_new store empty "foreign-populated" (state "source")
    in
    obligation_bytes store prepared
  in
  with_root ~fs "masc_memory_os_recover_foreign_populated_"
  @@ fun _ foreign ->
  ignore (seed_commit ~root:foreign "foreign-current" : Store.commit_receipt);
  within_store ~seed:41 ~root:foreign ~owner:"keeper-a" @@ fun store ->
  let obligation =
    require_ok (Store.publication_obligation_of_bytes bytes)
  in
  expect_error_tag
    "same-owner foreign populated root lacks the desired commit scope proof"
    Store.For_testing.Publication_obligation_store_mismatch_error
    (Store.recover_publication store obligation)
;;

let test_cloned_desired_commit_foreign_root_fails_closed ~fs () =
  with_root ~fs "masc_memory_os_recover_clone_source_"
  @@ fun source_path source ->
  let bytes, desired_commit_leaf =
    within_store ~root:source ~owner:"keeper-a" @@ fun store ->
    let empty = require_ok (Store.load store) in
    let prepared =
      prepare_new store empty "clone-scope" (state "source")
    in
    let bytes = obligation_bytes store prepared in
    let desired_commit_leaf =
      Yojson.Safe.from_string bytes
      |> json_field "desired"
      |> json_field "commit"
      |> json_field "leaf"
      |> json_string "desired obligation commit leaf"
    in
    bytes, desired_commit_leaf
  in
  let desired_commit =
    load_raw (Filename.concat source_path desired_commit_leaf)
  in
  with_root ~fs "masc_memory_os_recover_clone_foreign_"
  @@ fun foreign_path foreign ->
  within_store ~seed:45 ~root:foreign ~owner:"keeper-a" (fun _ -> ());
  save_raw
    (Filename.concat foreign_path desired_commit_leaf)
    desired_commit;
  within_store ~seed:46 ~root:foreign ~owner:"keeper-a" @@ fun store ->
  let obligation =
    require_ok (Store.publication_obligation_of_bytes bytes)
  in
  expect_error_tag
    "cloning the desired commit does not clone the private store identity"
    Store.For_testing.Publication_obligation_store_mismatch_error
    (Store.recover_publication store obligation)
;;

let test_store_identity_tamper_fails_closed ~fs () =
  with_root ~fs "masc_memory_os_store_identity_tamper_"
  @@ fun root_path root ->
  within_store ~root ~owner:"keeper-a" (fun _ -> ());
  let path = store_identity_path root_path in
  let tampered =
    load_raw path
    |> Yojson.Safe.from_string
    |> replace_json_field "store_id" (`String (String.make 64 'a'))
    |> Yojson.Safe.to_string
  in
  save_raw path tampered;
  let result =
    Store.with_store
      ~secure_random:(entropy_source 47)
      ~root
      ~owner_id:"keeper-a"
      (fun _ -> Ok ())
  in
  expect_error_tag
    "canonical marker tamper without matching checksum is rejected"
    Store.For_testing.Invalid_store_identity_error
    result
;;

let test_missing_store_identity_never_adopts_nonfresh_root ~fs () =
  with_root ~fs "masc_memory_os_store_identity_missing_"
  @@ fun root_path root ->
  ignore (seed_commit ~root "nonfresh" : Store.commit_receipt);
  Sys.remove (store_identity_path root_path);
  let result =
    Store.with_store
      ~secure_random:(entropy_source 48)
      ~root
      ~owner_id:"keeper-a"
      (fun _ -> Ok ())
  in
  expect_error_tag
    "store data without its identity marker is not adopted or migrated"
    Store.For_testing.Store_identity_missing_from_non_fresh_root_error
    result
;;

let test_lower_authority_relation_fails_closed ~fs () =
  with_root ~fs "masc_memory_os_recover_lower_authority_"
  @@ fun root_path root ->
  ignore (seed_commit ~root "base" : Store.commit_receipt);
  let bytes =
    within_store ~seed:42 ~root ~owner:"keeper-a" @@ fun store ->
    let base = require_ok (Store.load store) in
    let prepared =
      prepare_new store base "lower-authority" (state "desired")
    in
    obligation_bytes store prepared
  in
  Sys.remove (head_path root_path);
  within_store ~seed:43 ~root ~owner:"keeper-a" @@ fun store ->
  let obligation =
    require_ok (Store.publication_obligation_of_bytes bytes)
  in
  expect_error_tag
    "non-empty obligation cannot recover against a regressed empty authority"
    Store.For_testing.Publication_obligation_mismatch_error
    (Store.recover_publication store obligation)
;;

let test_same_receipt_different_authority_fails_closed ~fs () =
  with_root ~fs "masc_memory_os_recover_receipt_collision_"
  @@ fun root_path root ->
  let bytes =
    within_store ~root ~owner:"keeper-a" @@ fun store ->
    let empty = require_ok (Store.load store) in
    let prepared =
      prepare_new store empty "receipt-collision" (state "desired")
    in
    let bytes = obligation_bytes store prepared in
    ignore (publish_committed store prepared : Store.commit_receipt);
    bytes
  in
  let head = load_head root_path in
  let commit_leaf = commit_leaf_of_head head in
  let duplicate_leaf =
    let bytes = Bytes.of_string commit_leaf in
    let index = String.length "memory-os-commit-" in
    Bytes.set
      bytes
      index
      (if Char.equal (Bytes.get bytes index) '0' then '1' else '0');
    Bytes.unsafe_to_string bytes
  in
  save_raw
    (Filename.concat root_path duplicate_leaf)
    (load_raw (Filename.concat root_path commit_leaf));
  let duplicate_commit =
    json_field "commit" head
    |> replace_json_field "leaf" (`String duplicate_leaf)
  in
  save_head
    root_path
    (replace_json_field "commit" duplicate_commit head);
  within_store ~seed:44 ~root ~owner:"keeper-a" @@ fun store ->
  let obligation =
    require_ok (Store.publication_obligation_of_bytes bytes)
  in
  expect_error_tag
    "same receipt under a different exact HEAD authority is corruption"
    Store.For_testing.Publication_obligation_mismatch_error
    (Store.recover_publication store obligation)
;;

let test_obligation_codec_is_exact_and_tamper_evident ~fs () =
  with_root ~fs "masc_memory_os_obligation_codec_"
  @@ fun _root_path root ->
  let bytes =
    within_store ~root ~owner:"keeper-a" @@ fun store ->
    let empty = require_ok (Store.load store) in
    let prepared =
      prepare_new store empty "codec-operation" (state "codec")
    in
    obligation_bytes store prepared
  in
  let decoded =
    require_ok (Store.publication_obligation_of_bytes bytes)
  in
  check string
    "obligation codec is exact canonical JSON"
    bytes
    (Store.publication_obligation_to_bytes decoded);
  let tampered_owner =
    Yojson.Safe.from_string bytes
    |> replace_json_field "owner_id" (`String "keeper-b")
    |> Yojson.Safe.to_string
  in
  expect_error_tag
    "owner tamper without a matching domain checksum is rejected"
    Store.For_testing.Invalid_publication_obligation_error
    (Store.publication_obligation_of_bytes tampered_owner);
  let extra_field =
    match Yojson.Safe.from_string bytes with
    | `Assoc fields ->
      Yojson.Safe.to_string
        (`Assoc (("legacy_fallback", `Bool true) :: fields))
    | _ -> fail "canonical obligation was not an object"
  in
  expect_error_tag
    "unknown obligation fields are rejected"
    Store.For_testing.Invalid_publication_obligation_error
    (Store.publication_obligation_of_bytes extra_field);
  expect_error_tag
    "noncanonical whitespace is rejected"
    Store.For_testing.Invalid_publication_obligation_error
    (Store.publication_obligation_of_bytes (" " ^ bytes))
;;

let test_obligation_projectors_bind_published_identity ~fs () =
  with_root ~fs "masc_memory_os_obligation_projectors_"
  @@ fun _root_path root ->
  within_store ~root ~owner:"keeper-a" @@ fun store ->
  let empty = require_ok (Store.load store) in
  let prepared =
    prepare_new
      store
      empty
      "projected-obligation-operation"
      (state "projected-obligation")
  in
  let prepared_obligation =
    require_ok
      (Store.publication_obligation_of_prepared store prepared)
  in
  let encoded =
    Store.publication_obligation_to_bytes prepared_obligation
  in
  let decoded_obligation =
    require_ok (Store.publication_obligation_of_bytes encoded)
  in
  check string
    "decoded obligation retains exact canonical bytes"
    encoded
    (Store.publication_obligation_to_bytes decoded_obligation);
  let receipt = publish_committed store prepared in
  let check_projection label obligation =
    check string
      (label ^ " operation id")
      (Store.commit_receipt_operation_id receipt)
      (Store.publication_obligation_operation_id obligation);
    check string
      (label ^ " desired receipt id")
      (sha256_string (Store.commit_receipt_id receipt))
      (sha256_string
         (Store.publication_obligation_desired_receipt_id obligation));
    check string
      (label ^ " desired state digest")
      (sha256_string (Store.commit_receipt_state_sha256 receipt))
      (sha256_string
         (Store.publication_obligation_desired_state_sha256 obligation));
    check int64
      (label ^ " desired generation")
      (Store.commit_receipt_generation receipt)
      (Store.publication_obligation_desired_generation obligation)
  in
  check_projection "prepared" prepared_obligation;
  check_projection "decoded" decoded_obligation
;;

let test_foreign_owner_obligation_fails_closed ~fs () =
  with_root ~fs "masc_memory_os_obligation_owner_source_"
  @@ fun _source_path source ->
  let bytes =
    within_store ~root:source ~owner:"keeper-a" @@ fun store ->
    let empty = require_ok (Store.load store) in
    let prepared =
      prepare_new store empty "foreign-owner" (state "foreign")
    in
    obligation_bytes store prepared
  in
  with_root ~fs "masc_memory_os_obligation_owner_foreign_"
  @@ fun _foreign_path foreign ->
  within_store ~seed:38 ~root:foreign ~owner:"keeper-b"
  @@ fun foreign_store ->
  let obligation =
    require_ok (Store.publication_obligation_of_bytes bytes)
  in
  expect_error_tag
    "foreign owner obligation is rejected before authority classification"
    Store.For_testing.Publication_obligation_owner_mismatch_error
    (Store.recover_publication foreign_store obligation)
;;

let test_recovery_validates_desired_reachable_graph ~fs () =
  with_root ~fs "masc_memory_os_recover_tamper_"
  @@ fun root_path root ->
  let bytes =
    within_store ~root ~owner:"keeper-a" @@ fun store ->
    let empty = require_ok (Store.load store) in
    let prepared =
      prepare_new store empty "recover-tamper" (state "tamper")
    in
    let bytes = obligation_bytes store prepared in
    ignore (publish_committed store prepared : Store.commit_receipt);
    bytes
  in
  let commit_leaf = load_head root_path |> commit_leaf_of_head in
  let commit_path = Filename.concat root_path commit_leaf in
  let raw = load_raw commit_path in
  let tampered = Bytes.of_string raw in
  Bytes.set tampered 0 '[';
  save_raw commit_path (Bytes.unsafe_to_string tampered);
  within_store ~seed:39 ~root ~owner:"keeper-a" @@ fun reopened ->
  let obligation =
    require_ok (Store.publication_obligation_of_bytes bytes)
  in
  expect_error_tag
    "desired HEAD is not committed when its reachable graph is corrupt"
    Store.For_testing.Immutable_digest_mismatch_error
    (Store.recover_publication reopened obligation)
;;

let () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let clock = Eio.Stdenv.clock env in
  run
    "keeper memory os canonical store"
    [ ( "store"
      , [ test_case "existing absent read is effect-free" `Quick
            (test_existing_read_absent_is_effect_free ~fs)
        ; test_case "missing identity preserves settlement warning" `Quick
            (test_missing_identity_preserves_settlement_warning ~fs)
        ; test_case "existing empty store read is read-only" `Quick
            (test_existing_read_empty_store_is_read_only ~fs)
        ; test_case "existing populated projection is exact" `Quick
            (test_existing_read_populated_projection_is_exact ~fs)
        ; test_case "existing read rejects current-schema failures" `Quick
            (test_existing_read_rejects_current_schema_failures ~fs)
        ; test_case "genesis roundtrip reopen" `Quick
            (test_genesis_roundtrip_reopen ~fs)
        ; test_case "current replay and conflict" `Quick
            (test_current_replay_and_conflict ~fs)
        ; test_case "concurrent publish has one CAS winner" `Quick
            (test_concurrent_publish_has_single_cas_winner ~fs ~clock)
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
        ; test_case "facts oversize is effect-free" `Quick
            (test_facts_oversize_is_effect_free ~fs)
        ; test_case "last episode oversize is effect-free" `Quick
            (test_last_episode_oversize_is_effect_free ~fs)
        ; test_case "manifest oversize is effect-free" `Quick
            (test_manifest_oversize_is_effect_free ~fs)
        ; test_case "commit oversize is effect-free" `Quick
            (test_commit_oversize_is_effect_free ~fs)
        ; test_case "HEAD oversize is effect-free" `Quick
            (test_head_oversize_is_effect_free ~fs)
        ; test_case "exact implementation boundary" `Quick
            (test_exact_implementation_boundary ~fs)
        ; test_case "canonical state and digest parity" `Quick
            test_canonical_state_and_digest_parity
        ; test_case "long fact list is stack-safe" `Quick
            (test_long_fact_list_is_stack_safe ~fs)
        ; test_case "long episode claims publish and reopen" `Quick
            (test_long_episode_claims_publish_reopen ~fs)
        ; test_case "genesis obligation recovers not published" `Quick
            (test_genesis_obligation_recovers_not_published_after_reopen ~fs)
        ; test_case "desired obligation recovers same receipt" `Quick
            (test_desired_obligation_recovers_same_receipt_after_reopen ~fs)
        ; test_case "nonempty expected obligation recovers not published" `Quick
            (test_nonempty_expected_obligation_recovers_not_published ~fs)
        ; test_case "third authority recovers superseded" `Quick
            (test_third_authority_recovers_superseded ~fs)
        ; test_case "foreign empty root obligation fails closed" `Quick
            (test_foreign_empty_root_obligation_fails_closed ~fs)
        ; test_case "foreign populated root obligation fails closed" `Quick
            (test_foreign_populated_root_obligation_fails_closed ~fs)
        ; test_case "cloned desired commit foreign root fails closed" `Quick
            (test_cloned_desired_commit_foreign_root_fails_closed ~fs)
        ; test_case "store identity tamper fails closed" `Quick
            (test_store_identity_tamper_fails_closed ~fs)
        ; test_case "missing store identity does not adopt nonfresh root" `Quick
            (test_missing_store_identity_never_adopts_nonfresh_root ~fs)
        ; test_case "lower authority relation fails closed" `Quick
            (test_lower_authority_relation_fails_closed ~fs)
        ; test_case "same receipt different authority fails closed" `Quick
            (test_same_receipt_different_authority_fails_closed ~fs)
        ; test_case "obligation codec is exact and tamper evident" `Quick
            (test_obligation_codec_is_exact_and_tamper_evident ~fs)
        ; test_case "obligation projectors bind published identity" `Quick
            (test_obligation_projectors_bind_published_identity ~fs)
        ; test_case "foreign owner obligation fails closed" `Quick
            (test_foreign_owner_obligation_fails_closed ~fs)
        ; test_case "recovery validates desired reachable graph" `Quick
            (test_recovery_validates_desired_reachable_graph ~fs)
        ] )
    ]
;;
