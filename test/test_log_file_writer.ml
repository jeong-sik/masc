open Alcotest

(* RFC async-log-sink-durable-append-offload §7. The file-sink writer is
   process-wide, so the cases run in this order: synchronous before start;
   complete and ordered across domains; a stalled file makes producers wait
   and drops nothing; synchronous after stop. The console mirror is silenced
   with its existing writer seam so only the JSONL file is under test. *)

let module_name = "log_file_writer_test"

let silence_console () = Console_sink.For_testing.set_writer (Some (fun (_ : string) -> ()))

(* A test that hangs on a blocked write fails the run instead. [Unix._exit]
   skips [at_exit], where [stop_writer] would wait for a writer still
   blocked on a pipe nobody reads. *)
let bounded seconds what f =
  let finished = Atomic.make false in
  let (_ : Thread.t) =
    Thread.create
      (fun () ->
        let rec watch left =
          if not (Atomic.get finished)
          then
            if left <= 0.
            then (
              Printf.eprintf "FAIL %s did not finish within %.0f s\n%!" what seconds;
              Unix._exit 3)
            else (
              Unix.sleepf 0.05;
              watch (left -. 0.05))
        in
        watch seconds)
      ()
  in
  Fun.protect ~finally:(fun () -> Atomic.set finished true) f
;;

let sink_file dir =
  match
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (String.starts_with ~prefix:"system_log_")
  with
  | [ name ] -> Filename.concat dir name
  | names -> failf "expected one sink file in %s, found %d" dir (List.length names)
;;

let lines_of text = String.split_on_char '\n' text |> List.filter (fun line -> line <> "")

(* Every line must be one JSON object: a [}{]-joined line fails here. *)
let our_messages lines =
  List.filter_map
    (fun line ->
       let json = Yojson.Safe.from_string line in
       let field name = Yojson.Safe.Util.(member name json |> to_string_option) in
       match field "module", field "message" with
       | Some name, Some message when String.equal name module_name -> Some message
       | Some _, Some _ | None, _ | Some _, None -> None)
    lines
;;

let file_messages dir = our_messages (lines_of (In_channel.with_open_text (sink_file dir) In_channel.input_all))
let emit message = Log.emit Log.Warn ~module_name message

