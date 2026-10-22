open Alcotest
open Masc
module R = Exact_lane_run_registry
let json=testable Yojson.Safe.pp Yojson.Safe.equal
let accepted value=match value with Ok value -> value
  | Error error -> fail (R.reconciliation_error_to_string error)
let with_registry work=
  let dir=Filename.temp_dir "exact-original-reconciliation-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir) (fun () ->
    let path=Filename.concat dir R.storage_filename in work dir path (R.replay path))
let terminal ?(output=`Null) () : R.original_completion =
  {outcome=R.Succeeded;elapsed_s=None;output;selected_slot=Some "actual-slot";usage=None}
let reconcile ?(id="original") ?(input=`Null) ?(started_at=123.) registry completion =
  R.reconcile_original registry ~run_id:id ~lane:R.Workspace_curator ~actor:"original-workspace"
    ~started_at ~input:(R.Exact_input input) ~completion
let snapshot path=let stat=Unix.stat path in stat.st_ino,Fs_compat.load_file path
let test_original_retry ()=with_registry (fun _ path registry ->
  accepted (reconcile registry None);
  let first=snapshot path in
  accepted (reconcile registry None);
  check (pair int string) "start confirmation never appends or replaces" first (snapshot path);
  accepted (reconcile registry (Some (terminal ())));
  let completed=snapshot path in
  accepted (reconcile registry (Some (terminal ())));
  check (pair int string) "terminal confirmation never appends or replaces" completed (snapshot path);
  match R.get registry ~run_id:"original" with
  | None -> fail "confirmed original is absent"
  | Some run ->
    check bool "original input is available" true (run.input_availability=R.Available);
    check bool "original output is available" true (run.output_availability=Some R.Available);
    match run.status with
    | R.Completed c ->
      check json "available null is a real terminal" `Null c.output;
      check bool "unknown elapsed is not fabricated" true (c.elapsed_s=None && c.usage=None)
    | R.Running | R.Completion_persistence_failed _ -> fail "confirmed original is not terminal")
let test_both_facts_are_one_transaction ()=with_registry (fun _ path registry ->
  accepted (reconcile ~input:(`Assoc ["original",`String (String.make 70000 'x')]) registry (Some (terminal ())));
  check int "exactly original registration and terminal rows" 2
    (List.length (String.split_on_char '\n' (Fs_compat.load_file path))-1))
let test_conflicts_do_not_reset ()=with_registry (fun _ path registry ->
  accepted (reconcile registry (Some (terminal ())));
  let before=snapshot path in
  (match reconcile ~input:(`String "another request") registry None with
   | Error R.Original_registration_conflict -> () | Error _ | Ok () -> fail "input mismatch must conflict");
  (match reconcile registry (Some (terminal ~output:(`String "another answer") ())) with
   | Error R.Original_completion_conflict -> () | Error _ | Ok () -> fail "producer result must be immutable");
  check (pair int string) "conflict leaves exact bytes and inode" before (snapshot path))
let test_bad_history_is_never_repaired ()=with_registry (fun _ path registry ->
  accepted (reconcile registry (Some (terminal ())));
  let good=Fs_compat.load_file path in
  let original_completion=match String.split_on_char '\n' good with
    | _registration::completion::_ -> Yojson.Safe.from_string completion
    | [] | [_] -> fail "expected original completion row" in
  let orphan=match original_completion with
    | `Assoc fields -> `Assoc (("id",`String "orphan")::List.remove_assoc "id" fields)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "expected object row" in
  List.iter (fun damage ->
    Out_channel.with_open_bin path (fun c -> output_string c (good^damage));
    let before=snapshot path in
    (match reconcile registry (Some (terminal ())) with
     | Error (R.Reconciliation_unavailable _) -> ()
     | Error _ | Ok () -> fail "incomplete or malformed history must refuse confirmation");
    check (pair int string) "source refusal preserves malformed or partial bytes" before (snapshot path))
    ["{bad}\n";"{unfinished";Yojson.Safe.to_string orphan ^ "\n"])
let test_missing_payload_refuses ()=with_registry (fun dir path registry ->
  accepted (reconcile ~input:(`String "original payload") registry (Some (terminal ())));
  let root=Filename.concat (Filename.concat dir R.payload_dirname) "original" in
  let leaf=Array.to_list (Sys.readdir root) |> List.find (fun name -> String.sub name 0 5="input") in
  Unix.unlink (Filename.concat root leaf);
  let before=snapshot path in
  (match reconcile ~input:(`String "original payload") registry (Some (terminal ())) with
   | Error (R.Reconciliation_unavailable _) -> ()
   | Error _ | Ok () -> fail "missing full payload must refuse confirmation");
  check (pair int string) "unavailable payload never replaces the row" before (snapshot path))
let test_restart_correction_is_typed ()=with_registry (fun _ path registry ->
  accepted (reconcile registry None);
  let restarted=R.replay path in
  accepted (reconcile restarted (Some (terminal ())));
  let before=snapshot path in
  accepted (reconcile restarted (Some (terminal ())));
  check (pair int string) "corrected terminal retry is no append" before (snapshot path);
  let reopened=R.replay path in
  accepted (reconcile reopened (Some (terminal ())));
  let failed={ (terminal ()) with outcome=R.Failed {code=R.server_restarted_code;detail="real producer failure"}} in
  accepted (reconcile ~id:"producer" reopened (Some failed));
  (match reconcile ~id:"producer" reopened (Some (terminal ())) with
   | Error R.Original_completion_conflict -> ()
   | Error _ | Ok () -> fail "a producer restart-looking error never grants correction"))
let test_immediate_retention_is_historical_confirmation ()=with_registry (fun _ path _registry ->
  let row value=Yojson.Safe.to_string value ^ "\n" in
  let completion=`Assoc ["outcome",`String "succeeded";"origin",`String "producer";
    "elapsed_s",`Null;"output",`Assoc ["kind",`String "row";"value",`Null];
    "selected_slot",`Null;"usage",`Null] in
  Out_channel.with_open_bin path (fun channel ->
    for index=1 to R.max_completed_retained do
      let id=string_of_int index in
      output_string channel (row (`Assoc ["event",`String "register";"id",`String id;
        "started_at",`Float (1000.+.float_of_int index);"registration",`Assoc [
          "lane",`String (Standalone_lane.to_id Standalone_lane.Workspace_curator);"actor",`String "original-workspace";
          "input",`Assoc ["kind",`String "row";"value",`Null]]]));
      output_string channel (row (`Assoc ["event",`String "complete";"id",`String id;"completion",completion]))
    done);
  let registry=R.replay path in
  accepted (reconcile ~started_at:1. registry (Some (terminal ())));
  check bool "historical publication can immediately leave the retained page" true
    (R.get registry ~run_id:"original"=None);
  let before=snapshot path in
  accepted (reconcile ~started_at:1. registry (Some (terminal ())));
  check (pair int string) "pending ACK retry confirms durable historical row without republishing" before (snapshot path))
