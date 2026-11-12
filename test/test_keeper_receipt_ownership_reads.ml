(** Which run may read a retained receipt.

    A receipt a waiting chat execution owns is read by that execution alone.
    A run that completes acknowledges exactly the receipts it read, so another
    run's read would delete the receipt the owner waits for. These tests pin
    the filter through the outbox the runs read, with the owner record in the
    Keeper's chat operation journal. Nothing creates an owner record yet, so
    the journal row is patched in. *)

open Alcotest
open Masc

module Background = Keeper_execute_background.For_testing
module Outbox = Keeper_client_tool_outbox
module Store = Keeper_chat_operation_store
module Execution = Keeper_semantic_execution
module Scope = Keeper_execution_scope_id
module Chat = Keeper_chat_operation

let get = function Ok value -> value | Error detail -> fail detail
let store_ok = function Ok value -> value | Error error -> fail (Store.error_to_string error)
let keeper_name = "receipt-owner-reader"
let owned_request = "request-owned"
let free_request = "request-free"

let arguments =
  `Assoc [ "command", `String "sleep 30; echo done"; "run_in_background", `Bool true ]
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let base_path = Filename.temp_dir "receipt-ownership-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  f base_path
;;

let retain base_path request_id =
  get
    (Outbox.retain
       ~base_path
       ~keeper_name
       (Background.receipt_of_unfinished
          ~request_id
          ~arguments
          ~cause:Background.restart_cause))
;;

let store_path base_path =
  Store.path_for_keeper
    ~keepers_runtime_dir:(Common.keepers_runtime_dir_of_base ~base_path)
    ~keeper_name
;;

let task_scope name =
  Scope.direct_operation (get (Chat.Operation_id.of_string name))
;;

(* The store refuses a record whose text is not the canonical encoding. *)
let canonical json =
  match Chat.canonical_json_string json with
  | Ok text -> text
  | Error detail -> fail detail
;;

let pending request_id =
  `Assoc [ "request_id", `String request_id; "state", `Assoc [ "kind", `String "pending" ] ]
;;

(* A task that ended its turn on a checkpoint, with [requests] written into its
   record. The record format has no action that does that yet. *)
let waiting_task_owning base_path requests =
  let path = store_path base_path in
  let store = Store.open_or_create ~path |> store_ok in
  let operation_id = get (Chat.Operation_id.of_string "waiting-task") in
  ignore
    (Store.submit
       store
       ~now:1.
       ~operation_id
       ~source:(`Assoc [ "kind", `String "direct" ])
       ~input:(`Assoc [ "message", `String "wait for a background request" ])
     |> store_ok);
  let claimed =
    match Store.claim_next store ~now:2. |> store_ok with
    | Some operation -> operation
    | None -> fail "the submitted task was not claimable"
  in
  let checkpoint =
    let trace_id = get (Keeper_id.Trace_id.of_string "receipt-ownership-trace") in
    match
      Keeper_checkpoint_ref.of_persisted
        ~trace_id
        ~turn_count:3
        ~sha256:(Keeper_checkpoint_ref.sha256_of_canonical_bytes "checkpoint bytes")
    with
    | Ok reference -> reference
    | Error _ -> fail "checkpoint fixture rejected"
  in
  ignore
    (Store.defer_direct_checkpoint
       store
       ~now:3.
       ~operation_id
       ~execution_digest:claimed.execution_digest
       ~checkpoint:(Execution.Agent_core checkpoint)
     |> store_ok);
  let scope = Scope.direct_operation operation_id in
  let record =
    match Store.semantic_get store scope with
    | Ok (Some record) -> record
    | Ok None -> fail "the deferred task has no execution record"
    | Error error -> fail (Store.semantic_error_to_string error)
  in
  Store.close store |> store_ok;
  let patched =
    match Execution.to_json record with
    | `Assoc fields ->
      `Assoc
        (("receipt_obligations", `List (List.map pending requests))
         :: List.remove_assoc "receipt_obligations" fields)
    | _ -> fail "execution JSON is not an object"
  in
  let db = Sqlite3.db_open path in
  Fun.protect
    ~finally:(fun () -> check bool "journal closed" true (Sqlite3.db_close db))
    (fun () ->
       let statement =
         Sqlite3.prepare db "UPDATE semantic_executions SET record_json=? WHERE phase='suspended'"
       in
       Fun.protect
         ~finally:(fun () -> check bool "statement finalized" true (Sqlite3.finalize statement = Sqlite3.Rc.OK))
         (fun () ->
            check
              bool
              "record bound"
              true
              (Sqlite3.bind_text statement 1 (canonical patched) = Sqlite3.Rc.OK);
            check bool "record stored" true (Sqlite3.step statement = Sqlite3.Rc.DONE)));
  scope
;;

let holds viewer base_path request_id =
  Outbox.contains_call (get (Outbox.load ~base_path ~keeper_name ~viewer)) ~call_id:request_id
;;

let test_an_owned_receipt_is_invisible_to_other_runs () =
  with_workspace (fun base_path ->
    retain base_path owned_request;
    retain base_path free_request;
    let owner = waiting_task_owning base_path [ owned_request ] in
    let other = task_scope "another-task" in
    let reads label viewer ~owned ~free =
      check bool (label ^ ": the owned receipt") owned (holds viewer base_path owned_request);
      check bool (label ^ ": the unowned receipt") free (holds viewer base_path free_request)
    in
    reads "a run that serves no task" Outbox.Unowned_only ~owned:false ~free:true;
    reads "a run that serves another task" (Outbox.Owner_and_unowned other) ~owned:false ~free:true;
    reads "a run that serves the owner" (Outbox.Owner_and_unowned owner) ~owned:true ~free:true;
    reads "a read that carries nothing" Outbox.Every_receipt ~owned:true ~free:true;
    check
      bool
      "the start guard still sees the owned receipt, so it writes no second one"
      true
      (get (Background.holds_receipt ~base_path ~keeper_name ~request_id:owned_request));
    (* A run that completes acknowledges what it read. The patrol run takes the
       unowned receipt and leaves the owned one on disk. *)
    let patrol = get (Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Unowned_only) in
    get (Outbox.acknowledge patrol);
    reads "after the other run completed" Outbox.Every_receipt ~owned:true ~free:false;
    let resumed =
      get (Outbox.load ~base_path ~keeper_name ~viewer:(Outbox.Owner_and_unowned owner))
    in
    check int "the owner's run reads its receipt" 1 (List.length (Outbox.receipt_ids resumed));
    get (Outbox.acknowledge resumed);
    reads "after the owner completed" Outbox.Every_receipt ~owned:false ~free:false)
;;

let test_without_an_owner_every_run_reads_every_receipt () =
  with_workspace (fun base_path ->
    retain base_path owned_request;
    retain base_path free_request;
    List.iter
      (fun (label, viewer) ->
         check bool (label ^ ": first") true (holds viewer base_path owned_request);
         check bool (label ^ ": second") true (holds viewer base_path free_request))
      [ "no task", Outbox.Unowned_only
      ; "a task", Outbox.Owner_and_unowned (task_scope "any-task")
      ])
;;

let test_an_unreadable_journal_is_not_an_empty_owner_set () =
  with_workspace (fun base_path ->
    retain base_path owned_request;
    Out_channel.with_open_bin (store_path base_path) (fun channel ->
      Out_channel.output_string channel "not a database");
    (match Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Unowned_only with
     | Error _ -> ()
     | Ok _ -> fail "an unreadable owner journal let a run read a receipt");
    check
      bool
      "a read that carries nothing needs no owners"
      true
      (holds Outbox.Every_receipt base_path owned_request))
;;

let test_receipt_visible_covers_every_pair () =
  let owner = task_scope "owner" in
  let other = task_scope "other" in
  List.iter
    (fun (label, viewer, request_owner, expected) ->
       check bool label expected (Outbox.receipt_visible viewer ~owner:request_owner))
    [ "unowned only, unowned receipt", Outbox.Unowned_only, None, true
    ; "unowned only, owned receipt", Outbox.Unowned_only, Some owner, false
    ; "owner, unowned receipt", Outbox.Owner_and_unowned owner, None, true
    ; "owner, its receipt", Outbox.Owner_and_unowned owner, Some owner, true
    ; "owner, another's receipt", Outbox.Owner_and_unowned owner, Some other, false
    ; "every receipt, unowned receipt", Outbox.Every_receipt, None, true
    ; "every receipt, owned receipt", Outbox.Every_receipt, Some owner, true
    ]
;;

let () =
  run
    "keeper_receipt_ownership_reads"
    [ ( "viewer"
      , [ test_case "an owned receipt is invisible to other runs" `Quick test_an_owned_receipt_is_invisible_to_other_runs
        ; test_case "without an owner every run reads every receipt" `Quick test_without_an_owner_every_run_reads_every_receipt
        ; test_case "an unreadable journal is not an empty owner set" `Quick test_an_unreadable_journal_is_not_an_empty_owner_set
        ; test_case "receipt_visible covers every pair" `Quick test_receipt_visible_covers_every_pair
        ] )
    ]
;;
