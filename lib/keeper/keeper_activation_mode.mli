(** Declarative owner activation and initiative policy. Explicit requested
    work remains eligible independently of this mode, subject to lifecycle
    pause and shutdown ownership. *)
type t = Manual | On_demand | Autonomous
val default : t
val restore_owner : t -> bool
val spontaneous : t -> bool
val to_string : t -> string
val of_string : string -> t option
val to_yojson : t -> Yojson.Safe.t
