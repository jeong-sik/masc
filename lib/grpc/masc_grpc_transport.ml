(** MASC Agent Transport — protocol selection for MASC coordination. *)

type t =
  | Http
  | Grpc
  | Local

let from_env () =
  match Sys.getenv_opt "MASC_AGENT_TRANSPORT" with
  | Some "grpc" -> Grpc
  | Some "http" -> Http
  | Some "local" -> Local
  | _ -> Local

let to_string = function
  | Http -> "http"
  | Grpc -> "grpc"
  | Local -> "local"
