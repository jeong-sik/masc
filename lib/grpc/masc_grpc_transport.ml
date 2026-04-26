(** MASC Agent Transport — protocol selection for MASC coordination. *)

type t =
  | Http
  | Grpc
  | Ws
  | Webrtc
  | Local

let from_env () =
  match Env_config.Transport.agent_transport_opt () with
  | Some Env_config.Transport.Grpc -> Grpc
  | Some Env_config.Transport.Http -> Http
  | Some Env_config.Transport.Ws -> Ws
  | Some Env_config.Transport.Webrtc -> Webrtc
  | Some Env_config.Transport.Local -> Local
  | Some (Env_config.Transport.Unknown_agent_transport _) | None -> Local
;;

let to_string = function
  | Http -> "http"
  | Grpc -> "grpc"
  | Ws -> "ws"
  | Webrtc -> "webrtc"
  | Local -> "local"
;;
