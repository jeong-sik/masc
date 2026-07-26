open Alcotest

module Store = Masc.Keeper_memory_os_store
module Types = Masc.Keeper_memory_os_types

let require_ok = function
  | Ok value -> value
  | Error error -> fail (Store.error_to_string error)
;;

let contains_substring haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop offset =
    if offset + needle_length > haystack_length
    then false
    else if
      String.equal
        (String.sub haystack offset needle_length)
        needle
    then true
    else loop (offset + 1)
  in
  needle_length = 0 || loop 0
;;

let expect_error_contains label needle = function
  | Error error ->
    check
      bool
      label
      true
      (contains_substring (Store.error_to_string error) needle)
  | Ok _ -> failf "%s: expected an error" label
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

let load_result ?(seed = 101) ~root =
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
  expect_error_contains
    "same operation with different state conflicts"
    "current memory os operation"
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
  expect_error_contains
    "active cross-store snapshot rejected"
    "different open store instance"
    (Store.prepare
       store_b
       ~expected:snapshot_a
       ~operation_id:"cross-store"
       ~state:(state "cross-store"));
  let escaped_store =
    within_store ~seed:2 ~root:root_a ~owner:"keeper-a"
      (fun store -> store)
  in
  expect_error_contains
    "post-callback store rejected"
    "callback lifetime has ended"
    (Store.load escaped_store);
  let escaped_snapshot =
    within_store ~seed:3 ~root:root_a ~owner:"keeper-a"
      (fun store -> require_ok (Store.load store))
  in
  within_store ~seed:4 ~root:root_a ~owner:"keeper-a" @@ fun reopened ->
  (match
     Store.prepare
       reopened
       ~expected:escaped_snapshot
       ~operation_id:"escaped-snapshot"
       ~state:(state "escaped")
   with
   | Error _ -> ()
   | Ok _ -> fail "post-callback snapshot was accepted");
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
  (match Store.publish reopened escaped_prepared with
   | Error _ -> ()
   | Ok _ -> fail "post-callback prepared commit was accepted")
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
  expect_error_contains
    "digest mismatch precedes invalid JSON decode"
    "does not match its sha-256 digest"
    (load_result ~root)
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
      , "persisted store binding mismatch" )
    ; ( "store"
      , (fun head ->
          replace_json_field
            "store_id"
            (`String zero_digest)
            head)
      , "persisted store binding mismatch" )
    ; ( "generation"
      , (fun head ->
          replace_json_field "generation" (`Intlit "2") head)
      , "persisted store binding mismatch" )
    ; ( "commit-ref"
      , (fun head ->
          let commit =
            json_field "commit" head
            |> replace_json_field
                 "sha256"
                 (`String zero_digest)
          in
          replace_json_field "commit" commit head)
      , "does not match its sha-256 digest" )
    ]
  in
  List.iteri
    (fun index (label, tamper, expected_error) ->
      with_root
        ~fs
        ("masc_memory_os_head_tamper_" ^ label ^ "_")
      @@ fun root_path root ->
      ignore
        (seed_commit ~seed:index ~root "alpha"
          : Store.commit_receipt);
      load_head root_path |> tamper |> save_head root_path;
      expect_error_contains
        (label ^ " tamper fails closed")
        expected_error
        (load_result ~seed:(100 + index) ~root))
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
          expect_error_contains
            "exclusive random leaf collision fails"
            "failed to durably create immutable facts object"
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
        ] )
    ]
;;
