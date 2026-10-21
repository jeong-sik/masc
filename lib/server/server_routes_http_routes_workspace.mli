module Http = Http_server_eio

val add_routes : Http.Router.t -> Http.Router.t

val resolve_workspace_base :
  state:Mcp_server.server_state ->
  uri:Uri.t ->
  string
  * [ `Project
    | `Repository of string
    | `RepositoryMissing of string
    | `RepositoryUnknown of string
    | `Playground of string
    | `PlaygroundMissing of string
    | `KeeperUnknown of string ]
(** The absolute workspace tree a request's relative paths hang off, from
    the [?repo_id=] / [?keeper=] query params, plus the source tag naming how
    it was resolved.

    This is the anchor for every repo-relative path the dashboard sends. The
    IDE LSP proxy resolves its connection anchor through the same function.
    Missing/unknown scoped sources retain the project base for tree fallback;
    [/api/v1/workspace/file] rejects those source tags before resolving or
    reading a file, rather than serving a same-named project file. *)

(** Pure dispatch logic for the [?keeper=<name>] query param. Exposed
    for unit testing — production code goes through {!add_routes}. *)
val classify_keeper_query :
  project_base:string ->
  lookup_playground:(string -> string option) ->
  exists_dir:(string -> bool) ->
  string option ->
  string * [ `Project
           | `Playground of string
           | `PlaygroundMissing of string
           | `KeeperUnknown of string ]

(** Pure dispatch logic for repository-aware workspace queries.
    [repo_param] takes precedence over [keeper_param], matching the
    dashboard IDE repository picker. *)
val classify_workspace_query :
  project_base:string ->
  lookup_repository:(string -> string option) ->
  lookup_playground:(string -> string option) ->
  exists_dir:(string -> bool) ->
  repo_param:string option ->
  keeper_param:string option ->
  string * [ `Project
           | `Repository of string
           | `RepositoryMissing of string
           | `RepositoryUnknown of string
           | `Playground of string
           | `PlaygroundMissing of string
           | `KeeperUnknown of string ]

