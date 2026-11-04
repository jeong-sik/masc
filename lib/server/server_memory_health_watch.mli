(** The Keeper memory health, kept and compared on the server's clock
    (RFC-0480 §3.4).

    Every {!compare_interval_s} the server computes
    {!Server_dashboard_http_keeper_memory_health.keeper_memory_health_http_json},
    keeps it as the answer [GET /api/v1/dashboard/keeper-memory-health] serves,
    and compares it with the last one. It announces [memory_health] for each
    Keeper whose row moved, appeared or left. The Librarian journal and the
    turn boundaries are read from where the last read stopped, so a computation
    reads only what was written since.

    One computation runs per workspace at a time. A reader that asks while one
    runs waits for it, so a burst of reads after boot computes once. *)

val compare_interval_s : float
(** The interval the route's cached answer used to live for, so a change is
    shown no later than it was. *)

type answer =
  | Computed of Yojson.Safe.t
  | Failed of string
      (** The last computation raised or timed out. The rows it would have
          replaced stay the ones the next computation is compared with. *)

val observe : base_path:string -> Yojson.Safe.t -> unit
(** Keeps [health] as the answer for [base_path] and announces each Keeper
    whose row moved since the last answer kept for it, every Keeper when
    there is none. *)

val latest : base_path:string -> answer option
(** The last answer kept for [base_path]. *)

val compute : base_path:string -> answer
(** Computes the answer on the worker pool and observes it, or waits for the
    computation already running for [base_path]. A waiter whose computation
    was cancelled computes again. *)

val compute_window_key : base_path:string -> string
(** The name a bounded wait for [base_path]'s computation is reported under. *)

val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> base_path:string -> unit
(** Computes now and then every interval, each wait bounded by
    {!Dashboard_cache.within_default_compute_window}. A computation that fails
    or outlasts that window is kept as [Failed] and tried again on the next
    interval. *)
