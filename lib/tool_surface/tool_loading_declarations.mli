(** Which built-in tools declare that their schema can be left out of a
    request until the model asks for it.

    The declaration lives in each tool's own [config/tools/<name>.toml], next
    to the description and parameters it governs, as [defer_loading = true].
    This module only reads them; it holds no list of its own. That is the
    difference from the per-Keeper tool groups PR #31728 removed: nobody has
    to keep a roster in sync, and a tool that changes its mind changes one
    line in its own file.

    Absence means {!Tool_definition_toml.Always_loaded}. A tool says nothing
    and rides in every request, which is what all of them did before this
    module existed.

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

(** [loading_of_tool name] is what [config/tools/<name>.toml] declares.

    [Always_loaded] for a name with no such file: tools built in OCaml rather
    than declared in TOML cannot opt into deferral, and answering [Deferrable]
    for a name this module cannot see would defer a schema nothing can serve. *)
val loading_of_tool : string -> Tool_definition_toml.loading

(** [loading_of_declaration ~path ~name ~contents] is what one tool file
    declares, and what {!loading_of_tool} reads every file through.

    @raise Failure if [contents] does not parse. A file that cannot be read is
    not a file that declares nothing: the two are the same answer at every call
    site, so the error has to leave here to be seen at all. [path] names the
    file in that message. *)
val loading_of_declaration
  :  path:string
  -> name:string
  -> contents:string
  -> Tool_definition_toml.loading
