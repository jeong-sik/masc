(** Process-owned observation of Dashboard_tla_specs' external source files. *)
type error =
  | Native of Native_file_change.error
  | Inventory of Dashboard_tla_specs.scan_error
  | Filesystem of Unix.error
type state = Starting | Available | Unavailable of error | Stopped

val health_json : unit -> Yojson.Safe.t
(** Read only the atomic worker state, never the filesystem. Diagnostics omit
    source paths. Availability is distinct from a successful HTTP read. *)

val start :
  sw:Eio.Switch.t -> mono_clock:_ Eio.Time.Mono.t ->
  report:(state -> unit) -> unit
(** Own one daemon and its sealed native watch generations. Scans run only for
    initial setup, native topology hints and loss/recovery. Content hints emit
    the relevant process observation topics. Failed setup/observation alone has
    bounded retry delays; available idle has no timer or scan.

    [report] follows actual state transitions and connects existing health
    invalidation in bootstrap; it must not call back into this worker. Normal
    switch release cancels pending readiness and closes all native resources.
    This worker never executes TLC, writes source files or replays a command. *)
