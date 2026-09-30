(** A Muse readiness turn in a temporary private workspace, using the selected
    account's managed configuration and only the readiness MCP challenge.
    The listener, workspace and private native session storage are released
    after the owned child is reaped;
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
  quota_scope:Runtime_quota_window.scope ->
  config:Runtime_muse_serve.config ->
  prompt_capacity:(int, Runtime_muse_prompt_capacity.error) result ->
  reasoning_effort:Runtime_muse_msp.reasoning_effort option ->
  tool:Runtime_official_client_tool.dynamic_tool -> prompt:string ->
  (Runtime_muse_serve.turn_result, error) result
(** [directory] is the absolute spelling of [cwd]. Product callers supply
    the foreground process manager that owns descendants. The helper forces
    native read posture regardless of the incoming config. [prompt_capacity]
    is the model's {!Runtime_instance.muse_prompt_capacity}; the complete prompt must
    fit it before HOME preparation or process launch, and an [Error] refuses
    with its cause.
    [reasoning_effort] is the caller's effective frozen model
    setting. [quota_scope] is captured from that same candidate before effects;
    typed provider reset observations survive failures and do not infer exhaustion
    from generic errors. The verification command owns its single overall deadline. *)
