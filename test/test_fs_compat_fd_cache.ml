(** RFC-0162 §3.4 — [Fs_compat.append_jsonl] per-path fd cache tests.

    The fd cache is a behaviour-preserving optimisation: the
    Record-interleave-0 and partial-write-0 guarantees must continue
    to hold. We re-run the canonical stress cases (16-thread
    concurrent records, 4 KB PIPE_BUF-busting records, multibyte
    boundary) against the cached path and additionally verify the
    lifecycle helper ([reset_fd_cache_for_testing]). *)

open Alcotest

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "%s_%d_%d_%.0f"
         prefix
         !counter
         (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  Unix.mkdir dir 0o755;
  dir
;;

let read_lines path =
  if not (Sys.file_exists path)
  then []
  else (
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let buf = Buffer.create 4096 in
        (try
           while true do
             Buffer.add_channel buf ic 4096
           done
         with
         | End_of_file -> ());
        let content = Buffer.contents buf in
        String.split_on_char '\n' content |> List.filter (fun s -> s <> "")))
;;

(* Re-run the canonical 16-fiber stress, now over the cached path.
   The cache must NOT degrade the existing Record-interleave-0
   guarantee. *)
let test_concurrent_multibyte_records () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_multibyte" in
  let path = Filename.concat dir "out.jsonl" in
  let n_threads = 16 in
  let n_records_per_thread = 100 in
  let threads =
    List.init n_threads (fun tid ->
      Thread.create
        (fun () ->
          for seq = 0 to n_records_per_thread - 1 do
            let kor_count = 100 + (seq mod 300) in
            let kor =
              String.concat "" (List.init kor_count (fun _ -> "가"))
            in
            let json =
              `Assoc
                [ "tid", `Int tid; "seq", `Int seq; "k", `String kor ]
            in
            Fs_compat.append_jsonl path json
          done)
        ())
  in
  List.iter Thread.join threads;
  let lines = read_lines path in
  check
    int
    "line count == threads × records"
    (n_threads * n_records_per_thread)
    (List.length lines);
  let seen = Hashtbl.create (n_threads * n_records_per_thread) in
  List.iter
    (fun line ->
      let json =
        try Yojson.Safe.from_string line with
        | e ->
          failf
            "invalid JSON (len=%d): %s\nfirst bytes: %S"
            (String.length line)
            (Printexc.to_string e)
            (if String.length line > 60 then String.sub line 0 60 else line)
      in
      let open Yojson.Safe.Util in
      let tid = json |> member "tid" |> to_int in
      let seq = json |> member "seq" |> to_int in
      let key = tid, seq in
      if Hashtbl.mem seen key then failf "duplicate record: tid=%d seq=%d" tid seq;
      Hashtbl.add seen key ())
    lines;
  check
    int
    "unique (tid, seq) pairs"
    (n_threads * n_records_per_thread)
    (Hashtbl.length seen)
;;

(* PIPE_BUF-busting record (>4 KB). With per-domain fds an early RFC
   draft would have interleaved here; per-path cache must serialise. *)
let test_large_records_no_interleave () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_large" in
  let path = Filename.concat dir "out.jsonl" in
  let n_threads = 8 in
  let n_records_per_thread = 60 in
  let big_payload =
    String.init 5_000 (fun i -> Char.chr (33 + (i mod 90)))
  in
  let threads =
    List.init n_threads (fun tid ->
      Thread.create
        (fun () ->
          for seq = 0 to n_records_per_thread - 1 do
            let json =
              `Assoc
                [ "tid", `Int tid
                ; "seq", `Int seq
                ; "big", `String big_payload
                ]
            in
            Fs_compat.append_jsonl path json
          done)
        ())
  in
  List.iter Thread.join threads;
  let lines = read_lines path in
  check
    int
    "line count == threads × records (large records)"
    (n_threads * n_records_per_thread)
    (List.length lines);
  List.iter
    (fun line ->
      let _ =
        try Yojson.Safe.from_string line with
        | e ->
          failf
            "interleaved large record (len=%d): %s"
            (String.length line)
            (Printexc.to_string e)
      in
      ())
    lines
;;

(* Cache lifecycle: [reset_fd_cache_for_testing] must close the cached
   fd, and a subsequent append must re-open without losing data. *)
let test_reset_then_continue_writing () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_reset" in
  let path = Filename.concat dir "out.jsonl" in
  Fs_compat.append_jsonl path (`Assoc [ "phase", `String "before" ]);
  Fs_compat.reset_fd_cache_for_testing ();
  Fs_compat.append_jsonl path (`Assoc [ "phase", `String "after" ]);
  let lines = read_lines path in
  check int "both pre- and post-reset records persisted" 2 (List.length lines)
;;

(* LRU eviction: write to many paths so the cache must evict; the
   data on every path must still be intact. *)
let test_lru_evict_preserves_data () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_lru" in
  (* Slightly above the cache's 32 places to force at least a few evictions. *)
  let n_paths = 40 in
  let paths = List.init n_paths (fun i ->
    Filename.concat dir (Printf.sprintf "p_%03d.jsonl" i))
  in
  List.iter
    (fun p ->
      Fs_compat.append_jsonl p (`Assoc [ "p", `String p ]))
    paths;
  List.iter
    (fun p ->
      let lines = read_lines p in
      check int (Printf.sprintf "path %s preserved 1 record" p) 1 (List.length lines))
    paths
;;

(* Record-interleave-0 over the cached [append_file_unix] path.
   task-196 reinstated the fd cache for [append_file_unix]; this
   stress re-runs the canonical 16-thread case against that path so the
   cache must not degrade the existing guarantee. *)
let test_append_file_unix_concurrent_records () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_append_file" in
  let path = Filename.concat dir "out.log" in
  let n_threads = 16 in
  let n_records_per_thread = 100 in
  let threads =
    List.init n_threads (fun tid ->
      Thread.create
        (fun () ->
          for seq = 0 to n_records_per_thread - 1 do
            Fs_compat.append_file path (Printf.sprintf "%d:%d\n" tid seq)
          done)
        ())
  in
  List.iter Thread.join threads;
  let lines = read_lines path in
  check
    int
    "line count == threads × records (append_file_unix)"
    (n_threads * n_records_per_thread)
    (List.length lines);
  let seen = Hashtbl.create (n_threads * n_records_per_thread) in
  List.iter
    (fun line ->
      match String.split_on_char ':' line with
      | [ tid_s; seq_s ] ->
        let tid = int_of_string tid_s in
        let seq = int_of_string seq_s in
        let key = tid, seq in
        if Hashtbl.mem seen key
        then failf "duplicate record: tid=%d seq=%d" tid seq;
        Hashtbl.add seen key ()
      | _ -> failf "interleaved/corrupt record: %S" line)
    lines;
  check
    int
    "unique (tid, seq) pairs (append_file_unix)"
    (n_threads * n_records_per_thread)
    (Hashtbl.length seen)
;;

let test_lru_evict_skips_active_writer () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_active" in
  let active_path = Filename.concat dir "active.jsonl" in
  let ready = Atomic.make false in
  let release = Atomic.make false in
  let worker_error = Atomic.make None in
  let worker =
    Thread.create
      (fun () ->
         try
           Fs_compat.with_cached_writer_for_testing active_path (fun fd ->
             let write line =
               let written = Unix.write_substring fd line 0 (String.length line) in
               if written <> String.length line then failwith "short write"
             in
             write "{\"phase\":\"before\"}\n";
             Atomic.set ready true;
             while not (Atomic.get release) do
               Thread.yield ()
             done;
             write "{\"phase\":\"after\"}\n")
         with exn -> Atomic.set worker_error (Some (Printexc.to_string exn)))
      ()
  in
  while not (Atomic.get ready) do
    Thread.yield ()
  done;
  for i = 0 to 40 do
    let path = Filename.concat dir (Printf.sprintf "other_%02d.jsonl" i) in
    Fs_compat.append_jsonl path (`Assoc [ "i", `Int i ])
  done;
  Atomic.set release true;
  Thread.join worker;
  (match Atomic.get worker_error with
   | Some msg -> failf "active writer was closed during LRU eviction: %s" msg
   | None -> ());
  let lines = read_lines active_path in
  check int "active writer kept both records" 2 (List.length lines)
;;

let test_deleted_path_reopens () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_deleted" in
  let path = Filename.concat dir "out.jsonl" in
  Fs_compat.append_jsonl path (`Int 1);
  Sys.remove path;
  Fs_compat.append_jsonl path (`Int 2);
  check (list string) "new append is visible after unlink" [ "2" ] (read_lines path)
;;

let test_replaced_path_reopens () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_replaced" in
  let path = Filename.concat dir "out.jsonl" in
  let old = Filename.concat dir "old.jsonl" in
  let replacement = Filename.concat dir "replacement.jsonl" in
  Fs_compat.append_jsonl path (`Int 1);
  Unix.link path old;
  Out_channel.with_open_bin replacement (fun oc -> output_string oc "2\n");
  Unix.rename replacement path;
  Fs_compat.append_jsonl path (`Int 3);
  check (list string) "append follows replacement" [ "2"; "3" ] (read_lines path);
  check (list string) "retired inode receives no new record" [ "1" ] (read_lines old)
;;

