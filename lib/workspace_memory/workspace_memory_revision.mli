(** Ledger and Briefing states, each stored once under the SHA-256 of its
    bytes (RFC-workspace-curator-originals-name-ledger-revisions §3.1–3.2).

    A revision is computed from a typed state, never by hashing a published
    file. [ledger.json] holds the same bytes as the ledger's revision file;
    [briefing.json] is written with unsorted keys, so its file hash is not the
    Briefing revision. *)

type ledger
(** The revision of a ledger state. *)

type briefing
(** The revision of a Briefing state. *)

type t = Ledger of ledger | Briefing of briefing

val of_ledger : Workspace_memory_ledger.t -> ledger
(** {!Workspace_memory_ledger.sha256}. *)

val of_briefing : Workspace_memory_briefing.t -> (briefing, string) result
(** The SHA-256 of the state's key-sorted JSON. *)

val ledger_sha256 : ledger -> string
val briefing_sha256 : briefing -> string

val to_json : t -> Yojson.Safe.t
(** [{"kind": "ledger" | "briefing", "sha256": <64 lowercase hex digits>}]. *)

val of_json : Yojson.Safe.t -> (t, string) result
(** Refuses another kind, a digest that is not 64 lowercase hex digits, and a
    missing, repeated or other field. *)

val path : base_path:string -> t -> string
(** [revisions/<kind>/<sha256>.json] in the workspace memory directory. *)

type error =
  | Missing of t
  | Damaged of { revision : t; detail : string }
      (** The file's bytes do not hash to the revision, or they do not decode
          as that kind of state. *)
  | Unavailable of { revision : t; detail : string }
      (** The workspace, a directory or the file could not be read or
          written. *)
  | Unencodable of string
      (** The Briefing state has no key-sorted JSON (a repeated key or a
          non-finite number), so it has no revision. *)

val error_to_string : error -> string

val write_ledger : base_path:string -> Workspace_memory_ledger.t -> (ledger, error) result

val write_briefing : base_path:string -> Workspace_memory_briefing.t -> (briefing, error) result
(** Writes the state's revision bytes with
    {!Keeper_fs.save_bytes_durable_atomic}, as the run registry writes its
    payloads: a temporary file, fsync, rename, and the directory fsyncs that
    make the file and any directory created for it durable. It writes every
    time. The name is the digest of the bytes, so writing
    again publishes the same file and replaces one damaged from outside. A
    write stopped midway leaves no file under the revision's name. The
    workspace base must already be a directory. *)

val read_ledger : base_path:string -> ledger -> (Workspace_memory_ledger.t, error) result

val read_briefing : base_path:string -> briefing -> (Workspace_memory_briefing.t, error) result
(** Accepts the file only when its SHA-256 is the revision, it decodes as that
    kind of state (each state decoder refuses another [schema]) and the decoded
    state has this revision again. A missing file is [Missing], never an empty
    state. *)
