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
  :  now:(unit -> float)
  -> base_path:string
  -> keeper:Keeper_id.Keeper_name.t
  -> (account, error) result
(** The keeper's account through {!Candle_status.current_view}, which publishes
    a changed half-life before answering. Read-only surfaces read
    {!Candle_status.observed_view} instead. *)

val catalog : base_path:string -> (catalog_entry list, error) result

(** The caller supplies its trusted Keeper identity. A single cursor-checked
    ledger update recomputes funds and ownership before appending one purchase.
    A competing append reruns that decision with the new ledger. The price
    recorded is the explicit policy re-read within each cursor attempt; an
    item that becomes unpriced is refused before any debit. *)
val purchase
  :  now:(unit -> float)
  -> base_path:string
  -> keeper:Keeper_id.Keeper_name.t
  -> item:Keeper_portrait_item.t
  -> (receipt, error) result
