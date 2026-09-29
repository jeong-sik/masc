(** One immutable authoritative read for a whole response. No recovery writes. *)
type t
val read : base_path:string -> t
val summary : t -> Candle_observation.t
val balance : t -> keeper:string -> string option
val equipment : t -> keeper:string -> (Keeper_portrait_look.equipment, string) result
(** Stable digest of the ready Item account's balance, ownership and current
    catalog prices. A free purchase or price-only edit changes this even when
    the wallet and portrait do not. Off and Disabled have no account. *)
val account_revision : t -> keeper:string -> string option
