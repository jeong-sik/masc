(** See [keeper_synthetic_marker.mli] for the contract. *)

let marker_prefix = "[SYNTHETIC]"

let tag (text : string) : string = marker_prefix ^ " " ^ text

let contains_marker (s : string) : bool =
  String_util.contains_substring s marker_prefix
