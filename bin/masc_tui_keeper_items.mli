(** Strict wire reading for the authenticated Keeper Items view. *)

type price = Unpriced | Priced of int
type entry = { item : Keeper_portrait_item.t; price : price }
type account = {
  balance_milli : int;
  owned_items : Keeper_portrait_item.t list;
  catalog : entry list;
}
type t = Off | Disabled of string | Ready of account
type observation = { revision : string option; account : t }

val decode : keeper_name:string -> Yojson.Safe.t -> (observation, string) result
(** Refuses a response for another Keeper, unknown or duplicate items,
    incomplete catalogs, and malformed balances or prices. *)
