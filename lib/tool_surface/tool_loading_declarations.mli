(** Which built-in tools declare that their schema can be left out of a
    request until the model asks for it.

    The declaration lives in each tool's own [config/tools/<name>.toml], next
    to the description and parameters it governs, as [defer_loading = true].
    A Skill composition declares it in its own composition block instead
    ([Keeper_tool_composition_catalog.entry.loading]), where its description lives;
    this module answers only for tool files.
    This module only reads them; it holds no list of its own. That is the
    difference from the per-Keeper tool groups PR #31728 removed: nobody has
    to keep a roster in sync, and a tool that changes its mind changes one
    line in its own file.

    A file without the key means {!Tool_definition_toml.Always_loaded}: the
    tool says nothing and rides in every request, which is what all of them
    did before this module existed. A missing file is not that answer. Every
    built-in tool has its file, so {!required} raises for one without it;
    only a caller that may hold a name with no file at all asks {!declared}.

    A file that does not parse raises on first ask rather than answering
    [Always_loaded]: a misplaced declaration and no declaration are the same
    answer at every call site, so swallowing the error would make a
    [defer_loading] nobody honours and nobody reports.

    What a declaration buys, and where it stops. Two limits are easy to state
    wrongly in a tool file, so they live here once rather than in each of
    them.

    It reaches the Agent Core lane only. The codex, antigravity and
    claude_code runtimes are handed the whole tools array and never read this
    key, so on those requests a deferred schema rides exactly as before.

    And it holds until the conversation calls the tool. After the first call
    [Keeper_identity_tool_search]'s [already_used] puts the schema back for
    the turns that follow, which is what stops the model asking for the same
    tool every turn. So the bytes a declaration saves are the tools a
    conversation has not used yet, not the tools it does not use much.
    Measured on 2026-09-03 (#32711): of nineteen tools moved behind the
    listing, fifteen left one Keeper's live array and four stayed, all four
    already called in that conversation.

    There is deliberately no "which tools defer" listing here. Such a list
    reads as a roster the moment something takes it as input rather than as a
    report, and a roster of tools loaded together is the group axis again.
    Loading several tools as a unit is already a composition entry
    ([keeper_compose_<name>]), which names its tools in [compositions.nodes]
    along with their order and the data flowing between them -- and costs no
    schema bytes at all, because the model calls the one composition rather
    than the tools inside it. *)

(** [declared name] is what [config/tools/<name>.toml] declares, or [None]
    when there is no such file. *)
val declared : string -> Tool_definition_toml.loading option

(** [required name] is what [config/tools/<name>.toml] declares, for a name
    that must have that file: a tool descriptor's internal name, or a tool the
    composition surface builds from its own file.

    @raise Failure naming the file when it is missing. Answering
    [Always_loaded] there would let a descriptor looked up under a name with
    no file drop its [defer_loading] with nothing reporting it. *)
val required : string -> Tool_definition_toml.loading

(** [loading_of_declaration ~path ~name ~contents] is what one tool file
    declares, and what {!declared} reads every file through.

    @raise Failure if [contents] does not parse. A file that cannot be read is
    not a file that declares nothing: the two are the same answer at every call
    site, so the error has to leave here to be seen at all. [path] names the
    file in that message. *)
val loading_of_declaration
  :  path:string
  -> name:string
  -> contents:string
  -> Tool_definition_toml.loading