(* #52980. No byte of a failed append reaches the file later: not with the
   next append and not when the cached descriptor is closed. Before, the
   cached [out_channel] kept the unwritten bytes in its buffer and wrote them
   on the next flush or close. Bytes a partial write did put in the file are
   removed again when they are the file's last and nobody else's. *)

module Whole = Fs_compat_internal.Fd_append_whole

let read_all path = In_channel.with_open_bin path In_channel.input_all
let no_space () = raise (Unix.Unix_error (Unix.ENOSPC, "write", ""))

(* The real write, limited to [budget] more bytes in total. Once they are
   used up every write fails the way a full disk does. *)
let io_failing_after budget =
  let left = ref budget in
  { Whole.unix_io with
    write =
      (fun fd content offset length ->
        if !left = 0
        then no_space ()
        else (
          let written =
            Unix.single_write_substring fd content offset (min length !left)
          in
          left := !left - written;
          written))
  }
;;

let failing_append ?(start = Whole.Anywhere) ~io path content =
  match Fs_compat.append_file_unix_with_io_for_testing ~io ~start path content with
  | () -> fail "the append was expected to fail"
  | exception Sys_error message -> message
;;

let fail_append ?start ~budget path content =
  ignore (failing_append ?start ~io:(io_failing_after budget) path content : string)
;;

(* One [Whole.run] on a descriptor of its own, for the typed result. *)
let run_on_own_descriptor ~io ~start path content =
  let target = Whole.open_target path in
  Fun.protect
    ~finally:(fun () -> Unix.close (Whole.descriptor target))
    (fun () -> Whole.run ~io ~start target content)
;;

let describe = function
  | Ok () -> "Ok"
  | Error failure -> Whole.failure_to_string failure
;;

let row_0 = "{\"row\":0}\n"
let row_a = "{\"row\":\"A\"}\n"
let row_a2 = "{\"row\":\"A2\"}\n"
let row_b = "{\"row\":\"B\"}\n"

let failed_append_file name =
  Fs_compat.reset_fd_cache_for_testing ();
  let path = Filename.concat (tmpdir "fd_cache_failed_append") name in
  Fs_compat.append_file path row_0;
  path
;;

let test_failed_append_without_bytes_leaves_nothing () =
  let path = failed_append_file "no-bytes.jsonl" in
  let io = io_failing_after 0 in
  (match run_on_own_descriptor ~io ~start:Whole.Anywhere path row_a with
   | Error (Whole.Write_failed { rollback = Whole.Nothing_written; _ }) -> ()
   | other -> failf "expected nothing written, got: %s" (describe other));
  fail_append ~budget:0 path row_a;
  check string "file after the failed append" row_0 (read_all path);
  Fs_compat.append_file path row_b;
  check string "the next append adds its own row only" (row_0 ^ row_b) (read_all path)
;;

let test_failed_append_with_bytes_is_rolled_back () =
  let path = failed_append_file "some-bytes.jsonl" in
  fail_append ~budget:4 path row_a;
  check string "the four written bytes are removed again" row_0 (read_all path);
  Fs_compat.append_file path row_b;
  check string "the next append starts where the file ended" (row_0 ^ row_b) (read_all path)
;;

let test_failed_append_is_not_written_on_close () =
  let path = failed_append_file "close.jsonl" in
  fail_append ~budget:4 path row_a;
  Fs_compat.reset_fd_cache_for_testing ();
  check string "closing the cached descriptor writes nothing" row_0 (read_all path)
;;

let test_repeated_failed_appends_do_not_pile_up () =
  let path = failed_append_file "repeated.jsonl" in
  fail_append ~budget:4 path row_a;
  fail_append ~budget:6 path row_a2;
  check string "file after two failed appends" row_0 (read_all path);
  Fs_compat.append_file path row_b;
  check string "only the append that succeeded is in the file" (row_0 ^ row_b) (read_all path)
;;

let test_rollback_result_names_the_bytes () =
  let path = failed_append_file "typed.jsonl" in
  (match run_on_own_descriptor ~io:(io_failing_after 4) ~start:Whole.Anywhere path row_a with
   | Error
       (Whole.Write_failed
         { rollback = Whole.Rolled_back { bytes = 4 }
         ; write_failure =
             Fs_compat_internal.Fd_write_all.Unix_error
               { bytes_written = 4; error = Unix.ENOSPC; _ }
         }) -> ()
   | other -> failf "expected 4 bytes rolled back, got: %s" (describe other));
  check string "the file is as it was" row_0 (read_all path)
;;

(* More than one [write(2)]: [Unix.single_write] sends at most 65536 bytes. *)
let test_rollback_spans_several_writes () =
  let path = failed_append_file "several-writes.jsonl" in
  let content = String.make 149_999 'x' ^ "\n" in
  (match
     run_on_own_descriptor ~io:(io_failing_after 100_000) ~start:Whole.Anywhere path content
   with
   | Error (Whole.Write_failed { rollback = Whole.Rolled_back { bytes = 100_000 }; _ }) -> ()
   | other -> failf "expected 100000 bytes rolled back, got: %s" (describe other));
  check string "the file is as it was" row_0 (read_all path)
;;

(* When the truncation fails the bytes stay, and the result says so. *)
let io_whose_truncate_fails ~budget attempts =
  { (io_failing_after budget) with
    truncate =
      (fun _ _ ->
        incr attempts;
        raise (Unix.Unix_error (Unix.EIO, "ftruncate", "")))
  }
;;

