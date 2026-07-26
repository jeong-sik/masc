open Alcotest

module Store = Masc.Keeper_memory_os_store
module Types = Masc.Keeper_memory_os_types

let require_ok = function
  | Ok value -> value
  | Error error -> fail (Store.error_to_string error)
;;

let with_store ~fs owner fn =
  let root = Filename.temp_file "masc_memory_os_store_" ".tmp" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Eio.Switch.run @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree root);
  require_ok
    (Store.with_open
       ~fs
       ~root_path:root
       ~owner_id:owner
       (fun store -> fn root store))
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
  { Types.trace_id = "trace-1"
  ; generation = 1
  ; episode_summary = "summary"
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

let prepare store snapshot operation_id state =
  match
    require_ok
      (Store.prepare store ~expected:snapshot ~operation_id ~state)
  with
  | Store.Prepared prepared -> prepared
  | Store.Already_committed _ ->
    fail "expected a new prepared commit"
;;

let publish store prepared =
  require_ok (Store.publish store prepared)
;;

let test_round_trip ~fs () =
  with_store ~fs "keeper-a" @@ fun _root store ->
  let empty = (require_ok (Store.load store)).value in
  check int64 "fresh sequence" 0L (Store.snapshot_sequence empty);
  let prepared = prepare store empty "operation-a" (state "alpha") in
  let publication = publish store prepared in
  check bool "durable publication has no settlement warning" true
    (Option.is_none publication.settlement_error);
  let receipt = publication.value in
  check int64 "receipt sequence" 1L (Store.commit_receipt_sequence receipt);
  check string "receipt operation" "operation-a"
    (Store.commit_receipt_operation_id receipt);
  let loaded = (require_ok (Store.load store)).value in
  check int64 "reloaded sequence" 1L (Store.snapshot_sequence loaded);
  let loaded_state = Store.snapshot_state loaded in
  check int "one fact" 1 (List.length loaded_state.facts);
  check int "one episode" 1 (List.length loaded_state.episodes);
  check string "fact round-trips" "alpha"
    (List.hd loaded_state.facts).claim;
  Ok ()
;;

let test_idempotency_and_conflict ~fs () =
  with_store ~fs "keeper-a" @@ fun _root store ->
  let empty = (require_ok (Store.load store)).value in
  let first = publish store (prepare store empty "operation-a" (state "alpha")) in
  let committed = first.value in
  let current = (require_ok (Store.load store)).value in
  (match
     require_ok
       (Store.prepare
          store
          ~expected:current
          ~operation_id:"operation-a"
          ~state:(state "alpha"))
   with
   | Store.Already_committed replayed ->
     check string "stable receipt id"
       (Store.commit_receipt_id committed |> Store.Sha256.to_string)
       (Store.commit_receipt_id replayed |> Store.Sha256.to_string)
   | Store.Prepared _ -> fail "idempotent operation allocated a new commit");
  (match
     Store.prepare
       store
       ~expected:current
       ~operation_id:"operation-a"
       ~state:(state "different")
   with
   | Error (Store.Conflicting_operation _) -> ()
   | Error error -> fail (Store.error_to_string error)
   | Ok _ -> fail "same operation id accepted a different payload");
  Ok ()
;;

let test_stale_head_loses_without_retry ~fs () =
  with_store ~fs "keeper-a" @@ fun _root store ->
  let empty = (require_ok (Store.load store)).value in
  let winner = prepare store empty "winner" (state "winner") in
  let loser = prepare store empty "loser" (state "loser") in
  ignore (publish store winner : Store.commit_receipt Store.observation);
  (match Store.publish store loser with
   | Error (Store.Head_conflict _) -> ()
   | Error error -> fail (Store.error_to_string error)
   | Ok _ -> fail "stale prepared commit overwrote HEAD");
  let current = (require_ok (Store.load store)).value in
  check int64 "only winner advanced sequence" 1L
    (Store.snapshot_sequence current);
  check string "winner remains authoritative" "winner"
    (List.hd (Store.snapshot_state current).facts).claim;
  Ok ()
;;

let test_directory_junk_is_not_authority ~fs () =
  with_store ~fs "keeper-a" @@ fun root store ->
  let empty = (require_ok (Store.load store)).value in
  ignore
    (publish store (prepare store empty "operation-a" (state "alpha"))
      : Store.commit_receipt Store.observation);
  let unreferenced =
    Filename.concat
      (Filename.concat root "objects")
      "manifest-00000000-0000-4000-8000-000000000000.json"
  in
  let channel = open_out_bin unreferenced in
  output_string channel {|{"newer_sequence":999999}|};
  close_out channel;
  let current = (require_ok (Store.load store)).value in
  check string "HEAD remains the only authority" "alpha"
    (List.hd (Store.snapshot_state current).facts).claim;
  Ok ()
;;

let test_corrupt_reachable_object_fails_closed ~fs () =
  with_store ~fs "keeper-a" @@ fun root store ->
  let empty = (require_ok (Store.load store)).value in
  let receipt =
    publish store (prepare store empty "operation-a" (state "alpha"))
  in
  let current = Store.committed_snapshot receipt.value in
  let commit_ref =
    match Store.snapshot_head_commit current with
    | Some reference -> reference
    | None -> fail "committed snapshot has no HEAD commit"
  in
  let path =
    Filename.concat
      (Filename.concat root "objects")
      (Store.immutable_ref_leaf commit_ref)
  in
  let channel = open_out_bin path in
  output_string channel "corrupt";
  close_out channel;
  (match Store.load store with
   | Error (Store.Immutable_digest_mismatch reference) ->
     check string "exact corrupt leaf"
       (Store.immutable_ref_leaf commit_ref)
       (Store.immutable_ref_leaf reference)
   | Error error -> fail (Store.error_to_string error)
   | Ok _ -> fail "reachable corrupt object was accepted");
  Ok ()
;;

let () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  run
    "keeper memory os canonical store"
    [ ( "store"
      , [ test_case "round trip" `Quick (test_round_trip ~fs)
        ; test_case "idempotency and conflict" `Quick
            (test_idempotency_and_conflict ~fs)
        ; test_case "stale HEAD loses without retry" `Quick
            (test_stale_head_loses_without_retry ~fs)
        ; test_case "directory junk is not authority" `Quick
            (test_directory_junk_is_not_authority ~fs)
        ; test_case "reachable corruption fails closed" `Quick
            (test_corrupt_reachable_object_fails_closed ~fs)
        ] )
    ]
;;
