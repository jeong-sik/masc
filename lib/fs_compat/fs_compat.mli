(** Filesystem Compatibility Layer - Eio-native I/O with fallback

    @since 2026-02 - Keeper Emergent Identity v2.0
*)

(** #9921: raised by mutating [Fs_compat] entry points
    ([append_file], [save_file], [mkdir_p]) when the target path falls
    under [HOME] and the process is a test executable. Defense in depth
    behind [Env_config_core.base_path_prod_guard]. Bypass with
    [MASC_TEST_ALLOW_HOME_BASE_PATH=1]. *)
exception Test_isolation_breach of string

(** Set global Eio filesystem. Call at server startup. *)
val set_fs : Eio.Fs.dir_ty Eio.Path.t -> unit

(** Clear global fs (testing/shutdown). *)
val clear_fs : unit -> unit

(** Get the global Eio filesystem if available. *)
val get_fs_opt : unit -> Eio.Fs.dir_ty Eio.Path.t option

(** Check if Eio fs is available. *)
val has_fs : unit -> bool

(** Load entire file as string. *)
val load_file : string -> string

(** Save string to file (overwrite). *)
val save_file : string -> string -> unit

(** Write content to path via temp file + rename.
    Returns [Error msg] on I/O failure instead of raising. *)
val save_file_atomic : string -> string -> (unit, string) Result.t

(** [true] iff [name] matches the [.atomic_*.tmp] pattern produced
    by [Filename.temp_file ~temp_dir:dir ".atomic_" ".tmp"] inside
    {!save_file_atomic}.  Exposed for tests and for a potential
    periodic sweep. *)
val is_atomic_orphan_name : string -> bool

(** #10130: boot-time sweep for [.atomic_*.tmp] orphans left
    behind when [save_file_atomic]'s with-handler never ran (the
    owning process was SIGKILL'd, or [Filename.temp_file] itself
    raised ENFILE/EMFILE before the cleanup was registered).

    Scans [base_path] and its immediate subdirectories (skipping
    [recovered_subdir] and anything that isn't a directory).
    - Zero-byte orphans are deleted.
    - Non-zero orphans are moved to
      [<base_path>/<recovered_subdir>/<original-name>.<ts-ms>]
      so operators can forensically inspect data-loss events
      instead of having them silently cleaned up.

    Returns [(deleted, preserved)]:
    - [deleted]: zero-byte orphans removed.
    - [preserved]: non-zero orphans moved to [recovered_subdir]. *)
val cleanup_atomic_orphans
  :  base_path:string
  -> ?recovered_subdir:string
  -> unit
  -> int * int

(** Append string to file. *)
val append_file : string -> string -> unit

(** Check if file exists. *)
val file_exists : string -> bool

(** Return file size or None *)
val file_size : string -> int option

(** Return file mtime or None *)
val file_mtime : string -> float option

(** Rename file. *)
val rename : string -> string -> unit

(** Remove directory. *)
val rmdir : string -> unit

(** Get realpath. *)
val realpath : string -> string

(** Create directory recursively. *)
val mkdir_p : string -> unit

(** Load JSONL file as list of JSON values.
    Malformed lines are logged and dropped. *)
val load_jsonl : string -> Yojson.Safe.t list

(** Load JSONL file, returning parsed values and count of malformed lines.
    Logs each malformed line with the provided source label. Use when the caller needs
    to surface degraded state (e.g. dashboard malformed_lines field). *)
val load_jsonl_diagnostics : string -> Yojson.Safe.t list * int

(** Parse pre-read string lines as JSONL, returning parsed values and
    malformed count.  [source] is used in log messages.
    Use when lines come from tail-readers or non-file sources. *)
val parse_jsonl_lines : source:string -> string list -> Yojson.Safe.t list * int

(** Stream JSONL line-by-line via [Eio.Buf_read.lines] when the global
    fs is registered, falling back to {!load_jsonl} + [List.fold_left]
    otherwise.  [line_no] is the 1-based index of {b non-blank} JSONL
    rows (matches {!load_jsonl_diagnostics}).  Use when the file may be
    too large to materialize as a list, e.g. audit/metrics JSONL on
    HTTP hot paths.  Returns [init] when [path] is missing (consistent
    with {!load_jsonl}); raises [Sys_error] on read failures of an
    existing file. *)
val fold_jsonl_lines
  :  init:'acc
  -> f:('acc -> line_no:int -> Yojson.Safe.t -> 'acc)
  -> string
  -> 'acc

(** Append JSON value as line to JSONL file. *)
val append_jsonl : string -> Yojson.Safe.t -> unit

(** {1 Storage Backend Abstraction}

    Types for future migration to composite backends (local + remote).
    Existing functions continue to operate on the local filesystem.
    New code can use [backend] to select storage targets.

    @since 2.95.0 — Issue #1442 *)

type backend_kind =
  | Local (** Local filesystem (Eio or Unix fallback) *)
  | Remote of string (** Remote endpoint URL *)

type backend =
  { kind : backend_kind
  ; base_path : string (** Root directory for this backend *)
  }

(** Create a backend descriptor.
    Defaults to [Local] when [kind] is omitted. *)
val create_backend : ?kind:backend_kind -> base_path:string -> unit -> backend

(** Return the base_path of a backend. *)
val backend_base_path : backend -> string

(** Serialize backend_kind for logging/diagnostics. *)
val backend_kind_to_string : backend_kind -> string

(** Convenience: create a [Local] backend with the given base_path. *)
val default_backend : base_path:string -> backend