let test_unconfigured_sink_stays_disabled () =
  silence_console ();
  Log.Ring.start_writer ();
  Fun.protect ~finally:Log.Ring.stop_writer (fun () -> emit "ring-only");
  let sink = Yojson.Safe.Util.member "file_sink" (Log.Ring.summary_json ()) in
  check bool "no file sink was enabled" false Yojson.Safe.Util.(member "enabled" sink |> to_bool);
  check bool "no directory was configured" true (Yojson.Safe.Util.member "dir" sink = `Null);
  check (list string) "the ring still receives the record" [ "ring-only" ]
    (Log.Ring.recent ~limit:1 ~module_filter:module_name ()
     |> List.map (fun (entry : Log.Ring.entry) -> entry.message))
;;

let open_file_sink ?identity_recheck_interval_s dir =
  match Log.Ring.init_file_sink ?identity_recheck_interval_s dir with
  | Ok () -> ()
  | Error error -> Alcotest.fail (Log.Ring.file_sink_error_to_string error)
;;

let test_synchronous_before_start () =
  silence_console ();
  let dir = Filename.temp_dir "masc-log-writer-" "" in
  open_file_sink dir;
  emit "before-start";
  check (list string) "the record is in the file when emit returns" [ "before-start" ] (file_messages dir)
;;

let test_queued_records_are_complete_and_ordered () =
  silence_console ();
  let dir = Filename.temp_dir "masc-log-writer-" "" in
  open_file_sink dir;
  Log.Ring.start_writer ();
  let per_producer = 2000
  and producers = 4 in
  let name p i = Printf.sprintf "d%d-%05d" p i in
  bounded 60.0 "four producers" (fun () ->
    List.init producers (fun p ->
      Domain.spawn (fun () ->
        for i = 0 to per_producer - 1 do
          emit (name p i)
        done))
    |> List.iter Domain.join;
    Log.Ring.stop_writer ());
  let messages = file_messages dir in
  check int "every record is written" (per_producer * producers) (List.length messages);
  for p = 0 to producers - 1 do
    check
      (list string)
      (Printf.sprintf "producer %d in emit order" p)
      (List.init per_producer (name p))
      (List.filter (String.starts_with ~prefix:(Printf.sprintf "d%d-" p)) messages)
  done
;;

(* Collect [expected] of our records from [reader], in arrival order. *)
let read_records reader expected =
  let chunk = Bytes.create 65536 in
  let pending = Buffer.create 65536 in
  let records = ref [] in
  let count = ref 0 in
  while !count < expected do
    let n = Unix.read reader chunk 0 (Bytes.length chunk) in
    if n = 0 then failwith "the sink closed the pipe before every record arrived";
    Buffer.add_subbytes pending chunk 0 n;
    let text = Buffer.contents pending in
    let last_newline = String.rindex_opt text '\n' in
    match last_newline with
    | None -> ()
    | Some index ->
      let complete = String.sub text 0 (index + 1) in
      Buffer.clear pending;
      Buffer.add_string pending (String.sub text (index + 1) (String.length text - index - 1));
      let mine = our_messages (lines_of complete) in
      count := !count + List.length mine;
      records := List.rev_append mine !records
  done;
  List.rev !records
;;

let test_a_stalled_file_makes_producers_wait_and_drops_nothing () =
  silence_console ();
  let dir = Filename.temp_dir "masc-log-writer-" "" in
  (* Rechecking the sink's identity on every write moves it onto the FIFO
     that replaces the file. *)
  open_file_sink ~identity_recheck_interval_s:0.0 dir;
  let path = sink_file dir in
  (* Renamed, not unlinked: the file keeps its inode, so the FIFO gets
     another one and the identity check sees a different file. An unlinked
     inode can be handed straight to the FIFO. *)
  Unix.rename path (Filename.concat (Filename.get_temp_dir_name ()) (Filename.basename dir ^ ".replaced"));
  Unix.mkfifo path 0o600;
  let reader = Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
  Unix.clear_nonblock reader;
  Log.Ring.start_writer ();
  let pad = String.make 1000 'x' in
  let record phase i = Printf.sprintf "%s-%06d-%s" phase i pad in
  let first = 300 in
  (* Before a producer waits, the pipe and the capacity (queued lines plus the
     batch the writer is holding) take records. A pipe grows to at most 64 KB
     on macOS and Linux by default, under 60 of these records. *)
  let second = Log.Ring.file_writer_capacity + 100 in
  let returned = Atomic.make 0 in
  let producer = ref None in
  let received = ref [] in
  (* Whatever happens, read the pipe to its end so the writer can finish,
     then move the sink off the FIFO. *)
  let release () =
    let drain = Thread.create (fun () ->
      let chunk = Bytes.create 65536 in
      while Unix.read reader chunk 0 (Bytes.length chunk) > 0 do () done) ()
    in
    Option.iter Thread.join !producer;
    Log.Ring.stop_writer ();
    open_file_sink (Filename.temp_dir "masc-log-writer-" "");
    Thread.join drain;
    Unix.close reader
  in
  Fun.protect ~finally:release (fun () ->
    (* Phase a: nothing reads the pipe, so the writer blocks in write() once
       a few dozen 1 KB records fill it (300 KB cannot fit). Each emit still
       returns: the producer queues and does not wait for the file. *)
    bounded 20.0 "emits while the writer is blocked" (fun () ->
      Eio_main.run (fun _env ->
        for i = 0 to first - 1 do
          emit (record "a" i)
        done));
    (* Phase b: the producer stops returning before it finishes. *)
    producer :=
      Some
        (Thread.create
           (fun () ->
             for i = 0 to second - 1 do
               emit (record "b" i);
               Atomic.incr returned
             done)
           ());
    let stalled =
      bounded 30.0 "the producer stalls" (fun () ->
        let rec wait last since =
          Unix.sleepf 0.1;
          let now = Atomic.get returned in
          if now <> last then wait now (Unix.gettimeofday ())
          else if Unix.gettimeofday () -. since >= 0.5 then now
          else wait last since
        in
        wait (-1) (Unix.gettimeofday ()))
    in
    check bool "the producer waits before its last record" true (stalled < second);
    check bool "the queue took records before it filled" true (stalled > 0);
    (* Phase c: read. The producer finishes and every record arrives. *)
    received := bounded 60.0 "reading every record" (fun () -> read_records reader (first + second)));
  check int "the producer finished" second (Atomic.get returned);
  check
    (list string)
    "every record, in emit order"
    (List.init first (record "a") @ List.init second (record "b"))
    !received
;;

let test_synchronous_after_stop () =
  silence_console ();
  let dir = Filename.temp_dir "masc-log-writer-" "" in
  open_file_sink dir;
  Log.Ring.start_writer ();
  Log.Ring.stop_writer ();
  emit "after-stop";
  check (list string) "the record is in the file when emit returns" [ "after-stop" ] (file_messages dir)
;;

let test_later_emit_reopens_after_write_failure ~queued ~large_message ~partial_tail () =
  silence_console ();
  let previous_sigpipe = Sys.signal Sys.sigpipe Sys.Signal_ignore in
  let reader = ref None in
  Fun.protect
    ~finally:(fun () ->
      Log.Ring.stop_writer ();
      Option.iter Unix.close !reader;
      Sys.set_signal Sys.sigpipe previous_sigpipe)
    (fun () ->
      let dir = Filename.temp_dir "masc-log-reopen-" "" in
      open_file_sink ~identity_recheck_interval_s:0.0 dir;
      let path = sink_file dir in
      if partial_tail then emit "retained-before-failure";
      let retained = In_channel.with_open_bin path In_channel.input_all in
      Unix.rename path (Filename.concat dir "previous-sink");
      Unix.mkfifo path 0o600;
      let pipe_reader = Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
      reader := Some pipe_reader;
      (* Open and flush the FIFO while it has a reader. The next write will
         fail on this same channel after the reader closes. *)
      emit "fifo-prime";
      Unix.close pipe_reader;
      reader := None;
      if queued then Log.Ring.start_writer ();
      (* A large message fails in [output_string]; a small one reaches the
         channel buffer and fails in [flush]. Both must retire the sink. *)
      emit (if large_message then String.make (1024 * 1024) 'x' else "flush-failure");
      bounded 20.0 "the failed append closes its channel" (fun () ->
        let rec await_close () =
          let sink = Yojson.Safe.Util.member "file_sink" (Log.Ring.summary_json ()) in
          if Yojson.Safe.Util.(member "enabled" sink |> to_bool)
          then (Thread.yield (); await_close ())
        in
        await_close ());
      (* The filesystem is healthy again while the queued writer, if any,
         remains running. Only the later emit may cause it to reopen. *)
      Unix.unlink path;
      let incomplete = "{\"failed-batch\":" in
      Out_channel.with_open_bin path (fun oc ->
        output_string oc retained;
        if partial_tail then output_string oc incomplete);
      emit "after-write-failure";
      Log.Ring.stop_writer ();
      if partial_tail then begin
        let text = In_channel.with_open_bin path In_channel.input_all in
        let prefix = retained ^ incomplete ^ "\n" in
        check bool "complete rows and incomplete bytes are preserved" true
          (String.starts_with ~prefix text);
        (match lines_of text with
         | [before; failed; after] ->
             check string "the incomplete row is isolated" incomplete failed;
             check (list string) "both complete rows decode"
               ["retained-before-failure"; "after-write-failure"]
               (our_messages [before; after])
         | rows -> failf "expected two complete rows and one incomplete row, found %d" (List.length rows));
        (* Exercise the production JSONL restore path: only the malformed
           row is skipped, and the healthy later record survives a restart. *)
        open_file_sink dir;
        check (list string) "restore keeps the complete records"
          ["after-write-failure"; "retained-before-failure"]
          (Log.Ring.recent ~limit:10 ~module_filter:module_name ()
           |> List.map (fun (entry : Log.Ring.entry) -> entry.message))
      end else
        check (list string) "the later record reaches the reopened file" [ "after-write-failure" ]
          (file_messages dir))
;;

let test_readerless_fifo_does_not_block_the_next_open ~queued () =
  silence_console ();
  let previous_sigpipe = Sys.signal Sys.sigpipe Sys.Signal_ignore in
  let reader = ref None in
  Fun.protect
    ~finally:(fun () ->
      Log.Ring.stop_writer ();
      Option.iter Unix.close !reader;
      Sys.set_signal Sys.sigpipe previous_sigpipe)
    (fun () ->
      let dir = Filename.temp_dir "masc-log-readerless-" "" in
      open_file_sink ~identity_recheck_interval_s:0.0 dir;
      let path = sink_file dir in
      Unix.rename path (Filename.concat dir "previous-sink");
      Unix.mkfifo path 0o600;
      let pipe_reader = Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
      reader := Some pipe_reader;
      if queued then Log.Ring.start_writer ();
      (* Prime the FIFO while a reader exists, then drop the reader so the
         next append fails EPIPE and retires the sink. *)
      emit "fifo-prime";
      Unix.close pipe_reader;
      reader := None;
      (* A large message fails inside [output_string] in both modes: a small
         one may sit in the channel buffer in queued mode and never reach
         the vanished reader. *)
      emit ("fifo-failure " ^ String.make (1024 * 1024) 'x');
      (* Give the queued writer a moment to drain the failed append; the
         readerless reopen below is what must not hang, and the rotate
         warnings already show retirement and retry without blocking. *)
      Thread.delay 0.2;
      (* The readerless FIFO stays in place. The next emit reopens it: a
         blocking write-open would park this emit (synchronous) or the
         writer (queued) under the sink lock; the nonblocking open fails
         ENXIO at once, the sink stays retired and the record waits in the
         ring. *)
      (* The readerless FIFO stays in place. The next emit reopens it: a
         blocking write-open would park the emit (synchronous) or the
         writer (queued) under the sink lock; the nonblocking open fails
         ENXIO at once — logged as a rotate warning — and control returns.
         The emit returning inside the bound is itself the no-hang proof;
         the summary's enabled flag differs between modes and is not part
         of this claim. *)
      bounded 5.0 "the readerless FIFO open fails instead of hanging" (fun () ->
        emit "into-a-readerless-fifo");
      Thread.delay 0.2;
      (* A later regular sink recovers the pipeline and keeps later records. *)
      Unix.unlink path;
      Out_channel.with_open_bin path (fun oc -> output_string oc "");
      emit "after-readerless-fifo";
      Log.Ring.stop_writer ();
      check (list string) "the later record reaches the recovered sink"
        ["after-readerless-fifo"] (file_messages dir))
;;

let test_failed_reconfiguration_retries_intended_directory ~queued () =
  silence_console ();
  let previous = Filename.temp_dir "masc-log-previous-" "" in
  open_file_sink previous;
  emit "previous-directory";
  let previous_path = sink_file previous in
  let previous_bytes = In_channel.with_open_bin previous_path In_channel.input_all in
  let intended = Filename.temp_file "masc-log-intended-" "" in
  (* A regular file in place of the directory is root-portably ENOTDIR.
     Neither dated file exists, so loading succeeds but opening fails. *)
  let failed =
    match Log.Ring.init_file_sink intended with
    | Error (Log.Ring.Open_io { dir; failure = Log.Ring.Unix_failure { error; _ } }) ->
      String.equal dir intended && error = Unix.ENOTDIR
    | Error
        (Log.Ring.Open_io
           { failure = Log.Ring.Sys_failure _ | Log.Ring.Eio_failure _; _ })
    | Error (Log.Ring.Restore_io _ | Log.Ring.Restore_undecodable _)
    | Ok () -> false
  in
  check bool "opening the new directory is returned as ENOTDIR on that directory" true failed;
  Sys.remove intended;
  Unix.mkdir intended 0o700;
  if queued then Log.Ring.start_writer ();
  Fun.protect ~finally:Log.Ring.stop_writer (fun () -> emit "intended-directory");
  check string "later emits never resume the previous sink" previous_bytes
    (In_channel.with_open_bin previous_path In_channel.input_all);
  check (list string) "the later record reaches the intended sink"
    ["intended-directory"] (file_messages intended)
;;

let test_failed_restore_disables_previous_directory () =
  silence_console ();
  let previous = Filename.temp_dir "masc-log-previous-" "" in
  open_file_sink previous;
  emit "previous-directory";
  let previous_path = sink_file previous in
  let previous_bytes = In_channel.with_open_bin previous_path In_channel.input_all in
  let rejected = Filename.temp_dir "masc-log-rejected-" "" in
  let rejected_path = Filename.concat rejected (Filename.basename previous_path) in
  Out_channel.with_open_bin rejected_path (fun oc -> output_string oc "{}\n");
  let failed =
    match Log.Ring.init_file_sink rejected with
    | Error (Log.Ring.Restore_undecodable { dir; _ }) -> String.equal dir rejected
    | Error (Log.Ring.Restore_io _ | Log.Ring.Open_io _) | Ok () -> false
  in
  check bool "a complete but invalid entry is returned as an undecodable restore" true failed;
  emit "after-rejected-restore";
  check string "a rejected restore does not resume the previous sink" previous_bytes
    (In_channel.with_open_bin previous_path In_channel.input_all);
  let sink = Yojson.Safe.Util.member "file_sink" (Log.Ring.summary_json ()) in
  check bool "no directory remains configured" true (Yojson.Safe.Util.member "dir" sink = `Null)
