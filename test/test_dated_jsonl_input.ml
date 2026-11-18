open Alcotest
module Fs = Fs_compat
module Dated = Dated_jsonl

let with_root f =
  let root = Filename.temp_dir "dated-input-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs.remove_tree root) (fun () -> f root)

let write path bytes =
  Out_channel.with_open_bin path (fun output -> output_string output bytes)

let require = function Ok value -> value | Error error -> fail (Dated.read_error_to_string error)

let require_update = function
  | Fs.Private_file_succeeded value -> value
  | Private_file_succeeded_with_cleanup_failure {cleanup_failure; _}
  | Private_file_failed_with_cleanup_failure {cleanup_failure; _} ->
    fail (Fs.private_jsonl_operation_failure_to_string cleanup_failure)
  | Private_file_failed error -> fail (Fs.durable_append_error_to_string error)

let assert_callback_context path =
  check bool "row callback retains caller fiber" true (Fs.execution_context ()=Fs.Eio_fiber);
  check bool "row callback runs outside data-path mutex" true
    (Fs.Input.For_testing.path_mutex_available path)

let append path bytes =
  Fs.update_private_file_durable_locked_result path (fun _ -> Some bytes, ()) |> require_update

let test_tail_and_admission_policies () = with_root (fun root ->
  let path = Filename.concat root "day.jsonl" in
  let bytes = " \t\r\n{\"i\":1}\r\nmalformed\n{\"i\":2" in
  write path bytes;
  let rows = Dated.map_tail_rows_result path ~max_lines:3 ~f:Fun.id |> require in
  check (list string) "physical rows preserve CR, malformed and incomplete bytes"
    ["{\"i\":1}\r"; "malformed"; "{\"i\":2"] (List.map (fun row -> row.Dated.line) rows);
  List.iter (fun row -> check string "offset still addresses exact physical row" row.Dated.line
    (String.sub bytes row.offset (String.length row.line))) rows;
  let absent = Filename.concat root "missing" in
  check (list string) "permissive missing tail stays empty" [] (Dated.load_tail_lines absent ~max_lines:3);
  check (list string) "result missing tail stays empty" []
    (Dated.map_tail_rows_result absent ~max_lines:3 ~f:(fun row -> row.Dated.line) |> require);
  (match Dated.find_latest_entry_in_file_result absent (fun _ -> Some ()) with
   | Error (Dated.Io_error {operation=Inspect; _}) -> ()
   | Error error -> fail (Dated.read_error_to_string error)
   | Ok _ -> fail "strict missing file became an empty success");
  let alias = Filename.concat root "alias" in
  Unix.symlink path alias;
  check (list string) "tail result retains its existing leaf-symlink policy"
    (Dated.load_tail_lines path ~max_lines:3)
    (Dated.map_tail_rows_result alias ~max_lines:3 ~f:(fun row -> row.Dated.line) |> require);
  (match Dated.find_latest_entry_in_file_result alias (fun _ -> Some ()) with
   | Error (Dated.Non_regular_file {kind=Symbolic_link; _}) -> ()
   | Error error -> fail (Dated.read_error_to_string error)
   | Ok _ -> fail "strict reader admitted a symlink");
  (match Dated.map_tail_rows_result root ~max_lines:3 ~f:Fun.id with
   | Error (Dated.Non_regular_file {kind=Directory; _}) -> ()
   | Error error -> fail (Dated.read_error_to_string error)
   | Ok _ -> fail "directory tail became readable"))

