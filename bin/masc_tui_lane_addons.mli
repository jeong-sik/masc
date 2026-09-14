module Row = Masc.Lane_addon_types
module Document = Masc_tui_lane_declaration
module Action = Masc.Lane_addon_action
type instance = {
  id : string; run_id : string; addon_id : string; title : string;
  revision : string; phase : Row.phase; observation_seq : int; rows_count : int;
  source_path : string option; binding : Yojson.Safe.t; outputs : Row.output_ports;
  skills_directory : string option; incarnation : string; action_schema : Yojson.Safe.t option; binding_schema : Yojson.Safe.t option; display : Masc.Lane_addon_presentation.t;
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
  | Subscriptions of Yojson.Safe.t
type action_menu = {
  target_id : string; target_incarnation : string; target_title : string; request_id : string;
  schema : Yojson.Safe.t; choices : Yojson.Safe.t list; cursor : int;
  form : Masc_tui_schema_form.t option;
}
type focus = Timeline | Connections | Configurations | Instances | Rows
type presentation = Summary | Technical | Flow
type evidence_prompt = {
  evidence : Yojson.Safe.t; owner_title : string; row_count : int;
  keepers : string list; choice : int;
}
(** Marked rows about to be frozen under [owner_title]. [choice] 0 preserves
    only; [choice] n sends the reference to the n-th Keeper of [keepers]. *)
type t = {
  installer : Masc_tui_lane_installer.t option;
  subscription_panel : Masc_tui_lane_subscriptions.t option;
  evidence_prompt : evidence_prompt option;
  presentation : presentation; action_menu : action_menu option;
  snapshot : snapshot option; loading : bool; error : string option;
  receipt : Yojson.Safe.t option; generation : int; instance_cursor : int;
  row_cursor : int; selected : string list; scroll : int; focus : focus;
  draft : string option; naming : bool; configuration_cursor : int;
  documents : Document.session list; document_key : string option; editor_ready : bool; last_action : action_request option; action_receipt : Action.receipt option;
}
type installed_reading =
  | Not_read
  | Nothing_installed
  | Installed of int
(** What this view knows about installed Add-ons. [Not_read] is the state
    before anything asked -- the Lanes surface loads standalone lanes and not
    Add-ons -- and is not the same answer as [Nothing_installed]. [Installed]
    carries at least one. *)

val installed : t -> installed_reading

val initial : t
val parse_request : string -> (request, string) result
val decode : Yojson.Safe.t -> (snapshot, string) result
val decode_slice : snapshot:snapshot -> Yojson.Safe.t -> (snapshot, string) result
val selected_declaration : t -> declaration option
val selected_document : t -> Document.session option
val put_document : t -> Document.session -> t
val selected_instance : t -> instance option
val selected_source_path : t -> string option
val selected_row : t -> Row.row option
val reconcile_snapshot : t -> snapshot -> t
(** Preserve exact selected identities. A removed row, worker incarnation or
    declaration requires explicit reselection before acting on a replacement. *)
val move_lane : t -> int -> t
val lines : ?height:int -> ?failed_note:string -> width:int -> t -> string list
(** Printable rows wrapped to the actual frame width. Rendering and scrolling
    must use the same width so every field and receipt remains reachable. *)

val action_json : action_request -> Yojson.Safe.t
val action_receipt : action_request -> Yojson.Safe.t -> (Action.receipt, string) result

val open_actions : request_id:string -> t -> (t, string) result
val move_action : t -> int -> t
val submit_action : t -> (action_request, string) result
val pending_action : t -> action_request option

val paste_action : text:string -> t -> t
val edit_action : key:string -> t -> (t * action_request option, string) result
val can_observe : instance -> bool
val overview_hints : t -> string
val subscription_targets : t -> Masc_tui_lane_subscriptions.target list
val move_observation : t -> int -> t
val evidence_request : t -> (request, string) result
val open_evidence : keepers:string list -> t -> (t, string) result
(** Open the export choice for the marked rows. Fails like [evidence_request]
    when the rows span owners or left the view. *)
val move_evidence : t -> int -> t
val submit_evidence : t -> (t * request, string) result
(** Close the choice and build the exact request: the frozen bundle alone, or
    with [keeper_name] when a Keeper was chosen. *)
val evidence_receipt_lines : Yojson.Safe.t -> string list
(** What an evidence receipt says in one or two readable lines: rows frozen
    and, separately, whether the optional Keeper delivery succeeded. Empty for
    receipts of other operations. *)
