(** RFC-0108: system_log writer atomicity stress (in-line Stdlib.Mutex fix).

    Drives [Log.Ring.push] from many concurrent OCaml threads against a
    real file sink, then re-reads the file and asserts every line is
    parseable JSON.  Pre-fix the 3-syscall write
    [output_string + output_char + flush] left a race window that
    surfaced as ["}{"]-concat lines under contention; this test
    reproduces the contention and the post-fix sink must yield zero
    malformed lines. *)

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

let today_path dir =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  let date =
    Printf.sprintf
      "%04d-%02d-%02d"
      (tm.tm_year + 1900)
      (tm.tm_mon + 1)
      tm.tm_mday
  in
  Filename.concat dir (Printf.sprintf "system_log_%s.jsonl" date)

let read_lines path =
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let buf = Buffer.create 4096 in
        (try
           while true do
             Buffer.add_channel buf ic 4096
           done
         with End_of_file -> ());
        let content = Buffer.contents buf in
        String.split_on_char '\n' content
        |> List.filter (fun s -> s <> ""))

(* ── 16 threads × 500 records — same race surface that produced
   "}{"-concat lines on 2026-05-17 (logs/system_log_2026-05-17.jsonl
   lines 3498, 4635). *)

let test_concurrent_threads () =
  let dir = tmpdir "system_log_atomicity" in
  Log.Ring.init_file_sink dir;
  let n_threads = 16 in
  let n_records_per_thread = 500 in
  let threads =
    List.init n_threads (fun tid ->
      Thread.create
        (fun () ->
          for seq = 0 to n_records_per_thread - 1 do
            Log.emit
              Log.Info
              ~module_name:"test"
              (Printf.sprintf
                 "thread=%d seq=%d payload=hello-from-concurrent-writer"
                 tid
                 seq)
          done)
        ())
  in
  List.iter Thread.join threads;
  (* Ring's at_exit handler flushes; force a flush via a sentinel push
     and then re-open the file directly. *)
  let path = today_path dir in
  let lines = read_lines path in
  (* Count must equal the total records.  The pre-fix race manifested
     as fewer-than-expected lines (because some lines held two
     records) — this assertion catches that. *)
  check
    int
    "line count == threads × records"
    (n_threads * n_records_per_thread)
    (List.length lines);
  (* Every line must parse: "}{"-concat fails with Yojson Extra_data. *)
  List.iter
    (fun line ->
      try ignore (Yojson.Safe.from_string line)
      with e ->
        failf
          "invalid JSON: %s\nline: %s"
          (Printexc.to_string e)
          line)
    lines

let () =
  Alcotest.run
    "system_log_atomicity"
    [ "atomicity", [ test_case "16 threads × 500 records" `Quick test_concurrent_threads ] ]
