(* Chat/autonomous turn admission under contention.

   The autonomous lane and the queue consumer compete for one per-Keeper turn
   slot. Both lanes are covered individually — Keeper_turn_admission's own
   suite pins the admission predicates, and the consumer suite pins receipt
   lifecycle — but nothing drives the two against each other. That gap is the
   reason a change to either lane's admission rule can silently starve the
   other: the failure only appears when a consumer and a repeating autonomous
   driver share a slot.

   These tests run the production Keeper_chat_consumer control loop against an
   autonomous driver on the same slot. The provider call is the only thing
   replaced: handle_turn calls Keeper_turn_admission.run_serialized, which is
   what the production handler reaches (keeper_chat_consumer.ml run_leased_turn
   -> server_bootstrap_loops.ml handle_turn -> ... -> keeper_turn.ml
   handle_keeper_invocation -> run_serialized).

   Assertions are one-sided on purpose: they pin that a queued receipt is
   admitted, not which admission rule admitted it. That keeps the tests valid
   across changes to the admission predicates while still failing if either
   lane starves the other. *)

open Masc

let failures = ref 0

let check name condition =
  if condition
  then Printf.printf "  ✓ %s\n%!" name
  else (
    incr failures;
    Printf.printf "  ✗ %s\n%!" name)

let keeper_name = "chat-admission-contention-keeper"

(* Wall-clock budgets are generous because CI shares cores; the turns
   themselves are short so a healthy run finishes far inside them. *)
let turn_seconds = 0.2
let receipt_count = 3
let budget_seconds = 20.0

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun n -> rm_rf (Filename.concat path n));
      Unix.rmdir path)
    else Unix.unlink path

let with_env body =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-chat-admission-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let clock = Eio.Stdenv.clock env in
       let config = Workspace.default_config base in
       ignore (Workspace.init config ~agent_name:(Some keeper_name));
       Keeper_chat_queue.For_testing.reset ();
       Keeper_turn_admission.For_testing.reset ();
       let report = Keeper_chat_queue.configure_persistence ~base_path:base in
       check "chat queue persistence configured" (report.load_errors = []);
       Fun.protect
         ~finally:(fun () ->
           Keeper_chat_queue.For_testing.reset ();
           Keeper_turn_admission.For_testing.reset ())
         (fun () -> body ~base ~clock))

let message content =
  { Keeper_chat_queue.content
  ; user_blocks = []
  ; attachments = []
  ; timestamp = 0.0
  ; source = Keeper_chat_queue.Discord { channel_id = "c1"; user_id = "u1" }
  ; user_row_origin = Keeper_chat_store.Already_persisted_upstream
  }

(* Wire the same transition observers the runtime installs, so the consumer is
   edge-woken on durable queue mutations and on turn-slot release. *)
let install_observers ~base =
  let canonical = Keeper_registry_types.canonical_base_path_exn base in
  Keeper_chat_queue.set_transition_observer
    (Some
       (fun ~keeper_name ~revision:_ ->
          Keeper_chat_consumer.notify_transition ~keeper_name));
  Keeper_turn_admission.set_slot_transition_observer
    (Some
       (fun ~base_path ~keeper_name ~transition:_ ->
          if String.equal base_path canonical
          then Keeper_chat_consumer.notify_transition ~keeper_name))

exception Budget_reached

(* [gap_seconds = 0.] is the back-to-back shape the autonomous lane can reach:
   Keeper_keepalive_signal.interruptible_sleep consumes a pre-armed wakeup
   before sleeping, so the heartbeat cadence is not a floor. *)
