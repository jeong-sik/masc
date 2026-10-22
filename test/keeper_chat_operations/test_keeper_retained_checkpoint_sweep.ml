open Alcotest
module Store = Keeper_chat_operation_store
module Execution = Keeper_semantic_execution
module Operation = Keeper_chat_operation
module Sweep = Masc.Keeper_retained_checkpoint_sweep

let store_ok = function Ok value -> value | Error error -> fail (Store.error_to_string error)
let string_ok = function Ok value -> value | Error detail -> fail detail
let checkpoint bytes =
  let trace_id = Keeper_id.Trace_id.of_string "sweep-trace" |> string_ok in
  match Keeper_checkpoint_ref.create ~trace_id ~turn_count:3 ~canonical_checkpoint_bytes:bytes with
  | Ok reference -> reference | Error _ -> fail "checkpoint fixture rejected"

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK); _ } ->
    Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
let rec mkdir_p path =
  if not (Sys.file_exists path) then (mkdir_p (Filename.dirname path); Unix.mkdir path 0o755)
let write path contents =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc contents)
let with_root f =
  let root = Filename.temp_dir "retained-checkpoint-sweep-" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> f root)
let keeper_store root keeper_name =
  let keepers_runtime_dir = Filename.concat root Common.keepers_runtime_dirname in
  let path = Store.path_for_keeper ~keepers_runtime_dir ~keeper_name in
  mkdir_p (Filename.dirname path);
  path
let with_open path f =
  let store = Store.open_or_create ~path |> store_ok in
  Fun.protect ~finally:(fun () -> Store.close store |> store_ok) (fun () -> f store)
let retained root ~session (reference : Keeper_checkpoint_ref.t) =
  List.fold_left Filename.concat (Masc.Keeper_fs.session_store_path_for_runtime_root root)
    (session @ [Masc.Keeper_checkpoint_store.retained_dirname; reference.sha256 ^ ".json"])

let claimed_direct store name =
  let operation_id = Operation.Operation_id.of_string name |> string_ok in
  let input = match Operation.canonical_json (`Assoc ["message", `String "continue"]) with
    | Ok input -> input | Error _ -> fail "invalid canonical input fixture" in
  ignore (Store.submit store ~now:10. ~operation_id
            ~source:(`Assoc ["channel", `String "dashboard"]) ~input |> store_ok);
  match Store.claim_next store ~now:11. |> store_ok with
  | Some operation -> operation | None -> fail "direct operation was not queued"

let defer_direct_checkpoint store name reference =
  let operation = claimed_direct store name in
  ignore (Store.defer_direct_checkpoint store ~now:12. ~operation_id:operation.operation_id
            ~execution_digest:operation.execution_digest ~checkpoint:(Execution.Agent_core reference)
          |> store_ok);
  operation.operation_id

let defer_direct_retry store reference =
  let operation_id = Operation.Operation_id.of_string "sweep-direct" |> string_ok in
  let input = match Operation.canonical_json (`Assoc ["message", `String "finish"]) with
    | Ok input -> input | Error _ -> fail "invalid canonical input fixture" in
  ignore (Store.submit store ~now:10. ~operation_id
            ~source:(`Assoc ["channel", `String "dashboard"]) ~input |> store_ok);
  let operation = match Store.claim_next store ~now:11. |> store_ok with
    | Some operation -> operation | None -> fail "direct operation was not queued" in
  let continuation = Execution.runtime_retry ~not_before:None ~checkpoint:reference
      ~assignment_id:"assignment" ~failed_runtime_id:"failed" ~next_runtime_id:"next"
      ~later_runtime_ids:[] |> string_ok in
  ignore (Store.defer_direct_runtime_retry store ~now:12. ~operation_id
            ~execution_digest:operation.execution_digest ~continuation |> store_ok)

let defer_direct_gate store reference =
  let operation_id = Operation.Operation_id.of_string "sweep-gate" |> string_ok in
  let input = match Operation.canonical_json (`Assoc ["message", `String "approve first"]) with
    | Ok input -> input | Error _ -> fail "invalid canonical input fixture" in
  ignore (Store.submit store ~now:10. ~operation_id
            ~source:(`Assoc ["channel", `String "dashboard"]) ~input |> store_ok);
  let operation = match Store.claim_next store ~now:11. |> store_ok with
    | Some operation -> operation | None -> fail "gate operation was not queued" in
  let obligation = Execution.gate_obligation ~approval_id:"approval" ~tool_name:"tool_execute"
      ~input_hash:(Digestif.SHA256.(digest_string "tool input" |> to_hex)) |> string_ok in
  let waiting = Execution.gate_wait ~checkpoint:reference ~obligations:[obligation] |> string_ok in
  ignore (Store.defer_direct_gate store ~now:12. ~operation_id
            ~execution_digest:operation.execution_digest ~waiting |> store_ok)

