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

let test_bytes_keep_their_order () =
  with_stdout_pipe (fun read_end ->
    Masc_tui_terminal_out.write "a";
    Masc_tui_terminal_out.write "bc";
    Masc_tui_terminal_out.flush ();
    Masc_tui_terminal_out.write "d";
    Masc_tui_terminal_out.drain ();
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
    Masc_tui_terminal_out.drain ();
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
    Masc_tui_terminal_out.drain ();
    Alcotest.(check bool) "loss reported" true (Masc_tui_terminal_out.take_lost ());
    Alcotest.(check bool) "loss reported once" false (Masc_tui_terminal_out.take_lost ());
    Unix.dup2 saved Unix.stdout;
    Unix.close saved;
    Masc_tui_terminal_out.write "after";
    Masc_tui_terminal_out.drain ();
    Alcotest.(check string) "writer still writes" "after" (read_exactly read_end 5))

let () =
  Alcotest.run "tui_terminal_out"
    [ ( "sink"
      , [ Alcotest.test_case "bytes keep their order" `Quick test_bytes_keep_their_order
        ; Alcotest.test_case "a stalled reader does not block the writer" `Quick
            test_a_stalled_reader_does_not_block_the_writer
        ; Alcotest.test_case "a failed write is reported and the writer lives" `Quick
            test_a_failed_write_is_reported_and_the_writer_lives
        ] )
    ]
