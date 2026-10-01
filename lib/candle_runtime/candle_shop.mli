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

type account_observation =
  | Account_off
  | Account_disabled of string
  | Account_ready of account * catalog_entry list

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

(** One immutable policy and ledger reading for account facts, catalog and revision. *)
val observe_account : base_path:string -> keeper:Keeper_id.Keeper_name.t ->
  (account_observation, error) result

(** Project the same observation already used by a roster response, without IO. *)
val account_observation_of_balance : policy:Candle_config.policy -> balance:Candle_balance.t ->
  keeper:string -> account_observation

val account_revision : account_observation -> string option
