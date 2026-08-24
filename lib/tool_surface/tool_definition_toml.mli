(** Tool_definition_toml — parse one [config/tools/<name>.toml] declaration
    into the [Masc_domain.tool_schema] that MCP clients and keeper surfaces
    publish (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoding is fail-closed: every key and every enumerated value is matched
    against a closed vocabulary, and anything unknown is an [Error] the
    caller turns into a boot failure. There is no partial acceptance — a key
    the runtime does not consume yet is rejected until the PR that consumes
    it also teaches this loader to decode it.

    The emitted [input_schema] JSON preserves the TOML author's key order
    (minus the [name] / [required] meta keys, which shape the [properties] /
    [required] aggregates instead of becoming JSON keys). A definition
    migrated out of an OCaml literal can therefore be proven byte-identical
    to the literal it replaced by comparing [Yojson.Safe.to_string] output.

    Definitions are read once at boot; there is no hot reload (RFC §6). *)

type loaded =
  { schema : Masc_domain.tool_schema
  ; keeper_projection : Masc_domain.tool_schema option
  }
(** One decoded tool definition. [schema] is the canonical schema published
    to MCP clients; [keeper_projection], when the file declares a
    [keeper_projection] table, is the deliberately narrower shape handed to
    keeper models (same tool name, own description and params). *)

val load
  :  name:string
  -> contents:string
  -> (loaded, string) result
(** [load ~name ~contents] parses [contents] as one tool definition.

    [name] is the canonical tool name the caller derives from the file path
    (basename minus [.toml]); the file's own [name] key must equal it, so a
    renamed file cannot silently redefine a different tool.

    Accepted top-level keys: [name], [description] (non-empty),
    [additional_properties] (bool), [[params]], and [keeper_projection]
    (a table of [description] / [additional_properties] / [[params]]).
    Accepted param keys: [name], [type] (string | integer | number |
    boolean | object | array), [required] (bool), [description], [enum]
    (non-empty string list, string params only), [default] (matching the
    declared scalar type), [minimum] / [maximum] (integer params only),
    [min_length] / [max_length] / [pattern] (string params only),
    [max_items] (array params only), [additional_properties] (object params
    only), [params] (object params only) and [items] (array params only).
    Everything else is an [Error] naming the offending key or value.

    [params] and an object [items] table take the same parameter grammar,
    at any depth: an object parameter declares its own [[params]], one of
    those can be an array whose [items] are objects with [params] again. A
    child's [required = true] is collected into its parent's [required]
    list, where JSON Schema puts it, rather than emitted onto the child.

    One thing the file cannot control is where a sub-table lands in the
    emitted JSON. TOML admits [[params.params]] and [params.items] only
    after every scalar key of their parent, so [items] cannot be written
    before [description]. Object key order is not part of a JSON object's
    meaning (RFC 8259 §4), and the acceptance criterion in RFC
    prompts-and-tool-definitions-outside-ocaml §4 compares schemas with
    keys sorted for exactly this reason. *)

val validate_embedded
  :  read:(string -> string option)
  -> files:string list
  -> (unit, string) result
(** [validate_embedded ~read ~files] loads every [tools/*.toml] entry of the
    embedded config tree ([Embedded_config.file_list] / [Embedded_config.read],
    passed in so this module stays asset-source agnostic) and returns the
    first definition that fails to decode. Files under [tools/] that are
    neither a [.toml] definition directly under the directory nor the
    [managed-assets.json] manifest are errors too. Called once from server
    bootstrap, before readiness, so a bad definition refuses the boot
    instead of publishing a partial tool surface. *)
