(** Eager Candle tools for the current Keeper. [keeper_name] is supplied by
    the Keeper turn or the authenticated credential owner, never arguments.
    Monetary result fields are canonical decimal strings, so a tool consumer
    can keep the full OCaml wallet range without JSON number rounding. *)

type operation =
  | Balance
  | Catalog
  | Purchase
  | Equip
  | Gift
  (** [Gift] sends Candle or one owned item to another Keeper. The giver is
      [keeper_name], never arguments; [to] names the receiver, and exactly
      one of [amount_milli] (with [reason]) or [item] names the gift. *)

val handle
  :  operation:operation
  -> base_path:string
  -> keeper_name:string
  -> tool_name:string
  -> start_time:Tool_timing.started
  -> args:Yojson.Safe.t
  -> Tool_result.result
