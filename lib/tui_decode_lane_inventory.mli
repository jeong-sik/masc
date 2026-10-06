(** Strict operator inventory decoder. No reads or mutations occur here.
    [None] declaration belongs only to a manual attachment; [None] applied
    revision means that instance has no declaration owner. Unobserved and
    incomplete readings never mean disabled or deleted. *)
type selection =
  | Exact of Standalone_lane.t
  | Browser of Browser_lane.Lane_name.t
  | Machine of Machine_lane.t
  | Declaration of string
  | Manual_instance of { instance_id : string; incarnation : string }

type configuration =
  | Configured of {
      admitted_slots : string list; cli_slots : string list;
      declared_slots : string list; declared_cli_slots : string list;
      dropped_slots : string list; admission_error : string option;
    }
  | Disabled of { declared_slots : string list; declared_cli_slots : string list }
  | Unconfigured of string
  | Registry_unavailable of string

type declaration =
  | Valid of {
      installation_id : string; enabled : bool; run_id : string; package_id : string;
      title : string; desired_revision : string;
    }
  | Invalid of string list
  | Absent
  | Unobserved

type phase = Lane_addon_types.phase = Attached | Observing | Failed of string | Detaching | Detached
type presence = Live | Retained
type instance = {
  instance_id : string; incarnation : string; run_id : string;
  package_id : string; title : string; package_revision : string;
  presence : presence; phase : phase; applied_revision : string option;
}
type browser_activity = Browser_enabled | Browser_disabled | Browser_unobserved
type machine_activity = Machine_enabled | Machine_disabled | Machine_unobserved
type machine_publication = No_screen | Stable | Running
type state =
  | Exact_state of configuration
  | Browser_clients of browser_activity * int
  | Browser_executor of browser_activity * bool
  | Machine_state of machine_activity * machine_publication
  | Package_state of { declaration : declaration option; instances : instance list }
type row = { id : string; label : string; purpose : string; selection : selection; state : state }
type package_read = {
  directory : string; complete : bool; owner_present : bool;
  issues : (string * string) list;
}
type snapshot = {
  observed_at : float; rows : row list;
  exact_snapshot : Tui_decode.standalone_lanes_snapshot; package_read : package_read;
}

val decode : Yojson.Safe.t -> (snapshot, string) result
(** Requires every built-in exactly once, coherent row targets and state,
    unique row/instance identities, and agreement with the existing complete
    exact snapshot.
    Unknown inventory fields/variants, duplicate JSON keys and missing fields
    are errors. The embedded exact payload uses its existing decoder. *)
