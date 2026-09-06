
(** Tool_library — Agent knowledge-library MCP tools.

    Implements 4 tools ([masc_library_list], [masc_library_read],
    [masc_library_add], [masc_library_search]) backed by Markdown
    documents under {!library_root} ([MASC_BASE_PATH/docs/library],
    then the host runtime fallback) with YAML frontmatter
    ([title], [source], [author], [created], [updated], [tags]).

    Every frontmatter field records something observable about the
    document: who wrote it, when, from what kind of work, and under
    what tags. The library is one flat directory — a document is
    either in it or it is not.

    Issue #8601 SSOT shape: {!library_source} variant +
    [source_to_string] + {!valid_source_strings} +
    {!source_of_string_opt} are kept in sync — adding a 5th
    constructor forces compile errors in [source_to_string].  There is
    no [library_source_ssot] test; the compile errors are the whole
    guard.

    Internal: [all_sources], the [frontmatter] type +
    [parse_frontmatter] + [list_documents], and [handle_list] /
    [handle_add] (reachable via {!dispatch}).  All consumed only
    inside the dispatch handlers or {!schemas}. *)

(** {1 Library source SSOT} *)

(** Variant SSOT for the library document [source] field
    (issue #8601).  Adding a 5th constructor forces compile
    errors across [source_to_string] and the
    [library_source_ssot] test. *)
type library_source =
  | Direct_experience
  | Research
  | Experiment
  | Observation

val valid_source_strings : string list
(** [valid_source_strings] is [List.map source_to_string
    all_sources] computed at module init.  Used by handler
    error messages and the [masc_library_add] schema [enum]
    field — adding a constructor updates both automatically. *)

(** {1 String helper} *)

(** {1 Context} *)

type context = {
  agent_name : string;
}
(** Per-call context.  [agent_name] populates the [author]
    frontmatter. *)

(** {1 Path resolution} *)

val library_root : unit -> string
(** [library_root ()] is [MASC_BASE_PATH/docs/library] when
    [MASC_BASE_PATH] is set, otherwise the host-config agent runtime root.
    Read every call — env mutation between calls takes effect. *)

(** {1 Direct handlers} *)

val handle_read : tool_name:string -> start_time:float -> 'ctx -> Yojson.Safe.t -> Tool_result.result
(** [handle_read ~tool_name ~start_time _ctx args] handles [masc_library_read].
    Required arg: [topic] (string, partial-match against
    Markdown filename).
    Failure classes: [Workflow_rejection] when [topic] is missing or
    no document matches; [Runtime_failure] when read I/O fails;
    [Ok] with ["## <basename>\n\n<content>"] in [data.text]. *)

val handle_search : tool_name:string -> start_time:float -> 'ctx -> Yojson.Safe.t -> Tool_result.result
(** [handle_search ~tool_name ~start_time _ctx args] handles [masc_library_search].
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
