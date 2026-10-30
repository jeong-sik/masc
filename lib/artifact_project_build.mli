(** Validated successful worker results and immutable retained build records.
    These codecs verify data/provenance consistency, not that a trusted lane ran. *)
type runtime = { node : string; platform : string; arch : string }
type lock_source = Supplied | Resolved
type lockfile = Package_lock | Shrinkwrap
type 'body install =
  { scripts : bool; lock_source : lock_source; lockfile : lockfile; lock : 'body }
type source_file = { path : string; sha256 : string }
type build =
  | Browser_modules of
      { entry_html : string; esbuild : string; inputs : string list; warnings : string list; external_resources : string list }
  | Package_script of { script : string; output_directory : string; entry_html : string }
type 'body file = { path : string; body : 'body }
type 'body output = Html of 'body | Site of { entry_html : string; sha256 : string; files : 'body file list }
type 'body receipt =
  { runtime : runtime; run_directory : string; source_files : source_file list
  ; install : 'body install; build : build; output : 'body output }
type input = private { receipt : string receipt }
type t =
  { id : string; source_id : string; author : string; created_at : string
  ; receipt : Tool_output.artifact_ref receipt }

val valid_id : string -> bool
val input_of_json : Yojson.Safe.t -> (input, string) result
val input_of_receipt : string receipt -> (input, string) result
val input_to_json : input -> Yojson.Safe.t
(** Exact [masc.artifact_project_result.v1] payload; no CLI ok/result wrapper. *)
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val map_bodies :
  (mime:string -> 'a -> ('b, 'error) result) -> 'a receipt -> ('b receipt, 'error) result
val validate_source :
  digest:('a -> string) -> source:Artifact_project_source.t -> 'a receipt -> (unit, string) result
(** Match source paths/digests, build selection, install hooks and supplied lock. *)
