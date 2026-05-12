(* RFC-0070 Phase 3b-iv.1b — Mock Docker_client. See .mli. *)

(* Injection queues — proper FIFO via [Queue.t] (amortized O(1) push +
   O(1) peek/pop), replacing the previous [q := !q @ [x]] list-append
   form which was O(n) per push and O(n²) across many injections (the
   ref-cell + list-append idiom from the original mock).  Behaviour
   is identical from the caller's perspective. *)

let run_queue
  : (Keeper_sandbox_oneshot_plan.t
     * (Docker_response.exec_result, Docker_client.sandbox_error) result)
      Queue.t
  = Queue.create ()

let exec_queue
  : ((Keeper_container_name.t * string)
     * (Docker_response.exec_result, Docker_client.sandbox_error) result)
      Queue.t
  = Queue.create ()

let ps_query_queue
  : ((string * string) list
     * (Docker_response.ps_record list, Docker_client.sandbox_error) result)
      Queue.t
  = Queue.create ()

let rm_queue
  : (Keeper_container_name.t * (unit, Docker_client.sandbox_error) result) Queue.t
  = Queue.create ()

(* [info_security_options] takes no input, so the queue holds bare
   responses (no input key to match on) — strict FIFO consume. *)
let info_security_options_queue
  : (string list, Docker_client.sandbox_error) result Queue.t
  = Queue.create ()

let image_present_queue
  : (string * (unit, Docker_client.sandbox_error) result) Queue.t
  = Queue.create ()

(* [run_detached]'s success value is mechanical ([plan.container_name]),
   so this queue is for *overriding* — inject an [Error] (or a
   different [Ok name]) when a test needs the spawn to fail. An empty
   queue ⇒ the deterministic [Ok plan.container_name], NOT a fail-closed
   error (deliberate deviation from the other queues: there is nothing
   to "expect" on the happy path). *)
let run_detached_queue
  : (Keeper_container_name.t, Docker_client.sandbox_error) result Queue.t
  = Queue.create ()

(* ── Injection API ──────────────────────────────────────────── *)

let inject_run plan response = Queue.add (plan, response) run_queue

let inject_exec ~container ~cmd response =
  Queue.add ((container, cmd), response) exec_queue
;;

let inject_ps_query ~labels response =
  Queue.add (labels, response) ps_query_queue
;;

let inject_rm container response = Queue.add (container, response) rm_queue

let inject_info_security_options response =
  Queue.add response info_security_options_queue
;;

let inject_image_present ~image response =
  Queue.add (image, response) image_present_queue
;;

let inject_run_detached response = Queue.add response run_detached_queue

(* ── Docker_client.S implementation ─────────────────────────── *)

(* Consume-on-match: peek the head; if it matches, pop and reply.
   Otherwise leave the queue intact and return Daemon_unreachable.
   Strict FIFO — out-of-order calls fail closed without consuming. *)

let run plan =
  match Queue.peek_opt run_queue with
  | Some (expected, response) when Keeper_sandbox_oneshot_plan.equal plan expected ->
    ignore (Queue.pop run_queue);
    response
  | _ -> Error Docker_client.Daemon_unreachable

let exec ?user:_ ?workdir:_ ~container ~cmd () =
  (* [?user] / [?workdir] shape the real [docker exec] argv (see
     {!Docker_client_real.exec_argv}) but do not affect the mocked
     response, so they are accepted and ignored for matching here —
     the injection key stays [(container, cmd)]. When a caller
     (Phase 4.1 [keeper_turn_sandbox_runtime] cutover) needs to
     assert the user/workdir threaded through, widen the injection
     key then; until then a narrower key keeps test setup minimal. *)
  match Queue.peek_opt exec_queue with
  | Some ((expected_c, expected_cmd), response)
    when Keeper_container_name.equal container expected_c
         && String.equal cmd expected_cmd ->
    ignore (Queue.pop exec_queue);
    response
  | _ -> Error Docker_client.Daemon_unreachable

let labels_equal a b =
  (* Order-sensitive comparison: parser layer (Phase 3b-iv.2) is
     responsible for canonicalising. *)
  List.length a = List.length b
  && List.for_all2
       (fun (k1, v1) (k2, v2) -> String.equal k1 k2 && String.equal v1 v2)
       a b

let ps_query ~labels =
  match Queue.peek_opt ps_query_queue with
  | Some (expected, response) when labels_equal labels expected ->
    ignore (Queue.pop ps_query_queue);
    response
  | _ -> Error Docker_client.Daemon_unreachable

let rm container =
  match Queue.peek_opt rm_queue with
  | Some (expected, response) when Keeper_container_name.equal container expected ->
    ignore (Queue.pop rm_queue);
    response
  | _ -> Error Docker_client.Daemon_unreachable

let info_security_options () =
  (* No input key — just consume the head. An empty queue fails closed
     with [Daemon_unreachable], same as an unexpected/out-of-order call
     on the keyed queues. *)
  match Queue.take_opt info_security_options_queue with
  | Some response -> response
  | None -> Error Docker_client.Daemon_unreachable
;;

let image_present ~image =
  match Queue.peek_opt image_present_queue with
  | Some (expected, response) when String.equal image expected ->
    ignore (Queue.pop image_present_queue);
    response
  | _ -> Error Docker_client.Daemon_unreachable

let run_detached plan =
  (* Override-or-default: a queued response (typically an [Error] for a
     failure test) wins; otherwise the deterministic [Ok
     plan.container_name] — the mock "spawns" by handing back the name
     the plan already determines, no daemon involved. *)
  match Queue.take_opt run_detached_queue with
  | Some response -> response
  | None -> Ok (Keeper_sandbox_session_plan.container_name plan)
;;

(* ── Fixture lifecycle ──────────────────────────────────────── *)

let reset () =
  Queue.clear run_queue;
  Queue.clear exec_queue;
  Queue.clear ps_query_queue;
  Queue.clear rm_queue;
  Queue.clear info_security_options_queue;
  Queue.clear image_present_queue;
  Queue.clear run_detached_queue

let pending_calls () =
  Queue.length run_queue
  + Queue.length exec_queue
  + Queue.length ps_query_queue
  + Queue.length rm_queue
  + Queue.length info_security_options_queue
  + Queue.length image_present_queue
  + Queue.length run_detached_queue
