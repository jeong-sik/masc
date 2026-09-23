(** Server side of [keeper_skill_publish] (RFC keeper-self-authored-skills).

    The Keeper tool cannot reach the Skill editor, which lives in this
    library. At boot the server fills
    {!Workspace_hooks.keeper_skill_publish_fn} with {!publish}: it creates
    the package in the [project-agents] source through
    [Server_skill_editor.create], the same path as the operator editor, and
    appends one [skill_write] audit row per created package. *)

(** The declared Skill source a Keeper writes to. The Keeper cannot choose
    another one. *)
val project_agents_source_id : string

(** The editor's refusal with its own code and message, and the kind of
    refusal it is. *)
val refusal_of_editor_error : Server_skill_editor.error -> Workspace_skill_publish.error

(** [refresh] republishes the catalog snapshot after the write; the installed
    publisher builds it from the live runtime.toml exactly as the operator
    create route does. *)
val publish :
  refresh:(unit -> (Skill_catalog_snapshot_service.publication, string) result) ->
  Workspace.config ->
  Workspace_skill_publish.request ->
  (Workspace_skill_publish.outcome, Workspace_skill_publish.error) result

val install : unit -> unit