(** Encode the workspace source tag as the [X-Workspace-Source] header
    so the frontend can render hints (e.g. "Playground 없음 — 프로젝트로
    fallback") without parsing the JSON body. Exposed for unit
    testing. *)

val source_header :
  [ `Project
  | `Repository of string
  | `RepositoryMissing of string
  | `RepositoryUnknown of string
  | `Playground of string
  | `PlaygroundMissing of string
  | `KeeperUnknown of string ] ->
  (string * string) list

(** [rel_under base safe] returns the path of [safe] relative to [base],
    handling [base = "/"], trailing slashes, and the [safe = base] case
    (returns [""]). Caller must have already enforced the prefix
    invariant via the workspace-file resolver. Exposed for unit testing. *)
val rel_under : string -> string -> string

(** [component_is_confidential name] is [true] when a single path
    component [name] names a secret or agent-internal store that must not
    be served by the file read routes nor listed in the file tree
    ([.git], [.masc]/[.masc-ide], [.env]*, [.ssh], any name containing
    "credentials"). Single SSOT shared by the workspace-file resolver and
    {!scan_dir}. Exposed for unit testing. *)
val component_is_confidential : string -> bool

type path_rejection =
  | Path_traversal
      (** [..]/[.] component or a lexical prefix escape. *)
  | Confidential_component of string
      (** A path component matched {!component_is_confidential}. *)
  | Symlink_escape
      (** A symlink whose real target resolves outside the base. *)

type workspace_file_read_error =
  | File_not_found
  | File_not_regular
  | File_changed_during_open
  | File_too_large of int
  | File_read_failed of string
(** Typed result from the workspace file endpoint's validated read path.
    [File_changed_during_open] means the lstat/open/fstat identity check
    did not match, so the route rejects the path without reading it. *)

type workspace_file_save_error =
  | Save_invalid_path
  | Save_invalid_revision
  | Save_conflict
  | Save_too_large
  | Save_read_failed of workspace_file_read_error
  | Save_write_failed of Fs_compat.capability_write_error
  | Save_recovery_unavailable of Keeper_publication_recovery_availability.unavailable
  | Save_recovery_release_failed of {
      save_result : (string, workspace_file_save_error) result;
      release_failure : Fs_compat.Publication_recovery.lane_release_failure;
    }
  | Save_io_failed of { publication_may_have_started : bool; detail : string }
(** Existing-file optimistic writes compare the revision under a shared
    resolved-path lock. Non-cooperating external writers must own their own
    exclusion; this is not a filesystem transaction against arbitrary writers.
    Revision comparison and publication use the same pinned root and parent
    capabilities. Publication uses the process recovery registry; its typed
    outcome retains uncertainty and simultaneous lane-release failure. *)

type workspace_file_catalog = {
  catalog_root : string;
  catalog_paths : string list;
}
(** Checkout root and exact file paths, both relative to the selected workspace.
    Paths obey the same confidentiality and symlink policy as file reads. *)

type workspace_file_catalog_error =
  | Catalog_invalid_path
  | Catalog_directory_unavailable
  | Catalog_repository_unavailable
  | Catalog_scan_failed of string

(** [tree_node_limit_of_query value] applies the workspace tree route's
    [limit] query parameter defaulting and [1, max_tree_node_limit] clamp.
    Invalid or missing values fall back to the route default. Exposed for
    unit testing. *)
val tree_node_limit_of_query : string option -> int

(** The largest [limit] the tree and children routes honour; a larger request
    is clamped to it. The TUI asks for exactly this many and treats a full
    page as "more not listed". *)
val max_tree_node_limit : int

(** [scan_dir ~base ~depth ~max_depth ~max_nodes acc dir] returns at most
    [max_nodes] tree nodes. The cap prevents a dashboard file-tree request
    against a large workspace root from monopolizing the server event loop.
    [diff_by_path], when present, maps relative file paths to compact
    display badges from git numstat. Exposed for regression testing. *)
val scan_dir :
  ?diff_by_path:(string, string) Hashtbl.t ->
  base:string ->
  depth:int ->
  max_depth:int ->
  max_nodes:int ->
  Yojson.Safe.t list ->
  string ->
  Yojson.Safe.t list

(** [valid_git_ref s] is [true] iff [s] is a non-empty, ≤256-char string
    drawn from the conservative ref/SHA charset and not starting with
    ["-"]. Used to refuse query-string values that could be parsed as
    git options (e.g. [?base_ref=-L1,9999]). Exposed for unit testing. *)
val valid_git_ref : string -> bool

module For_testing : sig
  (** White-box helpers for route-level regression tests. Not part of the
      stable/public workspace API. *)

  val sanitize_log_value : ?max_bytes:int -> string -> string

  val observe_workspace_route_failure :
    ?warn_on_failure:bool -> site:string -> path:string -> exn -> unit

  val parse_git_numstat_line : string -> (string * string) option

  val repository_owning : base:string -> path:string -> string option
  (** The repository that owns [path], searched upward from the file and
      stopped at [base].

      git does not stop. Asked about a file under a playground that keeps its
      clones in [repos/<id>/], it finds no repository at the playground root,
      walks past it, and answers from whichever repository encloses MASC's own
      checkout -- where the path does not exist, so it prints nothing and a
      modified file reads as unchanged (#30322).

      [base] is the far edge because it is where the caller's authority ends:
      the query named a keeper or a repository, and an answer from outside
      that is not an answer to the question asked. *)

  val workspace_file_catalog :
    base:string ->
    path:string ->
    (workspace_file_catalog, workspace_file_catalog_error) result
  (** List the checkout containing directory [path], stopping at [base].
      Includes tracked and nonignored untracked regular files across that
      checkout, rather than only the directory's immediate children. *)

  type safe_workspace_file

  (** Resolve to both the lexical path used for Git pathspecs and the
      realpath-resolved target used for file I/O. The concrete fields
      stay abstract so tests exercise the same read helper as routes. *)
  val resolve_workspace_file :
    string -> string -> (safe_workspace_file, path_rejection) result

  (** Read a resolved workspace file through lstat/open/fstat identity
      checks and a caller-supplied byte ceiling. *)
  val load_workspace_file_content :
    ?max_bytes:int ->
    safe_workspace_file ->
    (string, workspace_file_read_error) result

  val workspace_file_revision : base:string -> safe_workspace_file -> string -> string
  (** Bind original bytes to the canonical workspace root and resolved target. *)

  val save_workspace_file :
    publication_recovery:Keeper_publication_recovery_availability.provider ->
    base:string -> path:string -> expected_revision:string -> content:string ->
    (string, workspace_file_save_error) result
  (** Replace an existing permitted file, preserving ordinary permission bits.
      Success returns the revision of the committed bytes. *)

  val save_workspace_file_before_publication :
    before_publication:(unit -> unit) ->
    publication_recovery:Keeper_publication_recovery_availability.provider ->
    base:string -> path:string -> expected_revision:string -> content:string ->
    (string, workspace_file_save_error) result
  (** Exercise a directory/root change after revision comparison, before staging,
      while the production root and parent capabilities are held. *)
end

module For_testing_log : sig
  (** White-box helper for the [/api/v1/git/log] row format. Not part of the
      stable/public workspace API. *)

  (** [git_log_row_of_line line] reads one
      [%h%x09%ad%x09%an%x09%s]-formatted row; only the first three tabs
      split, so a subject keeps its own. Malformed rows answer [None]. *)
  val git_log_row_of_line : string -> Yojson.Safe.t option
end

module For_testing_blame : sig
  (** White-box helpers for [git blame --porcelain] parsing regression
      tests. Not part of the stable/public workspace API. *)

  type entry = { bl_line : int; bl_author : string; bl_time : int64 }

  (** [parse_blame_header line] returns [(sha, final_line, group_size)] when
      [line] is a porcelain group header
      ["<40-hex sha> <orig> <final>[ <count>]"]. *)
  val parse_blame_header : string -> (string * int * int) option

  (** [parse_blame_porcelain lines] joins per-line headers with each sha's
      metadata block (which git emits only on the sha's first group). Lines
      whose sha has incomplete metadata are omitted instead of being assigned
      fabricated authors or timestamps. *)
  val parse_blame_porcelain : string list -> entry list

  val group_blame_entries : string -> entry list -> Yojson.Safe.t list
end
