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

let test_synchronous_before_start () =
  silence_console ();
  let dir = Filename.temp_dir "masc-log-writer-" "" in
  Log.Ring.init_file_sink dir;
  emit "before-start";
  check (list string) "the record is in the file when emit returns" [ "before-start" ] (file_messages dir)
;;

let test_queued_records_are_complete_and_ordered () =
  silence_console ();
  let dir = Filename.temp_dir "masc-log-writer-" "" in
  Log.Ring.init_file_sink dir;
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
  Log.Ring.init_file_sink ~identity_recheck_interval_s:0.0 dir;
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
    Log.Ring.init_file_sink (Filename.temp_dir "masc-log-writer-" "");
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
  Log.Ring.init_file_sink dir;
  Log.Ring.start_writer ();
  Log.Ring.stop_writer ();
  emit "after-stop";
  check (list string) "the record is in the file when emit returns" [ "after-stop" ] (file_messages dir)
;;

let () =
  run
    "log_file_writer"
    [ ( "file sink writer"
      , [ test_case "synchronous before start" `Quick test_synchronous_before_start
        ; test_case
            "queued records are complete and ordered"
            `Quick
            test_queued_records_are_complete_and_ordered
        ; test_case
            "a stalled file makes producers wait and drops nothing"
            `Quick
            test_a_stalled_file_makes_producers_wait_and_drops_nothing
        ; test_case "synchronous after stop" `Quick test_synchronous_after_stop
        ] )
    ]
;;
