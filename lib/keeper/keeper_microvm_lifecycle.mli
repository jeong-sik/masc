(** microVM lifecycle ownership. Each Keeper owns its guest names across all
    network modes and its named work/build volumes. Unrelated Keepers may
    prepare concurrently. Inventory maintenance excludes every lifecycle
    operation from listing through deletion, so a dead-owner observation
    cannot race with adoption of the same stable guest name. *)

type t
val create : unit -> t

type keeper_scope
(** Callback-borrowed ownership of one canonical Keeper name. A scope is bound
    to its coordinator and cannot admit work once its callback has finished.
    This coordinator is process-local; it does not arbitrate concurrent servers. *)

type scope_error = Scope_closed | Other_keeper | Other_coordinator

val with_keeper_scope : t -> keeper_name:string -> (keeper_scope -> 'a) -> 'a
(** Own the same Keeper mutex and inventory exclusion as {!with_keeper}.
    On callback return or exception, stop admitting borrows and drain already
    admitted callbacks before releasing ownership. The admitted region and
    drain are cancellation-protected; waiting for admission is cancellable. *)

val with_borrowed_scope :
  t -> scope:keeper_scope -> keeper_name:string -> (unit -> 'a) ->
  ('a, scope_error) result
(** Run under an existing scope without reacquiring its Keeper mutex.
    Reject a different coordinator, different canonical Keeper, or closed scope
    before calling the callback. An admitted callback is cancellation-protected
    and remains owned across yields. Exceptions propagate after borrow release.
    Borrows share ownership; they do not serialize callbacks against each other.
    Do not reacquire {!with_keeper} for this Keeper or call {!with_inventory}
    inside the scope, and do not wait for its completion from a borrower. *)

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
