(** RFC-0107 Phase D Connection Pool — implementation stub.

    Phase D.2a places the type-correct stub so that downstream callers
    (Phase D.2c migration shim, Phase D.2d tests) can compile against
    the [Pool.t] / [Pool.request] / [Pool.with_connection] surface
    before the piaf binding lands in D.2b.

    All public functions raise [Failure] until D.2b. The intent is to
    fail fast and loud at runtime so a "stub-call-from-prod" cannot go
    unnoticed; type-only consumers (modules that take a [Pool.t] in
    function signatures without invoking it) build clean. *)

type config = {
  max_idle_per_host : int;
  max_total_idle    : int;
  idle_ttl_seconds  : float;
  connect_timeout_seconds : float;
}

let default_config = {
  max_idle_per_host = 8;
  max_total_idle    = 256;
  idle_ttl_seconds  = 60.0;
  connect_timeout_seconds = 5.0;
}

(* Phase D.2b fills in the actual fields (Host_key -> piaf Client.t
   queue, TLS context cache, eviction fiber stop signal, stats
   counters). The current type body is deliberately empty so any
   accidental field access fails at compile time. *)
type t = unit

let stub_msg fn =
  Failure
    (Printf.sprintf
       "Pool.%s: not implemented (RFC-0107 Phase D.2a stub; \
        binding lands in D.2b)" fn)

let create ~sw:_ ~net:_ ?https:_ ?config:_ () : t =
  raise (stub_msg "create")

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

type http_method = [ `GET | `POST | `PUT | `DELETE | `HEAD | `PATCH ]

let request _t ?clock:_ ?timeout_seconds:_ ~method_:_ ~url:_
            ?headers:_ ?body:_ () : (response, string) result =
  raise (stub_msg "request")

let with_connection _t ~url:_ _f =
  raise (stub_msg "with_connection")

type stats = {
  idle_per_host : (string * int) list;
  total_idle : int;
  total_inflight : int;
  reuse_count_total : int;
  evict_count_total : int;
  create_count_total : int;
}

let stats _t : stats =
  raise (stub_msg "stats")
