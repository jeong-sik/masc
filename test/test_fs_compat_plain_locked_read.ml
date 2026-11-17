open Alcotest
module Fs = Fs_compat

type reader = Contents | Lines
let readers = [Contents; Lines]

let with_root f =
  let root = Filename.temp_dir "plain-locked-read-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs.remove_tree root) (fun () -> f root)

let write path content = Out_channel.with_open_bin path (fun output -> output_string output content)

let with_fs filesystem f =
  let previous = Fs.get_fs_opt () in
  let set = function None -> Fs.clear_fs () | Some fs -> Fs.set_fs fs in
  set filesystem;
  Fun.protect ~finally:(fun () -> set previous) f

let read ~before_read reader path =
  match reader with
  | Contents -> ignore (Fs.Locked_read_for_testing.load_file ~before_read path : string)
  | Lines -> ignore (Fs.Locked_read_for_testing.load_lines_rev ~before_read path : string list)

let old_lines path =
  let input = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr input) (fun () ->
    let rec loop reversed =
      match input_line input with
      | line -> loop (line :: reversed)
      | exception End_of_file -> reversed in
    loop [])

let test_plain_contracts () = with_root (fun root ->
  let path = Filename.concat root "record" in
  List.iter (fun bytes ->
    write path bytes;
    check string "text whole-file contract unchanged" (Fs.load_file path) (Fs.load_file_locked path);
    check (list string) "binary physical lines retain order and final fragment"
      (old_lines path) (Fs.load_lines_rev_locked path))
    [""; "\n"; "first\r\n\nlast"; "{bad}\n42\n\"unfinished"; "nul\000byte\255\n"];
  Unix.chmod path 0o666;
  let alias = Filename.concat root "alias" in
  Unix.symlink path alias;
  check string "plain reads still follow leaf symlinks and accept ordinary modes"
    (Fs.load_file path) (Fs.load_file_locked alias);
  check (list string) "line reader retains the same plain path policy"
    (old_lines path) (Fs.load_lines_rev_locked alias);
  List.iter (fun reader ->
    match read ~before_read:ignore reader (Filename.concat root "missing") with
    | () -> fail "missing plain read became a success"
    | exception Sys_error _ -> ()) readers)

let assert_closed = function
  | None -> fail "reader never opened its descriptor"
  | Some fd ->
    (match Unix.fstat fd with
     | _ -> fail "reader descriptor escaped cleanup"
     | exception Unix.Unix_error (Unix.EBADF, _, _) -> ())

let assert_mutex_held path =
  check bool "shared append mutex covers the opened descriptor" false
    (Fs.Locked_read_for_testing.path_mutex_available path)

let test_mutex_and_settlement () = with_root (fun root ->
  let path = Filename.concat root "record" in
  let spelling = Filename.concat root "./record" in
  write path "original\nlast";
  List.iter (fun reader ->
    let descriptor = ref None in
    let before_read fd =
      descriptor := Some fd;
      assert_mutex_held path; assert_mutex_held spelling in
    read ~before_read reader spelling;
    assert_closed !descriptor;
    check bool "mutex released after successful read" true
      (Fs.Locked_read_for_testing.path_mutex_available path);
    let failure = Sys_error "injected plain read failure" in
    check_raises "read failure stays primary" failure (fun () ->
      read ~before_read:(fun fd -> before_read fd; raise failure) reader path);
    assert_closed !descriptor;
    check bool "mutex released after failed read" true
      (Fs.Locked_read_for_testing.path_mutex_available path)) readers)

let test_descriptor_survives_replacement () = with_root (fun root ->
  let path = Filename.concat root "record" in
  let replace () =
    let replacement = Filename.concat root "replacement" in
    write replacement "new bytes"; Unix.rename replacement path in
  write path "old bytes";
  check string "whole-file read retains the opened descriptor"
    "old bytes" (Fs.Locked_read_for_testing.load_file ~before_read:(fun _ -> replace ()) path);
  write path "old\nlast";
  check (list string) "line read retains the opened descriptor"
    ["last"; "old"] (Fs.Locked_read_for_testing.load_lines_rev ~before_read:(fun _ -> replace ()) path);
  check string "replacement remains at the path" "new bytes" (Fs.load_file path))

let test_eio_dispatch () = Eio_main.run (fun env ->
  List.iter (fun filesystem -> with_fs filesystem (fun () -> with_root (fun root ->
    let path = Filename.concat root "record" in
    write path "text\n";
    List.iter (fun reader ->
      read ~before_read:(fun _ ->
        assert_mutex_held path;
        match Eio.Fiber.is_cancelled () with
        | true | false -> fail "blocking read and mutex ran on an Eio fiber"
        | exception Effect.Unhandled _ -> ()) reader path) readers)))
    [None; Some (Eio.Stdenv.fs env)])

exception Cancel_plain_read
type cancelled_read = Read_cancelled | Read_returned

let test_cancellation_after_cleanup () = Eio_main.run (fun _ ->
  with_fs None (fun () -> List.iter (fun reader -> with_root (fun root ->
    let path = Filename.concat root "record" in
    write path "unchanged\n";
    let entered, resolve_entered = Eio.Promise.create () in
    let context, resolve_context = Eio.Promise.create () in
    let outcome, resolve_outcome = Eio.Promise.create () in
    let mutex = Stdlib.Mutex.create () and condition = Stdlib.Condition.create () in
    let released = ref false and descriptor = Atomic.make None in
    let release () = Stdlib.Mutex.protect mutex (fun () ->
      released := true; Stdlib.Condition.broadcast condition) in
    let before_read fd =
      Atomic.set descriptor (Some fd);
      Eio.Promise.resolve resolve_entered ();
      Stdlib.Mutex.protect mutex (fun () ->
        while not !released do Stdlib.Condition.wait condition mutex done) in
    Eio.Switch.run (fun sw ->
      Eio.Fiber.fork ~sw (fun () ->
        let result = try Eio.Cancel.sub (fun cancel ->
          Eio.Promise.resolve resolve_context cancel;
          read ~before_read reader path; Read_returned)
          with Eio.Cancel.Cancelled _ -> Read_cancelled in
        Eio.Promise.resolve resolve_outcome result);
      Fun.protect ~finally:release (fun () ->
        let cancel = Eio.Promise.await context in
        let did_enter = Eio.Fiber.first
          (fun () -> Eio.Promise.await entered; true)
          (fun () -> ignore (Eio.Promise.await outcome : cancelled_read); false) in
        check bool "actual reader entered before cancellation" true did_enter;
        Eio.Cancel.cancel cancel Cancel_plain_read;
        release ();
        match Eio.Promise.await outcome with
        | Read_cancelled -> ()
        | Read_returned -> fail "cancelled plain read returned a result"));
    assert_closed (Atomic.get descriptor);
    check bool "cancelled reader released mutex" true
      (Fs.Locked_read_for_testing.path_mutex_available path);
    check string "cancellation leaves bytes untouched" "unchanged\n" (Fs.load_file path))) readers))

let () = run "Plain reads under append mutex"
  ["plain read", [
    test_case "bytes, raw lines, final fragments and plain path policy" `Quick test_plain_contracts;
    test_case "canonical mutex and descriptor settlement" `Quick test_mutex_and_settlement;
    test_case "opened descriptor survives pathname replacement" `Quick test_descriptor_survives_replacement;
    test_case "Eio dispatch with and without global filesystem" `Quick test_eio_dispatch;
    test_case "cancellation is delivered after cleanup" `Quick test_cancellation_after_cleanup]]
