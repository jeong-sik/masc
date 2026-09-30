(** Equipment is derived from the same authoritative ledger as purchases.
    Reading never repairs or truncates the ledger. *)
val reader :
  base_path:string -> unit ->
  (keeper:string -> (Keeper_portrait_look.equipment, string) result)
(** Read once for a roster response; each lookup uses that immutable snapshot.
    Off means name-derived starting equipment. Disabled or corrupt data is an
    explicit error, never a fabricated starting picture. *)
val current : base_path:string -> keeper:string -> (Keeper_portrait_look.equipment, string) result

type receipt = {
  equipment : Keeper_portrait_look.equipment;
  changed : bool;
}
type error =
  | Unavailable of string
  | Invalid_ledger of Candle_balance.error
  | Refused of Candle_balance.error
val error_to_string : error -> string

val equip :
  now:(unit -> float) -> base_path:string ->
  keeper:Keeper_id.Keeper_name.t -> slot:Keeper_portrait_item.slot ->
  choice:Candle_event.equipment_choice -> (receipt, error) result
(** Checks ownership and records the choice under the ledger CAS. An identical
    choice writes nothing; Default restores only the requested starting slot. *)
