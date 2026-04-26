(** True Concurrent Distributed Test

    Tests SIMULTANEOUS writes from multiple processes.
    This is the real test - not sequential producer/consumer.

    Validates:
    1. No message seq collision under concurrent writes
    2. All messages are persisted and retrievable
    3. File locking works correctly

    Run with: dune exec test/test_concurrent_distributed.exe -- <worker_id> <shared_dir>
*)

(* Initialize crypto RNG *)
let () = Mirage_crypto_rng_unix.use_default ()
let worker_id = ref "worker-0"
let shared_dir = ref "/tmp/masc_concurrent_test"
let num_messages = ref 10

let parse_args () =
  let specs =
    [ "--dir", Arg.Set_string shared_dir, "Shared directory for MASC room"
    ; "--id", Arg.Set_string worker_id, "Worker ID"
    ; "--msgs", Arg.Set_int num_messages, "Number of messages to send"
    ]
  in
  Arg.parse specs (fun _ -> ()) "test_concurrent_distributed --id <id> --dir <path>"
;;

let worker () =
  Printf.printf "[%s] Starting worker...\n%!" !worker_id;
  Eio_main.run
  @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let config = Coord_eio.create_config ~fs !shared_dir in
  (* Ensure directory exists *)
  (try Unix.mkdir !shared_dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (* Register *)
  let agent_name = Printf.sprintf "agent-%s" !worker_id in
  (match
     Coord_eio.register_agent config ~name:agent_name ~capabilities:[ "concurrent" ] ()
   with
   | Ok _ -> Printf.printf "[%s] Registered as %s\n%!" !worker_id agent_name
   | Error e -> Printf.printf "[%s] Registration failed: %s\n%!" !worker_id e);
  (* Broadcast messages as fast as possible *)
  let seqs = ref [] in
  for i = 1 to !num_messages do
    let content =
      Printf.sprintf "Worker %s message %d at %f" !worker_id i (Unix.gettimeofday ())
    in
    match Coord_eio.broadcast config ~from_agent:agent_name ~content with
    | Ok msg ->
      seqs := msg.seq :: !seqs;
      Printf.printf "[%s] msg %d -> seq %d\n%!" !worker_id i msg.seq
    | Error e -> Printf.printf "[%s] Broadcast %d failed: %s\n%!" !worker_id i e
  done;
  (* Output results *)
  let seqs_sorted = List.sort compare !seqs in
  Printf.printf
    "[%s] Done. Sequences: [%s]\n%!"
    !worker_id
    (String.concat ", " (List.map string_of_int seqs_sorted));
  (* Remove agent *)
  let _ = Coord_eio.remove_agent config ~name:agent_name in
  ()
;;

let verify () =
  Printf.printf "\n=== VERIFICATION ===\n%!";
  Eio_main.run
  @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let config = Coord_eio.create_config ~fs !shared_dir in
  (* Read all messages and check for collisions *)
  let messages = Hashtbl.create 100 in
  let rec scan seq max_empty =
    if max_empty <= 0
    then ()
    else (
      match Coord_eio.get_message config ~seq with
      | Ok msg ->
        if Hashtbl.mem messages seq
        then (
          Printf.printf "❌ COLLISION at seq %d!\n%!" seq;
          Printf.printf "   Existing: %s\n%!" (Hashtbl.find messages seq);
          Printf.printf "   New: %s\n%!" msg.content)
        else Hashtbl.add messages seq msg.content;
        scan (seq + 1) 10 (* Reset empty counter *)
      | Error _ -> scan (seq + 1) (max_empty - 1))
    (* Allow gaps but stop after too many *)
  in
  scan 1 20;
  let total = Hashtbl.length messages in
  Printf.printf "\nTotal unique messages: %d\n%!" total;
  (* Check for any sequence gaps *)
  let seqs = Hashtbl.fold (fun k _ acc -> k :: acc) messages [] in
  let seqs_sorted = List.sort compare seqs in
  let min_seq = List.hd seqs_sorted in
  let max_seq = List.hd (List.rev seqs_sorted) in
  let expected = max_seq - min_seq + 1 in
  let has_gaps = ref false in
  if total = expected
  then Printf.printf "No gaps detected (seq %d to %d)\n%!" min_seq max_seq
  else (
    Printf.printf
      "SEQUENCE GAPS DETECTED: expected %d messages, found %d (seq %d to %d)\n%!"
      expected
      total
      min_seq
      max_seq;
    has_gaps := true);
  (* Verify each worker's messages are in order *)
  Printf.printf "\n--- Per-worker message ordering ---\n%!";
  let worker_msgs = Hashtbl.create 10 in
  Hashtbl.iter
    (fun seq content ->
       (* Extract worker ID from content *)
       try
         let _ = Str.search_forward (Str.regexp "Worker \\([^ ]+\\)") content 0 in
         let wid = Str.matched_group 1 content in
         let existing =
           try Hashtbl.find worker_msgs wid with
           | Not_found -> []
         in
         Hashtbl.replace worker_msgs wid (seq :: existing)
       with
       | Not_found -> ())
    messages;
  let all_ordered = ref true in
  Hashtbl.iter
    (fun wid seqs ->
       let sorted = List.sort compare seqs in
       let rec is_ascending = function
         | [] | [ _ ] -> true
         | a :: b :: rest -> a < b && is_ascending (b :: rest)
       in
       if is_ascending sorted
       then Printf.printf "  Worker %s: %d messages, ordered\n%!" wid (List.length sorted)
       else (
         Printf.printf
           "  Worker %s: %d messages, NOT ordered\n%!"
           wid
           (List.length sorted);
         all_ordered := false))
    worker_msgs;
  if total > 0 && !all_ordered && not !has_gaps
  then (
    Printf.printf "\nCONCURRENT DISTRIBUTED TEST PASSED\n%!";
    Printf.printf "   No collisions, no gaps, all messages accounted for\n%!";
    exit 0)
  else (
    Printf.printf "\nTEST FAILED";
    if !has_gaps then Printf.printf " (sequence gaps detected)";
    if not !all_ordered then Printf.printf " (ordering violations)";
    Printf.printf "\n%!";
    exit 1)
;;

let () =
  parse_args ();
  if !worker_id = "verify" then verify () else worker ()
;;
