(** The live Candle account and purchase boundary. The ledger owns money and
    inventory; no wallet or inventory file is maintained. *)

type account =
  { keeper : string
  ; balance_milli : int
  ; owned_items : Keeper_portrait_item.t list
  }

type catalog_entry =
  { item : Keeper_portrait_item.t
  ; price : Candle_config.price
  }

type receipt =
  { account : account
  ; item : Keeper_portrait_item.t
  ; amount_milli : int
  ; purchased_at : Candle_time.t
  }

type error =
  | Off
  | Disabled of string
  | Unpriced of Keeper_portrait_item.t
  | Account_invalid of Candle_balance.error
  | Purchase_refused of Candle_balance.error
  | Ledger_unavailable of string
  | Invalid_time of string

val error_to_string : error -> string

val account
  :  base_path:string
  -> keeper:Keeper_id.Keeper_name.t
  -> (account, error) result

val catalog : base_path:string -> (catalog_entry list, error) result

(** The caller supplies its trusted Keeper identity. A single cursor-checked
    ledger update recomputes funds and ownership before appending one purchase.
    A competing append reruns that decision with the new ledger. The price
    recorded is the explicit policy observed for this request. *)
val purchase
  :  now:(unit -> float)
  -> base_path:string
  -> keeper:Keeper_id.Keeper_name.t
  -> item:Keeper_portrait_item.t
  -> (receipt, error) result
