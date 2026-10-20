(** What an installation may read from the operator's records (RFC
    operator-quiz §4.5, K3). The grants are [binding.records]; the host reads
    that key itself, as it reads [binding.sources].

    Only an operator-owned TOML declaration may hold grants. A manual Attach or
    a Keeper-owned installation that names [records] is refused. *)

type grant =
  | Board of { source_id : string; visibilities : Board_types.visibility list }
      (** Posts and comments in exactly these visibilities. [direct] posts are
          read only when named. *)
  | Repository of { source_id : string; repository_id : string; paths : string list }
      (** First-parent commits of a registered repository's default branch,
          and files under [paths]. A path that ends in [/] covers a directory;
          any other path names one file. *)

val source_id : grant -> string

val grants : operator_owned:bool -> Yojson.Safe.t -> (grant list, string) result
(** The grants of a binding object. No [records] key is no grant.
    [operator_owned] says whether the binding belongs to an operator-owned
    TOML declaration. Every
    grant is checked: a closed kind, a unique non-blank [source_id], a
    non-empty [visibilities] for [board], and relative [paths] with no [..]
    for [repository]. Any other key is refused. *)

val covers : paths:string list -> string -> bool
(** Whether a repository-relative file path falls under a grant's [paths]. *)

(** What a read of a granted source answers. *)
type read =
  | Page of Yojson.Safe.t
      (** The final result body:
          [{"status": "records", "source_id", "records", "next_cursor",
          "complete", "sha256"}]. The records array is retained as a
          content-addressed blob in the Lane store before it is answered, and
          [sha256] names that blob, so a quote from a post edited or expired
          later stays checkable. *)
  | Not_allowed of string
      (** The source is not granted, or [after] is not a cursor this host gave. *)
  | Unavailable of string
      (** The source cannot be read now. The request waits for the next host event. *)

val read_records :
  base_path:string -> store:Lane_addon_store.t -> grants:grant list ->
  measure:(Yojson.Safe.t -> int) -> max_bytes:int ->
  source_id:string -> after:string option -> read
(** Records after [after], oldest first, as many as fit: [measure] gives the
    bytes a result body takes in the frame, and the page stays within
    [max_bytes]. A first record that does not fit alone is still the page. The
    host delivery retains that complete result JSON and supplies request-bound
    [read_result] continuations rather than skipping the record or its cursor.

    Board records are posts (id, author, created and updated time,
    visibility, title, body) in the granted visibilities and the comments on
    those posts (id, post id, author, created time, body).

    Repository records are the first-parent commits of the registered
    repository's default branch in its checkout under [base_path] (SHA,
    author name, commit time, subject, body, changed paths against the first
    parent), and the page names the [head] it read. The cursor is a commit
    SHA; one the head does not reach is not allowed. A repository that is not
    registered or cannot be read is unavailable. *)

val read_file :
  base_path:string -> store:Lane_addon_store.t -> grants:grant list ->
  source_id:string -> commit:string -> path:string -> read
(** One file's bytes at a commit the default branch's head reaches, under the
    grant's [paths]: [{"status": "file", "source_id", "commit", "path",
    "encoding", "content", "bytes", "sha256"}]. [encoding] is [utf-8] for text
    and [base64] otherwise. The bytes are retained as a blob first, and
    [sha256] names it. *)
