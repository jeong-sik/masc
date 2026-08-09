open Alcotest

module Store = Masc.Keeper_chat_operation_store

let store_ok = function
  | Ok value -> value
  | Error error -> fail (Store.error_to_string error)
;;

let temp_dir () =
  let path = Filename.temp_file "keeper-chat-operation-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Array.iter
        (fun child -> remove_tree (Filename.concat path child))
        (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
;;

let dashboard_input ?(content = "hello") ?(submitted_at = 100.0) () : Store.input =
  { content
  ; user_blocks = []
  ; attachments = []
  ; submitted_at
  ; source = Dashboard { thread_id = "thread-1" }
  ; user_row_origin = Masc.Keeper_chat_store.Needs_append
  }
;;

let with_store f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       let store = store_ok (Store.open_ ~base_path ~keeper_name:"sangsu") in
       Fun.protect
         ~finally:(fun () -> ignore (Store.close store))
         (fun () -> f ~base_path store))
;;

let accepted = function
  | Store.Accepted operation -> operation
  | Existing _ -> fail "fresh operation returned Existing"
;;

let existing = function
  | Store.Existing operation -> operation
  | Accepted _ -> fail "duplicate operation returned Accepted"
;;

let check_state label expected operation =
  let actual =
    match operation.Store.state with
    | Queued -> "queued"
    | Running _ -> "running"
    | Succeeded _ -> "succeeded"
    | Failed { kind; _ } -> "failed:" ^ Store.failure_kind_to_string kind
    | Cancelled _ -> "cancelled"
  in
  check string label expected actual
;;

let test_submit_is_durable_and_idempotent () =
  with_store @@ fun ~base_path store ->
  let input = dashboard_input () in
  let first = store_ok (Store.submit store ~operation_id:"kmsg-1" input) |> accepted in
  check_state "accepted queued" "queued" first;
  let duplicate =
    store_ok (Store.submit store ~operation_id:"kmsg-1" input) |> existing
  in
  check int64 "same durable sequence" first.sequence duplicate.sequence;
  (match Store.submit store ~operation_id:"kmsg-1" (dashboard_input ~content:"other" ()) with
   | Error (Idempotency_conflict "kmsg-1") -> ()
   | Error error -> fail ("wrong conflict: " ^ Store.error_to_string error)
   | Ok _ -> fail "same operation id accepted different input");
  store_ok (Store.close store);
  let reopened = store_ok (Store.open_ ~base_path ~keeper_name:"sangsu") in
  Fun.protect
    ~finally:(fun () -> ignore (Store.close reopened))
    (fun () ->
       let loaded = store_ok (Store.lookup reopened ~operation_id:"kmsg-1") in
       check_state "reopened queued" "queued" loaded;
       check bool "queued body retained" true (Option.is_some loaded.input))
;;

let test_fifo_edit_move_cancel_and_terminal_scrub () =
  with_store @@ fun ~base_path:_ store ->
  let op1 =
    store_ok (Store.submit store ~operation_id:"kmsg-1" (dashboard_input ()))
    |> accepted
  in
  let op2 =
    store_ok
      (Store.submit
         store
         ~operation_id:"kmsg-2"
         (dashboard_input ~content:"second" ~submitted_at:101.0 ()))
    |> accepted
  in
  let edited =
    store_ok
      (Store.edit
         store
         ~operation_id:"kmsg-1"
         { content = "edited"; user_blocks = []; attachments = [] })
  in
  (match edited.input with
   | Some input -> check string "edited content" "edited" input.content
   | None -> fail "edit scrubbed queued input");
  check bool
    "edit changes execution digest only"
    true
    (not (String.equal edited.admission_digest edited.execution_digest));
  let original_retry =
    store_ok
      (Store.submit store ~operation_id:"kmsg-1" (dashboard_input ()))
    |> existing
  in
  (match original_retry.input with
   | Some input ->
     check string
       "original retry dedupes to edited current input"
       "edited"
       input.content
   | None -> fail "original retry lost queued input");
  (match
     Store.submit
       store
       ~operation_id:"kmsg-1"
       (dashboard_input ~content:"edited" ())
   with
   | Error (Idempotency_conflict "kmsg-1") -> ()
   | Error error -> fail ("wrong edited retry conflict: " ^ Store.error_to_string error)
   | Ok _ -> fail "edited payload replaced immutable admission identity");
  let moved = store_ok (Store.move_to_end store ~operation_id:"kmsg-1") in
  check bool "move allocates new tail sequence" true (Int64.compare moved.sequence op2.sequence > 0);
  let running =
    store_ok (Store.start_next store ~started_at:110.0)
    |> Option.get
  in
  check string "FIFO head after move" "kmsg-2" running.operation_id;
  let succeeded =
    store_ok
      (Store.succeed
         store
         ~operation_id:"kmsg-2"
         ~completed_at:120.0
         ~outcome_ref:"chat-row-2")
  in
  check_state "terminal success" "succeeded" succeeded;
  check bool "success scrubs input" true (Option.is_none succeeded.input);
  let terminal_duplicate =
    store_ok
      (Store.submit
         store
         ~operation_id:"kmsg-2"
         (dashboard_input ~content:"second" ~submitted_at:101.0 ()))
    |> existing
  in
  check_state "terminal id dedupes forever" "succeeded" terminal_duplicate;
  (match
     Store.fail
       store
       ~operation_id:"kmsg-2"
       ~completed_at:122.0
       ~kind:Turn_failed
       ~detail:"must not rewrite terminal"
       ~outcome_ref:None
   with
   | Error (Not_queued _) -> ()
   | Error error -> fail ("wrong terminal immutability error: " ^ Store.error_to_string error)
   | Ok _ -> fail "terminal operation was rewritten");
  check_state
    "terminal remains succeeded"
    "succeeded"
    (store_ok (Store.lookup store ~operation_id:"kmsg-2"));
  let cancelled =
    store_ok (Store.cancel store ~operation_id:"kmsg-1" ~completed_at:121.0)
  in
  check_state "queued cancel" "cancelled" cancelled;
  check bool "cancel scrubs input" true (Option.is_none cancelled.input);
  let queued = store_ok (Store.list_queued store ~after_sequence:None ~limit:10) in
  check int "no queued rows remain" 0 (List.length queued);
  ignore op1
