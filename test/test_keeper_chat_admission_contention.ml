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
   what the production handler reaches (keeper_chat_consumer.ml observes
   Pending -> server_bootstrap_loops.ml handle_turn -> process_single_turn ->
   keeper_turn.ml handle_keeper_invocation -> run_serialized -> exact claim).

   The starvation cases pin that every queued receipt is admitted. The FIFO
   case additionally compares the exact receipt delivery keys and contents in
   enqueue order, while both lanes yield inside an instrumented slot body so
   overlap is observable instead of assumed. *)

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

type contention_result =
  { enqueued : (Keeper_chat_queue.enqueue_receipt * Keeper_chat_queue.queued_message) list
  ; admitted :
      ( Keeper_chat_delivery_identity.delivery_key
        * Keeper_chat_queue.queued_message )
        list
  ; autonomous_turns : int
  ; max_active_turns : int
  }

(* [gap_seconds = 0.] is the back-to-back shape the autonomous lane can reach:
   Keeper_keepalive_signal.interruptible_sleep consumes a pre-armed wakeup
   before sleeping, so the heartbeat cadence is not a floor. *)
let run_contention ~base ~clock ~gap_seconds =
  install_observers ~base;
  let admitted = ref [] in
  let enqueued = ref [] in
  let autonomous_turns = ref 0 in
  let active_turns = ref 0 in
  let max_active_turns = ref 0 in
  let with_active_turn body =
    incr active_turns;
    max_active_turns := max !max_active_turns !active_turns;
    Fun.protect ~finally:(fun () -> decr active_turns) body
  in
  let handle_turn
      ~sw:_
      ~keeper_name:_
      ~receipt_ids
      ~queued_message
      ~on_admitted =
    let delivery_key =
      Keeper_chat_delivery_identity.Queue_receipts receipt_ids
    in
    match
      Keeper_turn_admission.run_serialized ~base_path:base ~keeper_name
        (fun () ->
           match on_admitted () with
           | Error detail ->
             Keeper_chat_consumer.Failed
               { kind = Keeper_chat_queue.Internal_error
               ; detail
               ; outcome_ref = None
               }
           | Ok () ->
             with_active_turn (fun () ->
               admitted := (delivery_key, queued_message) :: !admitted;
               Eio.Time.sleep clock (turn_seconds /. 2.));
             Keeper_chat_consumer.Delivered
               { outcome_ref = "contention-turn" })
    with
    | `Ran outcome -> outcome
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
                (fun () ->
                   with_active_turn (fun () ->
                     Eio.Time.sleep clock turn_seconds))
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
           let queued_message = message (Printf.sprintf "contention-%d" i) in
           match Keeper_chat_queue.enqueue ~keeper_name queued_message with
           | Ok receipt -> enqueued := (receipt, queued_message) :: !enqueued
           | Error error ->
             Printf.printf "  enqueue failed: %s\n%!"
               (Keeper_chat_queue.mutation_error_to_string error)
         done);
       (* Stop as soon as every receipt is through, or when the budget runs
          out — whichever comes first. *)
       Eio.Fiber.fork ~sw (fun () ->
         let rec wait elapsed =
           if List.length !admitted >= receipt_count || elapsed > budget_seconds
           then ()
           else (
             Eio.Time.sleep clock 0.05;
             wait (elapsed +. 0.05))
         in
         wait 0.0;
         Eio.Switch.fail sw Budget_reached))
   with
   | Budget_reached -> ());
  { enqueued = List.rev !enqueued
  ; admitted = List.rev !admitted
  ; autonomous_turns = !autonomous_turns
  ; max_active_turns = !max_active_turns
  }

let test_back_to_back_autonomous_does_not_starve_chat () =
  Printf.printf
    "Test: back-to-back autonomous turns do not starve the queue consumer\n%!";
  with_env (fun ~base ~clock ->
    let result = run_contention ~base ~clock ~gap_seconds:0. in
    check "every receipt was enqueued" (List.length result.enqueued = receipt_count);
    check
      (Printf.sprintf
         "every receipt was admitted (%d/%d)"
         (List.length result.admitted)
         receipt_count)
      (List.length result.admitted = receipt_count);
    (* The driver must actually have contended, otherwise the test proves
       nothing about contention. *)
    check
      (Printf.sprintf
         "autonomous lane ran during the test (%d turns)"
         result.autonomous_turns)
      (result.autonomous_turns > 0))

let test_heartbeat_shaped_autonomous_does_not_starve_chat () =
  Printf.printf
    "Test: heartbeat-shaped autonomous cycles do not starve the queue consumer\n%!";
  with_env (fun ~base ~clock ->
    let result =
      run_contention ~base ~clock ~gap_seconds:(turn_seconds *. 1.5)
    in
    check "every receipt was enqueued" (List.length result.enqueued = receipt_count);
    check
      (Printf.sprintf
         "every receipt was admitted (%d/%d)"
         (List.length result.admitted)
         receipt_count)
      (List.length result.admitted = receipt_count);
    check
      (Printf.sprintf
         "autonomous lane ran during the test (%d turns)"
         result.autonomous_turns)
      (result.autonomous_turns > 0))

let test_receipts_are_admitted_in_fifo_order () =
  Printf.printf "Test: queued receipts are admitted one at a time, in order\n%!";
  with_env (fun ~base ~clock ->
    let result = run_contention ~base ~clock ~gap_seconds:0. in
    let expected_contents =
      List.map
        (fun (_, queued_message) -> queued_message.Keeper_chat_queue.content)
        result.enqueued
    in
    let admitted_contents =
      List.map
        (fun (_, queued_message) -> queued_message.Keeper_chat_queue.content)
        result.admitted
    in
    let expected_delivery_keys =
      List.map
        (fun ((receipt : Keeper_chat_queue.enqueue_receipt), _) ->
           Keeper_chat_delivery_identity.Queue_receipts
             (Keeper_chat_delivery_identity.Receipt_ids.singleton
                receipt.Keeper_chat_queue.receipt_id))
        result.enqueued
    in
    let admitted_delivery_keys = List.map fst result.admitted in
    let keys_match =
      List.length expected_delivery_keys = List.length admitted_delivery_keys
      && List.for_all2
           Keeper_chat_delivery_identity.delivery_key_equal
           expected_delivery_keys
           admitted_delivery_keys
    in
    check "every receipt content is admitted in FIFO order"
      (expected_contents = admitted_contents);
    check "every exact receipt delivery key is admitted in FIFO order" keys_match;
    check "chat and autonomous turns never overlap in the slot"
      (result.max_active_turns = 1))

let test_queued_server_turn_has_no_second_durable_request () =
  Printf.printf
    "Test: queued server turn reaches exact claim without a second durable request\n%!";
  with_env (fun ~base ~clock ->
    Keeper_msg_async.For_testing.clear ();
    Fun.protect
      ~finally:Keeper_msg_async.For_testing.clear
      (fun () ->
         let claim_count = ref 0 in
         let continuation_channel =
           Keeper_continuation_channel.dashboard
             ~thread_id:"queued-inline-boundary"
           |> function
           | Ok channel -> channel
           | Error detail -> failwith detail
         in
         let payload :
             Server_routes_http_keeper_stream.keeper_chat_stream_request =
           { name = keeper_name
           ; message = "queued inline boundary"
           ; user_blocks = []
           ; turn_instructions = None
           ; surface_context = None
           ; channel = ""
           ; channel_user_id = ""
           ; channel_user_name = ""
           ; channel_workspace_id = ""
           ; attachments = []
           }
         in
         let receipt_id =
           match Keeper_chat_queue.enqueue ~keeper_name (message payload.message) with
           | Ok receipt -> receipt.Keeper_chat_queue.receipt_id
           | Error error ->
             failwith (Keeper_chat_queue.mutation_error_to_string error)
         in
         let receipt_ids =
           Keeper_chat_delivery_identity.Receipt_ids.singleton receipt_id
         in
         let state = Mcp_server.For_testing.create_state ~base_path:base in
         let outcome =
           Eio.Switch.run (fun execution_sw ->
             Server_routes_http_keeper_stream.process_single_turn
               ~user_row_origin:Keeper_chat_store.Already_persisted_upstream
               ~submission:
                 (Queued_receipt
                    { receipt_ids
                    ; claim =
                        (fun () ->
                           incr claim_count;
                           Error "synthetic exact-claim refusal")
                    ; execution_sw
                    })
               ~state
               ~clock
               ~auth_token:None
               ~thread_id:"queued-inline-boundary"
               ~continuation_channel
               ~closed:(ref false)
               ~client_disconnects:None
               ~payload
               ~run_id:"queued-inline-run"
               ~message_id:"queued-inline-message"
               ~agent_name:keeper_name
               ~submitted_by:keeper_name
               ~events:(Keeper_chat_events.create ()))
         in
         check "exact Pending claim callback ran once" (!claim_count = 1);
         check "claim refusal leaves no queued turn outcome" (outcome = None);
         check
           "claim refusal leaves the durable receipt Pending"
           (match Keeper_chat_queue.lookup_receipt ~keeper_name ~receipt_id with
            | Ok
                { receipt =
                    Some { state = Keeper_chat_queue.Pending; _ }
                ; _
                } ->
              true
            | Ok _ | Error _ -> false);
         check
           "claim refusal emits no transcript effect"
           (Keeper_chat_store.load ~base_dir:base ~keeper_name = []);
         check
           "queued server turn reserved no durable async request id"
           (Keeper_msg_async.For_testing.reserved_request_id_count () = 0);
         check
           "queued server turn owns no durable async request switch"
           (Keeper_msg_async.For_testing.active_switch_count () = 0)))

let () =
  Printf.printf "=== keeper chat/autonomous admission contention ===\n%!";
  test_back_to_back_autonomous_does_not_starve_chat ();
  test_heartbeat_shaped_autonomous_does_not_starve_chat ();
  test_receipts_are_admitted_in_fifo_order ();
  test_queued_server_turn_has_no_second_durable_request ();
  if !failures > 0
  then (
    Printf.printf "\n%d check(s) failed\n%!" !failures;
    exit 1)
  else Printf.printf "\nall checks passed\n%!"
