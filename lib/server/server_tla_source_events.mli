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
    initial setup, changed spec rosters or guarded path bindings, and
    loss/recovery. Ancestor/result directory hints first check only their
    relevant path identities, symbolic-link destinations and access;
    unrelated churn does not enumerate
    the inventory. Content hints emit the relevant process observation topics.
    Failed setup/observation alone has
    bounded retry delays; available idle has no timer or scan.

    [report] follows actual state transitions and connects existing health
    invalidation in bootstrap; it must not call back into this worker. Normal
    switch release cancels pending readiness and closes all native resources.
    This worker never executes TLC, writes source files or replays a command. *)

module For_testing : sig
  val start :
    inventory:(unit -> (Dashboard_tla_specs.source_inventory, Dashboard_tla_specs.scan_error) result) ->
    after_directory_batch:(Native_file_change.target list -> unit) ->
    sw:Eio.Switch.t -> mono_clock:_ Eio.Time.Mono.t ->
    report:(state -> unit) -> unit
  (** The same worker with a per-instance inventory producer and a completion
      observer after a directory batch's read/check, before any needed re-arm.
      Tests wrap the real inventory
      reader to measure its calls while using actual kernel events. There is
      no global observer, counter or production configuration. The completion
      observer must not block or yield. *)
end