;;

let () =
  run
    "log_file_writer"
    [ ( "file sink writer"
      , [ test_case "unconfigured sink stays disabled" `Quick test_unconfigured_sink_stays_disabled
        ; test_case "synchronous before start" `Quick test_synchronous_before_start
        ; test_case
            "queued records are complete and ordered"
            `Quick
            test_queued_records_are_complete_and_ordered
        ; test_case
            "a stalled file makes producers wait and drops nothing"
            `Quick
            test_a_stalled_file_makes_producers_wait_and_drops_nothing
        ; test_case "synchronous after stop" `Quick test_synchronous_after_stop
        ; test_case "synchronous later emit reopens after write failure" `Quick
            (test_later_emit_reopens_after_write_failure ~queued:false ~large_message:true ~partial_tail:false)
        ; test_case "queued later emit reopens after write failure" `Quick
            (test_later_emit_reopens_after_write_failure ~queued:true ~large_message:true ~partial_tail:false)
        ; test_case "synchronous later emit reopens after flush failure" `Quick
            (test_later_emit_reopens_after_write_failure ~queued:false ~large_message:false ~partial_tail:false)
        ; test_case "queued later emit reopens after flush failure" `Quick
            (test_later_emit_reopens_after_write_failure ~queued:true ~large_message:false ~partial_tail:false)
        ; test_case "synchronous reopen preserves and seals a partial tail" `Quick
            (test_later_emit_reopens_after_write_failure ~queued:false ~large_message:true ~partial_tail:true)
        ; test_case "queued reopen preserves and seals a partial tail" `Quick
            (test_later_emit_reopens_after_write_failure ~queued:true ~large_message:true ~partial_tail:true)
        ; test_case "synchronous readerless FIFO does not block the next open" `Quick
            (test_readerless_fifo_does_not_block_the_next_open ~queued:false)
        ; test_case "queued readerless FIFO does not block the next open" `Quick
            (test_readerless_fifo_does_not_block_the_next_open ~queued:true)
        ; test_case "synchronous failed reconfiguration retries intended directory" `Quick
            (test_failed_reconfiguration_retries_intended_directory ~queued:false)
        ; test_case "queued failed reconfiguration retries intended directory" `Quick
            (test_failed_reconfiguration_retries_intended_directory ~queued:true)
        ; test_case "failed restore disables previous directory" `Quick
            test_failed_restore_disables_previous_directory
        ] )
    ]
;;
