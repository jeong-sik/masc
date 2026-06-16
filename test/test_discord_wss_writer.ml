(* Audit T7 — Discord WSS writer fiber death must record its cause.

   [Discord_wss_connection.writer_loop] contains [Eio.Io] on purpose:
   the writer runs on the per-session switch, so an escaping exception
   would fail that switch and tear down the whole gateway client.
   Before this fix the handler was [Eio.Io _ -> ()] and the TLS/WSS
   write failure cause was dropped.  These tests pin the contract:

   - [Eio.Io] from the flow write (or the queue take) returns instead
     of raising, and the cause lands in the log ring as a Discord warn
     entry carrying the exception text.
   - Non-[Eio.Io] exceptions still propagate (no silent catch-all). *)

open Alcotest

type Eio.Exn.Backend.t += Simulated_failure

let io_exn () =
  Eio.Net.err (Eio.Net.Connection_reset Simulated_failure)

let contains_substring haystack needle =
  let n = String.length haystack and m = String.length needle in
  let rec go i = i + m <= n && (String.sub haystack i m = needle || go (i + 1)) in
  go 0

(* [Ring.recent ~since_seq:n] returns entries with seq > n, and the
   first entry ever pushed has seq 0 — so the empty-ring sentinel must
   be -1, not 0. *)
let last_ring_seq () =
  match Log.Ring.recent ~limit:1 () with
  | [] -> -1
  | e :: _ -> e.Log.Ring.seq

let writer_warn_entries ~since_seq =
  Log.Ring.recent ~module_filter:"Discord" ~since_seq ()
  |> List.filter (fun (e : Log.Ring.entry) ->
       e.level = Log.Warn
       && contains_substring e.message "wss writer fiber terminated")

(* The realistic T7 path: a frame is dequeued and encoded, then the TLS
   write raises [Eio.Io].  The loop must return (containment) and the
   cause must be visible in the log ring. *)
let test_flow_write_io_contained_and_logged () =
  Mirage_crypto_rng_unix.use_default ();
  let seq_before = last_ring_seq () in
  let takes = ref 0 in
  let frame = Websocket.Frame.create ~content:"heartbeat" () in
  Discord_wss_connection.writer_loop
    ~take:(fun () -> incr takes; frame)
    ~write_string:(fun _ -> raise (io_exn ()));
  check int "writer stopped after the failed write" 1 !takes;
  match writer_warn_entries ~since_seq:seq_before with
  | [] -> fail "no Discord warn entry recorded for writer death"
  | e :: _ ->
    check bool "warn message carries the exception text" true
      (contains_substring e.Log.Ring.message "Connection_reset")

(* [Eio.Io] raised by the queue take is contained the same way. *)
let test_take_io_contained_and_logged () =
  let seq_before = last_ring_seq () in
  Discord_wss_connection.writer_loop
    ~take:(fun () -> raise (io_exn ()))
    ~write_string:(fun _ -> ());
  check bool "Discord warn entry recorded" true
    (writer_warn_entries ~since_seq:seq_before <> [])

(* Anything that is not [Eio.Io] must escape — the handler is not a
   catch-all. *)
let test_non_io_propagates () =
  check_raises "non-Io exception escapes" (Failure "boom") (fun () ->
    Discord_wss_connection.writer_loop
      ~take:(fun () -> failwith "boom")
      ~write_string:(fun _ -> ()))

let () =
  run "discord_wss_writer"
    [ ( "writer_loop containment",
        [ test_case "flow write Eio.Io is contained and logged" `Quick
            test_flow_write_io_contained_and_logged
        ; test_case "queue take Eio.Io is contained and logged" `Quick
            test_take_io_contained_and_logged
        ; test_case "non-Io exception propagates" `Quick
            test_non_io_propagates
        ] )
    ]
