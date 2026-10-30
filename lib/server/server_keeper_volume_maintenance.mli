(** Observe image-backed Keeper volumes without changing them. Volume names
    do not establish ownership across workspaces, so filesystem damage does
    not authorize automatic repair or guest teardown. *)

type notice_ledger
(** Process-local record of whether a damage notice returned a Board receipt.
    It does not establish delivery to an operator or durable deduplication. *)

val create_notice_ledger : unit -> notice_ledger

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
