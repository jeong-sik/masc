open Alcotest
open Masc

let ok = function
  | Ok value -> value
  | Error _ -> fail "fixture failed"
;;

let rec remove path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_base f =
  let base = Filename.temp_dir "compaction_object_store_" "" in
  Fun.protect ~finally:(fun () -> remove base) (fun () -> f base)
;;

let keeper_name =
  ok (Keeper_id.Keeper_name.of_string "object-store-keeper")
;;

let snapshot () =
  let session_id = "object-store-trace" in
  let checkpoint =
    Keeper_context_core.create
      ~eio:false
      ~system_prompt:"object store"
      ~max_tokens:1
    |> Keeper_context_core.checkpoint_of_context
  in
  Agent_sdk.Context.set_scoped
    checkpoint.context
    Agent_sdk.Context.Session
    "keeper_generation"
    (`Int 3);
  let checkpoint =
    { checkpoint with
      session_id
    ; agent_name = "object-store-agent"
    ; model = "test"
    ; turn_count = 7
    }
  in
  let canonical_bytes =
    Agent_sdk.Checkpoint.to_json checkpoint
    |> Yojson.Safe.pretty_to_string
    |> fun bytes -> bytes ^ "\n"
  in
  Keeper_checkpoint_store.exact_snapshot_of_canonical_bytes
    ~expected_session_id:(ok (Keeper_id.Trace_id.of_string session_id))
    canonical_bytes
  |> ok
;;

let test_put_load_idempotent () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_base @@ fun base_path ->
  let snapshot = snapshot () in
  let reference =
    Keeper_checkpoint_store.exact_snapshot_reference snapshot
  in
  ignore (ok (Keeper_compaction_object_store.put ~base_path ~keeper_name snapshot));
  let path =
    Keeper_compaction_object_store.object_path
      ~base_path
      ~keeper_name
      ~reference
  in
  check int "private mode" 0o600 ((Unix.stat path).st_perm land 0o777);
  let before = Fs_compat.load_file path in
  check bool "idempotent" true
    (Keeper_compaction_object_store.put ~base_path ~keeper_name snapshot
     = Ok Keeper_compaction_object_store.Already_present);
  check string "idempotent bytes" before (Fs_compat.load_file path);
  let loaded =
    Keeper_compaction_object_store.load
      ~base_path
      ~keeper_name
      ~reference
    |> ok
  in
  check string "raw bytes preserved"
    (Keeper_checkpoint_store.exact_snapshot_canonical_bytes snapshot)
    (Keeper_checkpoint_store.exact_snapshot_canonical_bytes loaded)
;;

let test_existing_mismatch_is_not_overwritten () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_base @@ fun base_path ->
  let snapshot = snapshot () in
  let reference =
    Keeper_checkpoint_store.exact_snapshot_reference snapshot
  in
  ignore
    (Keeper_compaction_object_store.put ~base_path ~keeper_name snapshot);
  let path =
    Keeper_compaction_object_store.object_path
      ~base_path
      ~keeper_name
      ~reference
  in
  Fs_compat.save_file path "";
  (match
     Keeper_compaction_object_store.put ~base_path ~keeper_name snapshot
   with
   | Error (Keeper_compaction_object_store.Existing_object_invalid _) -> ()
   | _ -> fail "zero-byte existing object was overwritten");
  Fs_compat.save_file path "corrupt\n";
  (match
     Keeper_compaction_object_store.put ~base_path ~keeper_name snapshot
   with
   | Error (Keeper_compaction_object_store.Existing_object_invalid _) -> ()
   | _ -> fail "mismatched object was accepted");
  check string "mismatch not overwritten" "corrupt\n" (Fs_compat.load_file path);
  match
    Keeper_compaction_object_store.load
      ~base_path
      ~keeper_name
      ~reference
  with
  | Error (Keeper_compaction_object_store.Snapshot_invalid _) -> ()
  | _ -> fail "corrupt object did not fail closed"
;;

let test_first_create_failure_retries_and_reconciles () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_base @@ fun base_path ->
  let snapshot = snapshot () in
  let first =
    Keeper_compaction_object_store.For_testing.put
      ~before_stage:(function
        | Keeper_fs.Payload_fsync -> failwith "injected pre-rename failure"
        | _ -> ())
      ~base_path
      ~keeper_name
      snapshot
  in
  (match first with
   | Error
       (Keeper_compaction_object_store.Write_not_committed
          { renamed = false; stage = Keeper_fs.Payload_fsync; _ }) -> ()
   | _ -> fail "pre-rename failure was not retryable");
  let reference =
    Keeper_checkpoint_store.exact_snapshot_reference snapshot
  in
  let path =
    Keeper_compaction_object_store.object_path
      ~base_path
      ~keeper_name
      ~reference
  in
  check bool "failed create left no target" false (Sys.file_exists path);
  check bool "retry stored" true
    (Keeper_compaction_object_store.put ~base_path ~keeper_name snapshot
     = Ok Keeper_compaction_object_store.Stored);
  let other = ok (Keeper_id.Keeper_name.of_string "reconciled-keeper") in
  check bool "post-rename exact reload reconciled" true
    (Keeper_compaction_object_store.For_testing.put
       ~before_stage:(function
         | Keeper_fs.Parent_directory_fsync_after_rename ->
           failwith "injected post-rename failure"
         | _ -> ())
       ~base_path
       ~keeper_name:other
       snapshot
     = Ok Keeper_compaction_object_store.Reconciled)
;;

let () =
  run "keeper compaction object store"
    [ ( "objects"
      , [ test_case "put load idempotent" `Quick test_put_load_idempotent
        ; test_case "mismatch fails closed" `Quick
            test_existing_mismatch_is_not_overwritten
        ; test_case "first-create retry and reconcile" `Quick
            test_first_create_failure_retries_and_reconciles
        ] )
    ]
;;
