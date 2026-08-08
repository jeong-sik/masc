(** MASC Agent Transport — protocol selection for MASC workspace. *)

type t =
  | Http
  | Grpc
  | Ws
  | Webrtc
  | Local

let of_env_value raw =
  match raw with
  | "http" -> Http
  | "grpc" -> Grpc
  | "ws" -> Ws
  | "webrtc" -> Webrtc
  | "local" -> Local
  | _ ->
    raise
      (Env_config_core.Config_error
         (Printf.sprintf
            "malformed env MASC_AGENT_TRANSPORT=%S (expected http|grpc|ws|webrtc|local)"
            raw))
;;

let read_env () =
  match Sys.getenv_opt "MASC_AGENT_TRANSPORT" with
  | None -> Local
  | Some raw -> of_env_value raw
;;

let configured = Atomic.make None

let rec configure_from_env () =
  match Atomic.get configured with
  | Some transport -> transport
  | None ->
    let transport = read_env () in
    if Atomic.compare_and_set configured None (Some transport)
    then transport
    else configure_from_env ()
;;

let from_env () =
  match Atomic.get configured with
  | Some transport -> transport
  | None -> read_env ()
;;

let to_string = function
  | Http -> "http"
  | Grpc -> "grpc"
  | Ws -> "ws"
  | Webrtc -> "webrtc"
  | Local -> "local"
;;
