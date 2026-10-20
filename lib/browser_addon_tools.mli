(** Existing public browser tools on the installation's advertised command.
    Arguments cannot select an installation or supply caller authority. Each
    call retains one original host; failures never replay or use builtin queues. *)
val handle :
  ?upload_paths:string list ->
  config:Workspace.config -> access:Lane_addon_sources.access ->
  principal:Lane_addon_call_context.principal -> reserved:string list ->
  keeper_name:string option -> tool:Browser_capabilities.tool ->
  tool_name:string -> start_time:Tool_timing.started -> Yojson.Safe.t -> Tool_result.result
(** [keeper_name=None] cannot persist a screenshot for an arbitrary owner.
    Scene retention and result manifests remain the verified caller's existing
    responsibility. [upload_paths] comes only from the host's staged-file
    authority, never the tool body. The installed adapter must support that
    scoped transfer; the bundled browser worker still refuses it until its
    broker is connected. *)