let sweep root = match Sweep.run ~runtime_root:root with
  | Ok report -> report | Error error -> fail (Sweep.error_to_string error)

let test_removes_only_what_no_unsettled_execution_names () = with_root (fun root ->
  let suspended = checkpoint "suspended" and settled = checkpoint "settled"
  and retried = checkpoint "retried" in
  with_open (keeper_store root "alpha") (fun store ->
    let released = defer_direct_checkpoint store "sweep-settled" settled in
    ignore (Store.cancel_queued store ~now:13. ~operation_id:released |> store_ok);
    ignore (defer_direct_checkpoint store "sweep-suspended" suspended));
  with_open (keeper_store root "beta") (fun store -> defer_direct_retry store retried);
  let kept_suspended = retained root ~session:["scope"; "sweep-trace"] suspended in
  let kept_retried = retained root ~session:["sweep-trace"] retried in
  let released_here = retained root ~session:["sweep-trace"] settled in
  let released_elsewhere = retained root ~session:["scope"; "sweep-trace"] settled in
  let other_file = Filename.concat (Filename.dirname kept_retried) "notes.txt" in
  List.iter (fun path -> write path "{}")
    [kept_suspended; kept_retried; released_here; released_elsewhere; other_file];
  let report = sweep root in
  check int "suspended and retried checkpoints are live" 2 report.live_references;
  check int "both copies of the settled execution's checkpoint removed" 2 report.removed;
  check int "removed bytes" 4 report.removed_bytes;
  check (list string) "no failures" [] report.failures;
  check bool "suspended checkpoint kept" true (Sys.file_exists kept_suspended);
  check bool "retried checkpoint kept" true (Sys.file_exists kept_retried);
  check bool "settled checkpoint removed" false (Sys.file_exists released_here);
  check bool "settled copy in another session removed" false (Sys.file_exists released_elsewhere);
  check bool "a file not named <sha>.json is left" true (Sys.file_exists other_file))

let test_a_gate_wait_keeps_its_checkpoint () = with_root (fun root ->
  let gated = checkpoint "gated" in
  with_open (keeper_store root "gamma") (fun store -> defer_direct_gate store gated);
  let path = retained root ~session:["sweep-trace"] gated in
  write path "{}";
  let report = sweep root in
  check int "the gate's checkpoint is live" 1 report.live_references;
  check int "nothing removed" 0 report.removed;
  check bool "gated checkpoint kept" true (Sys.file_exists path))

(* The runtime opens a keeper's store through a symlinked keepers directory
   or keeper directory; the sweep must read the same store, not treat the
   link as absent and release everything it names. *)
let test_symlinked_keeper_directories_are_read () =
  List.iter (fun link_keepers_dir -> with_root (fun root ->
    let held = checkpoint "held" in
    let elsewhere = Filename.concat root "elsewhere" in
    let keepers_dir = Filename.concat root Common.keepers_runtime_dirname in
    (if link_keepers_dir then begin
       with_open (keeper_store elsewhere "delta") (fun store ->
         ignore (defer_direct_checkpoint store "sweep-held" held));
       Unix.symlink (Filename.concat elsewhere Common.keepers_runtime_dirname) keepers_dir
     end else begin
       with_open (keeper_store elsewhere "delta") (fun store ->
         ignore (defer_direct_checkpoint store "sweep-held" held));
       mkdir_p keepers_dir;
       Unix.symlink
         (Filename.concat (Filename.concat elsewhere Common.keepers_runtime_dirname) "delta")
         (Filename.concat keepers_dir "delta")
     end);
    let path = retained root ~session:["sweep-trace"] held in
    write path "{}";
    let report = sweep root in
    check int "the linked store's checkpoint is live" 1 report.live_references;
    check bool "checkpoint named through a link kept" true (Sys.file_exists path)))
    [true; false]

(* [keepers/tool_usage] is a store kept beside the keepers, not a keeper; a
   stray empty operation store there (seen live) must not stop the sweep. A
   keeper actually named tool_usage stops it instead. *)
let test_workspace_store_directories_are_not_keepers () = with_root (fun root ->
  let stray = keeper_store root "tool_usage" in
  write stray "";
  let orphan = retained root ~session:["sweep-trace"] (checkpoint "orphan") in
  write orphan "{}";
  let report = sweep root in
  check int "orphan removed despite the stray store" 1 report.removed;
  let keepers_dir = Filename.concat root Common.keepers_runtime_dirname in
  write (Filename.concat keepers_dir "tool_usage.json") "{}";
  write orphan "{}";
  (match Sweep.run ~runtime_root:root with
   | Error (Sweep.Keeper_shares_store_directory { keeper_name = "tool_usage" }) -> ()
   | Error error -> fail (Sweep.error_to_string error)
   | Ok _ -> fail "a keeper named like a keepers/ store must stop the sweep");
  check bool "orphan kept while that keeper's store is ambiguous" true (Sys.file_exists orphan))

