(** Optional cross-lane observations. Domain meanings belong to packages;
    these types describe provenance, presentation and worker ownership only. *)
type contribution = Observe | Derive
type row_kind = Event | Value | Relation
type evidence = { uri : string; sha256 : string option }
type clock = { domain : string; value : string }
type row = {
  id : string;
  lane_id : string;
  kind : row_kind;
  title : string;
  observed_at : float;
  subject_id : string;
  clock : clock option;
  actor : string option;
  fields : (string * Yojson.Safe.t) list;
  evidence : evidence list;
  related_ids : string list;
}
type coverage = {
  source_id : string;
  incarnation : string;
  cursor : string option;
  complete : bool;
  detail : string option;
}
type output = { rows : row list; coverage : coverage list }
type resources = {
  cpus : float;
  memory_bytes : int64;
  pids : int;
  max_reply_bytes : int;
}
type package = {
  id : string;
  revision : string;
  title : string;
  contributions : contribution list;
  image : string;
  command : string list;
  directory : string;
  skills_directory : Skill_resource_path.t option;
  resources : resources;
}
type phase = Attached | Observing | Failed of string | Detaching | Detached
val row_to_json : row -> Yojson.Safe.t
val row_of_json : Yojson.Safe.t -> (row, string) result
val output_to_json : output -> Yojson.Safe.t
val output_of_json : Yojson.Safe.t -> (output, string) result
val coverage_to_json : coverage -> Yojson.Safe.t
val phase_to_json : phase -> Yojson.Safe.t
val phase_of_json : Yojson.Safe.t -> (phase, string) result
val package_to_json : package -> Yojson.Safe.t
