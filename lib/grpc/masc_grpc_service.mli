(** MASC gRPC Coordination Service.

    Implements the MascCoordination gRPC service using grpc-direct.
    See proto/masc_coordination.proto for the canonical API contract. *)

(** Full gRPC service name: "masc.coordination.v1.MascCoordination". *)
val service_name : string

(** Create the gRPC service with all handlers wired to the given room config.

    @param room_config The MASC room configuration.
    @param tool_dispatcher Function that dispatches tool calls:
      [tool_name -> arguments_json -> (result_json, error_message) result]. *)
val create_service :
  room_config:Coord_utils_backend_setup.config ->
  tool_dispatcher:(string -> string -> (string, string) result) ->
  Grpc_eio.Service.t
