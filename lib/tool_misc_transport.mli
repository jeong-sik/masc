
(** Tool_misc_transport — Transport, WebSocket, and WebRTC tool
    handlers.

    Extracted from {!Tool_misc} to reduce the god-file footprint.
    Contains HTTP/WS/gRPC/WebRTC discovery and status handlers.

    @since 2.188.0 *)

type tool_result = bool * string

(** {1 Transport status} *)

val handle_transport_status : Yojson.Safe.t -> tool_result

val handle_websocket_discovery : Yojson.Safe.t -> tool_result

(** {1 WebRTC handshake} *)

(** [handle_webrtc_offer args] accepts [agent_name], [ice_candidates],
    optional [dtls_fingerprint]. Returns an error result when WebRTC
    transport is disabled or required fields are missing. *)
val handle_webrtc_offer : Yojson.Safe.t -> tool_result

(** [handle_webrtc_answer args] accepts [offer_id], [agent_name],
    [ice_candidates]. Returns an error result when WebRTC transport
    is disabled or required fields are missing. *)
val handle_webrtc_answer : Yojson.Safe.t -> tool_result
