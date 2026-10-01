(** The complete equipment snapshot shared by server and remote renderers.
    This codec describes a picture, not purchase or ownership authority. *)
val to_json : Keeper_portrait_look.equipment -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (Keeper_portrait_look.equipment, string) result
(** Requires every slot exactly once; refuses unknown slots, item ids and
    items in the wrong slot. *)
val key : Keeper_portrait_look.equipment -> string
(** Canonical cache identity, including explicit empty slots. *)

type reading = Ready of Keeper_portrait_look.equipment | Unavailable of string
val reading_to_json : reading -> Yojson.Safe.t
val reading_of_json : Yojson.Safe.t -> (reading, string) result
(** A required server observation. Missing or malformed input is an error,
    never permission for a client to invent equipment from the name. *)