let test_unreadable_store_removes_nothing () = with_root (fun root ->
  write (keeper_store root "broken") "not a sqlite database";
  let orphan = retained root ~session:["sweep-trace"] (checkpoint "orphan") in
  write orphan "{}";
  (match Sweep.run ~runtime_root:root with
   | Error (Sweep.Store_unreadable _) -> ()
   | Error ((Sweep.Keeper_shares_store_directory _ | Sweep.Prior_input_history_unavailable _
            | Sweep.Store_missing _) as error) -> fail (Sweep.error_to_string error)
   | Ok _ -> fail "an unreadable store must stop the sweep");
  check bool "orphan kept while the live set is unknown" true (Sys.file_exists orphan))

(* 2026-10-22 (#45076): the live stores were moved aside before a start. The
   sweep read each missing store as naming nothing and removed the 53 retained
   checkpoints (1.57 GB) those stores named, suspended executions' included. *)
let test_missing_store_removes_nothing () = with_root (fun root ->
  let held = checkpoint "held" and named_by_moved = checkpoint "named-by-moved-store" in
  with_open (keeper_store root "present") (fun store ->
    ignore (defer_direct_checkpoint store "sweep-held" held));
  let moved_aside = keeper_store root "moved-aside" in
  let kept_held = retained root ~session:["sweep-trace"] held in
  let kept_moved = retained root ~session:["sweep-trace"] named_by_moved in
  List.iter (fun path -> write path "{}") [kept_held; kept_moved];
  (match Sweep.run ~runtime_root:root with
   | Error (Sweep.Store_missing { path }) ->
     check string "the missing store is named" moved_aside path
   | Error ((Sweep.Store_unreadable _ | Sweep.Keeper_shares_store_directory _
            | Sweep.Prior_input_history_unavailable _) as error) -> fail (Sweep.error_to_string error)
   | Ok _ -> fail "a missing store must stop the sweep");
  check bool "what the missing store named is kept" true (Sys.file_exists kept_moved);
  check bool "what a present store names is kept" true (Sys.file_exists kept_held))

let test_missing_directories_are_an_empty_sweep () = with_root (fun root ->
  let report = sweep root in
  check int "nothing live" 0 report.live_references;
  check int "nothing removed" 0 report.removed)

let test_input_owner_retains_only_current_checkpoint_after_restart () = with_root (fun root ->
  let previous = checkpoint "input-before-consumption" in
  let consumed = checkpoint "input-consumed" in
  with_open (keeper_store root "input-owner") (fun store ->
    let update observed checkpoint = match Store.update_input_checkpoint store ~observed ~checkpoint |> store_ok with
      | Store.Input_checkpoint_updated -> ()
      | Input_checkpoint_source_changed _ -> fail "fixture input owner changed" in
    update None previous;
    update (Some previous) consumed);
  let old_file = retained root ~session:["sweep-trace"] previous in
  let current_file = retained root ~session:["sweep-trace"] consumed in
  write old_file "previous";
  write current_file "consumed";
  let report = sweep root in
  check int "input owner survives without any active semantic execution" 1 report.live_references;
  check bool "current consumed evidence survives restart sweep" true (Sys.file_exists current_file);
  check bool "superseded input checkpoint is removed" false (Sys.file_exists old_file))

let test_prior_input_history_keeps_unnamed_retained_evidence () = with_root (fun root ->
  let path = keeper_store root "prior-input" in
  with_open path (fun _ -> ());
  let db = Sqlite3.db_open ~mode:`NO_CREATE path in
  check bool "mark unresolved history" true
    (Sqlite3.exec db "UPDATE input_history SET basis='prior_unavailable' WHERE singleton=1" = Sqlite3.Rc.OK);
  check bool "close fixture" true (Sqlite3.db_close db);
  let unnamed = retained root ~session:["omitted-trace"] (checkpoint "unresolved-answer") in
  write unnamed "accepted answer whose old owner may have retired";
  (match Sweep.run ~runtime_root:root with
   | Error (Sweep.Prior_input_history_unavailable _) -> ()
   | Error (Store_unreadable _ | Keeper_shares_store_directory _ | Store_missing _) | Ok _ ->
     fail "sweep did not preserve the unknown prior input boundary");
  check bool "unreferenced bytes survive while prior ownership is unknown" true (Sys.file_exists unnamed))

let test_response_intent_keeps_source_and_candidate_after_restart () = with_root (fun root ->
  let original=checkpoint "original waiting input" and source=checkpoint "extended response source"
  and candidate=checkpoint "frozen consumed candidate" and orphan=checkpoint "unrelated orphan" in
  let path=keeper_store root "response-intent" in
  let operation_id=with_open path (fun store ->
    let operation=claimed_direct store "original-response-intent" in
    let call_id="019a0010-1000-7000-8000-000000000051" in
    let pending : Agent_core.Agent_input_request.pending =
      {run_id="sweep-original-input-run";request={request_id="sweep-original-question";
        participant_name=None;question="Which original input?";schema=None;timeout_s=None;created_at=10.}} in
    let locator=Agent_core.Agent.execution_locator_of_yojson
      (`Assoc ["version",`Int 1;"run_id",`String "execution-run-sweep-original-input"]) |> string_ok in
    let call=Keeper_native_call.create ~call_id ~runtime_id:"native.primary" ~operation_digest:operation.execution_digest
      ~api:(Keeper_native_call.New_input {seed_message_count=1}) ~seed_checkpoint:original ~locator |> string_ok in
    Store.update_direct_native_call store ~now:12. ~operation_id:operation.operation_id ~execution_digest:operation.execution_digest
      (Keeper_native_call.Bind {observed=Keeper_native_call.No_native_call;call}) |> store_ok;
    ignore (Store.update_direct_input_checkpoint store ~now:13. ~operation_id:operation.operation_id ~execution_digest:operation.execution_digest
      ~call_id ~observed:original ~observed_input:None ~checkpoint:original |> store_ok);
    Store.update_direct_native_call store ~now:14. ~operation_id:operation.operation_id ~execution_digest:operation.execution_digest
      (Keeper_native_call.Terminal {call_id;disposition={Agent_core.Agent.outcome=Agent_core.Agent.Terminal_succeeded;
        recovery=Agent_core.Agent.Retire}}) |> store_ok;
    let waiting=Execution.input_wait ~checkpoint:original ~pending |> string_ok in
    ignore (Store.defer_direct_input_wait store ~now:15. ~operation_id:operation.operation_id ~execution_digest:operation.execution_digest ~waiting |> store_ok);
    let intent=Execution.input_response_intent ~destination:Execution.Canonical_input ~waiting ~source ~candidate ~response:Agent_core.Hooks.Declined |> string_ok in
    Store.prepare_direct_input_response store ~now:16. ~operation_id:operation.operation_id ~execution_digest:operation.execution_digest ~intent |> store_ok;
    operation.operation_id) in
  (* Sweep observes actual reopened SQLite facts; these files test retention,
     not checkpoint payload validation or physical response installation. *)
  let file reference=retained root ~session:["sweep-trace"] reference in
  List.iter (fun reference -> write (file reference) "{}") [original;source;candidate;orphan];
  let report=sweep root in
  check int "original wait plus response source/candidate survive restart" 3 report.live_references;
  check int "only unrelated orphan removed" 1 report.removed;
  List.iter (fun reference -> check bool "response recovery evidence retained" true (Sys.file_exists (file reference)))
    [original;source;candidate];
  check bool "unreferenced orphan removed" false (Sys.file_exists (file orphan));
  with_open path (fun store -> ignore (Store.cancel_queued store ~now:17. ~operation_id |> store_ok));
  let report=sweep root in
  check int "only current input ownership remains after cancellation" 1 report.live_references;
  check int "source and candidate no longer live after confirmed cancellation" 2 report.removed;
  check bool "current original input retained" true (Sys.file_exists (file original));
  List.iter (fun reference -> check bool "cancelled response evidence swept" false (Sys.file_exists (file reference))) [source;candidate])

let () =
  run "keeper_retained_checkpoint_sweep"
    [ ( "sweep"
      , [ test_case "response intent retains original source and candidate across restart" `Quick
            test_response_intent_keeps_source_and_candidate_after_restart;
          test_case "prior input uncertainty preserves every retained artifact" `Quick
            test_prior_input_history_keeps_unnamed_retained_evidence;
          test_case "input checkpoint owner survives restart sweep" `Quick
        test_input_owner_retains_only_current_checkpoint_after_restart;
      test_case "removes only what no unsettled execution names" `Quick
            test_removes_only_what_no_unsettled_execution_names
        ; test_case "a gate wait keeps its checkpoint" `Quick test_a_gate_wait_keeps_its_checkpoint
        ; test_case "symlinked keeper directories are read" `Quick
            test_symlinked_keeper_directories_are_read
        ; test_case "workspace store directories are not keepers" `Quick
            test_workspace_store_directories_are_not_keepers
        ; test_case "an unreadable store removes nothing" `Quick test_unreadable_store_removes_nothing
        ; test_case "a missing store removes nothing" `Quick test_missing_store_removes_nothing
        ; test_case "missing directories are an empty sweep" `Quick
            test_missing_directories_are_an_empty_sweep
        ] ) ]
