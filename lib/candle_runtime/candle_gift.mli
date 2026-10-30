(** Keeper-to-keeper gifts: money moves, never mints, and items change
    hands. The ledger owns the money and inventory; no wallet or inventory
    file is maintained. Only the keeper gift tool calls this boundary; the
    operator's own gifts use {!Candle_grant}. *)

type kind =
  | Money of { amount_milli : int; reason : string }
  | Item of Keeper_portrait_item.t

type receipt =
  { from_keeper : string
  ; to_keeper : string
  ; kind : kind
  ; from_balance_milli : int
  ; to_balance_milli : int
  ; gifted_at : Candle_time.t
  }

type error =
  | Off
  | Disabled of string
  | Invalid_gift of string
  | Account_invalid of Candle_balance.error
  | Gift_refused of Candle_balance.error
  | Ledger_unavailable of string
  | Invalid_time of string

val error_to_string : error -> string

(** A single cursor-checked ledger update recomputes both wallets and both
    inventories before appending one gift. A competing append reruns that
    decision with the new ledger. A gift to self is [Invalid_gift]; a
    money gift with a non-positive amount or a blank reason is
    [Invalid_gift] too, and the reason is stored trimmed, so surrounding
    whitespace does not name a second occasion. A second money gift under
    the same (from, to, reason) triple is refused, so a retried gift run
    cannot pay twice. [Off] and [Disabled] report the configuration,
    [Account_invalid] a ledger whose history already fails the money fold,
    [Gift_refused] the refusal of this gift against that history,
    [Ledger_unavailable] a lock or I/O failure, and [Invalid_time] a clock
    reading outside the calendar. *)
val gift
  :  now:(unit -> float)
  -> base_path:string
  -> from_keeper:Keeper_id.Keeper_name.t
  -> to_keeper:Keeper_id.Keeper_name.t
  -> kind:kind
  -> (receipt, error) result
