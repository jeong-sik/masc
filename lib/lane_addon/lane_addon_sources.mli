(** Source adapters reuse existing lane owners. They acquire observations only;
    packages decide what those observations mean. Files are explicitly bound by
    the installer, never dereferenced from package output. *)
type browser_selection = Live of Browser_lane.client_id | Automation

(** The lane name ({!Browser_lane.Lane_name.to_wire}) a selection reads from. *)
val browser_selection_lane : browser_selection -> string
type source =
  | Fusion_run of { id : string; run_id : string }
  | Snapshot_file of { id : string; path : string }
  | Msx_capture of { id : string }
  | Dos_capture of { id : string }
  | Lane_output of { id : string; installation_id : string; output_id : string option }
  | Browser_document of { id : string; selection : browser_selection;
      tab_id : int; target_id : string; environment : string; request_id : string }
val parse : Yojson.Safe.t -> (source list, string) result
(** Typed source bindings shared by acquisition and read-only presentation. *)
val validate : Yojson.Safe.t -> (unit, string) result
type kind = Snapshot_file_kind | Msx_capture_kind | Dos_capture_kind
  | Lane_output_kind | Browser_document_kind | Fusion_run_kind
val kind_of_string : string -> kind option
val kind_to_string : kind -> string
(** The wire name of a source kind, as a binding's ["kind"] spells it. *)
val kind_of_machine : Machine_lane.t -> kind
(** The source kind that captures the machine's screen. *)
val machine_of_kind : kind -> Machine_lane.t option
(** [Some] for the machine kinds, which have a current screen; [None] for all
    other kinds. A new source kind must choose here. *)
val offers : Lane_id.builtin -> kind list
(** The source kinds a built-in lane offers a binding. [parse] accepts a
    [browser_document] source only from a Browser Lane backend listed here;
    Stagehand has no idle document observer and offers none. *)
type activity = Tool_completed | Machine_changed of Machine_lane.t | Browser_changed
  | Fusion_changed of string
type refresh_interest
val refresh_interest : Yojson.Safe.t -> (refresh_interest, string) result
val interested : refresh_interest -> activity -> bool
val activity_of_misc_operation : Tool_schemas_misc.misc_operation -> activity
(** The activity a finished misc tool stands for. Exhaustive over the
    operation type, so a new MSX, DOS or browser tool cannot be read as a generic
    completion by omission. *)
val snapshot_files_only : refresh_interest -> bool
(** Automatic Tool completions are capture hints for explicitly bound files.
    Native MSX, DOS and browser sources additionally follow their own typed
    activity.
    Lane outputs follow producer notifications, not unrelated tool calls. *)
type lane_output = {
  installation_id : string;
  instance_id : string;
  run_id : string;
  configuration_revision : string;
  package_revision : string;
  outputs : Lane_addon_types.output_ports;
  observation_seq : int;
  output : Lane_addon_types.output;
  status : Lane_addon_types.coverage;
}
val dependencies : Yojson.Safe.t -> (string list, string) result
type access = Operator_configuration | Keeper of string | Unauthenticated
(** Native Fusion reads require the installation's authenticated Keeper owner,
    or an operator-owned persistent configuration. This value is host-owned. *)
val access_to_json : access -> Yojson.Safe.t
val access_of_json : Yojson.Safe.t -> (access, string) result
val has_native_fusion : Yojson.Safe.t -> (bool, string) result
val fusion_owner : access:access -> run_id:string -> (string, string) result
(** Read the authoritative registry owner only after the same Fusion access
    check used for acquisition. Unknown and foreign runs share one denial. *)
val authorize : access:access -> Yojson.Safe.t -> (unit, string) result
(** Reject unowned native Fusion bindings before attaching. Acquisition repeats
    the check before capturing any evidence. *)
val acquire : access:access -> store:Lane_addon_store.t -> package:Lane_addon_types.package ->
  resolve_lane_output:(installation_id:string -> (lane_output, string) result) ->
  binding:Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** The complete returned source array fits the package's ingress envelope.
    Unavailable sources retain explicit coverage entries. Bound file snapshots
    retain their exact bytes and hash in [store], independently of file rotation;
    evidence declared by a producer is never dereferenced by acquisition.

    A [lane_output] binding can select an [output_id] declared in the applied
    producer package. Absence selects the whole completed output. Unknown names
    remain unavailable. Selection retains whole-producer coverage; it does not
    claim completeness for one port independently of other producer inputs. *)
