open Alcotest
open Masc

module Intent = Keeper_continuation_delivery_intent
module Store = Keeper_continuation_delivery_store

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_config f =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "continuation-delivery-store-%d-%06x"
         (Unix.getpid ())
         (Random.bits ()))
  in
  Unix.mkdir base_path 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       Eio_main.run (fun env ->
         Fs_compat.set_fs (Eio.Stdenv.fs env);
         f (Workspace.default_config base_path)))
;;

let expect_ok = function
  | Ok value -> value
  | Error error -> fail (Store.error_to_string error)
;;

let dashboard thread_id =
  Keeper_continuation_channel.dashboard ~thread_id
  |> Result.fold ~ok:Fun.id ~error:fail
;;

let intent
      ?(source_id = "run-1")
      ?(channel = dashboard "thread-1")
      ?(response = "final answer")
      ()
  =
  let origin =
    Intent.fusion_origin ~run_id:source_id channel
    |> Result.fold ~ok:Fun.id ~error:(fun error -> fail (Intent.error_to_string error))
  in
  Intent.create
    ~keeper_name:"keeper-one"
    ~keeper_turn_id:7
    ~origin
    ~response_text:response
  |> Result.fold ~ok:Fun.id ~error:(fun error -> fail (Intent.error_to_string error))
;;

let test_create_load_and_exact_replay () =
  with_temp_config (fun config ->
    let pending = intent () in
    check bool "first persist creates" true
      (Store.persist ~config pending |> expect_ok = Store.Created);
    check bool "exact replay is idempotent" true
      (Store.persist ~config pending |> expect_ok = Store.Already_current);
    let loaded =
      Store.load
        ~config
        ~keeper_name:pending.keeper_name
        ~intent_id:pending.intent_id
      |> expect_ok
    in
    check bool "loaded intent is exact" true
      (Yojson.Safe.equal (Intent.to_yojson pending) (Intent.to_yojson loaded));
    let inventory = Store.inventory ~config ~keeper_name:pending.keeper_name |> expect_ok in
    check int "one inventory intent" 1 (List.length inventory.intents);
    check int "no inventory failures" 0 (List.length inventory.record_failures))
;;

let test_monotonic_state_machine () =
  with_temp_config (fun config ->
    let pending = intent () in
    ignore (Store.persist ~config pending |> expect_ok : Store.persist_outcome);
    let skipped_attempting =
      Intent.start_attempt ~started_at:1.0 pending
      |> Result.fold ~ok:Fun.id ~error:(fun error -> fail (Intent.error_to_string error))
    in
    let skipped_delivered =
      Intent.mark_delivered ~completed_at:2.0 skipped_attempting
      |> Result.fold ~ok:Fun.id ~error:(fun error -> fail (Intent.error_to_string error))
    in
    check bool "cannot skip attempting" true
      (Result.is_error (Store.persist ~config skipped_delivered));
    let attempting =
      Intent.start_attempt ~started_at:1.0 pending
      |> Result.fold ~ok:Fun.id ~error:(fun error -> fail (Intent.error_to_string error))
    in
    check bool "pending advances to attempting" true
      (Store.persist ~config attempting |> expect_ok = Store.Advanced);
    let delivered =
      Intent.mark_delivered
        ~completed_at:2.0
        ~connector_message_id:"message-1"
        attempting
      |> Result.fold ~ok:Fun.id ~error:(fun error -> fail (Intent.error_to_string error))
    in
    check bool "attempting advances to delivered" true
      (Store.persist ~config delivered |> expect_ok = Store.Advanced);
    check bool "terminal exact replay is idempotent" true
      (Store.persist ~config delivered |> expect_ok = Store.Already_current);
    check bool "terminal cannot regress" true
      (Result.is_error (Store.persist ~config attempting)))
;;

let test_identity_conflict_is_explicit () =
  with_temp_config (fun config ->
    let original = intent () in
    let changed_response = intent ~response:"different final answer" () in
    ignore (Store.persist ~config original |> expect_ok : Store.persist_outcome);
    match Store.persist ~config changed_response with
    | Error (Store.Identity_conflict _) -> ()
    | Error error -> fail ("wrong conflict: " ^ Store.error_to_string error)
    | Ok _ -> fail "changed immutable intent was accepted")
;;

let test_inventory_reports_corrupt_peer () =
  with_temp_config (fun config ->
    let valid = intent () in
    let corrupt_identity = intent ~source_id:"run-corrupt" () in
    ignore (Store.persist ~config valid |> expect_ok : Store.persist_outcome);
    let directory =
      Store.For_testing.active_directory
        ~config
        ~keeper_name:valid.keeper_name
      |> expect_ok
    in
    let corrupt_path =
      Filename.concat
        directory
        (Intent.Intent_id.to_string corrupt_identity.intent_id)
    in
    let channel = open_out_bin corrupt_path in
    output_string channel "{broken-json";
    close_out channel;
    let inventory = Store.inventory ~config ~keeper_name:valid.keeper_name |> expect_ok in
    check int "valid peer remains visible" 1 (List.length inventory.intents);
    check int "corrupt peer is explicit" 1 (List.length inventory.record_failures))
;;

let () =
  run
    "keeper continuation delivery store"
    [ ( "store"
      , [ test_case "create load exact replay" `Quick test_create_load_and_exact_replay
        ; test_case "monotonic state machine" `Quick test_monotonic_state_machine
        ; test_case "identity conflict" `Quick test_identity_conflict_is_explicit
        ; test_case "corrupt peer inventory" `Quick test_inventory_reports_corrupt_peer
        ] )
    ]
;;
