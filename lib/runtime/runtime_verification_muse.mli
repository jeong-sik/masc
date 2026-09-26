(** A Muse readiness turn in a temporary private workspace, using the selected
    account's managed configuration and only the readiness MCP challenge.
    The listener and workspace are released after the owned child is reaped;
    native credential refresh remains in the shared account generation. *)
type error =
  | Home_error of Runtime_muse_home.error
  | Private_workspace_unavailable
  | Client_error of Runtime_muse_serve.error

val run :
  secure_random:Eio.Flow.source_ty Eio.Resource.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  mgr:_ Eio.Process.mgr -> clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t -> directory:string -> account_home:string ->
  config:Runtime_muse_serve.config ->
  tool:Runtime_official_client_tool.dynamic_tool -> prompt:string ->
  (Runtime_muse_serve.turn_result, error) result
(** [directory] is the absolute spelling of [cwd]. Product callers supply
    the foreground process manager that owns descendants. The helper forces
    native read posture regardless of the incoming config; the verification
    command owns its single overall deadline. *)
