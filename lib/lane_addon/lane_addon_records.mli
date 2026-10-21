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
  | Wiki of { source_id : string }
      (** The workspace wiki's pages, in the order its [log.md] wrote them. *)
  | Github_pulls of { source_id : string; repository_id : string }
      (** The pull requests that merged a registered repository's
          default-branch commits, with their reviews, read from GitHub. *)

val source_id : grant -> string

val grants : operator_owned:bool -> Yojson.Safe.t -> (grant list, string) result
(** The grants of a binding object. No [records] key is no grant.
    [operator_owned] says whether the binding belongs to an operator-owned
    TOML declaration. Every
    grant is checked: a closed kind, a unique non-blank [source_id], a
    non-empty [visibilities] for [board], and relative [paths] with no [..]
    for [repository]. A [wiki] grant has no other key, and a
    [github_pulls] grant names its [repository_id]. Any other key is
    refused. *)

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

(** Where a read starts. *)
type start =
  | From_beginning
  | After of string  (** A cursor this host gave in an earlier result. *)
  | Since of float
      (** Records made at or after this Unix time: a Board post's or
          comment's creation time, a commit's commit time (for
          [github_pulls], the time of the commit that merged the pull
          request), the minute of a wiki page's latest log line. The wiki log stamps only the minute,
          so a page written up to a minute before this time is also read. A
          package that has no cursor yet reads what happened since it began,
          not the whole history. *)

(** One registered repository on GitHub, as the server's PR reader sees it.
    [post] sends one GraphQL request with the reader's credential, which
    stays with the server, and answers the response JSON. [Error] says why
    GitHub did not answer it: a transport failure, an HTTP status, a rate
    limit, GraphQL errors, or a body that is not JSON. *)
type github_repository = {
  owner : string;
  name : string;
  post : Yojson.Safe.t -> (Yojson.Safe.t, string) result;
}

type github = repository_id:string -> (github_repository, string) result
(** [Error] says why the repository cannot be read from GitHub now: no PR
    reader is declared or ready, the repository is not registered, or its
    remote is not on the configured GitHub host. *)

val read_records :
  base_path:string -> store:Lane_addon_store.t -> grants:grant list -> github:github ->
  measure:(Yojson.Safe.t -> int) -> max_bytes:int ->
  source_id:string -> start:start -> read
(** Records from [start], oldest first, as many as fit: [measure] gives the
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
    registered or cannot be read is unavailable.

    Wiki records are pages (name, revision, title, summary, author, body).
    The wiki keeps one body per page and replaces it on update, and its
    [log.md] is the only record of the order pages were written in. Each page
    is read once, at its latest log line, with the header and body it holds
    now, so a page updated after the cursor comes again with its new
    revision. An older revision is readable only from a page retained
    earlier. A log line whose page is gone or whose header does not read
    gives no record. The cursor names a log line by its position and its
    page and revision; one the log no longer holds at that position is not
    allowed. A wiki with no [log.md] has no records; one whose files cannot
    be read is unavailable.

    [github_pulls] records come in the order of the registered checkout's
    default-branch first-parent commits, read as for [repository], and the
    cursor is a commit SHA. GitHub lists merged pull requests by creation or
    update time, not by merge, so the commits give the order. For each commit
    the host asks GitHub for the pull request whose merge commit it is: number,
    title, body, merge commit, merge time and author, with every review (id,
    author, submitted time, state, body) and each review's comments (id,
    author, time, path, line, body), page by page. A commit no pull request
    merged has no record and the cursor passes it. Times are as GitHub writes
    them, and a deleted account's author is [null]. [github] failing, or
    GitHub not answering, is unavailable. *)

val read_file :
  base_path:string -> store:Lane_addon_store.t -> grants:grant list ->
  source_id:string -> commit:string -> path:string -> read
(** One file's bytes at a commit the default branch's head reaches, under the
    grant's [paths]: [{"status": "file", "source_id", "commit", "path",
    "encoding", "content", "bytes", "sha256"}]. [encoding] is [utf-8] for text
    and [base64] otherwise. The bytes are retained as a blob first, and
    [sha256] names it. A [board], [wiki] or [github_pulls] source is not
    allowed. *)
