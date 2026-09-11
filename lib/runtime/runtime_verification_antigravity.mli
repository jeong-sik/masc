(** One isolated Antigravity readiness turn with only the private MCP challenge.
    The operator OAuth source is copied, never modified; the temporary HOME and
    MCP listener are removed on success, failure and cancellation. *)
type error = Private_home_unavailable | Client_error of Runtime_antigravity.error
val run : secure_random:Eio.Flow.source_ty Eio.Resource.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t -> mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock -> cwd:Eio.Fs.dir_ty Eio.Path.t -> directory:string ->
  oauth_source:string -> config:Runtime_antigravity.config ->
  tool:Runtime_official_client_tool.dynamic_tool -> prompt:string ->
  (Runtime_antigravity.turn_result, error) result
