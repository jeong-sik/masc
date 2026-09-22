
(** Tool_library — Agent knowledge-library MCP tools.

    Implements 4 tools ([masc_library_list], [masc_library_read],
    [masc_library_add], [masc_library_search]) backed by Markdown
    documents under {!library_root} ([<base_path>/docs/library], where
    [base_path] is the workspace the caller resolved) with YAML frontmatter
    ([title], [source], [author], [created], [updated], [tags]).

    Every frontmatter field records something observable about the
    document: who wrote it, when, from what kind of work, and under
    what tags. The library is one flat directory — a document is
    either in it or it is not.

    {!library_source} owns the [source] vocabulary. Its spelling is written
    once, in the implementation's [source_to_string]; {!valid_source_strings}
    and the parser that reads [source] back are derived from it, so a new
    constructor is a non-exhaustive match in that one function. The
    [masc_library_add] schema repeats the strings as a literal enum in
    [config/tools/masc_library_add.toml]; the "library source enum" case in
    [test_enum_mirror_sync] compares that enum with {!valid_source_strings}.

    A document reads only when its frontmatter is closed and carries [title],
    [source], [author], [created] and [tags], with [source] inside the
    vocabulary. Any other document is printed by filename with the reason —
    by the tools here and by the [masc://library] resources, which read
    through {!parse_frontmatter} and {!list_documents} — instead of passing a
    raw or empty value through.

    Internal: [handle_list] / [handle_add] (reachable via {!dispatch}). *)

(** {1 Library source} *)

(** The kind of work a library document came from. *)
type library_source =
  | Direct_experience
  | Research
  | Experiment
  | Observation

val source_to_string : library_source -> string
(** The spelling written to, and read back from, a document's [source]. *)

val valid_source_strings : string list
(** Every spelling [masc_library_add] accepts for [source], derived from
    {!library_source}. Handler error messages list it. *)

(** {1 Documents} *)

type frontmatter = {
  title : string;
  source : library_source;
  author : string;
  created : string;
  tags : string list;
}

type frontmatter_error
(** Why a document does not read: no frontmatter, a block with no closing
    delimiter, a required field absent or empty, or a [source] outside
    {!library_source}. *)

val parse_frontmatter : string -> (frontmatter, frontmatter_error) result

val frontmatter_error_to_string : frontmatter_error -> string
(** The reason as a reader sees it. An unknown [source] is quoted as written. *)

val describe_unreadable : string -> frontmatter_error -> string
(** [describe_unreadable path error] is ["<basename> (<reason>)"], the line
    every library surface prints for a document that does not read. *)

val list_documents : base_path:string -> string list
(** Every [.md] file directly under {!library_root}, as full paths in name
    order; [[]] when the directory does not exist. No file is skipped by
    name. *)

(** {1 Context} *)

type context = {
  base_path : string;
  agent_name : string;
}
(** Per-call context.  [base_path] is the workspace the caller resolved
    (its [Workspace.config.base_path]); the library lives under it.
    [agent_name] populates the [author] frontmatter. *)

(** {1 Path resolution} *)

val library_root : base_path:string -> string
(** [library_root ~base_path] is [<base_path>/docs/library]. *)

(** {1 Direct handlers} *)

val handle_read : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
(** [handle_read ~tool_name ~start_time ctx args] handles [masc_library_read].
    Required arg: [topic] (string, case-insensitive partial match against
    the Markdown filename or, for a document whose frontmatter reads, its
    [title]).
    Failure classes: [Workflow_rejection] when [topic] is missing or
    no document matches; [Runtime_failure] when read I/O fails;
    [Ok] with ["## <basename>\n\n<content>"] in [data.text], the heading
    carrying the reason when the frontmatter does not read. *)

val handle_search : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
(** [handle_search ~tool_name ~start_time ctx args] handles [masc_library_search].
    Required arg: [query] (string, lowercase substring matched
    against document content).
    Failure classes: [Workflow_rejection] when [query] is missing.
    [Ok] always carries a Markdown bullet list or "No documents
    matching ..." in [data.text]. *)

(** {1 Dispatch} *)

val dispatch :
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.result option
(** [dispatch ctx ~name ~args] routes by tool name to the
    private handlers ([handle_list], [handle_add]) plus
    {!handle_read} / {!handle_search}.  Returns [None] when
    [name] is not one of the 4 library tools — caller treats
    that as "not my tool". *)

(** {1 MCP schemas} *)

val schemas : Masc_domain.tool_schema list
(** [schemas] is the 4-entry [Masc_domain.tool_schema] list registered
    with the MCP catalog.  Used by [Tool_spec.register] in this
    module's side-effect block at module load.  External
    callers (e.g. [Tools.ml]) read it for catalog enumeration. *)
