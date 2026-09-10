(** Durable binding records, source captures and assertions. Slices are queries;
    no cached query result is authoritative. All paths are below [root]. *)
type t
val create : root:string -> t
val root : t -> string
val digest : string -> string
val write_blob : t -> string -> (Lane_addon_types.evidence, string) result
val read_blob : t -> Lane_addon_types.evidence -> (string, string) result
val save_binding : t -> instance_id:string -> Yojson.Safe.t -> (unit, string) result
val bindings : t -> (Yojson.Safe.t list, string) result
val append_observation : t -> instance_id:string -> seq:int ->
  sources:Yojson.Safe.t -> Lane_addon_types.output -> (unit, string) result
val observations : t -> instance_id:string ->
  ((Yojson.Safe.t * Lane_addon_types.output) list, string) result
val query_observations : t -> instance_id:string -> expected_seq:int -> max_bytes:int ->
  since:float option -> until:float option -> lane_id:string option ->
  (Lane_addon_types.output, string) result
(** Streams retained sequence files with bounded response and per-record reads.
    Coverage records the scan cursor and an explicit incomplete result when the
    response bound is reached or a retained interval cannot be read. *)
val freeze : t -> instance_id:string -> binding:Yojson.Safe.t ->
  row_ids:string list -> (Yojson.Safe.t, string) result
val publish_for_keeper : base_path:string -> t -> Yojson.Safe.t ->
  (Yojson.Safe.t, string) result
(** Publishes a frozen bundle, its selected records and their retained source
    bodies byte-for-byte through the existing Tool artifact store. Only this
    store's verified content addresses are read; source bodies stay opaque.
    The returned [message] is an exact retained artifact marker, and
    [keeper_artifact] names the manifest whose child references retain all
    published bytes for [keeper_artifact_read]. No message is sent here. *)
