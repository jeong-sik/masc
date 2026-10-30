(** Immutable imported project sources. No dependency installation or execution. *)
type build =
  | Browser_modules of { entry_html : string }
  | Package_script of { script : string; output_directory : string; entry_html : string }
type file = { path : string; content : string }
type request = private
  { build : build; install_scripts : bool; files : file list }
type stored_file = { path : string; body : Tool_output.artifact_ref }
type t =
  { id : string; author : string; created_at : string; build : build
  ; install_scripts : bool; files : stored_file list }

val valid_id : string -> bool
val relative_path : string -> (string, string) result
val build_of_json : Yojson.Safe.t -> (build, string) result
val build_to_json : build -> Yojson.Safe.t
val request_of_json : Yojson.Safe.t -> (request, string) result
val request_to_json : request -> Yojson.Safe.t
(** The worker's [masc.artifact_project.v1] envelope with canonical base64 bytes. *)
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Strict metadata codec with normalized blob references for offline retention. *)
