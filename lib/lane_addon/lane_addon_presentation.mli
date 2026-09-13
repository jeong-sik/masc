(** Package-authored display metadata. Display never changes observation truth. *)
type format = Text | Number | Boolean | Json
type reading = {
  lane_id : string;
  path : string list;
  label : string;
  unit : string option;
  format : format;
}
type t = { description : string option; readings : reading list }
val empty : t
val of_json : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val render : reading -> Yojson.Safe.t -> (string, string) result
