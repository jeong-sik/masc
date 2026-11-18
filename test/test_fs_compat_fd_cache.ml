(** RFC-0162 §3.4 — [Fs_compat.append_jsonl] per-path fd cache tests.

    The fd cache is a behaviour-preserving optimisation: the
    Record-interleave-0 and partial-write-0 guarantees from
    RFC-0108 §3.2 must continue to hold. We re-run RFC-0108's
    canonical stress cases (16-thread concurrent records, 4 KB
    PIPE_BUF-busting records, multibyte boundary) against the
    cached path and additionally verify the lifecycle helpers
    ([close_all_cached_writers], [reset_fd_cache_for_testing]). *)

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

(* Re-run the canonical RFC-0108 §5.1 16-fiber stress, now over the
   cached path. The cache must NOT degrade the existing
   Record-interleave-0 guarantee. *)
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
  (* Slightly above fd_cache_max (=32) to force at least a few evictions. *)
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

(* RFC-0108 §3.2 Record-interleave-0 over the cached [append_file_unix]
   path. task-196 reinstated the fd cache for [append_file_unix]; this
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
              Whole.Left_in_place
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
             Whole.Left_in_place
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
                 Whole.Left_in_place { bytes = 2; reason = Whole.Not_a_regular_file }
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
  let moved = { Whole.unix_io with last_byte = (fun _ ~size:_ -> None) } in
  List.iter
    (fun io ->
      ignore (failing_append ~start:Whole.At_line_start ~io path row_a : string);
      check string "nothing was written" row_0 (read_all path))
    [ unreadable; moved ]
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
        ] )
    ]
;;

let () =
  match Sys.argv with
  | [| _; "--file-size-limit-probe"; path; bytes |] ->
    file_size_limit_probe path (int_of_string bytes)
  | _ -> tests ()
;;
