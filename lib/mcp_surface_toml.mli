(** Mcp_surface_toml — parse the [config/mcp/] declarations into the values
    the MCP wire surface publishes (RFC
    prompts-and-tool-definitions-outside-ocaml §3 item 8).

    Two files, decoded once each at module initialization:

    - [mcp/resources.toml] — the static [resources/list] and
      [resources/templates/list] catalogue, the [serverInfo.description]
      carried in every initialize result, and the name suffix [resources/list]
      composes onto each per-tool help resource.
    - [mcp/prompts.toml] — the [prompts/list] / [prompts/get] catalogue
      (names, titles, descriptions, argument prose).

    Decoding is fail-closed like {!Tool_definition_toml}: every key is matched
    against a closed set and anything unknown is an [Error]; at module init
    that error is a [failwith], so a bad file refuses the boot rather than
    publishing a partial surface. There is no hot reload (RFC §6) — boot
    re-decodes the embedded tree through {!validate_embedded}. *)

(** {1 resources.toml} *)

(** One [masc://…] resource advertised by [resources/list]. Every field is
    required in the file: the OCaml constructors the catalogue used to be
    written with default [title] to [name], but every shipped entry passes an
    explicit title, so the file carries them all. *)
type resource_entry =
  { uri : string
  ; name : string
  ; title : string
  ; description : string
  ; mime_type : string
  }

(** One [resources/templates/list] entry; [uri_template] carries the RFC 6570
    expression a concrete read URI is formed from. *)
type template_entry =
  { uri_template : string
  ; name : string
  ; title : string
  ; description : string
  ; mime_type : string
  }

(** The whole [resources.toml] declaration. *)
type surface =
  { server_description : string  (** From the [\[server\]] table. *)
  ; tool_help_name_suffix : string
      (** From [\[tool_help\] name_suffix] — the suffix [resources/list]
          appends to a tool name for its per-tool help resource. *)
  ; resources : resource_entry list
  ; resource_templates : template_entry list
  }

val load_resources : contents:string -> (surface, string) result
(** [load_resources ~contents] parses [contents] as [mcp/resources.toml].
    Accepted top-level keys, all required: [server] (a table of
    [description]), [tool_help] (a table of [name_suffix]), [[resources]]
    and [[resource_templates]]. Entry keys are exactly [uri] (or
    [uri_template]), [name], [title], [description], [mime_type]; all are
    required non-empty strings. Everything else is an [Error] naming the
    offending key. *)

val server_description : string
val tool_help_name_suffix : string
val resources : resource_entry list
val resource_templates : template_entry list
(** Decoded from the embedded [mcp/resources.toml] at module init. *)

(** {1 prompts.toml} *)

type prompt_argument =
  { argument_name : string
  ; argument_description : string
  ; argument_required : bool
  }

type prompt_entry =
  { prompt_name : string
  ; prompt_title : string
  ; prompt_description : string
  ; prompt_arguments : prompt_argument list
  }

val load_prompts : contents:string -> (prompt_entry list, string) result
(** [load_prompts ~contents] parses [contents] as [mcp/prompts.toml]. The only
    accepted top-level key is [[prompts]]; a prompt carries [name], [title]
    and [description] (required non-empty strings) and [[prompts.arguments]]
    entries of [name] / [description] / [required]. Everything else is an
    [Error] naming the offending key. *)

val prompts : prompt_entry list
(** Decoded from the embedded [mcp/prompts.toml] at module init. *)

(** {1 Embedded tree validation} *)

val validate_embedded
  :  read:(string -> string option)
  -> files:string list
  -> (unit, string) result
(** [validate_embedded ~read ~files] loads the two known [mcp/] entries of the
    embedded config tree ([Embedded_config.file_list] / [Embedded_config.read],
    passed in so this module stays asset-source agnostic) and returns the
    first one that fails to decode. Files under [mcp/] that are neither
    [resources.toml], [prompts.toml], nor the [managed-assets.json] manifest
    are errors too — the file set is fixed and consumed by name. Called once
    from server bootstrap, before readiness, so a bad file refuses the boot
    instead of publishing a partial MCP surface. *)
