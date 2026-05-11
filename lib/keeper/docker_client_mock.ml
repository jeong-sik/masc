(* RFC-0070 Phase 3b-iv.1b — Mock Docker_client. See .mli. *)

(* Injection queues. Each pair is (expected-input, prepared-response).
   FIFO consumption: only the head is consulted on each call. *)

let run_queue
  : (Keeper_sandbox_plan.t
     * (Docker_response.exec_result, Docker_client.sandbox_error) result)
      list ref
  = ref []

let exec_queue
  : ((Keeper_container_name.t * string)
     * (Docker_response.exec_result, Docker_client.sandbox_error) result)
      list ref
  = ref []

let ps_query_queue
  : ((string * string) list
     * (Docker_response.ps_record list, Docker_client.sandbox_error) result)
      list ref
  = ref []

let rm_queue
  : (Keeper_container_name.t * (unit, Docker_client.sandbox_error) result) list ref
  = ref []

(* ── Injection API ──────────────────────────────────────────── *)

let inject_run plan response = run_queue := !run_queue @ [ plan, response ]

let inject_exec ~container ~cmd response =
  exec_queue := !exec_queue @ [ (container, cmd), response ]

let inject_ps_query ~labels response =
  ps_query_queue := !ps_query_queue @ [ labels, response ]

let inject_rm container response =
  rm_queue := !rm_queue @ [ container, response ]

(* ── Docker_client.S implementation ─────────────────────────── *)

let run plan =
  match !run_queue with
  | (expected, response) :: rest when Keeper_sandbox_plan.equal plan expected ->
    run_queue := rest;
    response
  | _ -> Error Docker_client.Daemon_unreachable

let exec ~container ~cmd =
  match !exec_queue with
  | ((expected_c, expected_cmd), response) :: rest
    when Keeper_container_name.equal container expected_c
         && String.equal cmd expected_cmd ->
    exec_queue := rest;
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
  match !ps_query_queue with
  | (expected, response) :: rest when labels_equal labels expected ->
    ps_query_queue := rest;
    response
  | _ -> Error Docker_client.Daemon_unreachable

let rm container =
  match !rm_queue with
  | (expected, response) :: rest when Keeper_container_name.equal container expected ->
    rm_queue := rest;
    response
  | _ -> Error Docker_client.Daemon_unreachable

(* ── Fixture lifecycle ──────────────────────────────────────── *)

let reset () =
  run_queue := [];
  exec_queue := [];
  ps_query_queue := [];
  rm_queue := []

let pending_calls () =
  List.length !run_queue
  + List.length !exec_queue
  + List.length !ps_query_queue
  + List.length !rm_queue
