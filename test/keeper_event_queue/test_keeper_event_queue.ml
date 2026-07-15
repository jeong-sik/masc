(* Unit + property tests for [Keeper_event_queue]. The properties
   correspond 1:1 to the safety invariants in
   [specs/keeper-state-machine/KeeperEventQueue.tla]:

     Conservation               -> test_conservation
     QueueNeverStarvedBySkip    -> test_queue_overrides_policy
     EmitMatchesEvidence        -> test_dequeue_only_consumes_enqueued

   Wire-up tests (heartbeat loop integration) live in a follow-up
   patch alongside [Keeper_keepalive] changes. *)

open Keeper_event_queue

(* Stimuli are distinguished by [post_id] / [arrived_at]; the typed
   [payload] defaults to [Bootstrap] since the queue ordering/dedup
   logic is payload-agnostic. *)
let make_stim ?(urgency = Normal) ?(arrived_at = 0.0) ?(payload = Bootstrap) post_id =
  { post_id; urgency; arrived_at; payload }

(* ── Unit-level shape ──────────────────────────────────────────── *)

let test_empty () =
  assert (is_empty empty);
  assert (length empty = 0);
  assert (Option.is_none (dequeue empty))

let test_enqueue_dequeue_fifo () =
  let s1 = make_stim "p1" in
  let s2 = make_stim "p2" in
  let q = enqueue (enqueue empty s1) s2 in
  assert (length q = 2);
  match dequeue q with
  | Some (out, rest) ->
      assert (out.post_id = "p1");
      assert (length rest = 1);
      (match dequeue rest with
       | Some (out2, rest2) ->
           assert (out2.post_id = "p2");
           assert (is_empty rest2)
       | None -> assert false)
  | None -> assert false

(* ── TLA+ invariant correspondence ─────────────────────────────── *)

(* Conservation: enqueued >= dequeued at all times. *)
let test_conservation () =
  let stims = List.init 10 (fun i -> make_stim (Printf.sprintf "p%d" i)) in
  let q = List.fold_left enqueue empty stims in
  let rec drain n q =
    match dequeue q with
    | None -> n
    | Some (_, rest) -> drain (n + 1) rest
  in
  let dequeued = drain 0 q in
  assert (List.length stims >= dequeued);
  assert (dequeued = List.length stims)

(* QueueNeverStarvedBySkip surrogate: a non-empty queue must yield a
   stimulus on dequeue. The Policy Layer is responsible for never
   choosing Skip in that state; here we only confirm the data
   channel is ready when the policy asks. *)
let test_queue_overrides_policy () =
  let q = enqueue empty (make_stim "p1") in
  assert (not (is_empty q));
  match dequeue q with
  | Some (out, _) -> assert (out.post_id = "p1")
  | None -> assert false

(* EmitMatchesEvidence: dequeue only consumes stimuli that have been
   enqueued — there is no spurious Some. *)
let test_dequeue_only_consumes_enqueued () =
  assert (Option.is_none (dequeue empty));
  let q = enqueue empty (make_stim "p1") in
  let _, rest = Option.get (dequeue q) in
  assert (Option.is_none (dequeue rest))

(* Typed payload (RFC-0020): the kind is carried as a closed variant,
   not classified from a JSON-prefixed string. *)
let test_typed_payload_surface () =
  let stay = make_stim "p8" in
  assert (not (is_board_signal stay.payload));
  let board =
    make_stim
      ~payload:
        (Board_signal
           { kind = Comment_added
           ; author = "alice"
           ; title = "t"
           ; content = "c"
           ; hearth = None
           ; updated_at = None
           })
      "p9"
  in
  assert (is_board_signal board.payload);
  assert (String.equal (payload_kind_label board.payload) "board_signal")

let () =
  test_empty ();
  test_enqueue_dequeue_fifo ();
  test_conservation ();
  test_queue_overrides_policy ();
  test_dequeue_only_consumes_enqueued ();
  test_typed_payload_surface ();
  print_endline "Keeper_event_queue: all tests passed"
