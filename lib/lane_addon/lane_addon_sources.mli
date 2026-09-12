(** Source adapters reuse existing lane owners. They acquire observations only;
    packages decide what those observations mean. Files are explicitly bound by
    the installer, never dereferenced from package output. *)
val validate : Yojson.Safe.t -> (unit, string) result
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