let test_reverse_callback_keeps_channel () = Eio_main.run (fun _ -> with_root (fun root ->
  let path = Filename.concat root "day.jsonl" in
  let payload = String.concat "" (List.init 9000 (fun _ -> "한글")) in
  let older = `Assoc ["i",`Int 1; "payload",`String payload] in
  write path (Yojson.Safe.to_string older ^ "\n{\"i\":2}\n");
  let seen = ref [] in
  let result = Dated.find_latest_entry_in_file_result path (function
    | Dated.Malformed_json _ -> fail "valid row became malformed"
    | Dated.Parsed json ->
      assert_callback_context path;
      seen := json :: !seen;
      if List.length !seen=1 then (
        append path "{\"i\":3}\n";
        Eio.Fiber.yield ();
        let replacement = Filename.concat root "replacement" in
        write replacement "{\"replacement\":true}\n";
        Unix.rename replacement path;
        None)
      else Some json) |> require in
  check bool "older UTF-8 row survives multiple chunks and pathname replacement" true (result=Some older);
  check bool "new append is outside the reverse scan's captured length" true
    (!seen=[older; `Assoc ["i",`Int 2]]);
  check (list string) "replacement remains independently visible" ["{\"replacement\":true}"]
    (Dated.load_tail_lines path ~max_lines:1)))

let require_appended = function
  | Ok (Dated.Appended (value,cursor)) -> value,cursor
  | Ok Dated.Cursor_invalidated -> fail "unexpected cursor invalidation"
  | Error error -> fail (Dated.read_error_to_string error)

type visitor = Collect | Iterate | Strict_iterate | Range_incremental

let test_store_callbacks_share_writer_path () = Eio_main.run (fun _ ->
  List.iter (fun visitor -> with_root (fun root ->
    let location = Dated.Store.(at (root_of_masc_dir root) Root.Events) in
    let store = Dated.open_store location in
    let month = Filename.concat (Dated.base_dir store) "2026-01" in
    Fs.mkdir_p month;
    let path = Filename.concat month "01.jsonl" in
    write path "{\"i\":1}\n{\"i\":2}\n";
    let seen = ref [] in
    let visit row =
      assert_callback_context path;
      let value = Yojson.Safe.Util.(member "i" row |> to_int) in
      let first = !seen=[] in
      seen:=value::!seen;
      if first then (append path "{\"i\":3}\n"; Eio.Fiber.yield ()) in
    (match visitor with
     | Collect -> ignore (Dated.collect_matching store 10 ~f:(fun row -> visit row; Some ()) : unit list)
     | Iterate -> Dated.iter_all store visit
     | Strict_iterate ->
       Dated.iter_all_entries_result store (function
         | Dated.Parsed row -> visit row
         | Dated.Malformed_json _ -> fail "valid event became malformed") |> require
     | Range_incremental ->
       let (),_ = Dated.fold_range_appended_result store ~since:"2026-01-01" ~until:"2026-01-01"
         ~cursor:None ~init:() ~f:(fun () row -> visit row) |> require_appended in ());
    let expected = match visitor with
      | Collect -> [2;1]
      | Iterate | Strict_iterate -> [1;2;3]
      | Range_incremental -> [1;2] in
    check (list int) "existing callback order and captured/streaming extent" expected (List.rev !seen);
    check int "ordinary uncached counting sees all completed events" 3 (Dated.count_entries_uncached store)))
    [Collect; Iterate; Strict_iterate; Range_incremental])

let test_incremental_callback_and_torn_tail () = Eio_main.run (fun _ -> with_root (fun root ->
  let path = Filename.concat root "day.jsonl" in
  write path "{\"i\":1}\nmalformed\n{\"i\":2";
  let added = ref false in
  let read cursor = Dated.fold_file_appended_complete_entries_result path ~cursor ~init:[]
    ~f:(fun rows entry ->
      assert_callback_context path;
      if not !added then (added:=true; append path "}\n"; Eio.Fiber.yield ());
      entry::rows) |> require_appended in
  let first,cursor = read None in
  (match List.rev first with
   | [Dated.Parsed (`Assoc ["i",`Int 1]); Dated.Malformed_json _] -> ()
   | _ -> fail "captured extent changed physical rows or consumed a newly completed tail");
  let second,cursor = read (Some cursor) in
  check bool "completed tail arrives exactly once" true (second=[Dated.Parsed (`Assoc ["i",`Int 2])]);
  let empty,_ = read (Some cursor) in
  check int "unchanged extent has no new rows" 0 (List.length empty);
  append path "{\"i\":3";
  match Dated.fold_file_appended_entries_result path ~cursor:None ~init:() ~f:(fun () _ -> ()) with
  | Error (Dated.Io_error {operation=Read_file; _}) -> ()
  | Error error -> fail (Dated.read_error_to_string error)
  | Ok _ -> fail "strict incomplete-tail policy was weakened"))

exception Callback_failure
exception Cancel_read

let test_callback_failure_and_cancellation () = Eio_main.run (fun _ -> with_root (fun root ->
  let path = Filename.concat root "day.jsonl" in
  write path "{\"i\":1}\n";
  check_raises "callback exception remains primary" Callback_failure (fun () ->
    ignore (Dated.find_latest_entry_in_file_result path (fun _ ->
      assert_callback_context path;
      raise Callback_failure) : (unit option,Dated.read_error) result));
  let cancelled = try Eio.Cancel.sub (fun cancel ->
    ignore (Dated.find_latest_entry_in_file_result path (fun _ ->
      assert_callback_context path;
      Eio.Cancel.cancel cancel Cancel_read;
      Eio.Fiber.yield ();
      Some ()) : (unit option,Dated.read_error) result);
    false) with Eio.Cancel.Cancelled _ -> true in
  check bool "callback cancellation propagates after close" true cancelled;
  append path "{\"i\":2}\n";
  check int "later writer/read can reenter the same path" 2
    (Dated.map_tail_rows_result path ~max_lines:10 ~f:Fun.id |> require |> List.length)))

let lock_probe path =
  let fd = Unix.openfile path [Unix.O_RDWR; Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    match Unix.lockf fd Unix.F_TLOCK 0 with
    | () -> 0
    | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> 42)

let contender path =
  let pid = Unix.create_process Sys.executable_name [|Sys.executable_name; "--dated-lock-probe"; path|]
    Unix.stdin Unix.stdout Unix.stderr in
  let rec wait () =
    match Unix.waitpid [] pid with
    | result -> result
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait () in
  match wait () with
  | _, Unix.WEXITED code -> code
  | _, (Unix.WSIGNALED signal | Unix.WSTOPPED signal) -> failf "contender signal %d" signal

let test_close_uses_private_writer_mutex () = Eio_main.run (fun _ -> with_root (fun root ->
  let path = Filename.concat root "day.jsonl" in
  write path "{}\n";
  let entered,resolve_entered = Eio.Promise.create () in
  let body_done,resolve_body_done = Eio.Promise.create () in
  let writer_done,resolve_writer_done = Eio.Promise.create () in
  let mutex = Stdlib.Mutex.create () and condition = Stdlib.Condition.create () in
  let released = ref false and writer_closed = Atomic.make false in
  let closed = ref 0 in
  let release () = Stdlib.Mutex.protect mutex (fun () ->
    released:=true; Stdlib.Condition.broadcast condition) in
  let io = Fs.{before_sync_parent=ignore; close_fd=(fun fd ->
    Unix.close fd; Atomic.set writer_closed true)} in
  let await_entered () =
    let did_enter = Eio.Fiber.first
      (fun () -> Eio.Promise.await entered; true)
      (fun () -> Eio.Promise.await writer_done |> require_update; false) in
    check bool "actual private decision entered before reader finishes" true did_enter in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      Fun.protect ~finally:release (fun () ->
        await_entered ();
        Eio.Promise.await body_done;
        check bool "real private writer owns the same path mutex" false
          (Fs.Input.For_testing.path_mutex_available path);
        check int "another process remains excluded while writer is held" 42 (contender path)));
    let result = Fs.Input.For_testing.with_open ~path ~open_input:open_in_bin
      ~before_close:(fun _ ->
        incr closed;
        check bool "actual reader close holds shared data-path mutex" false
          (Fs.Input.For_testing.path_mutex_available path);
        check bool "reader closes only after entered writer settles" true (Atomic.get writer_closed))
      (fun input ->
        Eio.Fiber.fork ~sw (fun () ->
          let result = Fs.update_private_file_durable_locked_with_io_for_testing ~io path (fun _ ->
            Eio.Promise.resolve resolve_entered ();
            Stdlib.Mutex.protect mutex (fun () ->
              while not !released do Stdlib.Condition.wait condition mutex done);
            None,()) in
          Eio.Promise.resolve resolve_writer_done result);
        await_entered ();
        Fun.protect ~finally:(fun () -> Eio.Promise.resolve resolve_body_done ())
          (fun () -> input_line input)) in
    check string "read channel spans the private transaction" "{}" result;
    Eio.Promise.await writer_done |> require_update;
    check int "actual close boundary entered once" 1 !closed;
    check int "another process enters after both scopes settle" 0 (contender path))))

let () =
  match Sys.argv with
  | [|_; "--dated-lock-probe"; path|] -> exit (lock_probe path)
  | _ -> run "Dated reader input lifetime" ["input", [
      test_case "tail bytes and distinct admission policies" `Quick test_tail_and_admission_policies;
      test_case "reverse callback keeps one channel across chunks" `Quick test_reverse_callback_keeps_channel;
      test_case "store callbacks share the private writer path" `Quick test_store_callbacks_share_writer_path;
      test_case "incremental callback preserves captured and torn tails" `Quick test_incremental_callback_and_torn_tail;
      test_case "callback failure and cancellation settle" `Quick test_callback_failure_and_cancellation;
      test_case "reader close coordinates with the real private writer" `Quick test_close_uses_private_writer_mutex;
    ]]