let test_failed_rollback_is_reported () =
  let path = failed_append_file "rollback-fails.jsonl" in
  let attempts = ref 0 in
  let failure =
    match
      run_on_own_descriptor
        ~io:(io_whose_truncate_fails ~budget:4 attempts)
        ~start:Whole.Anywhere
        path
        row_a
    with
    | Error
        (Whole.Write_failed
          { rollback =
              Whole.Not_rolled_back
                { bytes = 4
                ; reason =
                    Whole.Rollback_error
                      { error = Unix.EIO; function_name = "ftruncate"; _ }
                }
          ; _
          } as failure) -> failure
    | other -> failf "expected 4 bytes left after a failed truncation, got: %s" (describe other)
  in
  check int "the truncation was tried once" 1 !attempts;
  let left = row_0 ^ String.sub row_a 0 4 in
  check string "the partial bytes are still there" left (read_all path);
  (* The same failure through the cached path: its message is the path and
     this result's text. *)
  let cached = failed_append_file "rollback-fails-cached.jsonl" in
  let message =
    failing_append ~io:(io_whose_truncate_fails ~budget:4 (ref 0)) cached row_a
  in
  check
    string
    "the error names the path and says the bytes were left"
    (Fs_compat.canonical_append_mutex_path_for_testing cached
     ^ ": "
     ^ Whole.failure_to_string failure)
    message;
  check string "the partial bytes are still there" left (read_all cached)
;;

(* What a writer in another process does: its own descriptor, the same
   append. *)
let append_as_another_writer path lines =
  match run_on_own_descriptor ~io:Whole.unix_io ~start:Whole.At_line_start path lines with
  | Ok () -> ()
  | Error failure -> failf "the other writer failed: %s" (Whole.failure_to_string failure)
;;

(* The rollback removes only bytes it can tell are this call's. A row another
   writer appended during the failed call makes the file longer than this
   call's bytes account for, so nothing is truncated and that row stays. *)
let test_another_writers_row_survives_a_failed_append () =
  let path = failed_append_file "another-writer.jsonl" in
  let writes = ref 0 in
  let io =
    { Whole.unix_io with
      write =
        (fun fd content offset length ->
          incr writes;
          if !writes > 1
          then no_space ()
          else (
            let written = Unix.single_write_substring fd content offset (min length 4) in
            append_as_another_writer path row_b;
            written))
    }
  in
  let torn = String.sub row_a 0 4 in
  let expected_size = String.length row_0 + 4 in
  let size = expected_size + 1 + String.length row_b in
  (match run_on_own_descriptor ~io ~start:Whole.At_line_start path row_a with
   | Error
       (Whole.Write_failed
         { rollback =
             Whole.Not_rolled_back
               { bytes = 4
               ; reason = Whole.Changed_by_another_writer { expected_size = e; size = s }
               }
         ; _
         })
     when e = expected_size && s = size -> ()
   | other -> failf "expected the bytes left for another writer, got: %s" (describe other));
  check
    string
    "the other writer's row is whole, on a line of its own"
    (row_0 ^ torn ^ "\n" ^ row_b)
    (read_all path);
  Fs_compat.append_lines path row_a2;
  check
    string
    "the next row follows it"
    (row_0 ^ torn ^ "\n" ^ row_b ^ row_a2)
    (read_all path)
;;

(* A real failed write: the kernel stops the write at the process's file
   size limit and fails the next one. The probe is this executable again,
   started under [ulimit -f]. *)
let file_size_limit_probe path bytes =
  (* Past the limit the kernel also sends SIGXFSZ, which ends the process
     unless it is ignored. *)
  Sys.set_signal Sys.sigxfsz Sys.Signal_ignore;
  let content = String.make (bytes - 1) 'x' ^ "\n" in
  match run_on_own_descriptor ~io:Whole.unix_io ~start:Whole.At_line_start path content with
  | Error (Whole.Write_failed { rollback = Whole.Rolled_back { bytes }; _ }) when bytes > 0 ->
    exit 0
  | other ->
    prerr_endline ("file size limit probe: " ^ describe other);
    exit 3
;;

let test_real_failed_write_is_rolled_back ~limit_kib ~bytes () =
  let path = failed_append_file "file-size-limit.jsonl" in
  Fs_compat.reset_fd_cache_for_testing ();
  let script =
    Printf.sprintf
      "set +o posix && builtin ulimit -S -f %d && exec %s --file-size-limit-probe %s %d"
      limit_kib
      (Filename.quote (Unix.realpath Sys.executable_name))
      (Filename.quote path)
      bytes
  in
  (match Unix.system ("/bin/bash -c " ^ Filename.quote script) with
   | Unix.WEXITED 0 -> ()
   | Unix.WEXITED code -> failf "the probe exited with %d" code
   | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> failf "the probe got signal %d" signal);
  check string "the file is as it was before the failed append" row_0 (read_all path)
;;

(* A FIFO has no last byte to read and its bytes cannot be taken back. *)
let test_stream_is_written_as_it_is () =
  let path = Filename.concat (tmpdir "fd_cache_stream") "out.fifo" in
  Unix.mkfifo path 0o600;
  let reader = Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
  let target = Whole.open_target path in
  Fun.protect
    ~finally:(fun () ->
      Unix.close (Whole.descriptor target);
      Unix.close reader)
    (fun () ->
      (match target with
       | Whole.Stream _ -> ()
       | Whole.Regular_file _ -> fail "a FIFO was opened as a regular file");
      (match Whole.run ~io:Whole.unix_io ~start:Whole.At_line_start target row_a with
       | Ok () -> ()
       | Error failure -> failf "append to a FIFO: %s" (Whole.failure_to_string failure));
      (match Whole.run ~io:(io_failing_after 2) ~start:Whole.At_line_start target row_b with
       | Error
           (Whole.Write_failed
             { rollback =
                 Whole.Not_rolled_back { bytes = 2; reason = Whole.Not_a_regular_file }
             ; _
             }) -> ()
       | other -> failf "expected 2 bytes left in the FIFO, got: %s" (describe other));
      let received = Bytes.create 64 in
      let count = Unix.read reader received 0 64 in
      check
        string
        "the row and the two bytes of the failed one arrived"
        (row_a ^ String.sub row_b 0 2)
        (Bytes.sub_string received 0 count))
;;

(* The descriptor is [O_APPEND]: a row another writer added after this call
   looked at the end of the file is not written over. *)
let test_append_lands_after_another_writers_row () =
  let lands_after name start io_for =
    let path = failed_append_file name in
    (match run_on_own_descriptor ~io:(io_for path) ~start path row_a with
     | Ok () -> ()
     | other -> failf "expected the append to succeed, got: %s" (describe other));
    check string "both rows are whole" (row_0 ^ row_b ^ row_a) (read_all path)
  in
  lands_after "after-length.jsonl" Whole.Anywhere (fun path ->
    { Whole.unix_io with
      end_offset =
        (fun fd ->
          let size = Whole.unix_io.end_offset fd in
          append_as_another_writer path row_b;
          size)
    });
  lands_after "after-last-byte.jsonl" Whole.At_line_start (fun path ->
    { Whole.unix_io with
      last_byte =
        (fun fd ~size ->
          let byte = Whole.unix_io.last_byte fd ~size in
          append_as_another_writer path row_b;
          byte)
    })
;;

(* A file that became shorter during the failed call is left as it is: the
   rollback does not grow it back to its old length. *)
let test_file_found_shorter_is_left_as_it_is () =
  let path = failed_append_file "shorter.jsonl" in
  let writes = ref 0 in
  let io =
    { Whole.unix_io with
      write =
        (fun fd content offset length ->
          incr writes;
          if !writes > 1
          then no_space ()
          else (
            let written = Unix.single_write_substring fd content offset (min length 4) in
            Unix.truncate path 3;
            written))
    }
  in
  let expected_size = String.length row_0 + 4 in
  (match run_on_own_descriptor ~io ~start:Whole.Anywhere path row_a with
   | Error
       (Whole.Write_failed
         { rollback =
             Whole.Not_rolled_back
               { bytes = 4
               ; reason = Whole.Changed_by_another_writer { expected_size = e; size = 3 }
               }
         ; _
         })
     when e = expected_size -> ()
   | other -> failf "expected nothing removed from a shorter file: %s" (describe other));
  check string "the file keeps its three bytes" (String.sub row_0 0 3) (read_all path)
;;

let interrupt name = raise (Unix.Unix_error (Unix.EINTR, name, ""))

(* A truncation that was interrupted is judged by the file's length: whether
   it had cut the file or not, the bytes end up removed and reported so. *)
let test_interrupted_rollback_is_finished () =
  List.iter
    (fun (name, cut_before_interrupt) ->
      let path = failed_append_file name in
      let first = ref true in
      let io =
        { (io_failing_after 4) with
          truncate =
            (fun fd length ->
              if !first
              then (
                first := false;
                if cut_before_interrupt then Unix.ftruncate fd length;
                interrupt "ftruncate")
              else Unix.ftruncate fd length)
        }
      in
      (match run_on_own_descriptor ~io ~start:Whole.Anywhere path row_a with
       | Error (Whole.Write_failed { rollback = Whole.Rolled_back { bytes = 4 }; _ }) ->
         ()
       | other -> failf "expected 4 bytes rolled back, got: %s" (describe other));
      check string "the file is as it was" row_0 (read_all path))
    [ "interrupted-before-cut.jsonl", false; "interrupted-after-cut.jsonl", true ]
;;

(* The length read that follows an interrupted truncation is interrupted
   too. The rollback still knows that its truncation was interrupted, so the
   file found at its old length is reported as rolled back. *)
let test_interrupted_length_read_keeps_the_interrupted_truncation () =
  let path = failed_append_file "interrupted-twice.jsonl" in
  let truncated = ref false in
  let length_read_interrupted = ref false in
  let io =
    { (io_failing_after 4) with
      truncate =
        (fun fd length ->
          if !truncated
          then Unix.ftruncate fd length
          else (
            truncated := true;
            Unix.ftruncate fd length;
            interrupt "ftruncate"))
    ; end_offset =
        (fun fd ->
          if !truncated && not !length_read_interrupted
          then (
            length_read_interrupted := true;
            interrupt "lseek")
          else Whole.unix_io.end_offset fd)
    }
  in
  (match run_on_own_descriptor ~io ~start:Whole.Anywhere path row_a with
   | Error (Whole.Write_failed { rollback = Whole.Rolled_back { bytes = 4 }; _ }) -> ()
   | other -> failf "expected 4 bytes rolled back, got: %s" (describe other));
  check bool "the length read was interrupted" true !length_read_interrupted;
  check string "the file is as it was" row_0 (read_all path)
;;

(* The file is back at its old length, and not by this call's truncation:
   another writer cut the bytes. The call did not remove them and says so. *)
let test_bytes_another_writer_cut_are_not_reported_as_removed () =
  let path = failed_append_file "cut-by-another.jsonl" in
  let size_before = String.length row_0 in
  let writes = ref 0 in
  let io =
    { Whole.unix_io with
      write =
        (fun fd content offset length ->
          incr writes;
          if !writes > 1
          then (
            Unix.truncate path size_before;
            no_space ())
          else Unix.single_write_substring fd content offset (min length 4))
    }
  in
  (match run_on_own_descriptor ~io ~start:Whole.Anywhere path row_a with
   | Error
       (Whole.Write_failed
         { rollback =
             Whole.Not_rolled_back
               { bytes = 4
               ; reason = Whole.Changed_by_another_writer { expected_size; size }
               }
         ; _
         })
     when expected_size = size_before + 4 && size = size_before -> ()
   | other -> failf "expected the bytes reported as not removed: %s" (describe other));
  check string "the file is as the other writer left it" row_0 (read_all path)
;;

exception Stop_writing

(* An exception that is not a system error leaves the append as it is, after
   the bytes written before it were taken back. *)
let test_other_exception_passes_through () =
  let path = failed_append_file "other-exception.jsonl" in
  let writes = ref 0 in
  let io =
    { Whole.unix_io with
      write =
        (fun fd content offset length ->
          incr writes;
          if !writes > 1
          then raise Stop_writing
          else Unix.single_write_substring fd content offset (min length 4))
    }
  in
  let append = Fs_compat.append_file_unix_with_io_for_testing ~io ~start:Whole.Anywhere in
  (match append path row_a with
   | () -> fail "the append was expected to fail"
   | exception Stop_writing -> ());
  check string "the bytes written before it are removed" row_0 (read_all path)
;;

let test_open_failure_names_the_path () =
  Fs_compat.reset_fd_cache_for_testing ();
  let plain_file = Filename.concat (tmpdir "fd_cache_open_failure") "plain" in
  Out_channel.with_open_bin plain_file (fun channel -> output_string channel "x");
  let path = Filename.concat plain_file "x.jsonl" in
  match
    Fs_compat.append_file_unix_with_io_for_testing
      ~io:Whole.unix_io
      ~start:Whole.At_line_start
      path
      row_a
  with
  | () -> fail "the append was expected to fail"
  | exception Sys_error message ->
    let prefix = Fs_compat.canonical_append_mutex_path_for_testing path ^ ": " in
    if not (String.starts_with ~prefix message)
    then failf "the error does not start with the path: %s" message
;;

(* The descriptor is close-on-exec, so a child process does not hold the
   file open. A FIFO shows it: its reader sees the end of the stream only
   when no process has it open for writing any more. *)
let test_child_process_does_not_inherit_the_descriptor () =
  let path = Filename.concat (tmpdir "fd_cache_cloexec") "out.fifo" in
  Unix.mkfifo path 0o600;
  let reader = Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close reader)
    (fun () ->
      let target = Whole.open_target path in
      let child =
        Fun.protect
          ~finally:(fun () -> Unix.close (Whole.descriptor target))
          (fun () ->
            Unix.create_process
              "sleep"
              [| "sleep"; "60" |]
              Unix.stdin
              Unix.stdout
              Unix.stderr)
      in
      Fun.protect
        ~finally:(fun () ->
          Unix.kill child Sys.sigkill;
          ignore (Unix.waitpid [] child : int * Unix.process_status))
        (fun () ->
          match Unix.select [ reader ] [] [] 5.0 with
          | [], _, _ -> fail "a writer is still open after this process closed its own"
          | _ :: _, _, _ ->
            let read = Unix.read reader (Bytes.create 1) 0 1 in
            check int "the reader is at the end of the stream" 0 read))
;;

let wait_until condition =
  let deadline = Unix.gettimeofday () +. 10.0 in
  let rec poll () =
    if condition ()
    then true
    else if Unix.gettimeofday () > deadline
    then false
    else (
      Thread.delay 0.01;
      poll ())
  in
  poll ()
;;

let listed_descriptors () =
  Sys.readdir "/dev/fd" |> Array.to_list |> List.filter_map int_of_string_opt
;;

(* Waits until [count] opens of this process are inside the system call, and
   says whether that came about.

   An open takes its descriptor number, the lowest one free, before it
   waits, and [/dev/fd] lists the number only once the open is over. A
   listing is read through a descriptor of its own, taken the same way, so
   every number below that one is taken: it is listed, or an open still in
   the call holds it. The listing's own number is the largest one that the
   listing before it did not hold.

   Each round keeps one more descriptor open. It takes the number the last
   listing gave back. Without it an open that started during a listing
   would sit above a free number, where no later listing counts it.

   A number missing from one listing is not yet an open that waits: an open
   that goes straight through holds its number for an instant, and so does a
   number another thread has just closed. So the same numbers have to be
   missing from two listings that are [settled_seconds] apart. *)
let settled_seconds = 0.02

let wait_for_opens_in_the_call count =
  let kept = ref [] in
  Fun.protect
    ~finally:(fun () -> List.iter Unix.close !kept)
    (fun () ->
      let deadline = Unix.gettimeofday () +. 10.0 in
      let rec poll before missing_before =
        kept := Unix.openfile "/dev/null" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 :: !kept;
        let now = listed_descriptors () in
        let own =
          List.filter (fun number -> not (List.mem number before)) now
          |> List.fold_left max 0
        in
        let missing =
          List.init own Fun.id |> List.filter (fun number -> not (List.mem number now))
        in
        if List.length missing = count && missing_before = Some missing
        then true
        else if Unix.gettimeofday () > deadline
        then false
        else (
          Thread.delay settled_seconds;
          poll now (Some missing))
      in
      poll (listed_descriptors ()) None)
;;

(* A FIFO is opened for writing only, so the open waits for a reader. That
   wait belongs to the FIFO's path: an append to another file goes through. *)
let test_fifo_open_waits_and_holds_up_no_other_path () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_fifo_wait" in
  let fifo = Filename.concat dir "out.fifo" in
  let other = Filename.concat dir "other.jsonl" in
  Unix.mkfifo fifo 0o600;
  let fifo_result = Atomic.make None in
  let other_result = Atomic.make None in
  let appending path row result =
    Thread.create
      (fun () ->
        Atomic.set
          result
          (Some
             (match Fs_compat.append_lines path row with
              | () -> Ok ()
              | exception Sys_error message -> Error message)))
      ()
  in
  let finished result = Option.is_some (Atomic.get result) in
  let fifo_writer = appending fifo row_a fifo_result in
  let fifo_waited = wait_for_opens_in_the_call 1 && not (finished fifo_result) in
  let other_writer = appending other row_b other_result in
  let other_went_through = wait_until (fun () -> finished other_result) in
  (* Opening the reader lets the FIFO writer go on, whatever was seen above.
     The reader does not wait itself: a writer that failed never opens. *)
  let reader = Unix.openfile fifo [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close reader)
    (fun () ->
      Thread.join fifo_writer;
      Thread.join other_writer;
      check bool "the FIFO open waited for a reader" true fifo_waited;
      check bool "the append to another file did not wait for it" true other_went_through;
      let succeeded name outcome =
        check (option (result unit string)) name (Some (Ok ())) (Atomic.get outcome)
      in
      succeeded "the append to the FIFO succeeded" fifo_result;
      succeeded "the append to the other file succeeded" other_result;
      let received = Bytes.create 64 in
      let count = Unix.read reader received 0 64 in
      check string "the row reached the reader" row_a (Bytes.sub_string received 0 count))
;;

(* A signal the process handles interrupts the open that waits for a FIFO's
   reader. The open is made again and the append goes on waiting, each time
   a signal comes. *)
let test_interrupted_fifo_open_is_made_again () =
  Fs_compat.reset_fd_cache_for_testing ();
  let fifo = Filename.concat (tmpdir "fd_cache_fifo_interrupted") "out.fifo" in
  Unix.mkfifo fifo 0o600;
  let handled = Atomic.make 0 in
  let previous =
    Sys.signal Sys.sigusr1 (Sys.Signal_handle (fun _ -> Atomic.incr handled))
  in
  (* Only the appending thread takes the signal. *)
  let (_ : int list) = Thread.sigmask Unix.SIG_BLOCK [ Sys.sigusr1 ] in
  let outcome = Atomic.make None in
  let writer =
    Thread.create
      (fun () ->
        let (_ : int list) = Thread.sigmask Unix.SIG_UNBLOCK [ Sys.sigusr1 ] in
        Atomic.set
          outcome
          (Some
             (match Fs_compat.append_lines fifo row_a with
              | () -> Ok ()
              | exception Sys_error message -> Error message)))
      ()
  in
  (* The signal is sent while the append is inside the open. Its handler
     runs in the appending thread, which is back in OCaml code only once
     that open has returned. *)
  let interrupt_the_open nth =
    let waiting = wait_for_opens_in_the_call 1 in
    Unix.kill (Unix.getpid ()) Sys.sigusr1;
    waiting && wait_until (fun () -> Atomic.get handled = nth)
  in
  let interrupted_once = interrupt_the_open 1 in
  let interrupted_twice = interrupt_the_open 2 in
  let still_waiting =
    wait_for_opens_in_the_call 1 && Option.is_none (Atomic.get outcome)
  in
  let reader = Unix.openfile fifo [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close reader;
      let (_ : int list) = Thread.sigmask Unix.SIG_UNBLOCK [ Sys.sigusr1 ] in
      Sys.set_signal Sys.sigusr1 previous)
    (fun () ->
      Thread.join writer;
      check bool "a signal interrupted the open" true interrupted_once;
      check bool "a second signal interrupted the open made again" true interrupted_twice;
      check bool "the append still waited after the signals" true still_waiting;
      check
        (option (result unit string))
        "the append succeeded"
        (Some (Ok ()))
        (Atomic.get outcome))
;;

let kind_swap_seconds = 0.3

(* The path changes between a regular file and a FIFO while it is opened
   again and again. Whatever [open_target] returns was opened the way its
   kind needs: a regular file can be read, anything else is write-only.

   The path is a hard link that another hard link is renamed over, so an
   open finds one inode or the other. A symbolic link renamed over would
   bring a failure of its own: on ext4 an open with O_CREAT through such a
   link fails now and then with EISDIR. Hard links do not. *)
let test_open_matches_the_kind_under_a_changing_path () =
  let dir = tmpdir "fd_cache_kind_swap" in
  let regular = Filename.concat dir "regular" in
  Out_channel.with_open_bin regular (fun channel -> output_string channel "r\n");
  let fifo = Filename.concat dir "fifo" in
  Unix.mkfifo fifo 0o600;
  (* An open of a FIFO for writing waits for a reader. This one is there for
     the whole test. *)
  let fifo_reader =
    Unix.openfile fifo [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0
  in
  let path = Filename.concat dir "swapped" in
  let staged = Filename.concat dir "swapped.next" in
  Unix.link regular path;
  let stop = Atomic.make false in
  (* What ended the swapping before it was told to stop. An exception leaves
     a thread without reaching anyone, and the opens below would go on, and
     pass, against a path that no longer changes. *)
  let swapping_ended_by = Atomic.make None in
  let swapper =
    Thread.create
      (fun () ->
        (* The two links always name different files: a rename of one hard
           link over another of the same file does nothing. *)
        let to_regular = ref false in
        try
          while not (Atomic.get stop) do
            Unix.link (if !to_regular then regular else fifo) staged;
            Unix.rename staged path;
            to_regular := not !to_regular
          done
        with
        | exn -> Atomic.set swapping_ended_by (Some exn))
      ()
  in
  let byte = Bytes.create 1 in
  (* A descriptor that can be read answers a read, with a byte or with "none
     yet". One opened for writing only refuses it. The read does not wait: a
     FIFO opened for reading too would wait for a byte from itself. *)
  let readable fd =
    Unix.set_nonblock fd;
    match Unix.read fd byte 0 1 with
    | (_ : int) -> true
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> true
    | exception Unix.Unix_error (Unix.EBADF, _, _) -> false
  in
  let wrong = ref 0 in
  let deadline = Unix.gettimeofday () +. kind_swap_seconds in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set stop true;
      Thread.join swapper;
      Unix.close fifo_reader)
    (fun () ->
      while Unix.gettimeofday () < deadline do
        let target = Whole.open_target path in
        let fd = Whole.descriptor target in
        let is_regular_file =
          match (Unix.fstat fd).Unix.st_kind with
          | Unix.S_REG -> true
          | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK
            -> false
        in
        let as_its_kind_needs =
          match target with
          | Whole.Regular_file _ -> is_regular_file && readable fd
          | Whole.Stream _ -> (not is_regular_file) && not (readable fd)
        in
        Unix.close fd;
        if not as_its_kind_needs then incr wrong
      done);
  (match Atomic.get swapping_ended_by with
   | None -> ()
   | Some exn -> failf "the path stopped changing: %s" (Printexc.to_string exn));
  check int "targets opened another way than their kind needs" 0 !wrong
;;

(* The places of the cache. Descriptors are counted from outside, as the
   entries of [/dev/fd]: the cache has no counter to read. *)
let open_descriptors () = Array.length (Sys.readdir "/dev/fd")

(* [Fd_cache.max_entries]. *)
let cache_bound = 32
let numbered_path dir i = Filename.concat dir (Printf.sprintf "p_%02d.jsonl" i)

let fill_cache dir =
  for i = 1 to cache_bound do
    Fs_compat.append_jsonl (numbered_path dir i) (`Int i)
  done
;;

(* Reads what is in the FIFO and says whether its stream then ends: it does
   once no descriptor has the FIFO open for writing. *)
let stream_ended reader =
  let buffer = Bytes.create 256 in
  let rec drain () =
    match Unix.select [ reader ] [] [] 5.0 with
    | [], _, _ -> false
    | _ :: _, _, _ ->
      (match Unix.read reader buffer 0 (Bytes.length buffer) with
       | 0 -> true
       | (_ : int) -> drain ())
  in
  drain ()
;;

(* What is in the FIFO now, without waiting for more. *)
let read_available reader =
  let buffer = Bytes.create 4096 in
  let rec read received =
    match Unix.read reader buffer 0 (Bytes.length buffer) with
    | 0 -> received
    | length -> read (received ^ Bytes.sub_string buffer 0 length)
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> received
  in
  read ""
;;

let hold_until release =
  while not (Atomic.get release) do
    Thread.delay 0.005
  done
;;

(* What reaches the FIFO until its stream ends, and whether it ended: it
   does once no descriptor has the FIFO open for writing. One pass does
   both, since a FIFO shows its end once on macOS and a second look would
   wait. *)
let read_to_the_end reader =
  let buffer = Bytes.create 4096 in
  let rec read received =
    match Unix.select [ reader ] [] [] 5.0 with
    | [], _, _ -> received, false
    | _ :: _, _, _ ->
      (match Unix.read reader buffer 0 (Bytes.length buffer) with
       | 0 -> received, true
       | length -> read (received ^ Bytes.sub_string buffer 0 length))
  in
  read ""
;;

let test_cache_closes_the_writers_it_drops () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_dropped" in
  let before = open_descriptors () in
  fill_cache dir;
  for i = cache_bound + 1 to cache_bound + 8 do
    Fs_compat.append_jsonl (numbered_path dir i) (`Int i)
  done;
  check int "descriptors the cache holds" cache_bound (open_descriptors () - before);
  Fs_compat.reset_fd_cache_for_testing ();
  check int "descriptors after the cache was emptied" 0 (open_descriptors () - before)
;;

(* A writer that is lent is never closed, so more than the bound are open
   while more than the bound are lent. They are closed as they come back. *)
let test_cache_returns_to_its_bound () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_many_lent" in
  let leases = cache_bound + 8 in
  let before = open_descriptors () in
  let lent = Atomic.make 0 in
  let release = Atomic.make false in
  let holders =
    List.init leases (fun i ->
      Thread.create
        (fun () ->
          Fs_compat.with_cached_writer_for_testing (numbered_path dir i) (fun _ ->
            Atomic.incr lent;
            hold_until release))
        ())
  in
  let all_lent = wait_until (fun () -> Atomic.get lent = leases) in
  let while_lent = open_descriptors () - before in
  Atomic.set release true;
  List.iter Thread.join holders;
  check bool "every writer was lent at once" true all_lent;
  check int "descriptors while all are lent" leases while_lent;
  check int "descriptors after they came back" cache_bound (open_descriptors () - before)
;;

(* A writer the cache drops while it is lent stays open for its caller and
   is closed when the caller returns it. *)
let test_writer_dropped_while_lent_is_closed_when_it_comes_back () =
  Fs_compat.reset_fd_cache_for_testing ();
  let path = Filename.concat (tmpdir "fd_cache_dropped_while_lent") "out.jsonl" in
  let before = open_descriptors () in
  let while_lent =
    Fs_compat.with_cached_writer_for_testing path (fun _ ->
      Fs_compat.reset_fd_cache_for_testing ();
      open_descriptors () - before)
  in
  check int "descriptors while the dropped writer is lent" 1 while_lent;
  check int "descriptors after it came back" 0 (open_descriptors () - before)
;;

(* An open that fails took a place in the cache while it ran. The place is
   free again afterwards: the cache still fills to its bound. *)
let test_failed_open_gives_its_place_back () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_failed_open" in
  let plain_file = Filename.concat dir "plain" in
  Out_channel.with_open_bin plain_file (fun channel -> output_string channel "x");
  for _ = 1 to cache_bound do
    match Fs_compat.append_lines (Filename.concat plain_file "x.jsonl") row_a with
    | () -> fail "the append was expected to fail"
    | exception Sys_error _ -> ()
  done;
  let before = open_descriptors () in
  fill_cache dir;
  check int "descriptors the cache holds" cache_bound (open_descriptors () - before)
;;

(* The two oldest writers are FIFOs, so their readers tell which one the
   cache closed. *)
let test_eviction_takes_the_least_recently_used_writer () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_lru_order" in
  let fifo name =
    let path = Filename.concat dir name in
    Unix.mkfifo path 0o600;
    path, Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0
  in
  let first, first_reader = fifo "first.fifo" in
  let second, second_reader = fifo "second.fifo" in
  Fun.protect
    ~finally:(fun () ->
      Unix.close first_reader;
      Unix.close second_reader)
    (fun () ->
      let before = open_descriptors () in
      Fs_compat.append_lines first row_a;
      Fs_compat.append_lines second row_a;
      for i = 3 to cache_bound do
        Fs_compat.append_jsonl (numbered_path dir i) (`Int i)
      done;
      (* [first] is used again, which leaves [second] the least recently
         used. *)
      Fs_compat.append_lines first row_b;
      Fs_compat.append_jsonl (numbered_path dir (cache_bound + 1)) (`Int 0);
      check
        int
        "one writer was closed for the new path"
        cache_bound
        (open_descriptors () - before);
      check bool "it was the least recently used one" true (stream_ended second_reader))
;;

(* Several callers open one path at the same time: the FIFO has no reader,
   so each of them waits in an open of its own. One of the descriptors is
   cached and the others are closed. Every caller is lent the cached one and
   writes its row through it: a caller left with a descriptor that was
   closed under it could not. *)
let test_callers_opening_one_path_together_share_one_writer () =
  Fs_compat.reset_fd_cache_for_testing ();
  let fifo = Filename.concat (tmpdir "fd_cache_shared_open") "out.fifo" in
  Unix.mkfifo fifo 0o600;
  let callers = 6 in
  let row_of caller = Printf.sprintf "caller-%d" caller in
  let before = open_descriptors () in
  let lent = Atomic.make 0 in
  let release = Atomic.make false in
  let write_failures = Array.make callers None in
  let holders =
    List.init callers (fun caller ->
      Thread.create
        (fun () ->
          Fs_compat.with_cached_writer_for_testing fifo (fun descriptor ->
            Atomic.incr lent;
            hold_until release;
            let line = row_of caller ^ "\n" in
            match Unix.single_write_substring descriptor line 0 (String.length line) with
            | (_ : int) -> ()
            | exception Unix.Unix_error (error, _, _) ->
              write_failures.(caller) <- Some (Unix.error_message error)))
        ())
  in
  let all_waiting = wait_for_opens_in_the_call callers in
  let none_lent_without_a_reader = Atomic.get lent = 0 in
  let reader = Unix.openfile fifo [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close reader)
    (fun () ->
      let all_lent = wait_until (fun () -> Atomic.get lent = callers) in
      let while_lent = open_descriptors () - before in
      Atomic.set release true;
      List.iter Thread.join holders;
      let after = open_descriptors () - before in
      let rows =
        read_available reader
        |> String.split_on_char '\n'
        |> List.filter (fun row -> not (String.equal row ""))
        |> List.sort String.compare
      in
      Fs_compat.reset_fd_cache_for_testing ();
      check bool "every caller waited in an open of its own" true all_waiting;
      check bool "the opens waited for the reader" true none_lent_without_a_reader;
      check bool "every caller got the writer" true all_lent;
      check int "the reader and one writer, while every caller holds it" 2 while_lent;
      check int "the reader and one writer, after they returned" 2 after;
      check
        (list (option string))
        "no caller's write failed"
        (List.init callers (fun _ -> None))
        (Array.to_list write_failures);
      check
        (list string)
        "every caller's row reached the reader"
        (List.init callers row_of)
        rows;
      check
        bool
        "no writer is open once the cache is emptied"
        true
        (stream_ended reader))
;;

(* The cache drops a writer that six callers hold, and the callers return
   one after another. The writer is closed by the last of them: a caller
   that returns earlier leaves it open for the others, which still write
   their rows. A writer lent without being counted, or a count that the
   first return clears, closes it under the callers that are left. *)
let test_dropped_writer_stays_open_until_its_last_caller_returns () =
  Fs_compat.reset_fd_cache_for_testing ();
  let fifo = Filename.concat (tmpdir "fd_cache_lease_count") "out.fifo" in
  Unix.mkfifo fifo 0o600;
  let callers = 6 in
  let row_of caller = Printf.sprintf "caller-%d" caller in
  let lent = Atomic.make 0 in
  let releases = Array.init callers (fun _ -> Atomic.make false) in
  let write_failures = Array.make callers None in
  let holders =
    List.init callers (fun caller ->
      Thread.create
        (fun () ->
          Fs_compat.with_cached_writer_for_testing fifo (fun descriptor ->
            Atomic.incr lent;
            hold_until releases.(caller);
            let line = row_of caller ^ "\n" in
            match Unix.single_write_substring descriptor line 0 (String.length line) with
            | (_ : int) -> ()
            | exception Unix.Unix_error (error, _, _) ->
              write_failures.(caller) <- Some (Unix.error_message error)))
        ())
  in
  let all_waiting = wait_for_opens_in_the_call callers in
  let reader = Unix.openfile fifo [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close reader)
    (fun () ->
      let all_lent = wait_until (fun () -> Atomic.get lent = callers) in
      Fs_compat.reset_fd_cache_for_testing ();
      List.iteri
        (fun caller holder ->
          Atomic.set releases.(caller) true;
          Thread.join holder)
        holders;
      let received, ended = read_to_the_end reader in
      let rows =
        received
        |> String.split_on_char '\n'
        |> List.filter (fun row -> not (String.equal row ""))
        |> List.sort String.compare
      in
      check bool "every caller waited in an open of its own" true all_waiting;
      check bool "every caller got the writer" true all_lent;
      check
        (list (option string))
        "no caller's write failed"
        (List.init callers (fun _ -> None))
        (Array.to_list write_failures);
      check
        (list string)
        "every caller's row reached the reader"
        (List.init callers row_of)
        rows;
      check bool "the writer is closed once the last caller returned" true ended)
;;

(* Two callers wait in the open of one FIFO. Then its directory can no
   longer be searched, so the caller that finds the other's writer cached
   cannot check that writer against the path, and fails. The descriptor it
   opened itself is closed, and the place its open held is given back once:
   more paths than the cache holds are then appended to, and the cache keeps
   its full number of writers, no fewer and no more. (A superuser can still
   search the directory; both callers then succeed, and nothing is left open
   and the number of places is what it was.) *)
let paths_past_the_bound = 8

let test_open_that_cannot_be_cached_is_closed () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_unsearchable" in
  let fifo = Filename.concat dir "out.fifo" in
  (* A second name of the FIFO, in a directory that stays searchable. *)
  let other_name = Filename.concat (tmpdir "fd_cache_other_name") "out.fifo" in
  Unix.mkfifo fifo 0o600;
  Unix.link fifo other_name;
  let failed = Atomic.make 0 in
  let holders =
    List.init 2 (fun _ ->
      Thread.create
        (fun () ->
          match Fs_compat.with_cached_writer_for_testing fifo (fun _ -> ()) with
          | () -> ()
          | exception Sys_error _ -> Atomic.incr failed)
        ())
  in
  (* Both callers have been in the open for two listings: they wait for the
     FIFO's reader, past the search of the directory, before it is closed to
     them. A caller that came later would fail in its open, and the second
     lookup would never be reached. *)
  let both_waiting = wait_for_opens_in_the_call 2 in
  Unix.chmod dir 0o000;
  let no_writer_left =
    Fun.protect
      ~finally:(fun () -> Unix.chmod dir 0o755)
      (fun () ->
        let reader = Unix.openfile other_name [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
        Fun.protect
          ~finally:(fun () -> Unix.close reader)
          (fun () ->
            List.iter Thread.join holders;
            Fs_compat.reset_fd_cache_for_testing ();
            stream_ended reader))
  in
  let before = open_descriptors () in
  let places = tmpdir "fd_cache_place_back" in
  for i = 1 to cache_bound + paths_past_the_bound do
    Fs_compat.append_jsonl (numbered_path places i) (`Int i)
  done;
  let kept = open_descriptors () - before in
  Fs_compat.reset_fd_cache_for_testing ();
  check bool "both callers waited in the open" true both_waiting;
  check
    int
    "the caller that could not check the cached writer failed"
    (if Unix.getuid () = 0 then 0 else 1)
    (Atomic.get failed);
  check bool "no writer is open once the cache is emptied" true no_writer_left;
  check int "the place of the open that failed came back, once" cache_bound kept
;;

let descriptor_limit = 100

(* Opens descriptors until the process may open no more. *)
let use_up_descriptors () =
  let rec fill held =
    match Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 with
    | fd -> fill (fd :: held)
    | exception Unix.Unix_error (Unix.EMFILE, _, _) -> held
  in
  ignore (fill [] : Unix.file_descr list)
;;

let probe_failed name message =
  prerr_endline (name ^ ": " ^ message);
  exit 3
;;

(* Run in a process whose descriptor limit is [descriptor_limit]: the cache
   is full, its least recently used writer is lent, and no descriptor is
   left. A new path still opens, because the cache closes a writer that is
   not lent before it opens the new one. *)
let descriptor_limit_probe dir =
  let name = "descriptor limit probe" in
  let lent = Atomic.make false in
  let release = Atomic.make false in
  let holder =
    Thread.create
      (fun () ->
        Fs_compat.with_cached_writer_for_testing (numbered_path dir 1) (fun _ ->
          Atomic.set lent true;
          hold_until release))
      ()
  in
  if not (wait_until (fun () -> Atomic.get lent))
  then probe_failed name "the first writer was not lent";
  for i = 2 to cache_bound do
    Fs_compat.append_jsonl (numbered_path dir i) (`Int i)
  done;
  use_up_descriptors ();
  let outcome =
    match Fs_compat.append_jsonl (numbered_path dir (cache_bound + 1)) (`Int 0) with
    | () -> Ok ()
    | exception Sys_error message -> Error message
  in
  Atomic.set release true;
  Thread.join holder;
  match outcome with
  | Ok () -> exit 0
  | Error message -> probe_failed name message
;;

(* The same with two new paths whose opens are in flight together: they are
   FIFOs without a reader. Each open made room for itself. *)
let descriptor_limit_two_opens_probe dir =
  let fifos =
    List.map
      (fun name ->
        let path = Filename.concat dir name in
        Unix.mkfifo path 0o600;
        path)
      [ "first.fifo"; "second.fifo" ]
  in
  fill_cache dir;
  (* One descriptor is set aside for each FIFO's reader. *)
  let set_aside = List.map (fun _ -> Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0) fifos in
  use_up_descriptors ();
  let appends =
    List.map
      (fun fifo ->
        let outcome = Atomic.make None in
        let thread =
          Thread.create
            (fun () ->
              Atomic.set
                outcome
                (Some
                   (match Fs_compat.append_lines fifo row_a with
                    | () -> Ok ()
                    | exception Sys_error message -> Error message)))
            ()
        in
        thread, outcome)
      fifos
  in
  Thread.delay 0.3;
  let readers =
    List.map2
      (fun fifo descriptor ->
        Unix.close descriptor;
        Unix.openfile fifo [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0)
      fifos
      set_aside
  in
  List.iter (fun (thread, _) -> Thread.join thread) appends;
  List.iter Unix.close readers;
  match
    List.filter_map
      (fun (_, outcome) ->
        match Atomic.get outcome with
        | Some (Ok ()) -> None
        | Some (Error message) -> Some message
        | None -> Some "the append did not end")
      appends
  with
  | [] -> exit 0
  | messages ->
    probe_failed "descriptor limit probe, two opens" (String.concat "; " messages)
;;

let test_at_the_descriptor_limit ~probe () =
  Fs_compat.reset_fd_cache_for_testing ();
  let dir = tmpdir "fd_cache_descriptor_limit" in
  let script =
    Printf.sprintf
      "set +o posix && builtin ulimit -S -n %d && exec %s %s %s"
      descriptor_limit
      (Filename.quote (Unix.realpath Sys.executable_name))
      probe
      (Filename.quote dir)
  in
  match Unix.system ("/bin/bash -c " ^ Filename.quote script) with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code -> failf "the probe exited with %d" code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> failf "the probe got signal %d" signal
;;

let descriptor_limit_probe_flag = "--descriptor-limit-probe"
let descriptor_limit_two_opens_probe_flag = "--descriptor-limit-two-opens-probe"

(* #52974. A line append starts at a line start. When the file ends in the
   middle of a line, the append writes a newline first, so the unfinished
   bytes stay a line of their own and the new row is read whole. Before, the
   row was written right after them and both were lost as one broken line. *)

(* Bytes written through a descriptor other than the cached one, the way a
   writer that died part-way leaves them. *)
let write_through_another_descriptor path content =
  Out_channel.with_open_gen
    [ Open_append; Open_creat; Open_binary ]
    0o644
    path
    (fun channel -> output_string channel content)
;;

let line_start_file name =
  Fs_compat.reset_fd_cache_for_testing ();
  Filename.concat (tmpdir "fd_cache_line_start") name
;;

let unfinished = "{\"ro"

let test_line_append_after_unfinished_line_on_open () =
  let path = line_start_file "open.jsonl" in
  write_through_another_descriptor path (row_0 ^ unfinished);
  Fs_compat.append_jsonl path (`Int 1);
  check
    string
    "the unfinished bytes keep their own line"
    (row_0 ^ unfinished ^ "\n1\n")
    (read_all path)
;;

let test_line_append_notices_bytes_from_another_descriptor () =
  let path = line_start_file "other-descriptor.jsonl" in
  Fs_compat.append_jsonl path (`Int 1);
  write_through_another_descriptor path unfinished;
  Fs_compat.append_jsonl path (`Int 2);
  check
    string
    "the end is read on every append"
    ("1\n" ^ unfinished ^ "\n2\n")
    (read_all path)
;;

(* The file is rewritten in place to the length it had, now ending in the
   middle of a line. Only reading the last byte tells. *)
let test_line_append_notices_a_same_size_rewrite () =
  let path = line_start_file "same-size.jsonl" in
  Fs_compat.append_lines path "12345\n";
  Out_channel.with_open_gen [ Open_wronly; Open_binary ] 0o644 path (fun channel ->
    output_string channel "abcdef");
  Fs_compat.append_jsonl path (`Int 2);
  check string "the row starts on a new line" "abcdef\n2\n" (read_all path)
;;

let test_line_append_at_a_line_start_adds_nothing () =
  let path = line_start_file "line-start.jsonl" in
  Fs_compat.append_jsonl path (`Int 1);
  Fs_compat.append_jsonl path (`Int 2);
  Fs_compat.reset_fd_cache_for_testing ();
  Fs_compat.append_jsonl path (`Int 3);
  check string "no blank line between rows" "1\n2\n3\n" (read_all path)
;;

(* The raw append is a byte append: a row written in two calls stays one row. *)
let test_raw_append_continues_the_line () =
  let path = line_start_file "raw.jsonl" in
  Fs_compat.append_file path "{\"i\":";
  Fs_compat.append_file path "1}\n";
  Fs_compat.append_jsonl path (`Int 2);
  check string "raw bytes are not split" "{\"i\":1}\n2\n" (read_all path)
;;

let test_line_append_after_raw_unfinished_bytes () =
  let path = line_start_file "raw-unfinished.jsonl" in
  Fs_compat.append_file path unfinished;
  Fs_compat.append_jsonl path (`Int 2);
  check string "the row starts on a new line" (unfinished ^ "\n2\n") (read_all path)
;;

(* Bytes a failed append could not remove are unfinished bytes like any
   other: the next row does not join them. *)
let test_line_append_after_failed_rollback () =
  let path = failed_append_file "after-failed-rollback.jsonl" in
  ignore
    (failing_append
       ~start:Whole.At_line_start
       ~io:(io_whose_truncate_fails ~budget:4 (ref 0))
       path
       row_a
     : string);
  Fs_compat.append_jsonl path (`Int 2);
  check
    string
    "the bytes the rollback could not remove keep their own line"
    (row_0 ^ String.sub row_a 0 4 ^ "\n2\n")
    (read_all path)
;;

let test_append_lines_after_unfinished_line () =
  let path = line_start_file "append-lines.jsonl" in
  write_through_another_descriptor path (row_0 ^ unfinished);
  Fs_compat.append_lines path (row_a ^ row_b);
  Fs_compat.append_lines path row_a2;
  check
    string
    "one newline before the first batch, none before the second"
    (row_0 ^ unfinished ^ "\n" ^ row_a ^ row_b ^ row_a2)
    (read_all path)
;;

let test_line_append_to_a_new_file () =
  let path = line_start_file "new.jsonl" in
  Fs_compat.append_lines path row_a;
  check string "an empty file gets the lines alone" row_a (read_all path)
;;

let test_empty_line_append_writes_nothing () =
  let path = line_start_file "empty-content.jsonl" in
  write_through_another_descriptor path unfinished;
  Fs_compat.append_lines path "";
  check string "no newline is added for empty content" unfinished (read_all path)
;;

(* The newline and the row are one write: when it fails, neither stays. *)
let test_failed_line_append_removes_its_newline_too () =
  let path = line_start_file "newline-rolled-back.jsonl" in
  write_through_another_descriptor path (row_0 ^ unfinished);
  fail_append ~start:Whole.At_line_start ~budget:3 path row_a;
  check string "the file is as it was" (row_0 ^ unfinished) (read_all path)
;;

let test_unreadable_end_writes_nothing () =
  let path = line_start_file "unreadable-end.jsonl" in
  write_through_another_descriptor path row_0;
  let unreadable =
    { Whole.unix_io with
      end_offset = (fun _ -> raise (Unix.Unix_error (Unix.EIO, "lseek", "")))
    }
  in
  ignore (failing_append ~start:Whole.At_line_start ~io:unreadable path row_a : string);
  check string "nothing was written" row_0 (read_all path)
;;

(* A last byte that cannot be read is not known to be a newline, so the row
   starts on a new line. The append does not fail and does not read on. *)
let test_unreadable_last_byte_starts_a_new_line () =
  let path = line_start_file "no-last-byte.jsonl" in
  write_through_another_descriptor path row_0;
  let io = { Whole.unix_io with last_byte = (fun _ ~size:_ -> None) } in
  (match run_on_own_descriptor ~io ~start:Whole.At_line_start path row_a with
   | Ok () -> ()
   | other -> failf "expected the append to succeed, got: %s" (describe other));
  check string "the row follows an empty line" (row_0 ^ "\n" ^ row_a) (read_all path)
;;

(* Another descriptor cuts the file between the length read and the
   last-byte read, as a process does that takes back its failed append. *)
let io_cutting_after_the_first_length_read path ~cut_to =
  let first = ref true in
  { Whole.unix_io with
    end_offset =
      (fun fd ->
        let size = Whole.unix_io.end_offset fd in
        if !first
        then (
          first := false;
          Unix.truncate path cut_to);
        size)
  }
;;

(* The byte the append asked for is gone, and what the file ends with now is
   not read again: the row goes on a new line, unless the file is empty. *)
let test_file_cut_while_its_end_is_read () =
  List.iter
    (fun (name, cut_to, left) ->
      let path = line_start_file name in
      write_through_another_descriptor path (row_0 ^ row_b);
      let io = io_cutting_after_the_first_length_read path ~cut_to in
      (match run_on_own_descriptor ~io ~start:Whole.At_line_start path row_a with
       | Ok () -> ()
       | other ->
         failf "%s: expected the append to succeed, got: %s" name (describe other));
      check string name (left ^ row_a) (read_all path))
    [ "cut-mid-line.jsonl", 3, String.sub row_0 0 3 ^ "\n"
    ; "cut-to-a-line-start.jsonl", String.length row_0, row_0 ^ "\n"
    ; "cut-to-nothing.jsonl", 0, ""
    ]
;;

(* A write that fails after such a cut is taken back from the end the file
   had when the row was written, not from the length read before the cut. *)
let test_failed_append_after_a_cut_is_taken_back () =
  let path = line_start_file "cut-then-failed.jsonl" in
  write_through_another_descriptor path (row_0 ^ row_b);
  let cutting = io_cutting_after_the_first_length_read path ~cut_to:3 in
  let io = { (io_failing_after 4) with end_offset = cutting.Whole.end_offset } in
  (match run_on_own_descriptor ~io ~start:Whole.At_line_start path row_a with
   | Error (Whole.Write_failed { rollback = Whole.Rolled_back { bytes = 4 }; _ }) -> ()
   | other -> failf "expected 4 bytes rolled back, got: %s" (describe other));
  check string "the file is as the cut left it" (String.sub row_0 0 3) (read_all path)
;;

(* Each call is made again after [EINTR], and the row is still written once. *)
let test_interrupted_calls_are_made_again () =
  let path = line_start_file "interrupted.jsonl" in
  write_through_another_descriptor path (row_0 ^ unfinished);
  let pending = ref [ "lseek"; "read"; "write" ] in
  let interrupted_once name =
    if List.mem name !pending
    then (
      pending := List.filter (fun other -> not (String.equal other name)) !pending;
      interrupt name)
  in
  let io =
    { Whole.write =
        (fun fd content offset length ->
          interrupted_once "write";
          Whole.unix_io.write fd content offset length)
    ; end_offset =
        (fun fd ->
          interrupted_once "lseek";
          Whole.unix_io.end_offset fd)
    ; last_byte =
        (fun fd ~size ->
          interrupted_once "read";
          Whole.unix_io.last_byte fd ~size)
    ; truncate = Whole.unix_io.truncate
    }
  in
  (match run_on_own_descriptor ~io ~start:Whole.At_line_start path row_a with
   | Ok () -> ()
   | other -> failf "expected the append to succeed, got: %s" (describe other));
  check (list string) "every call was interrupted once" [] !pending;
  check
    string
    "the row is there once, on a new line"
    (row_0 ^ unfinished ^ "\n" ^ row_a)
    (read_all path)
;;

let test_newline_and_row_are_one_write () =
  let path = line_start_file "one-write.jsonl" in
  write_through_another_descriptor path unfinished;
  let lengths = ref [] in
  let io =
    { Whole.unix_io with
      write =
        (fun fd content offset length ->
          lengths := length :: !lengths;
          Whole.unix_io.write fd content offset length)
    }
  in
  (match run_on_own_descriptor ~io ~start:Whole.At_line_start path row_a with
   | Ok () -> ()
   | other -> failf "expected the append to succeed, got: %s" (describe other));
  check (list int) "one write carries both" [ 1 + String.length row_a ] !lengths
;;

let test_batch_starts_on_a_new_line () =
  let path = line_start_file "batch.jsonl" in
  write_through_another_descriptor path unfinished;
  Fs_compat.append_jsonl_batch path [ `Int 1; `Int 2 ];
  check string "the batch starts on a new line" (unfinished ^ "\n1\n2\n") (read_all path)
;;

let tests () =
  Alcotest.run
    "fs_compat_fd_cache"
    [ ( "fd_cache"
      , [ test_case "deleted path reopens" `Quick test_deleted_path_reopens
        ; test_case "replaced path reopens" `Quick test_replaced_path_reopens
        ; test_case
            "16 threads × 100 multibyte records (RFC-0108 §5.1 reproduction)"
            `Quick
            test_concurrent_multibyte_records
        ; test_case
            "8 threads × 60 PIPE_BUF-busting records (>4 KB)"
            `Quick
            test_large_records_no_interleave
        ; test_case
            "reset then continue writing"
            `Quick
            test_reset_then_continue_writing
        ; test_case
            "LRU eviction preserves data on every path"
            `Quick
            test_lru_evict_preserves_data
        ; test_case
            "16 threads × 100 records over cached append_file_unix"
            `Quick
            test_append_file_unix_concurrent_records
        ; test_case
            "LRU eviction does not close active writer"
            `Quick
            test_lru_evict_skips_active_writer
        ] )
    ; ( "failed append"
      , [ test_case
            "a write that fails before any byte leaves nothing for later"
            `Quick
            test_failed_append_without_bytes_leaves_nothing
        ; test_case
            "a write that fails part-way is rolled back"
            `Quick
            test_failed_append_with_bytes_is_rolled_back
        ; test_case
            "closing the cached descriptor after a failed append writes nothing"
            `Quick
            test_failed_append_is_not_written_on_close
        ; test_case
            "repeated failed appends do not pile up"
            `Quick
            test_repeated_failed_appends_do_not_pile_up
        ; test_case
            "the result names the bytes rolled back"
            `Quick
            test_rollback_result_names_the_bytes
        ; test_case
            "a rollback spans several writes"
            `Quick
            test_rollback_spans_several_writes
        ; test_case
            "a failed truncation is reported and the bytes stay"
            `Quick
            test_failed_rollback_is_reported
        ; test_case
            "another writer's row survives a failed append"
            `Quick
            test_another_writers_row_survives_a_failed_append
        ; test_case
            "a real short write at the file size limit is rolled back"
            `Quick
            (test_real_failed_write_is_rolled_back ~limit_kib:1 ~bytes:2_000)
        ; test_case
            "a real failure after several writes is rolled back"
            `Quick
            (test_real_failed_write_is_rolled_back ~limit_kib:100 ~bytes:150_000)
        ; test_case
            "a FIFO is written as it is and nothing is taken back"
            `Quick
            test_stream_is_written_as_it_is
        ; test_case
            "a row another writer added meanwhile is not written over"
            `Quick
            test_append_lands_after_another_writers_row
        ; test_case
            "a file found shorter is left as it is"
            `Quick
            test_file_found_shorter_is_left_as_it_is
        ; test_case
            "an interrupted truncation is finished"
            `Quick
            test_interrupted_rollback_is_finished
        ; test_case
            "an interrupted length read keeps the interrupted truncation"
            `Quick
            test_interrupted_length_read_keeps_the_interrupted_truncation
        ; test_case
            "bytes another writer cut are not reported as removed"
            `Quick
            test_bytes_another_writer_cut_are_not_reported_as_removed
        ; test_case
            "another exception passes through after the rollback"
            `Quick
            test_other_exception_passes_through
        ; test_case
            "an open failure names the path"
            `Quick
            test_open_failure_names_the_path
        ; test_case
            "a child process does not inherit the descriptor"
            `Quick
            test_child_process_does_not_inherit_the_descriptor
        ; test_case
            "a FIFO open waits for its reader and holds up no other path"
            `Quick
            test_fifo_open_waits_and_holds_up_no_other_path
        ; test_case
            "an interrupted FIFO open is made again"
            `Quick
            test_interrupted_fifo_open_is_made_again
        ; test_case
            "a target is opened the way its kind needs while the path changes"
            `Quick
            test_open_matches_the_kind_under_a_changing_path
        ] )
    ; ( "cache places"
      , [ test_case
            "the cache closes the writers it drops"
            `Quick
            test_cache_closes_the_writers_it_drops
        ; test_case
            "the cache returns to its bound after more writers were lent"
            `Quick
            test_cache_returns_to_its_bound
        ; test_case
            "a writer dropped while it is lent is closed when it comes back"
            `Quick
            test_writer_dropped_while_lent_is_closed_when_it_comes_back
        ; test_case
            "a failed open gives its place back"
            `Quick
            test_failed_open_gives_its_place_back
        ; test_case
            "eviction takes the least recently used writer"
            `Quick
            test_eviction_takes_the_least_recently_used_writer
        ; test_case
            "callers that open one path together share one writer"
            `Quick
            test_callers_opening_one_path_together_share_one_writer
        ; test_case
            "a dropped writer stays open until its last caller returns"
            `Quick
            test_dropped_writer_stays_open_until_its_last_caller_returns
        ; test_case
            "an open that cannot be cached is closed"
            `Quick
            test_open_that_cannot_be_cached_is_closed
        ; test_case
            "a new path opens at the descriptor limit"
            `Quick
            (test_at_the_descriptor_limit ~probe:descriptor_limit_probe_flag)
        ; test_case
            "two new paths open together at the descriptor limit"
            `Quick
            (test_at_the_descriptor_limit ~probe:descriptor_limit_two_opens_probe_flag)
        ] )
    ; ( "line start"
      , [ test_case
            "a row after unfinished bytes found on open starts a new line"
            `Quick
            test_line_append_after_unfinished_line_on_open
        ; test_case
            "bytes from another descriptor are noticed"
            `Quick
            test_line_append_notices_bytes_from_another_descriptor
        ; test_case
            "a rewrite to the same size is noticed"
            `Quick
            test_line_append_notices_a_same_size_rewrite
        ; test_case
            "a row at a line start gets no extra newline"
            `Quick
            test_line_append_at_a_line_start_adds_nothing
        ; test_case
            "the raw append continues an unfinished line"
            `Quick
            test_raw_append_continues_the_line
        ; test_case
            "a row after raw unfinished bytes starts a new line"
            `Quick
            test_line_append_after_raw_unfinished_bytes
        ; test_case
            "a row after a failed rollback starts a new line"
            `Quick
            test_line_append_after_failed_rollback
        ; test_case
            "append_lines starts a batch on a new line"
            `Quick
            test_append_lines_after_unfinished_line
        ; test_case
            "a new file gets the lines alone"
            `Quick
            test_line_append_to_a_new_file
        ; test_case
            "empty content writes nothing"
            `Quick
            test_empty_line_append_writes_nothing
        ; test_case
            "a failed row removes its leading newline too"
            `Quick
            test_failed_line_append_removes_its_newline_too
        ; test_case
            "an end that cannot be read writes nothing"
            `Quick
            test_unreadable_end_writes_nothing
        ; test_case
            "a last byte that cannot be read starts a new line"
            `Quick
            test_unreadable_last_byte_starts_a_new_line
        ; test_case
            "a file cut while its end is read gets the row on a new line"
            `Quick
            test_file_cut_while_its_end_is_read
        ; test_case
            "a failed row after such a cut is taken back from the new end"
            `Quick
            test_failed_append_after_a_cut_is_taken_back
        ; test_case
            "interrupted calls are made again"
            `Quick
            test_interrupted_calls_are_made_again
        ; test_case
            "the newline and the row are one write"
            `Quick
            test_newline_and_row_are_one_write
        ; test_case
            "a batch starts on a new line"
            `Quick
            test_batch_starts_on_a_new_line
        ] )
    ]
;;

let () =
  match Sys.argv with
  | [| _; "--file-size-limit-probe"; path; bytes |] ->
    file_size_limit_probe path (int_of_string bytes)
  | [| _; flag; dir |] when String.equal flag descriptor_limit_probe_flag ->
    descriptor_limit_probe dir
  | [| _; flag; dir |] when String.equal flag descriptor_limit_two_opens_probe_flag ->
    descriptor_limit_two_opens_probe dir
  | _ -> tests ()
;;
