(** Checked wallets, ownership, equipment and currency supply from the Candle ledger.
    Values are never clamped or wrapped. This projection does not authorize
    a recipient: the settlement boundary validates durable candidate evidence. *)
type t

type error =
  | Missing_half_life
  | Clock_reversed of {previous : Candle_time.t; actual : Candle_time.t}
  | Invalid_half_life of Candle_decay.error
  | Decay_failed of {keeper : string; error : Candle_decay.error}
  | Duplicate_payment of string
  | Balance_overflow of string
  | Negative_purchase of string
  | Invalid_grant of { keeper : string; amount_milli : int }
  | Duplicate_grant of { keeper : string; reason : string }
  | Invalid_gift of { from_keeper : string; to_keeper : string; amount_milli : int }
  | Duplicate_gift of { from_keeper : string; to_keeper : string; reason : string }
  | Unowned_gift of { keeper : string; item : Keeper_portrait_item.t }
  | Unowned_equipment of {keeper : string; item : Keeper_portrait_item.t}
  | Wrong_equipment_slot of Keeper_portrait_item.t
  | Already_owned of
      { keeper : string
      ; item : Keeper_portrait_item.t
      }
  | Insufficient_balance of
      { keeper : string
      ; available_milli : int
      ; required_milli : int
      }

val error_to_string : error -> string
val empty : t
val half_life : t -> Candle_decay.half_life option
(** The latest explicit policy in this projection, or [None] before the first
    policy fact. Configuration synchronization compares this domain value. *)
val set_half_life : t -> at:Candle_time.t -> Candle_decay.half_life -> (t, error) result
(** Close every wallet's preceding interval before changing policy. An identical
    policy does not create a new rounding interval. Money requires an explicit
    first policy record; no initial decay policy is invented. *)
val balance : t -> keeper:string -> int

(** Exact nonnegative decimal milli-Candle amounts. Aggregate issuance can
    exceed a machine integer even when every individual wallet is valid. *)
type supply =
  { issued_milli : string
  ; burned_milli : string
  ; circulating_milli : string
  }

val supply : t -> supply
(** Issuance counts actual credited allocations after deduction, plus
    granted gifts. Purchases burn their recorded debit; equipment changes
    do not move currency. *)

(** Purchased items, in canonical catalog order. Starting portrait equipment
    does not imply ownership. *)
val owned : t -> keeper:string -> Keeper_portrait_item.t list

(** Atomically add every allocation, or return an error without a partial
    result. A Goal can be credited only once. *)
val credit : t -> at:Candle_time.t -> Candle_payment.t -> (t, error) result

(** Check funds and existing ownership, then derive both the reduced balance
    and the new inventory together. The input is never changed on failure. *)
val purchase
  :  t
  -> at:Candle_time.t
  -> keeper:string
  -> item:Keeper_portrait_item.t
  -> amount_milli:int
  -> (t, error) result
val grant
  :  t
  -> at:Candle_time.t
  -> keeper:string
  -> amount_milli:int
  -> reason:string
  -> (t, error) result
(** Credit an operator gift. A non-positive amount is [Invalid_grant]; a
    second gift to the same keeper under the same reason is
    [Duplicate_grant], so a retried grant run cannot pay twice. *)
val gift
  :  t
  -> at:Candle_time.t
  -> from_keeper:string
  -> to_keeper:string
  -> amount_milli:int
  -> reason:string
  -> (t, error) result
(** Move money between keepers: a transfer, never issuance — supply is
    untouched. A non-positive amount is [Invalid_gift]; a second gift
    under the same (from, to, reason) triple is [Duplicate_gift], so a
    retried gift run cannot pay twice; an unfunded giver is
    [Insufficient_balance] and an overflowing receiver [Balance_overflow]. *)
val gift_item
  :  t
  -> at:Candle_time.t
  -> from_keeper:string
  -> to_keeper:string
  -> item:Keeper_portrait_item.t
  -> (t, error) result
(** Move item ownership between keepers. The giver must own the item
    ([Unowned_gift]) and the receiver must not ([Already_owned]). A worn
    item comes off the giver; anything else worn stays worn. *)

(** Replay payments, purchases, grants and gifts in file order. A repeated purchase,
    negative amount, overspend, duplicate payment, duplicate grant, duplicate
    gift, unowned gift or overflow rejects the whole fold. *)
val of_events : at:Candle_time.t -> Candle_event.t list -> (t, error) result
(** Observe wallets at [at] after replaying chronological monetary and policy
    facts. Current configuration never rewrites historical intervals or debits.
    Equipment events do not create monetary rounding boundaries. Derived decay
    is included in burned supply but never emitted as a ledger event. Monetary
    and policy records, including equal-policy records, must not move the
    observation clock backwards, even before any wallet has been credited. *)

val selection : t -> keeper:string -> slot:Keeper_portrait_item.slot -> Candle_event.equipment_choice
val equipment : t -> keeper:string -> Keeper_portrait_look.equipment
val equip : t -> keeper:string -> slot:Keeper_portrait_item.slot -> choice:Candle_event.equipment_choice -> (t, error) result
(** Equipment is applied only after ownership was established in file order.
    Default removes the explicit choice for that slot. *)
