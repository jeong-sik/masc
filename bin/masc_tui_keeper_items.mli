(** Strict wire reading for the authenticated Keeper Items view. *)

type price = Unpriced | Priced of int
type entry = { item : Keeper_portrait_item.t; price : price }
type account = {
  balance_milli : int;
  owned_items : Keeper_portrait_item.t list;
  catalog : entry list;
}
type t = Off | Disabled of string | Ready of account

val decode : keeper_name:string -> Yojson.Safe.t -> (string option * t, string) result
(** Refuses a response for another Keeper, unknown or duplicate items,
    incomplete catalogs, malformed balances or prices, and missing or malformed
    account revisions. Returns that revision with the account, so publication
    can compare it with the roster. Off requires null; ready/disabled require canonical SHA-256. *)

val match_revision : expected_revision:(string option, string) result ->
  string option * t -> (t, string) result
(** Requires a successful roster revision reading equal to this account response.
    [None] is the explicit Candle-off revision, never an unread observation. *)
