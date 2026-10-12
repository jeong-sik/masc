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
      [keeper_name], never arguments; [to] names the receiver, which must be
      in [keeper_names], and exactly one of [amount_milli] (with [reason]) or
      [item] names the gift. *)

val operation_of_misc : Tool_schemas_misc.misc_operation -> operation option
(** The Candle operation a misc tool runs, or [None] for a misc tool that is
    not a Candle tool. Every dispatcher that routes Candle tools reads this,
    so a Candle tool is wired in one place. *)

val handle
  :  operation:operation
  -> base_path:string
  -> keeper_name:string
  -> keeper_names:(string list, string) result
  -> tool_name:string
  -> start_time:Tool_timing.started
  -> args:Yojson.Safe.t
  -> Tool_result.result
(** [keeper_names] is the Auth keeper roster (Play_seat.keeper_names), the
    same source the invite flow checks names against. [Gift] refuses a target
    absent from the roster with [unknown_target] before the ledger sees it:
    the balance fold would otherwise create a wallet for a name no keeper
    holds, and there is no clawback. *)
