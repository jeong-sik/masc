(** Read-only fleet health over the ordinary and source-bound current snapshots
    recall consumes. *)

type keeper_health

val keeper_memory_health_http_json : base_path:string -> Yojson.Safe.t

val fleet_cache_key : base_path:string -> string
(** The key the route caches {!keeper_memory_health_http_json} under. A
    write to one of its inputs empties it before the write is announced, so a
    fleet read after the announcement does not answer older than the row read
    it announced. *)

val keeper_memory_health_row_http_json : base_path:string -> keeper:string -> Yojson.Safe.t
(** [keeper]'s row alone, as [{"schema", "generated_at", "keeper"}] where
    ["keeper"] is the element {!keeper_memory_health_http_json} carries for
    it under ["keepers"], or [null] when the fleet answer has no row for
    [keeper] (it left, or never had one). The name is matched against the
    Keepers that answer lists, so it never names a file on its own. *)

val invalidate_after_write : keepers_dir:string -> keeper_id:string -> unit
(** Empty [keeper_id]'s cached row when [keepers_dir] is a root a read of
    that row registered: the config root the row is cached under, or the
    runtime root next to it. The next read recomputes that Keeper alone, not
    the fleet. [keepers_dir] is resolved through symlinks, as
    {!Keeper_memory_health_input} and {!Keeper_memory_commit_notifications}
    name it; this looks nothing up on the filesystem, so it can run inside
    either signal's callback. A root no read registered, or a Keeper with no
    cached row, is left alone. *)

val install : unit -> unit
(** Invalidate only the changed Keeper after a durable journal commit. The next
    visible read recomputes that Keeper outside the store locks, not the fleet.
    These store hooks run beside {!Server_memory_health_broadcast}, which
    empties the row for every write signal; a write both reach empties it
    twice, which is the same as once. *)

module For_testing : sig
  val keeper_health : config:Workspace.config -> keepers_dir:string -> string -> keeper_health

  val invalidate : base_path:string -> keeper:string -> unit
  (** Empty [keeper]'s cached row under [base_path]. A test that writes an
      input file directly has no writer to announce the commit [install]
      listens for, so it says so here instead.

      The row is found through
      [Config_dir_resolver.keepers_dir_for_base_path], so only a row cached
      under the config root can be emptied from here. That holds today
      because every row is cached under the config root; a row cached under
      the runtime root would need its own lookup. *)

  val with_runtime :
    keeper_health:(config:Workspace.config -> keepers_dir:string -> string -> keeper_health) ->
    (unit -> 'a) -> 'a
end

(** Complete current snapshots grouped by canonical keeper identity for a
    workspace memory curator. Read-only: source file bindings are reported as
    stored, never presented as revalidated. Missing and unreadable stores are
    distinct. There is no atomic cross-keeper snapshot or synthesized revision. *)
val workspace_memory_context_http_json : base_path:string -> Yojson.Safe.t
