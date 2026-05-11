(* RFC-0070 Phase 3b-iv.1b — Mock Docker_client. See .mli. *)

(* Injection queues — proper FIFO via [Queue.t] (amortized O(1) push +
   O(1) peek/pop), replacing the previous [q := !q @ [x]] list-append
   form which was O(n) per push and O(n²) across many injections (the
   ref-cell + list-append idiom from the original mock).  Behaviour
   is identical from the caller's perspective. *)

let run_queue
  : (Keeper_sandbox_plan.t
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

(* ── Injection API ──────────────────────────────────────────── *)

let inject_run plan response = Queue.add (plan, response) run_queue

let inject_exec ~container ~cmd response =
  Queue.add ((container, cmd), response) exec_queue
;;

let inject_ps_query ~labels response =
  Queue.add (labels, response) ps_query_queue
;;

let inject_rm container response = Queue.add (container, response) rm_queue

(* ── Docker_client.S implementation ─────────────────────────── *)

(* Consume-on-match: peek the head; if it matches, pop and reply.
   Otherwise leave the queue intact and return Daemon_unreachable.
   Strict FIFO — out-of-order calls fail closed without consuming. *)

let run plan =
  match Queue.peek_opt run_queue with
  | Some (expected, response) when Keeper_sandbox_plan.equal plan expected ->
    ignore (Queue.pop run_queue);
    response
  | _ -> Error Docker_client.Daemon_unreachable

let exec ~container ~cmd =
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

(* ── Fixture lifecycle ──────────────────────────────────────── *)

let reset () =
  Queue.clear run_queue;
  Queue.clear exec_queue;
  Queue.clear ps_query_queue;
  Queue.clear rm_queue

let pending_calls () =
  Queue.length run_queue
  + Queue.length exec_queue
  + Queue.length ps_query_queue
  + Queue.length rm_queue
