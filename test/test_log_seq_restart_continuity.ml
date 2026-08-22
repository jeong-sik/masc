(* Regression: [seq] stopped identifying a row in the daily JSONL.

   [Log.Ring.total] is process-local but the JSONL sink is per-UTC-day and
   append-only, so every restart used to resume the sequence at the number of
   rows it managed to restore — capped at [capacity] — and then re-issue
   numbers that rows already in the file carried. Measured on
   [.masc/logs/system_log_2026-08-21.jsonl]: 130,102 rows, 35,068 distinct
   [seq], twelve resets inside the one file, one value reused ten times. A
   dashboard cursor taken before a restart therefore pointed into the middle
   of the reissued range and silently skipped or replayed records.

   The file below reproduces the shape the resets leave behind — a row from a
   run that reached a high sequence, followed by rows from a run that resumed
   low — and pins two things: the next sequence this process hands out is
   above every sequence on disk, and the restored window still answers
   exactly the rows it holds rather than scanning ring slots this process
   never filled. *)

open Masc

let high_seq_on_disk = 90_000

let utc_today () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf
    "%04d-%02d-%02d"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday

let row ~seq ~message =
  Printf.sprintf
    {|{"seq":%d,"ts":"2026-08-22T00:00:00Z","level":"INFO","source":"structured","module":"Misc","keeper_name":"system","turn_id":null,"message":%s,"details":null,"category":null}|}
    seq
    (Yojson.Safe.to_string (`String message))

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then begin
      Array.iter
        (fun name -> rm_rf (Filename.concat path name))
        (Sys.readdir path);
      Sys.rmdir path
    end
    else Sys.remove path

let write_restart_shaped_log dir =
  rm_rf dir;
  Sys.mkdir dir 0o755;
  let path =
    Filename.concat dir (Printf.sprintf "system_log_%s.jsonl" (utc_today ()))
  in
  let oc = open_out path in
  List.iter
    (fun line -> output_string oc (line ^ "\n"))
    [ row ~seq:0 ~message:"run-a first"
    ; row ~seq:1 ~message:"run-a second"
    ; row ~seq:high_seq_on_disk ~message:"run-a last before restart"
    ; row ~seq:2 ~message:"run-b reissued 2"
    ];
  close_out oc;
  path

let restored_rows = 4

let test_next_sequence_clears_every_sequence_on_disk () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      "masc-test-log-seq-restart-continuity"
  in
  let path = write_restart_shaped_log dir in
  Log.Ring.init_file_sink dir;
  Log.Misc.info "seq-restart-continuity: first emit after restore";
  (match Log.Ring.recent ~limit:1 () with
   | [] -> Alcotest.fail "the emit after restore is not in the ring"
   | newest :: _ ->
     Alcotest.(check bool)
       "a sequence issued after restore is above every sequence on disk"
       true
       (newest.Log.Ring.seq > high_seq_on_disk));
  let bounds = Log.Ring.bounds () in
  Alcotest.(check int)
    "the live window starts at the first restored sequence"
    (high_seq_on_disk + 1)
    bounds.Log.Ring.start_seq;
  Alcotest.(check bool)
    "nothing was evicted from a window this small"
    false
    bounds.Log.Ring.dropped_before;
  (* Resuming the counter without moving the window lower bound would make
     [recent] scan [total - capacity, total), i.e. tens of thousands of ring
     slots this process never wrote. *)
  Alcotest.(check int)
    "the window answers the restored rows and the new one, nothing else"
    (restored_rows + 1)
    (List.length (Log.Ring.recent ~limit:Log.Ring.capacity ()));
  Alcotest.(check bool) "the daily file is still the sink" true (Sys.file_exists path);
  rm_rf dir

let () =
  Alcotest.run
    "log_seq_restart_continuity"
    [ ( "restart"
      , [ Alcotest.test_case
            "the sequence resumes above the file"
            `Quick
            test_next_sequence_clears_every_sequence_on_disk
        ] )
    ]
