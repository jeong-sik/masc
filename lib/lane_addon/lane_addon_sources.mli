(** Source adapters reuse existing lane owners. They acquire observations only;
    packages decide what those observations mean. Files are explicitly bound by
    the installer, never dereferenced from package output. *)
type browser_selection = Live of Browser_lane.client_id | Automation
type source =
  | Snapshot_file of { id : string; path : string }
  | Msx_capture of { id : string }
  | Dos_capture of { id : string }
  | Lane_output of { id : string; installation_id : string; output_id : string option }
  | Browser_document of { id : string; selection : browser_selection;
      tab_id : int; target_id : string; environment : string; request_id : string }
val parse : Yojson.Safe.t -> (source list, string) result
(** Typed source bindings shared by acquisition and read-only presentation. *)
val validate : Yojson.Safe.t -> (unit, string) result
type activity = Tool_completed | Msx_changed | Dos_changed | Browser_changed
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
val acquire : store:Lane_addon_store.t -> package:Lane_addon_types.package ->
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
