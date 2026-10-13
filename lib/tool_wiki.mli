
(** Tool_wiki — Wiki MCP tools.

    Implements 5 tools ([masc_wiki_list], [masc_wiki_read],
    [masc_wiki_create], [masc_wiki_update], [masc_wiki_search]) backed by
    Markdown pages under {!wiki_root} ([<base_path>/docs/wiki], where
    [base_path] is the workspace the caller resolved) with YAML frontmatter
    ([title], [summary], [source], [author], [created], [updated],
    [revision], [tags]).

    A page lives at [<page>.md]. The writer chooses [page] (lowercase a-z,
    digits and [-]; [index] and [log] are reserved) and it never changes. A
    name that breaks the rule is refused, not repaired. [title] may be in any
    script.

    [masc_wiki_create] refuses a page that exists. [masc_wiki_update] takes
    the [revision] the writer read as [base_revision]: when the page has
    moved on, the update is refused and the refusal carries the current
    revision and body, so the writer merges and sends again. An accepted
    update replaces the body, adds one to [revision] and keeps [author],
    [created] and [source]. Both run under one lock for the wiki directory
    and replace the file by rename.

    Every frontmatter field records something observable about the
    page: who wrote it, when, from what kind of work, and under
    what tags. The wiki is one flat directory — a page is
    either in it or it is not.

    {!wiki_source} owns the [source] vocabulary. Its spelling is written
    once, in the implementation's [source_to_string]; {!valid_source_strings}
    and the parser that reads [source] back are derived from it, so a new
    constructor is a non-exhaustive match in that one function. The
    [masc_wiki_create] schema repeats the strings as a literal enum in
    [config/tools/masc_wiki_create.toml]; the "wiki source enum" case in
    [test_enum_mirror_sync] compares that enum with {!valid_source_strings}.

    A page reads only when its frontmatter is closed and carries [title],
    [summary], [source], [author], [created], [revision] and [tags], with
    [source] inside the vocabulary, [revision] a whole number from 1 and
    [tags] written as [\[a, b\]]. Any other page is printed by filename with
    the reason — by the tools here and by the [masc://wiki] resources, which
    read through {!parse_frontmatter} and {!list_pages} — instead of passing a
    raw or empty value through. No tool rewrites a page that does not read.

    A header value is written on one line and read back trimmed, so the page
    writer takes only values that come back as they went in: a {!Line.t} for
    [title], [summary], [author] and the update [note], a {!Tag.t} for each
    tag. The tool arguments and a page on disk are both turned into these
    types, and a value that is not one is refused by name: blank, more than
    one line, whitespace at either end, or for a tag a comma. A tag that is
    blank or not a string is refused too, not dropped.

    Internal: [handle_list] / [handle_create] / [handle_update] (reachable via
    {!dispatch}). *)

(** {1 Wiki source} *)

(** The kind of work a wiki page came from. *)
type wiki_source =
  | Direct_experience
  | Research
  | Experiment
  | Observation

val source_to_string : wiki_source -> string
(** The spelling written to, and read back from, a page's [source]. *)

val valid_source_strings : string list
(** Every spelling [masc_wiki_create] accepts for [source], derived from
    {!wiki_source}. Handler error messages list it. *)

(** {1 Header values} *)

(** A value that fits one header line and reads back unchanged. *)
module Line : sig
  type t = private string

  type problem =
    | Blank  (** Empty once trimmed. *)
    | Spans_lines  (** Holds a line feed or a carriage return. *)
    | Outer_whitespace  (** The reader would trim it. *)

  val of_string : string -> (t, problem) result

  val of_date : Unix.tm -> t
  (** [YYYY-MM-DD]. *)
end

(** One tag: a {!Line.t} with no comma. *)
module Tag : sig
  type t = private string

  type problem =
    | Not_a_line of Line.problem
    | Has_comma  (** Would read back as two tags. *)

  val of_string : string -> (t, problem) result

  val to_line : t list -> string
  (** The value of the [tags] line: [\[a, b\]], or [\[\]] for none. *)

  val of_line : string -> t list option
  (** Reads what {!to_line} wrote, and for every list of tags
      [of_line (to_line tags) = Some tags]. [None] for anything else: no
      brackets around the value, or an empty piece between commas. *)
end

(** {1 Pages} *)

type frontmatter = {
  title : Line.t;
  summary : Line.t;  (** One line saying what the page holds. *)
  source : wiki_source;
  author : Line.t;
  created : Line.t;
  revision : int;  (** 1 when created; one more after each update. *)
  tags : Tag.t list;
}

type frontmatter_error
(** Why a page does not read: no frontmatter, a block with no closing
    delimiter, a required field absent or empty, a [source] outside
    {!wiki_source}, a [revision] that is not a whole number from 1, a [tags]
    value {!Tag.of_line} does not read, or a carriage return inside a value. *)

val parse_frontmatter : string -> (frontmatter, frontmatter_error) result

val frontmatter_error_to_string : frontmatter_error -> string
(** The reason as a reader sees it. An unknown [source] is quoted as written. *)

val describe_unreadable : string -> frontmatter_error -> string
(** [describe_unreadable path error] is ["<basename> (<reason>)"], the line
    every wiki surface prints for a page that does not read. *)

val page_path : base_path:string -> string -> string
(** [page_path ~base_path page] is [<wiki_root>/<page>.md]. *)

val list_pages : base_path:string -> string list
(** Every [.md] file directly under {!wiki_root}, as full paths in name
    order; [[]] when the directory does not exist. No file is skipped by
    name. *)

(** {1 Context} *)

type context = {
  base_path : string;
  agent_name : string;
}
(** Per-call context.  [base_path] is the workspace the caller resolved
    (its [Workspace.config.base_path]); the wiki lives under it.
    [agent_name] populates the [author] frontmatter. *)

(** {1 Path resolution} *)

val wiki_root : base_path:string -> string
(** [wiki_root ~base_path] is [<base_path>/docs/wiki]. *)

(** {1 Direct handlers} *)

val handle_read : tool_name:string -> start_time:Tool_timing.started -> context -> Yojson.Safe.t -> Tool_result.result
(** [handle_read ~tool_name ~start_time ctx args] handles [masc_wiki_read].
    Required arg: [topic] (string, case-insensitive partial match against
    the Markdown filename or, for a page whose frontmatter reads, its
    [title]).
    Failure classes: [Workflow_rejection] when [topic] is missing or
    no page matches; [Runtime_failure] when read I/O fails;
    [Ok] with ["## <basename>\n\n<content>"] in [data.text], the heading
    carrying the reason when the frontmatter does not read. *)

val handle_search : tool_name:string -> start_time:Tool_timing.started -> context -> Yojson.Safe.t -> Tool_result.result
(** [handle_search ~tool_name ~start_time ctx args] handles [masc_wiki_search].
    Required arg: [query] (string, lowercase substring matched
    against page content).
    Failure classes: [Workflow_rejection] when [query] is missing.
    [Ok] always carries a Markdown bullet list or "No pages
    matching ..." in [data.text]. *)

(** {1 Dispatch} *)

val dispatch :
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.result option
(** [dispatch ctx ~name ~args] routes by tool name to the
    private handlers ([handle_list], [handle_create], [handle_update]) plus
    {!handle_read} / {!handle_search}.  Returns [None] when
    [name] is not one of the 5 wiki tools — caller treats
    that as "not my tool". *)

(** {1 MCP schemas} *)

val schemas : Masc_domain.tool_schema list
(** [schemas] is the 5-entry [Masc_domain.tool_schema] list registered
    with the MCP catalog.  Used by [Tool_spec.register] in this
    module's side-effect block at module load.  External
    callers (e.g. [Tools.ml]) read it for catalog enumeration. *)
