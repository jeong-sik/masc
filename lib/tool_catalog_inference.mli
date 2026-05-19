(** Tool_catalog_inference — typed-tool-name -> effect_domain / tool_group.

    Owns the {!effect_domain} and {!tool_group} types. [Tool_catalog]
    re-exports them via type aliasing so [tool_catalog.mli] stays
    byte-compatible. *)

type effect_domain =
  | Read_only
  | Masc_coordination
  | Playground_write
  | Main_worktree_write

type tool_group =
  | Board
  | Knowledge
  | Tasks
  | Voice
  | Filesystem
  | Masc_board
  | Masc_keeper
  | Masc_plan
  | Masc_worktree
  | Masc_code
  | Masc_autoresearch
  | Masc_agent
  | Masc_core

val effect_domain_to_string : effect_domain -> string
val tool_group_to_string : tool_group -> string

val inferred_effect_domain : string -> effect_domain option
(** [None] when the name does not parse as a typed [Tool_name.t]. *)

val tool_group : string -> tool_group option
(** [None] when the name does not parse as a typed [Tool_name.t],
    or when the typed name falls in an arm that returns [None]. *)
