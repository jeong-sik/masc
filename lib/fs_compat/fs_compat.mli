(** Filesystem Compatibility Layer - Eio-native I/O with fallback

    @since 2026-02 - Keeper Emergent Identity v2.0
*)

val set_fs : Eio.Fs.dir_ty Eio.Path.t -> unit
(** Set global Eio filesystem. Call at server startup. *)

val clear_fs : unit -> unit
(** Clear global fs (testing/shutdown). *)

val get_fs_opt : unit -> Eio.Fs.dir_ty Eio.Path.t option
(** Get the global Eio filesystem if available. *)

val has_fs : unit -> bool
(** Check if Eio fs is available. *)

val load_file : string -> string
(** Load entire file as string. *)

val save_file : string -> string -> unit
(** Save string to file (overwrite). *)

val save_file_atomic : string -> string -> (unit, string) result
(** Write content to path via temp file + rename.
    Returns [Error msg] on I/O failure instead of raising. *)

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

(** {1 Storage Backend Abstraction}

    Types for future migration to composite backends (local + remote).
    Existing functions continue to operate on the local filesystem.
    New code can use [backend] to select storage targets.

    @since 2.95.0 — Issue #1442 *)

type backend_kind =
  | Local            (** Local filesystem (Eio or Unix fallback) *)
  | Remote of string (** Remote endpoint URL *)

type backend = {
  kind : backend_kind;
  base_path : string;  (** Root directory for this backend *)
}

val create_backend : ?kind:backend_kind -> base_path:string -> unit -> backend
(** Create a backend descriptor.
    Defaults to [Local] when [kind] is omitted. *)

val backend_base_path : backend -> string
(** Return the base_path of a backend. *)

val backend_kind_to_string : backend_kind -> string
(** Serialize backend_kind for logging/diagnostics. *)

val default_backend : base_path:string -> backend
(** Convenience: create a [Local] backend with the given base_path. *)
