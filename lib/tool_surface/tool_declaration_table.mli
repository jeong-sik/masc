(** Every [config/tools/<name>.toml] declaration, parsed once.

    The per-tool axes a file can declare -- {!Tool_loading_declarations}
    reads its [defer_loading], {!Tool_repeat_declarations} its
    [same_input_advances] -- share this one parse of the embedded tree rather
    than each walking it. *)

(** [find name] is the declaration in [config/tools/<name>.toml], or [None]
    for a name with no such file: a tool built in OCaml rather than declared
    in TOML.

    @raise Failure on first ask if any tool file does not parse. A file that
    cannot be read is not a file that declares nothing: the two are the same
    answer at every call site, so the error has to leave here to be seen. *)
val find : string -> Tool_definition_toml.loaded option

(** [declaration_of_file ~path ~name ~contents] is what one tool file
    declares, and what {!find} reads every file through.

    @raise Failure if [contents] does not parse; [path] names the file. *)
val declaration_of_file
  :  path:string
  -> name:string
  -> contents:string
  -> Tool_definition_toml.loaded
