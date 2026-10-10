(** Actual SDK stdio machine worker under an attached Runtime installation.
    The caller installs the Eio owner context, activity observer and test deadline.
    Container provisioning alone is substituted. [invoke] is a private-port
    fixture setup operation; behavior under test should call the host surfaces. *)
val with_dos : clock:_ Eio.Time.clock -> sw:Eio.Switch.t -> base_path:string ->
  (invoke:(principal:Lane_addon_call_context.principal ->
     controller:Machine_controller_contract.admission option -> name:string -> arguments:Yojson.Safe.t ->
     (Mcp_protocol.Mcp_types.tool_result, string) result) ->
   detach:(unit -> unit) -> unit) -> unit

(** [other_backend] supplies non-machine packages when a test also attaches
    an observer. The MSX package still uses the actual SDK worker connection. *)
val with_msx : ?other_backend:Masc.Lane_addon_runtime.For_testing.backend ->
  clock:_ Eio.Time.clock -> sw:Eio.Switch.t -> base_path:string ->
  (invoke:(principal:Lane_addon_call_context.principal -> name:string -> arguments:Yojson.Safe.t ->
     (Mcp_protocol.Mcp_types.tool_result, string) result) ->
   detach:(unit -> unit) -> unit) -> unit
