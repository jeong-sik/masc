(** Existing public browser tools on the installation's advertised command.
    Arguments cannot select an installation or supply caller authority. Each
    call retains one original host; failures never replay or use builtin queues. *)
val handle :
  ?initial_goal_ids:(unit -> (string list, string) result) ->
  ?upload_paths:string list ->
  config:Workspace.config -> access:Lane_addon_sources.access ->
  principal:Lane_addon_call_context.principal -> reserved:string list ->
  keeper_name:string option -> tool:Browser_capabilities.tool ->
  tool_name:string -> start_time:Tool_timing.started -> Yojson.Safe.t -> Tool_result.result
(** The host-only Goal callback is evaluated solely for identity-free initial
    discovery/open. Explicit browser identities never consult or use it.

    A Keeper's screenshot is persisted to its workspace. With [keeper_name=None]
    the checked PNG is an image block of the result; it is never persisted
    for an arbitrary owner.
    Scene retention and result manifests remain the verified caller's existing
    responsibility. [upload_paths] comes only from the host's staged-file
    authority, never the tool body. The bundled owned-Gecko path copies them into
    a one-use worker lease before invoking the ordinary exported tool/hooks.
    Other backends must support their own scoped transfer before admission. *)
