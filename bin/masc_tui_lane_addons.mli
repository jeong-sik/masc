(** Optional retained cross-lane projection. It owns no Keeper or game state. *)
module Row = Masc.Lane_addon_types
type instance = {
  id : string; run_id : string; addon_id : string; title : string;
  revision : string; phase : Row.phase; observation_seq : int; rows_count : int;
}
type snapshot = { instances : instance list; output : Row.output; complete : bool option }
type request = Inspect | Attach of Yojson.Safe.t | Observe of string | Detach of string
  | Slice of (string * string) list | Evidence of Yojson.Safe.t
type focus = Instances | Rows
type t = {
  snapshot : snapshot option; loading : bool; error : string option;
  receipt : Yojson.Safe.t option; generation : int; instance_cursor : int;
  row_cursor : int; selected : string list; scroll : int; focus : focus;
  draft : string option;
}
val initial : t
val parse_request : string -> (request, string) result
val decode : Yojson.Safe.t -> (snapshot, string) result
val decode_slice : instances:instance list -> Yojson.Safe.t -> (snapshot, string) result
val selected_instance : t -> instance option
val selected_row : t -> Row.row option
val lines : ?width:int -> t -> string list
