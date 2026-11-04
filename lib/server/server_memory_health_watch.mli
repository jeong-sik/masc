(** The Keeper memory health, kept and compared on the server's clock
    (RFC-0480 §3.4).

    Every {!compare_interval_s} the server computes
    {!Server_dashboard_http_keeper_memory_health.keeper_memory_health_http_json},
    keeps it as the answer [GET /api/v1/dashboard/keeper-memory-health] serves,
    and compares it with the last one. It announces [memory_health] for each
    Keeper whose row moved, appeared or left, and [memory_execution] when the
    Memory execution availability moved. The Librarian journal and the turn
    boundaries are read from where the last read stopped, so a computation
    reads only what was written since. *)

val compare_interval_s : float
(** The interval the route's cached answer used to live for, so a change is
    shown no later than it was. *)

val observe : base_path:string -> Yojson.Safe.t -> unit
(** Keeps [health] as the answer for [base_path] and announces what moved
    since the last answer kept for it, everything when there is none. *)

val latest : base_path:string -> Yojson.Safe.t option
(** The last answer kept for [base_path]. *)

val compute : base_path:string -> Yojson.Safe.t
(** Computes the answer on the worker pool, observes it and returns it. *)

val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> base_path:string -> unit
(** Computes now and then every interval. A computation that raises is logged
    and tried again on the next interval. *)
