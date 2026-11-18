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

(* #52980. A write that fails part-way leaves the file as it was, and nothing
   of it reaches the file later: not with the next append and not when the
   cached descriptor is closed. Before, the cached [out_channel] kept the
   unwritten bytes in its buffer and wrote them on the next flush or close. *)

let read_all path = In_channel.with_open_bin path In_channel.input_all

(* The real write, limited to [budget] more bytes in total. Once they are
   used up every write fails the way a full disk does. *)
let io_failing_after budget =
  let left = ref budget in
  { Fs_compat_internal.Fd_append_whole.unix_io with
    write =
      (fun fd content offset length ->
        if !left = 0
        then raise (Unix.Unix_error (Unix.ENOSPC, "write", ""))
        else (
          let written =
            Unix.single_write_substring fd content offset (min length !left)
          in
          left := !left - written;
          written))
  }
;;

let failing_append ~budget path content =
  match
    Fs_compat.append_file_unix_with_io_for_testing
      ~io:(io_failing_after budget)
      path
      content
  with
  | () -> fail "the append was expected to fail"
  | exception Sys_error _ -> ()
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
  failing_append ~budget:0 path row_a;
  check string "file after the failed append" row_0 (read_all path);
  Fs_compat.append_file path row_b;
  check string "the next append adds its own row only" (row_0 ^ row_b) (read_all path)
;;

let test_failed_append_with_bytes_is_rolled_back () =
  let path = failed_append_file "some-bytes.jsonl" in
  failing_append ~budget:4 path row_a;
  check string "the four written bytes are removed again" row_0 (read_all path);
  Fs_compat.append_file path row_b;
  check string "the next append starts where the file ended" (row_0 ^ row_b) (read_all path)
;;

let test_failed_append_is_not_written_on_close () =
  let path = failed_append_file "close.jsonl" in
  failing_append ~budget:0 path row_a;
  Fs_compat.reset_fd_cache_for_testing ();
  check string "closing the cached descriptor writes nothing" row_0 (read_all path)
;;

let test_repeated_failed_appends_do_not_pile_up () =
  let path = failed_append_file "repeated.jsonl" in
  failing_append ~budget:0 path row_a;
  failing_append ~budget:0 path row_a2;
  check string "file after two failed appends" row_0 (read_all path);
  Fs_compat.append_file path row_b;
  check string "only the append that succeeded is in the file" (row_0 ^ row_b) (read_all path)
;;

(* When the rollback itself fails the bytes stay, and the error says so. *)
let test_failed_rollback_is_reported () =
  let path = failed_append_file "rollback-fails.jsonl" in
  let io =
    { (io_failing_after 4) with
      truncate = (fun _ _ -> raise (Unix.Unix_error (Unix.EIO, "ftruncate", "")))
    }
  in
  (match Fs_compat.append_file_unix_with_io_for_testing ~io path row_a with
   | () -> fail "the append was expected to fail"
   | exception Sys_error message ->
     check
       bool
       "the error names the path"
       true
       (String.starts_with ~prefix:(Fs_compat.canonical_append_mutex_path_for_testing path) message));
  check string "the partial bytes are still there" (row_0 ^ String.sub row_a 0 4) (read_all path)
;;

let () =
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
            "closing the cached descriptor writes nothing"
            `Quick
            test_failed_append_is_not_written_on_close
        ; test_case
            "repeated failed appends do not pile up"
            `Quick
            test_repeated_failed_appends_do_not_pile_up
        ; test_case
            "a failed rollback is reported and the bytes stay"
            `Quick
            test_failed_rollback_is_reported
        ] )
    ]
;;
