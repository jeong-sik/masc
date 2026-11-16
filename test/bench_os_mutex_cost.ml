(* Not a test: prints what Os_mutex.protect costs next to Mutex.protect
   (RFC a-fiber-that-suspends-while-holding-an-os-mutex-fails-at-unlock,
   §6.1 case 12). The Os_mutex workflow runs it on CI.

   Each section runs under both locks:
   - an empty section, outside Eio and inside it;
   - the section of a queued log line, inside Eio. It has the shape of
     [Log.write_to_sink] in lib/masc_log/log.ml: the line is encoded
     outside the lock, and the lock covers adding it to the writer's queue
     and signalling the writer. Here the same section takes the line back
     off the queue, so the queue stays one line long.

   A row is the median, lowest and highest ns per call over [rounds] rounds.
   Nothing is checked: the numbers are for the reader. *)

let rounds = 5

(* Calls per round: a round lasts milliseconds, far above the microsecond
   resolution of [Unix.gettimeofday]. *)
let empty_calls = 1_000_000
let log_line_calls = 200_000

let ns_per_call ~calls f =
  let started = Unix.gettimeofday () in
  for _call = 1 to calls do
    f ()
  done;
  (Unix.gettimeofday () -. started) *. 1e9 /. float_of_int calls
;;

let print_row what ~calls f =
  let samples = Array.init rounds (fun _round -> ns_per_call ~calls f) in
  Array.sort Float.compare samples;
  Printf.printf
    "%-40s %8.1f %8.1f %8.1f\n%!"
    what
    samples.(rounds / 2)
    samples.(0)
    samples.(rounds - 1)
;;

(* A line of the kind the server writes for every turn. *)
let log_entry =
  `Assoc
    [ "ts", `String "2026-11-16T05:01:02.123Z"
    ; "level", `String "info"
    ; "module", `String "keeper"
    ; "msg", `String "turn finished"
    ; "keeper", `String "polisher"
    ; "turn", `Int 42
    ]
;;

let writer_queue : string Queue.t = Queue.create ()
let writer_nonempty = Condition.create ()

let queued_log_line protect =
  let line = Yojson.Safe.to_string log_entry ^ "\n" in
  protect (fun () ->
    Queue.add line writer_queue;
    Condition.signal writer_nonempty;
    ignore (Queue.take writer_queue : string))
;;

let () =
  let mutex = Mutex.create () in
  let os_mutex = Os_mutex.create ~name:"bench" () in
  Printf.printf
    "OCaml %s, %s, %d recommended domains\n"
    Sys.ocaml_version
    Sys.os_type
    (Domain.recommended_domain_count ());
  Printf.printf "%-40s %8s %8s %8s\n" "ns per call" "median" "lowest" "highest";
  print_row "outside Eio, empty, Mutex" ~calls:empty_calls (fun () ->
    Mutex.protect mutex ignore);
  print_row "outside Eio, empty, Os_mutex" ~calls:empty_calls (fun () ->
    Os_mutex.protect os_mutex ignore);
  Eio_posix.run (fun _env ->
    print_row "inside Eio, empty, Mutex" ~calls:empty_calls (fun () ->
      Mutex.protect mutex ignore);
    print_row "inside Eio, empty, Os_mutex" ~calls:empty_calls (fun () ->
      Os_mutex.protect os_mutex ignore);
    print_row "inside Eio, log line, Mutex" ~calls:log_line_calls (fun () ->
      queued_log_line (Mutex.protect mutex));
    print_row "inside Eio, log line, Os_mutex" ~calls:log_line_calls (fun () ->
      queued_log_line (Os_mutex.protect os_mutex)))
;;
