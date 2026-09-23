(** Keeper-authored Skill publication (RFC keeper-self-authored-skills).

    Parses [package_id], [source_text] and a non-empty [evidence] list, then
    asks {!Workspace_hooks.keeper_skill_publish_fn} to create the package in
    the [project-agents] source. The Keeper cannot pick the source. The
    editor's typed outcome is projected to JSON as is:
    [Created_and_published] carries the reference and snapshot revision,
    [Created_but_shadowed] completes too and adds the [winner] identity that
    turns listing Skills by name see instead, [Created_but_unpublished] the
    reason, and a refusal its [error] code and message. *)
val handle :
  config:Workspace.config ->
  keeper_name:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
