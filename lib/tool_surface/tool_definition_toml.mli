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

type help =
  { short_description : string option
  ; when_to_use : string option
  ; key_constraints : string list
  ; details_markdown : string option
  ; doc_refs : string list
  ; prompt_hints : string list
  ; examples : string list
  ; alternatives : string list
  }
(** The [\[help\]] table: the operator-authored usage knowledge
    {!Tool_help_registry} serves through [masc_tool_help] and the
    [masc://tool-help] resources. Every field is optional — an absent field
    falls back to the registry's derivation from the schema — but a [\[help\]]
    table that declares nothing is a load error, because config without a
    payload has no consumer. *)

(** Whether a tool's argument schema rides in every request, or is left out
    until the model asks for it by name.

    Declared per tool, not per source. A tool is not deferrable because of
    where it came from — an attached service, a skill, a built-in descriptor —
    but because this particular tool is rarely enough reached for its schema to
    be worth the bytes it costs on every request of the turn. Grouping by
    source is what {b RFC-0389} did and what PR #31728 removed: eight of nine
    Keepers declared every group, so the axis bought nothing. *)
type loading =
  | Always_loaded
      (** The schema rides in every request. This is the default: a tool that
          says nothing about loading is loaded. *)
  | Deferrable
      (** Only the name and a summary ride, in the listing. The schema arrives
          when the model names the tool, and only on a lane that can widen a
          running turn. *)

val loading_to_string : loading -> string

(** One decoded tool definition. [schema] is the canonical schema published
    to MCP clients; [keeper_projection], when the file declares a
    [keeper_projection] table, is the deliberately narrower shape handed to
    keeper models (same tool name, own description and params);
    [agent_core_projection], when the file declares an
    [agent_core_projection] table with the same grammar, is the deliberately
    narrower shape [Agent_core_tool_contract] hands to agent-core models;
    [help], when the file declares a [\[help\]] table, is the authored usage
    knowledge. *)
type loaded =
  { schema : Masc_domain.tool_schema
  ; keeper_projection : Masc_domain.tool_schema option
  ; agent_core_projection : Masc_domain.tool_schema option
  ; help : help option
  ; loading : loading
    (** From the file's [defer_loading] key; [Always_loaded] when absent. *)
  ; operator_remote_description : string option
    (** From the file's [operator_remote_description] key: the sentence the
        operator-remote subset publishes for this tool, when the file
        declares one. [schema.description] stays the local surface's
        sentence; nothing here swaps them, the consumer picks. *)
  ; shell_command : string list option
    (** From the file's [shell_command] key, stored word-split.  The
        sub-command path this tool answers to inside a keeper's shell line
        (RFC tools-as-shell-commands); absent means no shell form. *)
  }

val load
  :  name:string
  -> contents:string
  -> (loaded, string) result
(** [load ~name ~contents] parses [contents] as one tool definition.

    [name] is the canonical tool name the caller derives from the file path
    (basename minus [.toml]); the file's own [name] key must equal it, so a
    renamed file cannot silently redefine a different tool.

    Accepted top-level keys: [name], [description] (non-empty),
    [additional_properties] (bool), [[params]], [keeper_projection]
    (a table of [description] / [additional_properties] / [[params]]),
    [agent_core_projection] (the same table grammar), [defer_loading]
    (bool), [operator_remote_description] (non-empty string), and
    [help] (a table of [short_description] / [when_to_use] /
    [details_markdown] strings and [key_constraints] / [doc_refs] /
    [prompt_hints] / [examples] / [alternatives] string lists, at least one
    of which must be present).
    Accepted param keys: [name], [type] (string | integer | number |
    boolean | object | array), [required] (bool), [description], [enum]
    (non-empty string list, string params only), [default] (matching the
    declared scalar type), [minimum] / [maximum] (integer params only),
    [min_length] / [max_length] / [pattern] (string params only),
    [min_items] / [max_items] / [unique_items] (array params only),
    [additional_properties] (object params
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
