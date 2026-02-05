(** Filesystem Compatibility Layer - Eio-native I/O with fallback

    @since 2026-02 - Lodge Emergent Identity v2.0
*)

val set_fs : Eio.Fs.dir_ty Eio.Path.t -> unit
(** Set global Eio filesystem. Call at server startup. *)

val clear_fs : unit -> unit
(** Clear global fs (testing/shutdown). *)

val has_fs : unit -> bool
(** Check if Eio fs is available. *)

val load_file : string -> string
(** Load entire file as string. *)

val save_file : string -> string -> unit
(** Save string to file (overwrite). *)

val append_file : string -> string -> unit
(** Append string to file. *)

val file_exists : string -> bool
(** Check if file exists. *)

val mkdir_p : string -> unit
(** Create directory recursively. *)

val load_jsonl : string -> Yojson.Safe.t list
(** Load JSONL file as list of JSON values. *)

val append_jsonl : string -> Yojson.Safe.t -> unit
(** Append JSON value as line to JSONL file. *)