;;

let test_restart_interrupts_running_once_and_preserves_queued () =
  with_store @@ fun ~base_path store ->
  ignore
    (store_ok (Store.submit store ~operation_id:"run" (dashboard_input ()))
     |> accepted);
  ignore
    (store_ok
       (Store.submit
          store
          ~operation_id:"wait"
          (dashboard_input ~content:"wait" ~submitted_at:101.0 ()))
     |> accepted);
  ignore (store_ok (Store.start_next store ~started_at:110.0));
  store_ok (Store.close store);
  let reopened = store_ok (Store.open_ ~base_path ~keeper_name:"sangsu") in
  Fun.protect
    ~finally:(fun () -> ignore (Store.close reopened))
    (fun () ->
       check int "one interrupted row" 1
         (store_ok (Store.settle_interrupted reopened ~completed_at:120.0));
       check int "settlement is idempotent" 0
         (store_ok (Store.settle_interrupted reopened ~completed_at:121.0));
       let interrupted = store_ok (Store.lookup reopened ~operation_id:"run") in
       check_state
         "running becomes interrupted failure"
         "failed:interrupted_by_restart"
         interrupted;
       check bool "interrupted body scrubbed" true (Option.is_none interrupted.input);
       let queued = store_ok (Store.lookup reopened ~operation_id:"wait") in
       check_state "queued survives restart" "queued" queued;
       check bool "queued body survives" true (Option.is_some queued.input))
;;

let test_commit_failure_readback_is_durable_only () =
  with_store @@ fun ~base_path:_ store ->
  Store.For_testing.fail_next_commit Before_commit;
  (match
     Store.submit store ~operation_id:"pre-commit" (dashboard_input ())
   with
   | Error (Store_unavailable _) -> ()
   | Error error -> fail ("wrong pre-commit failure: " ^ Store.error_to_string error)
   | Ok _ -> fail "pre-commit failure returned success");
  (match Store.lookup store ~operation_id:"pre-commit" with
   | Error (Unknown_operation "pre-commit") -> ()
   | Error error -> fail ("wrong pre-commit readback: " ^ Store.error_to_string error)
   | Ok _ -> fail "pre-commit failure changed durable state");
  Store.For_testing.fail_next_commit After_commit;
  let committed =
    store_ok
      (Store.submit store ~operation_id:"uncertain" (dashboard_input ()))
    |> accepted
  in
  check_state "durable read-back confirms applied commit" "queued" committed;
  let observed = store_ok (Store.lookup store ~operation_id:"uncertain") in
  check int64 "read-back identity" committed.sequence observed.sequence
;;

let () =
  run
    "keeper_chat_operation_store"
    [ ( "store"
      , [ test_case
            "durable submit and permanent idempotency"
            `Quick
            test_submit_is_durable_and_idempotent
        ; test_case
            "FIFO edit move cancel and terminal scrub"
            `Quick
            test_fifo_edit_move_cancel_and_terminal_scrub
        ; test_case
            "restart interruption settlement"
            `Quick
            test_restart_interrupts_running_once_and_preserves_queued
        ; test_case
            "commit failure uses independent durable readback"
            `Quick
            test_commit_failure_readback_is_durable_only
        ] )
    ]
;;