let test_not_initialized_and_invalid ()=with_registry (fun _ path _registry ->
  List.iter (fun registry ->
    match reconcile registry None with
    | Error (R.Reconciliation_unavailable _) -> ()
    | Error _ | Ok () -> fail "missing startup/disk authority must refuse") [R.create ();R.create ~path ()];
  let registry=R.replay path in
  (match reconcile ~input:(`Float nan) registry None with
   | Error (R.Invalid_original _) -> () | Error _ | Ok () -> fail "invalid JSON must refuse before I/O");
  check bool "invalid intent creates no log" false (Sys.file_exists path))
let test_json_integer_representation_retry ()=with_registry (fun _ path registry ->
  let completion=terminal ~output:(`Assoc ["value",`Intlit "1"]) () in
  accepted (reconcile ~input:(`Intlit "1") registry (Some completion));
  let before=snapshot path in
  accepted (reconcile ~input:(`Intlit "1") registry (Some completion));
  check (pair int string) "actual JSON representation survives decode" before (snapshot path))
let test_concurrent_original_delivery ()=with_registry (fun _ path registry ->
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
      Eio.Fiber.both
        (fun () -> accepted (reconcile registry (Some (terminal ()))))
        (fun () -> accepted (reconcile registry (Some (terminal ()))))));
  check int "concurrent same original publishes once" 2
    (List.length (String.split_on_char '\n' (Fs_compat.load_file path))-1))
let test_confirmation_fsync_and_refusal_are_distinct ()=with_registry (fun _ path _ ->
  Out_channel.with_open_bin path (fun c -> output_string c "original\n");
  let syncs=ref 0 in
  let append_io:Fs_compat.durable_append_io_for_testing={write=Unix.write;ftruncate=Unix.ftruncate;
    fsync=(fun _ -> incr syncs;raise (Unix.Unix_error (Unix.EIO,"fsync","injected data sync")))} in
  let transaction decide=Fs_compat.reconcile_private_file_durable_locked_with_append_io_for_testing
    ~append_io path decide in
  (match transaction (fun _ -> Fs_compat.Refuse_update "original refusal") with
   | Fs_compat.Private_file_succeeded "original refusal" -> ()
   | Private_file_succeeded _ | Private_file_failed _ | Private_file_succeeded_with_cleanup_failure _
   | Private_file_failed_with_cleanup_failure _ -> fail "refusal must preserve its original result");
  check int "refusal never calls data fsync" 0 !syncs;
  (match transaction (fun _ -> Fs_compat.Confirm_existing ()) with
   | Fs_compat.Private_file_failed {append_failure=Fs_compat.Unix_error {operation=Fs_compat.Append_fsync;_};rollback_failures=[]} -> ()
   | Private_file_failed _ | Private_file_succeeded () | Private_file_succeeded_with_cleanup_failure _
   | Private_file_failed_with_cleanup_failure _ -> fail "failed existing-data fence must not confirm");
  check int "existing confirmation actually attempts data fsync" 1 !syncs;
  check string "failed fence never truncates original bytes" "original\n" (Fs_compat.load_file path))
let test_same_inode_change_after_decision_refuses ()=with_registry (fun _ path _ ->
  Out_channel.with_open_bin path (fun c -> output_string c "before\n");
  let changed=ref false in
  (match Fs_compat.reconcile_private_file_durable_locked_result path (fun _ ->
     Out_channel.with_open_bin path (fun c -> output_string c "changed-after-decision\n");
     Fs_compat.Confirm_existing ()) with
   | exception Sys_error _ -> changed:=true
   | Fs_compat.Private_file_succeeded () | Private_file_succeeded_with_cleanup_failure _
   | Private_file_failed _ | Private_file_failed_with_cleanup_failure _ -> ());
  check bool "same descriptor identity does not certify rewritten content" true !changed)
let ()=Alcotest.run "exact original reconciliation" ["actual disk",[
  test_case "refusal differs from failed existing-data fsync" `Quick test_confirmation_fsync_and_refusal_are_distinct;
  test_case "same-inode callback change cannot confirm" `Quick test_same_inode_change_after_decision_refuses;
  test_case "matching original and terminal retries never append" `Quick test_original_retry;
  test_case "registration and terminal publish together" `Quick test_both_facts_are_one_transaction;
  test_case "conflicting original and producer remain immutable" `Quick test_conflicts_do_not_reset;
  test_case "malformed and partial history remains unchanged" `Quick test_bad_history_is_never_repaired;
  test_case "unavailable payload refuses confirmation" `Quick test_missing_payload_refuses;
  test_case "only typed restart is correctable" `Quick test_restart_correction_is_typed;
  test_case "immediate retention keeps historical confirmation semantics" `Quick test_immediate_retention_is_historical_confirmation;
  test_case "uninitialized and invalid intentions cannot confirm" `Quick test_not_initialized_and_invalid;
  test_case "integer wire representation remains idempotent" `Quick test_json_integer_representation_retry;
  test_case "concurrent real file delivery publishes once" `Quick test_concurrent_original_delivery]]
