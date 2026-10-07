(** Operator gifts outside any Goal. A grant credits one keeper under a
    reason that names the occasion; the ledger owns the money, no wallet
    file is maintained. No keeper tool calls this boundary; only the
    operator CLI does. *)

type receipt =
  { keeper : string
  ; balance_milli : int
  ; amount_milli : int
  ; reason : string
  ; granted_at : Candle_time.t
  }

type error =
  | Off
  | Disabled of string
  | Invalid_grant of string
  | Account_invalid of Candle_balance.error
  | Grant_refused of Candle_balance.error
  | Ledger_unavailable of string
  | Invalid_time of string

val error_to_string : error -> string

(** A single cursor-checked ledger update recomputes the balance before
    appending one grant. A competing append reruns that decision with the
    new ledger. A non-positive amount or a blank reason is [Invalid_grant];
    the reason is stored trimmed, so surrounding whitespace does not name
    a second occasion. A second grant to the same keeper under the same
    reason is refused, so a retried grant run cannot pay twice. [Off] and
    [Disabled] report the configuration, [Account_invalid] a ledger whose
    history already fails the money fold, [Grant_refused] the refusal of
    this grant against that history, [Ledger_unavailable] a lock or I/O
    failure, and [Invalid_time] a clock reading outside the calendar. *)
val grant
  :  now:(unit -> float)
  -> base_path:string
  -> keeper:Keeper_id.Keeper_name.t
  -> amount_milli:int
  -> reason:string
  -> (receipt, error) result
