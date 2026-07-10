(** MASC gRPC Workspace Service.

    Implements the MascWorkspace gRPC service using grpc-direct.
    See proto/masc_workspace.proto for the canonical API contract. *)

(** Full gRPC service name: "masc.workspace.v1.MascWorkspace". *)
val service_name : string

(** Per-subscriber outbound buffer drop threshold.  Reads
    [MASC_GRPC_STREAM_MAX_BUFFER] on each call; defaults to 48.  When
    [Grpc_eio.Stream.length] reaches this value the subscriber
    callback drops new events and [masc_grpc_events_dropped_total]
    advances.  Exposed so tests and operators can verify the effective
    value without instrumenting the full subscribe handler. *)
val stream_max_buffer : unit -> int

(** Create the gRPC service with all handlers wired to the given workspace config.

    @param workspace_config The MASC workspace configuration.
    @param tool_dispatcher Function that dispatches already-decoded tool calls
      under the admitted identity and transport bearer. *)
val create_service :
  workspace_config:Workspace_utils_backend_setup.config ->
  tool_dispatcher:(identity:Server_transport_admission.identity ->
                   auth_token:string ->
                   tool_name:string ->
                   arguments:Yojson.Safe.t ->
                   (string, string) result) ->
  Grpc_eio.Service.t
