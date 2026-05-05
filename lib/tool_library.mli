
(** Tool_library — Agent knowledge-library MCP tools.

    Implements 5 tools ([masc_library_list], [masc_library_read],
    [masc_library_add], [masc_library_promote],
    [masc_library_search]) backed by Markdown documents under
    {!library_root} ([\$HOME/me/docs/library]) with YAML
    frontmatter ([title], [source], [confidence], [author],
    [created], [tags], [verified_by]).

    Confidence routing: documents with [confidence < 0.5] land
    in {!candidates_dir} for human verification; promoting via
    [masc_library_promote] requires the new confidence to be
    [>= 0.5].

    Issue #8601 SSOT shape: {!library_source} variant +
    {!source_to_string} + {!valid_source_strings} +
    {!source_of_string_opt} are kept in sync — adding a 5th
    constructor forces compile errors in [source_to_string] and
    fails the [library_source_ssot] test in [test_types.ml].

    Internal: 9 helpers stay private — the two regex hoists
    \[promote_confidence_re] / \[promote_verified_by_re],
    \[library_confidence_threshold] (= 0.5), \[all_sources],
    the \[frontmatter] type + \[parse_frontmatter] +
    \[list_documents], \[handle_list] / \[handle_add] /
    \[handle_promote] (reachable via {!dispatch}), and
    \[tool_definitions].  All consumed only inside the dispatch
    handlers or {!schemas}. *)

(** {1 Library source SSOT} *)

(** Variant SSOT for the library document [source] field
    (issue #8601).  Adding a 5th constructor forces compile
    errors across {!source_to_string} and the
    [library_source_ssot] test. *)
type library_source =
  | Direct_experience
  | Research
  | Experiment
  | Observation

val source_to_string : library_source -> string
(** [source_to_string s] returns the canonical lowercase label:
    ["direct_experience"] / ["research"] / ["experiment"] /
    ["observation"]. *)

val all_sources : library_source list
(** [all_sources] is the canonical witness list — one entry per
    {!library_source} constructor (in declaration order).  Used
    by {!valid_source_strings} and by behaviour-tests under
    {!test/test_types}. *)

val valid_source_strings : string list
(** [valid_source_strings] is [List.map source_to_string
    all_sources] computed at module init.  Used by handler
    error messages and the [masc_library_add] schema [enum]
    field — adding a constructor updates both automatically. *)

val source_of_string_opt : string -> library_source option
(** [source_of_string_opt s] returns [Some _] when [s] matches a
    canonical label exactly, [None] otherwise.  Pinned at the
    contract seam — fail-closed parsing is the SSOT contract for
    the [source] field. *)

(** {1 String helper} *)

val string_contains : sub:string -> string -> bool
(** [string_contains ~sub s] is [true] iff [sub] is a contiguous
    substring of [s].  Byte-wise — case-sensitive.  Callers
    lowercase both inputs when case-insensitive matching is
    required (see {!handle_read} / {!handle_search}). *)

(** {1 Tool result + context} *)

type tool_result = bool * string
(** [(success, message)] return shape used by every dispatch
    handler. *)

type context = {
  agent_name : string;
}
(** Per-call context.  [agent_name] populates the [author]
    frontmatter and the [verified_by] field on promotion. *)

(** {1 Path resolution} *)

val library_root : unit -> string
(** [library_root ()] is [\$HOME/me/docs/library] with [\$HOME]
    falling back to ["/tmp"] when unset.  Read every call —
    env mutation between calls takes effect. *)

val candidates_dir : unit -> string
(** [candidates_dir ()] is [{library_root}/candidates].
    Documents with [confidence < 0.5] land here pending
    verification. *)

(** {1 Direct handlers} *)

val handle_read : 'ctx -> Yojson.Safe.t -> tool_result
(** [handle_read _ctx args] handles [masc_library_read].
    Required arg: [topic] (string, partial-match against
    Markdown filename).  Returns [(false, _)] when [topic] is
    missing or no document matches; otherwise [(true,
    "## <basename>\n\n<content>")]. *)

val handle_search : 'ctx -> Yojson.Safe.t -> tool_result
(** [handle_search _ctx args] handles [masc_library_search].
    Required arg: [query] (string, lowercase substring matched
    against document content).  Returns a Markdown bullet list
    when matches exist, or a plain ["No documents matching
    '<query>'"] message when empty. *)

(** {1 Dispatch} *)

val dispatch :
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  tool_result option
(** [dispatch ctx ~name ~args] routes by tool name to the
    private handlers ([handle_list], [handle_add],
    [handle_promote]) plus {!handle_read} / {!handle_search}.
    Returns [None] when [name] is not one of the 5 library
    tools — caller treats that as "not my tool". *)

(** {1 MCP schemas} *)

val schemas : Masc_domain.tool_schema list
(** [schemas] is the 5-entry [Masc_domain.tool_schema] list registered
    with the MCP catalog.  Used by [Tool_spec.register] in this
    module's side-effect block at module load.  External
    callers (e.g. [Tools.ml]) read it for catalog enumeration. *)
