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
val value : reading -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** The value [reading.path] addresses in a row's fields, once it matches the
    declared format. A text value keeps its line breaks; the terminal and HTML
    consumers lay the value out and sanitize/escape it at their own display
    boundary. *)
