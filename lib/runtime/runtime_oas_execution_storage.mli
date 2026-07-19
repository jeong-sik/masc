(** Filesystem mechanics for MASC-owned OAS execution recovery records. *)

val ensure_private_child :
  sw:Eio.Switch.t ->
  Eio.Fs.dir_ty Eio.Path.t ->
  string ->
  (Eio.Fs.dir_ty Eio.Path.t, string) result

val create_private_child :
  sw:Eio.Switch.t ->
  Eio.Fs.dir_ty Eio.Path.t ->
  string ->
  (Eio.Fs.dir_ty Eio.Path.t, string) result

val open_verified_directory :
  sw:Eio.Switch.t ->
  Eio.Fs.dir_ty Eio.Path.t ->
  (Eio.Fs.dir_ty Eio.Path.t, string) result

val load_json :
  max_bytes:int ->
  Eio.Fs.dir_ty Eio.Path.t ->
  (Yojson.Safe.t option, string) result

val persist_exclusive :
  max_bytes:int ->
  parent:Eio.Fs.dir_ty Eio.Path.t ->
  path:Eio.Fs.dir_ty Eio.Path.t ->
  string ->
  (unit, string) result

val remove_file :
  parent:Eio.Fs.dir_ty Eio.Path.t ->
  Eio.Fs.dir_ty Eio.Path.t ->
  (unit, string) result

val remove_empty_directory :
  parent:Eio.Fs.dir_ty Eio.Path.t ->
  Eio.Fs.dir_ty Eio.Path.t ->
  (unit, string) result

(** [remove_directory_tree ~parent dir] removes [dir] and its contents
    depth-first without following symbolic links, then fsyncs [parent].  A
    missing [dir] is treated as already removed. *)
val remove_directory_tree :
  parent:Eio.Fs.dir_ty Eio.Path.t ->
  Eio.Fs.dir_ty Eio.Path.t ->
  (unit, string) result
