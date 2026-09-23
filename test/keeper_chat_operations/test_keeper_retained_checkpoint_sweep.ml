open Alcotest
module Store = Keeper_chat_operation_store
module Execution = Keeper_semantic_execution
module Operation = Keeper_chat_operation
module Scope = Keeper_execution_scope_id
module Sweep = Masc.Keeper_retained_checkpoint_sweep

let store_ok = function Ok value -> value | Error error -> fail (Store.error_to_string error)
let execution_ok = function Ok value -> value | Error error -> fail (Store.semantic_error_to_string error)
let string_ok = function Ok value -> value | Error detail -> fail detail
let uuid n =
  match Uuidm.of_string (Printf.sprintf "00000000-0000-4000-8000-%012d" n) with
  | Some id -> id | None -> fail "invalid fixture UUID"
let checkpoint bytes =
  let trace_id = Keeper_id.Trace_id.of_string "sweep-trace" |> string_ok in
  match Keeper_checkpoint_ref.create ~trace_id ~turn_count:3 ~canonical_checkpoint_bytes:bytes with
  | Ok reference -> reference | Error _ -> fail "checkpoint fixture rejected"
let fixture_input = `Assoc ["kind", `String "test_turn"; "message", `String "continue"]

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

let apply store execution action = Store.semantic_apply store ~expected:execution ~now:20. action |> execution_ok
let running store n =
  let prepared = match Store.semantic_prepare ~input:fixture_input store
      ~id:(Scope.autonomous_admission (uuid n)) ~sources:[] ~now:10. |> execution_ok with
    | Store.Semantic_created execution -> execution
    | Store.Semantic_existing _ -> fail "new identity unexpectedly replayed" in
  apply store (apply store prepared Execution.Confirm_sources) Execution.Begin_execution

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
  let waiting = Execution.gate_wait ~checkpoint:reference
      ~session_scope:(Execution.session_scope [] |> string_ok) ~obligations:[obligation] |> string_ok in
  ignore (Store.defer_direct_gate store ~now:12. ~operation_id
            ~execution_digest:operation.execution_digest ~waiting |> store_ok)

let sweep root = match Sweep.run ~runtime_root:root with
  | Ok report -> report | Error error -> fail (Sweep.error_to_string error)

let test_removes_only_what_no_unsettled_execution_names () = with_root (fun root ->
  let suspended = checkpoint "suspended" and settled = checkpoint "settled"
  and retried = checkpoint "retried" in
  with_open (keeper_store root "alpha") (fun store ->
    ignore (apply store (running store 1) (Execution.Suspend suspended));
    let released = apply store (running store 2) (Execution.Suspend settled) in
    ignore (apply store released (Execution.Settle Execution.Cancelled)));
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
         ignore (apply store (running store 1) (Execution.Suspend held)));
       Unix.symlink (Filename.concat elsewhere Common.keepers_runtime_dirname) keepers_dir
     end else begin
       with_open (keeper_store elsewhere "delta") (fun store ->
         ignore (apply store (running store 1) (Execution.Suspend held)));
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

(* [keepers/tool_usage] and [keepers/trajectories] are workspace stores, not
   keepers; a stray empty operation store there (seen live) must not stop the
   sweep. A keeper actually named like one of them stops it instead. *)
let test_workspace_store_directories_are_not_keepers () = with_root (fun root ->
  let stray = keeper_store root "tool_usage" in
  write stray "";
  let orphan = retained root ~session:["sweep-trace"] (checkpoint "orphan") in
  write orphan "{}";
  let report = sweep root in
  check int "orphan removed despite the stray store" 1 report.removed;
  let keepers_dir = Filename.concat root Common.keepers_runtime_dirname in
  write (keeper_store root "trajectories") "";
  write (Filename.concat keepers_dir "trajectories.json") "{}";
  write orphan "{}";
  (match Sweep.run ~runtime_root:root with
   | Error (Sweep.Keeper_shares_store_directory { keeper_name = "trajectories" }) -> ()
   | Error error -> fail (Sweep.error_to_string error)
   | Ok _ -> fail "a keeper named like a workspace store must stop the sweep");
  check bool "orphan kept while that keeper's store is ambiguous" true (Sys.file_exists orphan))

let test_unreadable_store_removes_nothing () = with_root (fun root ->
  write (keeper_store root "broken") "not a sqlite database";
  let orphan = retained root ~session:["sweep-trace"] (checkpoint "orphan") in
  write orphan "{}";
  (match Sweep.run ~runtime_root:root with
   | Error (Sweep.Store_unreadable _) -> ()
   | Error (Sweep.Keeper_shares_store_directory _ as error) -> fail (Sweep.error_to_string error)
   | Ok _ -> fail "an unreadable store must stop the sweep");
  check bool "orphan kept while the live set is unknown" true (Sys.file_exists orphan))

let test_missing_directories_are_an_empty_sweep () = with_root (fun root ->
  let report = sweep root in
  check int "nothing live" 0 report.live_references;
  check int "nothing removed" 0 report.removed)

let () =
  run "keeper_retained_checkpoint_sweep"
    [ ( "sweep"
      , [ test_case "removes only what no unsettled execution names" `Quick
            test_removes_only_what_no_unsettled_execution_names
        ; test_case "a gate wait keeps its checkpoint" `Quick test_a_gate_wait_keeps_its_checkpoint
        ; test_case "symlinked keeper directories are read" `Quick
            test_symlinked_keeper_directories_are_read
        ; test_case "workspace store directories are not keepers" `Quick
            test_workspace_store_directories_are_not_keepers
        ; test_case "an unreadable store removes nothing" `Quick test_unreadable_store_removes_nothing
        ; test_case "missing directories are an empty sweep" `Quick
            test_missing_directories_are_an_empty_sweep
        ] ) ]
