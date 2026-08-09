(** Single-fiber metadata owner for one Keeper.

    Producers communicate through a bounded mailbox.  [apply_meta],
    and [exact_projection] apply backpressure when the mailbox is full;
    commands are never dropped or coalesced. Routine reads use {!projection}
    and do not enter the mailbox. *)

val mailbox_capacity : int

type store =
  { replace : Keeper_meta_contract.keeper_meta -> (unit, string) result
  ; remove : Keeper_meta_contract.keeper_meta -> (unit, string) result
  }

type error =
  | Reducer_rejected of Keeper_owner_reducer.error
  | Store_unavailable of string
  | Owner_closed

type t

val start
  :  sw:Eio.Switch.t
  -> store:store
  -> keeper_name:string
  -> initial_meta:Keeper_meta_contract.keeper_meta option
  -> (t, error) result

val projection : t -> Keeper_owner_reducer.projection
(** Lock-free immutable snapshot. *)

val exact_projection
  :  t
  -> (Keeper_owner_reducer.projection, error) result
(** Mailbox-linearized projection for mutation and exact-operation paths. *)

val apply_meta
  :  t
  -> Keeper_owner_reducer.meta_command
  -> (Keeper_meta_contract.keeper_meta option, error) result

val begin_stopping : t -> (unit, error) result
(** Reject future external commands. *)

val error_to_string : error -> string

module For_testing : sig
  val mailbox_depth : t -> int
end