let run_contention ~base ~clock ~gap_seconds ~on_admitted =
  install_observers ~base;
  let admitted = ref 0 in
  let enqueued = ref 0 in
  let autonomous_turns = ref 0 in
  let handle_turn ~sw:_ ~keeper_name:_ ~delivery_key:_ ~queued_message:_ =
    match
      Keeper_turn_admission.run_serialized ~base_path:base ~keeper_name
        (fun () ->
           incr admitted;
           on_admitted !admitted)
    with
    | `Ran () -> Keeper_chat_consumer.Delivered { outcome_ref = "contention-turn" }
    | `Rejected rejection -> Keeper_chat_consumer.Deferred { rejection }
  in
  (try
     Eio.Switch.run (fun sw ->
       Eio.Fiber.fork ~sw (fun () ->
         Keeper_chat_consumer.run ~sw ~clock ~base_path:base ~handle_turn);
       (* Autonomous driver: keep re-attempting admission for the whole run. *)
       Eio.Fiber.fork ~sw (fun () ->
         let rec drive () =
           (match
              Keeper_turn_admission.run_if_free ~base_path:base ~keeper_name
                (fun () -> Eio.Time.sleep clock turn_seconds)
            with
            | `Ran () -> incr autonomous_turns
            | `Busy _ -> ());
           (* Unconditional: at [gap_seconds = 0.] this is the yield that keeps
              a Busy result from spinning the driver against the scheduler. *)
           Eio.Time.sleep clock gap_seconds;
           drive ()
         in
         drive ());
       Eio.Fiber.fork ~sw (fun () ->
         for i = 1 to receipt_count do
           Eio.Time.sleep clock (turn_seconds *. 1.5);
           match
             Keeper_chat_queue.enqueue ~keeper_name
               (message (Printf.sprintf "contention-%d" i))
           with
           | Ok _ -> incr enqueued
           | Error error ->
             Printf.printf "  enqueue failed: %s\n%!"
               (Keeper_chat_queue.mutation_error_to_string error)
         done);
       (* Stop as soon as every receipt is through, or when the budget runs
          out — whichever comes first. *)
       Eio.Fiber.fork ~sw (fun () ->
         let rec wait elapsed =
           if !admitted >= receipt_count || elapsed > budget_seconds
           then ()
           else (
             Eio.Time.sleep clock 0.05;
             wait (elapsed +. 0.05))
         in
         wait 0.0;
         Eio.Switch.fail sw Budget_reached))
   with
   | Budget_reached -> ()
   | Eio.Cancel.Cancelled _ -> ());
  !enqueued, !admitted, !autonomous_turns

let test_back_to_back_autonomous_does_not_starve_chat () =
  Printf.printf
    "Test: back-to-back autonomous turns do not starve the queue consumer\n%!";
  with_env (fun ~base ~clock ->
    let enqueued, admitted, autonomous_turns =
      run_contention ~base ~clock ~gap_seconds:0. ~on_admitted:(fun _ -> ())
    in
    check "every receipt was enqueued" (enqueued = receipt_count);
    check
      (Printf.sprintf "every receipt was admitted (%d/%d)" admitted receipt_count)
      (admitted = receipt_count);
    (* The driver must actually have contended, otherwise the test proves
       nothing about contention. *)
    check
      (Printf.sprintf "autonomous lane ran during the test (%d turns)" autonomous_turns)
      (autonomous_turns > 0))

let test_heartbeat_shaped_autonomous_does_not_starve_chat () =
  Printf.printf
    "Test: heartbeat-shaped autonomous cycles do not starve the queue consumer\n%!";
  with_env (fun ~base ~clock ->
    let enqueued, admitted, autonomous_turns =
      run_contention ~base ~clock ~gap_seconds:(turn_seconds *. 1.5)
        ~on_admitted:(fun _ -> ())
    in
    check "every receipt was enqueued" (enqueued = receipt_count);
    check
      (Printf.sprintf "every receipt was admitted (%d/%d)" admitted receipt_count)
      (admitted = receipt_count);
    check
      (Printf.sprintf "autonomous lane ran during the test (%d turns)" autonomous_turns)
      (autonomous_turns > 0))

let test_receipts_are_admitted_in_fifo_order () =
  Printf.printf "Test: queued receipts are admitted one at a time, in order\n%!";
  with_env (fun ~base ~clock ->
    let concurrent = ref false in
    let in_turn = ref false in
    let _, admitted, _ =
      run_contention ~base ~clock ~gap_seconds:0.
        ~on_admitted:(fun _ ->
          if !in_turn then concurrent := true;
          in_turn := true;
          in_turn := false)
    in
    check "receipts were admitted" (admitted > 0);
    check "no two chat turns held the slot at once" (not !concurrent))

let () =
  Printf.printf "=== keeper chat/autonomous admission contention ===\n%!";
  test_back_to_back_autonomous_does_not_starve_chat ();
  test_heartbeat_shaped_autonomous_does_not_starve_chat ();
  test_receipts_are_admitted_in_fifo_order ();
  if !failures > 0
  then (
    Printf.printf "\n%d check(s) failed\n%!" !failures;
    exit 1)
  else Printf.printf "\nall checks passed\n%!"
