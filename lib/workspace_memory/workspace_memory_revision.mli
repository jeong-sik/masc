(** Ledger and Briefing states, each stored once under the SHA-256 of its
    bytes (RFC-workspace-curator-originals-name-ledger-revisions §3.1–3.2).

    A revision is computed from a typed state, never by hashing a published
    file. [ledger.json] holds the same bytes as the ledger's revision file;
    [briefing.json] is written with unsorted keys, so its file hash is not the
    Briefing revision. A file lives at
    [<base>/.masc/workspace-memory/revisions/<kind>/<sha256>.json]. *)

type ledger
(** The revision of a ledger state. *)

type briefing
(** The revision of a Briefing state. *)

type t = Ledger of ledger | Briefing of briefing

val of_ledger : Workspace_memory_ledger.t -> ledger
(** {!Workspace_memory_ledger.sha256}. *)

val of_briefing : Workspace_memory_briefing.t -> briefing
(** The SHA-256 of the state's compact JSON with every object's keys sorted. *)

val ledger_sha256 : ledger -> string
val briefing_sha256 : briefing -> string

val to_json : t -> Yojson.Safe.t
(** [{"kind": "ledger" | "briefing", "sha256": <64 lowercase hex digits>}]. *)

val of_json : Yojson.Safe.t -> (t, string) result
(** Refuses another kind, a digest that is not 64 lowercase hex digits, and a
    missing, repeated or other field. *)

type write_error = { revision : t; detail : string }
(** The workspace, a directory or the file could not be written. *)

val write_error_to_string : write_error -> string

type read_error =
  | Missing of t
  | Damaged of { revision : t; detail : string }
      (** The file's bytes do not hash to the revision, or they do not decode
          as that kind of state, or the decoded state has another revision. *)
  | Unreadable of { revision : t; detail : string }
      (** The file could not be read, or a symbolic link or something other
          than a regular file sits at its place or below the base. *)

val read_error_to_string : read_error -> string

type stored_ledger
(** Evidence that [write_ledger] completed in the observed physical workspace.
    A computed or decoded revision cannot construct this receipt. It does not
    authorize later effects or prevent external deletion after the write. *)
val stored_ledger_revision : stored_ledger -> ledger
val stored_ledger_workspace : stored_ledger -> string * int * int
(** Canonical workspace path, device and inode checked across the write. *)

val write_ledger : base_path:string -> Workspace_memory_ledger.t -> (stored_ledger, write_error) result
(** Performs the durable revision write described below and returns its receipt
    only after the physical workspace is checked again. *)

val write_briefing : base_path:string -> Workspace_memory_briefing.t -> (briefing, write_error) result
(** Writes the state's revision bytes with
    {!Keeper_fs.save_bytes_durable_atomic}, as the run registry writes its
    payloads: a temporary file, fsync, rename, and the directory fsyncs that
    make the file and any directory created for it durable. [base_path] is
    the ownership root: it must already be a directory and not a symbolic
    link, no symbolic link may sit below it, and a revision directory removed
    since an earlier write is created again. It writes every time. The name is the digest of the bytes,
    so writing again publishes the same file and replaces one damaged from
    outside. A write stopped midway leaves no file under the revision's
    name. *)

val read_ledger : base_path:string -> ledger -> (Workspace_memory_ledger.t, read_error) result

val read_briefing : base_path:string -> briefing -> (Workspace_memory_briefing.t, read_error) result
(** Reads the file under the same ownership root as the write. Accepts it only
    when its SHA-256 is the revision, it decodes as that kind of state (each
    state decoder refuses another [schema]) and the decoded state has this
    revision again. A missing file is [Missing], never an empty state. *)
