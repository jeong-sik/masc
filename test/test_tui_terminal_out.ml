(* The terminal sink keeps byte order and never makes the writer wait on a
   terminal that is not reading. stdout is a pipe here, read by the test. *)

let with_stdout_pipe f =
  let saved = Unix.dup Unix.stdout in
  let read_end, write_end = Unix.pipe ~cloexec:true () in
  Unix.dup2 write_end Unix.stdout;
  Unix.close write_end;
  Fun.protect
    ~finally:(fun () -> Unix.dup2 saved Unix.stdout; Unix.close saved; Unix.close read_end)
    (fun () -> f read_end)

let read_exactly fd count =
  let buffer = Bytes.create count in
  let rec go offset =
    if offset < count then go (offset + Unix.read fd buffer offset (count - offset))
  in
  go 0;
  Bytes.to_string buffer

(* Long enough for any reading pipe; the stalled case below uses a short
   one and checks it is honoured. *)
let reading_limit_s = 10.0

let drained name result =
  Alcotest.(check bool) name true
    (match result with
     | Masc_tui_terminal_out.Drained -> true
     | Masc_tui_terminal_out.Abandoned -> false)

let test_bytes_keep_their_order () =
  with_stdout_pipe (fun read_end ->
    Masc_tui_terminal_out.write "a";
    Masc_tui_terminal_out.write "bc";
    Masc_tui_terminal_out.flush ();
    Masc_tui_terminal_out.write "d";
    drained "every byte written" (Masc_tui_terminal_out.drain ~within_s:reading_limit_s);
    Alcotest.(check string) "in write order" "abcd" (read_exactly read_end 4);
    Alcotest.(check bool) "nothing left behind" false (Masc_tui_terminal_out.behind ()))

(* A pipe nobody reads fills like a terminal that stopped reading its pty.
   Writing more than it holds returns at once and reports the sink behind;
   once the reader takes the bytes, drain finishes with all of them. *)
let test_a_stalled_reader_does_not_block_the_writer () =
  with_stdout_pipe (fun read_end ->
    let chunk = String.make 65536 'x' in
    let chunks = 8 in
    let started = Unix.gettimeofday () in
    for _ = 1 to chunks do
      Masc_tui_terminal_out.write chunk;
      Masc_tui_terminal_out.flush ()
    done;
    let elapsed = Unix.gettimeofday () -. started in
    Alcotest.(check bool) "writes return while nothing reads" true (elapsed < 1.0);
    Thread.delay 0.05;
    Alcotest.(check bool) "behind while the reader is stalled" true
      (Masc_tui_terminal_out.behind ());
    let total = String.length chunk * chunks in
    let reader = Thread.create (fun () -> ignore (read_exactly read_end total)) () in
    drained "drained once the reader reads" (Masc_tui_terminal_out.drain ~within_s:reading_limit_s);
    Thread.join reader;
    Alcotest.(check bool) "caught up" false (Masc_tui_terminal_out.behind ()))

(* A terminal that is gone fails the write. The writer stays alive, says
   the screen was lost, and still writes what comes after. *)
let test_a_failed_write_is_reported_and_the_writer_lives () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  ignore (Masc_tui_terminal_out.take_lost ());
  with_stdout_pipe (fun read_end ->
    let saved = Unix.dup Unix.stdout in
    let dead_read, dead_write = Unix.pipe ~cloexec:true () in
    Unix.close dead_read;
    Unix.dup2 dead_write Unix.stdout;
    Unix.close dead_write;
    Masc_tui_terminal_out.write "lost";
    drained "a failed write still settles" (Masc_tui_terminal_out.drain ~within_s:reading_limit_s);
    Alcotest.(check bool) "loss reported" true (Masc_tui_terminal_out.take_lost ());
    Alcotest.(check bool) "loss reported once" false (Masc_tui_terminal_out.take_lost ());
    Unix.dup2 saved Unix.stdout;
    Unix.close saved;
    Masc_tui_terminal_out.write "after";
    drained "the later write lands" (Masc_tui_terminal_out.drain ~within_s:reading_limit_s);
    Alcotest.(check string) "writer still writes" "after" (read_exactly read_end 5))

