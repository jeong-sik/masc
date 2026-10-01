(** One immutable authoritative read for a whole response. No recovery writes. *)
type t
val read : base_path:string -> t
val summary : t -> Candle_observation.t
val balance : t -> keeper:string -> string option
val equipment : t -> keeper:string -> (Keeper_portrait_look.equipment, string) result
