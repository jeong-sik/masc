(* Unit + property tests for [Keeper_event_queue]. The properties
   correspond 1:1 to the safety invariants in
   [specs/keeper-state-machine/KeeperEventQueue.tla]:

     Conservation               -> test_conservation
     QueueNeverStarvedBySkip    -> test_queue_overrides_policy
     EmitMatchesEvidence        -> test_dequeue_only_consumes_enqueued

   Wire-up tests (heartbeat loop integration) live in a follow-up
   patch alongside [Keeper_keepalive] changes. *)

open Keeper_event_queue

(* The typed [payload] defaults to [Bootstrap] since these ordering tests do
   not need a domain payload. *)
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

let test_sort_by_urgency () =
  let s_low = make_stim ~urgency:Low "p1" in
  let s_imm = make_stim ~urgency:Immediate "p2" in
  let s_norm = make_stim ~urgency:Normal "p3" in
  let q = enqueue (enqueue (enqueue empty s_low) s_imm) s_norm in
  let sorted = sort_by_urgency q in
  match dequeue sorted with
  | Some (head, _) -> assert (head.urgency = Immediate)
  | None -> assert false

let test_sort_stable_within_bucket () =
  let s1 = make_stim ~urgency:Normal "p1" in
  let s2 = make_stim ~urgency:Normal "p2" in
  let s3 = make_stim ~urgency:Normal "p3" in
  let q = enqueue (enqueue (enqueue empty s1) s2) s3 in
  let sorted = sort_by_urgency q in
  match dequeue sorted with
  | Some (head, _) -> assert (head.post_id = "p1")
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
           { kind = Comment_added { comment_id = "c-one"; parent_id = None }
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

let test_durable_comment_identity () =
  let module Persistence = Keeper_event_queue_persistence in
  let rec remove_tree path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  let base_path = Filename.temp_dir "queued-comment-identity" "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () ->
    let board comment_id parent_id =
      { kind = Comment_added { comment_id; parent_id }; author = "alice";
        title = "thread"; content = "identical body"; hearth = None; updated_at = Some 1.0 }
    in
    let first = make_stim ~payload:(Board_signal (board "c-first" None)) "post" in
    let second = make_stim ~payload:(Board_signal (board "c-second" None)) "post" in
    let attention = make_stim ~payload:(Board_attention
      {candidate_id = "candidate"; signal = board "c-third" (Some "c-first")}) "post" in
    assert (not (stimulus_identity_equal first second));
    let persist source =
      match Persistence.enqueue_stimulus_if_absent_result ~base_path ~keeper_name:"reader" source with
      | Ok result -> result | Error detail -> failwith detail in
    List.iter (fun source -> assert (persist source = Persistence.Enqueued)) [first; second; attention];
    assert (persist first = Persistence.Already_present);
    let loaded = match Persistence.load_result ~base_path ~keeper_name:"reader" with
      | Ok queue -> queue | Error detail -> failwith detail in
    let rec drain queue = match dequeue queue with
      | None -> [] | Some (source, rest) -> source :: drain rest in
    assert (drain loaded = [first; second; attention]);
    let payload_json = match stimulus_to_yojson second with
      | `Assoc fields -> List.assoc "payload" fields | _ -> assert false in
    let malformed mutate =
      let json = match stimulus_to_yojson second, payload_json with
        | `Assoc fields, `Assoc payload ->
          `Assoc (List.map (fun (key, value) ->
            key, if key = "payload" then `Assoc (mutate payload) else value) fields)
        | _ -> assert false in
      assert (Result.is_error (stimulus_of_yojson json))
    in
    malformed (List.remove_assoc "comment_id");
    malformed (List.remove_assoc "parent_id");
    malformed (fun fields -> ("comment_id", `String "") :: List.remove_assoc "comment_id" fields);
    malformed (fun fields -> ("parent_id", `String " ") :: List.remove_assoc "parent_id" fields);
    malformed (fun fields -> ("comment_id", `String "duplicate") :: fields))

let () =
  test_empty ();
  test_enqueue_dequeue_fifo ();
  test_sort_by_urgency ();
  test_sort_stable_within_bucket ();
  test_conservation ();
  test_queue_overrides_policy ();
  test_dequeue_only_consumes_enqueued ();
  test_typed_payload_surface ();
  test_durable_comment_identity ();
  print_endline "Keeper_event_queue: all tests passed"
