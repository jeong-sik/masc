(** Tool_definition_embedded — the tool definitions shipped inside the binary,
    looked up by tool name.

    The [config/tools/<name>.toml] files are crunched into the binary as
    {!Embedded_config} entries. Every module that publishes a tool schema
    reads its definitions through here, so the entry path and the wording of
    a boot failure live in one place (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    {!Tool_definition_toml} stays source agnostic: it decodes bytes and never
    reads the tree itself. *)

val path : string -> string
(** [path name] is the key of [name]'s definition in the embedded tree:
    [tools/<name>.toml]. *)

val find : string -> (Tool_definition_toml.loaded, string) result
(** [find name] decodes the embedded definition of the tool [name]. The
    [Error] message names the missing entry, or carries the decode failure of
    {!Tool_definition_toml.load}. *)

val load : string -> Tool_definition_toml.loaded
(** [load name] is [find name] with an [Error] raised as [Failure]. For module
    initialization, where a missing or undecodable definition refuses the boot
    instead of publishing a partial tool surface. *)

val schema : string -> Masc_domain.tool_schema
(** [schema name] is the [schema] of [load name]. *)

val path_params : string -> string list
(** [path_params name] is the [path_params] of [name]'s embedded definition —
    the params it declares [role = "path"] — or [[]] when the tree holds no
    definition for [name] (an attached service tool, a composition, a name
    that is not a built-in). Decoded once per name and kept. A definition
    that does not decode is a boot failure in {!validate_embedded} terms and
    reads as [[]] here. *)
