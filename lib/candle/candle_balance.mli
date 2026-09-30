(** Checked wallets, ownership, equipment and currency supply from the Candle ledger.
    Values are never clamped or wrapped. This projection does not authorize
    a recipient: the settlement boundary validates durable candidate evidence. *)
type t

type error =
  | Duplicate_payment of string
  | Balance_overflow of string
  | Negative_purchase of string
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
val balance : t -> keeper:string -> int

(** Exact nonnegative decimal milli-Candle amounts. Aggregate issuance can
    exceed a machine integer even when every individual wallet is valid. *)
type supply =
  { issued_milli : string
  ; burned_milli : string
  ; circulating_milli : string
  }

val supply : t -> supply
(** Issuance counts actual credited allocations after deduction. Purchases
    burn their recorded debit; equipment changes do not move currency. *)

(** Purchased items, in canonical catalog order. Starting portrait equipment
    does not imply ownership. *)
val owned : t -> keeper:string -> Keeper_portrait_item.t list

(** Atomically add every allocation, or return an error without a partial
    result. A Goal can be credited only once. *)
val credit : t -> Candle_payment.t -> (t, error) result

(** Check funds and existing ownership, then derive both the reduced balance
    and the new inventory together. The input is never changed on failure. *)
val purchase
  :  t
  -> keeper:string
  -> item:Keeper_portrait_item.t
  -> amount_milli:int
  -> (t, error) result

(** Replay payments and purchases in file order. A repeated purchase, negative
    amount, overspend, duplicate payment or overflow rejects the whole fold. *)
val of_events : Candle_event.t list -> (t, error) result

val selection : t -> keeper:string -> slot:Keeper_portrait_item.slot -> Candle_event.equipment_choice
val equipment : t -> keeper:string -> Keeper_portrait_look.equipment
val equip : t -> keeper:string -> slot:Keeper_portrait_item.slot -> choice:Candle_event.equipment_choice -> (t, error) result
(** Equipment is applied only after ownership was established in file order.
    Default removes the explicit choice for that slot. *)