(* A terminal that never reads again must not keep the TUI from exiting
   (#52897). drain gives up within its limit, drops what is still queued and
   marks the screen lost; the write already in progress ends when the reader
   comes back, and the writer goes on. *)
let test_a_reader_that_never_reads_does_not_hold_drain () =
  ignore (Masc_tui_terminal_out.take_lost ());
  with_stdout_pipe (fun read_end ->
    let chunk = String.make 65536 'x' in
    for _ = 1 to 8 do
      Masc_tui_terminal_out.write chunk;
      Masc_tui_terminal_out.flush ()
    done;
    let limit_s = 0.2 in
    let started = Unix.gettimeofday () in
    let result = Masc_tui_terminal_out.drain ~within_s:limit_s in
    let elapsed = Unix.gettimeofday () -. started in
    Alcotest.(check bool) "abandoned" true
      (match result with
       | Masc_tui_terminal_out.Abandoned -> true
       | Masc_tui_terminal_out.Drained -> false);
    Alcotest.(check bool) "within the limit" true (elapsed >= limit_s && elapsed < limit_s +. 1.0);
    Alcotest.(check bool) "the screen is marked lost" true (Masc_tui_terminal_out.take_lost ());
    (* Exit drains more than once. A terminal still stuck is not waited on
       again for a whole limit. *)
    let again_started = Unix.gettimeofday () in
    let again = Masc_tui_terminal_out.drain ~within_s:reading_limit_s in
    Alcotest.(check bool) "still stuck: abandoned at once" true
      ((match again with
        | Masc_tui_terminal_out.Abandoned -> true
        | Masc_tui_terminal_out.Drained -> false)
       && Unix.gettimeofday () -. again_started < 1.0);
    (* The reader comes back: take whatever the writer still has in hand. *)
    Unix.set_nonblock read_end;
    let buffer = Bytes.create 65536 in
    let rec take_rest () =
      match Unix.read read_end buffer 0 (Bytes.length buffer) with
      | _ -> take_rest ()
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
          if Masc_tui_terminal_out.behind () then (Thread.delay 0.001; take_rest ())
    in
    take_rest ();
    Unix.clear_nonblock read_end;
    Masc_tui_terminal_out.write "tail";
    drained "the writer goes on" (Masc_tui_terminal_out.drain ~within_s:reading_limit_s);
    Alcotest.(check string) "and writes what came after" "tail" (read_exactly read_end 4))

(* A terminal that reads slowly is not one that stopped: the limit runs
   from its last read, so it gets everything even when the whole drain
   takes longer than the limit. *)
let test_a_slow_reader_gets_everything () =
  with_stdout_pipe (fun read_end ->
    let chunk = String.make 65536 'y' in
    let chunks = 4 in
    for _ = 1 to chunks do
      Masc_tui_terminal_out.write chunk;
      Masc_tui_terminal_out.flush ()
    done;
    let total = String.length chunk * chunks in
    let reader = Thread.create (fun () ->
      let buffer = Bytes.create 32768 in
      let rec go taken =
        if taken < total then begin
          Thread.delay 0.05;
          go (taken + Unix.read read_end buffer 0 (Bytes.length buffer))
        end
      in
      go 0) ()
    in
    let started = Unix.gettimeofday () in
    let result = Masc_tui_terminal_out.drain ~within_s:0.15 in
    let elapsed = Unix.gettimeofday () -. started in
    Thread.join reader;
    drained "a slow reader is drained" result;
    Alcotest.(check bool) "and the drain outlasted the limit" true (elapsed > 0.15))

let () =
  Alcotest.run "tui_terminal_out"
    [ ( "sink"
      , [ Alcotest.test_case "bytes keep their order" `Quick test_bytes_keep_their_order
        ; Alcotest.test_case "a stalled reader does not block the writer" `Quick
            test_a_stalled_reader_does_not_block_the_writer
        ; Alcotest.test_case "a failed write is reported and the writer lives" `Quick
            test_a_failed_write_is_reported_and_the_writer_lives
        ; Alcotest.test_case "a reader that never reads does not hold drain" `Quick
            test_a_reader_that_never_reads_does_not_hold_drain
        ; Alcotest.test_case "a slow reader gets everything" `Quick
            test_a_slow_reader_gets_everything
        ] )
    ]
