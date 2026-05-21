(** Tool_misc_transport — Transport and WebSocket tool
    handlers.

    Extracted from {!Tool_misc} to reduce the god-file footprint.
    Contains HTTP/WS/gRPC discovery and status handlers.

    @since 2.188.0 *)

type tool_result = Tool_result.t

(** {1 Transport status} *)

val handle_transport_status : tool_name:string -> start_time:float -> Yojson.Safe.t -> tool_result

val handle_websocket_discovery : tool_name:string -> start_time:float -> Yojson.Safe.t -> tool_result
