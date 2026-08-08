(** Single-fiber owner for one Keeper.

    Producers communicate through a bounded mailbox.  [apply_meta],
    [exact_projection], and [start_turn] apply backpressure when the mailbox is
    full; commands are never dropped or coalesced.  Routine reads use
    {!projection} and do not enter the mailbox. *)

val mailbox_capacity : int

type store =
  { replace : Keeper_meta_contract.keeper_meta -> (unit, string) result
  ; remove : Keeper_meta_contract.keeper_meta -> (unit, string) result
  }

type error =
  | Reducer_rejected of Keeper_owner_reducer.error
  | Store_unavailable of string
  | Owner_closed

type turn_start =
  | Started
  | Busy of { running_operation_id : string }

type t

val start
  :  sw:Eio.Switch.t
  -> store:store
  -> initial_meta:Keeper_meta_contract.keeper_meta option
  -> t

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

val start_turn
  :  t
  -> operation_id:string
  -> run:(Eio.Switch.t -> unit)
  -> (turn_start, error) result
(** Admit one child turn and return after actor admission, without waiting for
    the child.  A child exception is contained by the owner and releases the
    running slot. *)

val begin_stopping : t -> (unit, error) result
(** Reject future external commands.  The root switch remains the structured
    cancellation and join authority for the actor and its current child. *)

val error_to_string : error -> string

module For_testing : sig
  val mailbox_depth : t -> int
end
