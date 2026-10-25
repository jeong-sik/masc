(** microVM lifecycle ownership. Each Keeper owns its guest names across all
    network modes and its named work/build volumes. Unrelated Keepers may
    prepare concurrently. Inventory maintenance excludes every lifecycle
    operation from listing through deletion, so a dead-owner observation
    cannot race with adoption of the same stable guest name. *)

type t
val create : unit -> t

val with_keeper : t -> keeper_name:string -> (unit -> 'a) -> 'a
(** Serialize the same canonical guest-name Keeper segment, including case
    aliases and across base paths. Work-volume names are Keeper-scoped,
    whereas guest names also include the workspace hash. Waiting is
    cancellable; an admitted lifecycle action is protected. *)

val with_inventory : t -> (unit -> 'a) -> 'a
(** Stop admitting new Keeper actions, await already admitted actions, then
    run the exclusive inventory operation. Waiting remains cancellable; only
    the admitted inventory callback is protected. Exceptions release ownership
    and propagate with their original backtraces. *)
