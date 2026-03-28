(** MASC Agent Transport — protocol selection for MASC coordination. *)

type t =
  | Http
  | Grpc
  | Ws
  | Webrtc
  | Local

let from_env () =
  match Some Env_config.Server.Agent.transport with
  | Some "grpc" -> Grpc
  | Some "http" -> Http
  | Some "ws" | Some "websocket" -> Ws
  | Some "webrtc" -> Webrtc
  | Some "local" -> Local
  | _ -> Local

let to_string = function
  | Http -> "http"
  | Grpc -> "grpc"
  | Ws -> "ws"
  | Webrtc -> "webrtc"
  | Local -> "local"
