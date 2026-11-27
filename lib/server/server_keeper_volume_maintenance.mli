(** Observe image-backed Keeper volumes without changing them. Volume names
    do not establish ownership across workspaces, so filesystem damage does
    not authorize automatic repair or guest teardown. *)

type notice_ledger
(** Process-local record of whether a damage notice returned a Board receipt.
    It does not establish delivery to an operator or durable deduplication. *)

val create_notice_ledger : unit -> notice_ledger

val inspect_from_list :
  list_volumes:(unit -> (Yojson.Safe.t, string) result) ->
  fallback_inspect:(volume:string -> (Yojson.Safe.t, string) result) ->
  volume:string ->
  (Yojson.Safe.t, string) result
(** Build a single-fiber per-sweep [inspect] function backed by one lazy
    [container volume list --format json] snapshot. The returned closure is
    not synchronized across concurrent fibers. When every listed entry carries
    a unique non-blank [configuration.name] (and, if present, a matching unique
    [id]), present volumes return their single-element inspect array and absent
    volumes return [Error "volume not found: <name>"] without spawning
    per-volume subprocesses. An incomplete or ambiguous listing falls back to
    [fallback_inspect]. A listing [Error] or non-array JSON payload is cached
    for the sweep without falling back; [Eio.Cancel.Cancelled] is not cached. *)

val sweep :
  notices:notice_ledger ->
  now:(unit -> float) ->
  inspect:(volume:string -> (Yojson.Safe.t, string) result) ->
  read_image:
    (path:string ->
     (Keeper_volume_filesystem.state, Keeper_volume_filesystem.read_failure) result) ->
  post:
    (keeper_name:string ->
     volume:string -> content:string -> meta_json:Yojson.Safe.t -> (unit, string) result) ->
  warn_uncertain:(keeper_name:string -> volume:string -> observed_at:float -> detail:string -> unit) ->
  volumes:(unit -> (string * Keeper_volume_filesystem_watch.volume) list) ->
  unit
(** Record and report observations for the selected volumes. A failed or
    interrupted post is outcome-unknown and is not blindly retried within
    the same observed damage episode; repeated sweeps log that uncertainty.
    A clean observation closes the episode, even if the read was transient.
    This does not deduplicate incidents or survive restart. No maintenance or
    repair is scheduled. *)

val start :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Workspace.config ->
  unit
