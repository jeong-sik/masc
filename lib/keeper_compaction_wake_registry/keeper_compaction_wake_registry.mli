(** Process-local wake hints for per-Keeper compaction actors.

    Durable compaction operations remain the sole work authority. A pending
    hint only asks an already-registered actor to drain that journal; multiple
    hints may coalesce without dropping durable work. Registration never
    invents startup work, so the actor owner performs startup drain explicitly. *)

type t
type registration

type register_error = Already_registered

type unregister_result =
  | Unregistered
  | Registration_not_current

type wake_result =
  | Signaled
  | Coalesced
  | Not_registered

type await_result =
  | Wake
  | Registration_closed

val create : unit -> t

val register
  :  sw:Eio.Switch.t
  -> t
  -> Keeper_id.Keeper_name.t
  -> (registration, register_error) result
(** Register one exact Keeper identity for the lifetime of [sw]. A duplicate
    live registration is rejected; switch release unregisters it. *)

val unregister : registration -> unregister_result
(** Idempotent lifecycle close. A stale token cannot remove a replacement. *)

val wake : t -> Keeper_id.Keeper_name.t -> wake_result
(** Set one non-blocking pending hint. An existing pending hint coalesces. *)

val await : registration -> await_result
(** Cancellably await and consume one hint, or observe registration close. *)
