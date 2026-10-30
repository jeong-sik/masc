(** Strict wire reading for the authenticated Keeper Items view. *)

type price = Unpriced | Priced of int
type entry = { item : Keeper_portrait_item.t; price : price }
type account = {
  balance_milli : int;
  owned_items : Keeper_portrait_item.t list;
  catalog : entry list;
}
type t = Off | Disabled of string | Ready of account

type filter = All | Owned | Can_buy | In_slot of Keeper_portrait_item.slot
val next_filter : filter -> filter
val filter_name : filter -> string
val items : filter:filter -> account:t option -> Keeper_portrait_item.t list
(** Account-dependent filters return no items until a ready account is read.
    Starting equipment does not imply ownership. Catalog order is retained. *)
val cursor : items:Keeper_portrait_item.t list -> int -> int
val move : items:Keeper_portrait_item.t list -> cursor:int -> delta:int -> int
(** Cursors are indexes into the visible list, including the empty-list sentinel
    0. Normalize again after account/filter changes; never select a hidden item. *)
val item_name : Keeper_portrait_item.t -> string
type request =
  | Equip of Keeper_portrait_item.t
  | Buy_and_equip of { item : Keeper_portrait_item.t; expected_price_milli : int }
val request : account:t option -> Keeper_portrait_item.t -> (request, string) result
(** An editable request for the selected Keeper's own tools, never a transaction.
    Buying is bounded by the observed price; owned items only request equip.
    Unavailable, unpriced and unaffordable selections return an explanation. *)
val request_draft : request -> string

val decode : keeper_name:string -> Yojson.Safe.t -> (string option * t, string) result
(** Refuses a response for another Keeper, unknown or duplicate items,
    incomplete catalogs, malformed balances or prices, and missing or malformed
    account revisions. Returns that revision with the account, as one authenticated reading. Off requires null; ready/disabled require canonical SHA-256. *)
