module Row = Masc.Lane_addon_types
module Document = Masc_tui_lane_declaration
module Action = Masc.Lane_addon_action
type instance = {
  id : string; run_id : string; addon_id : string; title : string;
  revision : string; phase : Row.phase; observation_seq : int; rows_count : int;
  source_path : string option; binding : Yojson.Safe.t; outputs : Row.output_ports;
  skills_directory : string option; incarnation : string; action_schema : Yojson.Safe.t option;
}
type declaration = {
  source_path : string; installation_id : string option; desired : string option;
  applied : string option; instance_id : string option; issues : string list;
}
type configuration = { directory : string; complete : bool; declarations : declaration list }
type snapshot = { instances : instance list; output : Row.output; complete : bool option;
  configuration : configuration option }
type action_request = { instance_id : string; incarnation : string; request_id : string; action : Yojson.Safe.t }
type request = Inspect | Attach of Yojson.Safe.t | Observe of string | Detach of string
  | Slice of (string * string) list | Evidence of Yojson.Safe.t
  | Act of action_request | Action_status of action_request
type focus = Configurations | Instances | Rows
type t = {
  snapshot : snapshot option; loading : bool; error : string option;
  receipt : Yojson.Safe.t option; generation : int; instance_cursor : int;
  row_cursor : int; selected : string list; scroll : int; focus : focus;
  draft : string option; naming : bool; configuration_cursor : int;
  documents : Document.session list; document_key : string option; editor_ready : bool; last_action : action_request option; action_receipt : Action.receipt option;
}
val initial : t
val parse_request : string -> (request, string) result
val decode : Yojson.Safe.t -> (snapshot, string) result
val decode_slice : snapshot:snapshot -> Yojson.Safe.t -> (snapshot, string) result
val selected_declaration : t -> declaration option
val selected_document : t -> Document.session option
val put_document : t -> Document.session -> t
val selected_instance : t -> instance option
val selected_row : t -> Row.row option
val lines : ?width:int -> t -> string list

val action_json : action_request -> Yojson.Safe.t
val action_receipt : action_request -> Yojson.Safe.t -> (Action.receipt, string) result
