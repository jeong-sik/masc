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
    [defer_loading] nobody honours and nobody reports. *)

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

(** Every tool name whose file declares [defer_loading = true], sorted.

    For the gates and operator projections that ask what the fleet defers
    without walking the tool surface itself. *)
val deferrable_tool_names : unit -> string list
